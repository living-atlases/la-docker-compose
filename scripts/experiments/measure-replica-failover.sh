#!/usr/bin/env bash
# Mide que le pasa al trafico de un servicio replicado detras del patron de nginx
# que la-docker-compose emite HOY: 'resolver 127.0.0.11 valid=30s' mas un
# proxy_pass con variable y SIN bloque upstream (nginx_load_balancing es false,
# asi que ala-install/.../nginx_vhost/templates/fragment_02_upstream.j2 no se
# renderiza nunca y el portal renderizado tiene cero bloques upstream).
#
# Por que existe (TASK-112): hacen falta numeros, no intuicion, para decidir si
# replicar un servicio sin estado mejora o empeora la disponibilidad. El modo de
# fallo que importa en este stack no es el contenedor parado, es la JVM viva pero
# atascada, que docker NUNCA retira del DNS porque el contenedor no para.
#
# No toca el portal: levanta su propio proyecto compose con nginx y backends de
# juguete. Uso: scripts/experiments/measure-replica-failover.sh [puerto]
# Tarda ~3 min. Necesita docker y docker compose. No esta en CI a proposito.
set -u
PORT="${1:-18099}"
P=lareplicas
T=$(mktemp -d); chmod 700 "$T"
cleanup() {
  docker compose -p $P -f "$T/base.yml" -f "$T/sick.yml" down -v >/dev/null 2>&1 || true
  docker compose -p ${P}cn -f "$T/cn.yml" down -v >/dev/null 2>&1 || true
  echo "logs y configs del banco: $T  (borralo tu cuando acabes)"
}
trap cleanup EXIT

cat > "$T/web.conf" <<'EOF'
server { listen 9180; location / { default_type text/plain; return 200 "$hostname\n"; } }
EOF
# Viva pero enferma: el contenedor CORRE y responde, pero da error. Es lo que hace
# una JVM atascada, y es el caso para el que existe autoheal.
cat > "$T/sick.conf" <<'EOF'
server { listen 9180; location / { default_type text/plain; return 503 "SICK\n"; } }
EOF
front() { # $1 = directivas extra dentro del location
cat > "$T/front.conf" <<EOF
server {
  listen 80;
  location / {
    resolver 127.0.0.11 valid=30s ipv6=off;
    set \$backend_proto "http";
    set \$backend_host "web";
    set \$backend_port "9180";
$1
    proxy_pass \$backend_proto://\$backend_host:\$backend_port;
  }
}
EOF
docker compose -p $P -f "$T/base.yml" restart front >/dev/null 2>&1
}
cat > "$T/base.yml" <<EOF
services:
  web:
    image: nginx:1.30-alpine
    volumes: ["$T/web.conf:/etc/nginx/conf.d/default.conf:ro"]
    networks: [internal]
  front:
    image: nginx:1.30-alpine
    ports: ["127.0.0.1:$PORT:80"]
    volumes: ["$T/front.conf:/etc/nginx/conf.d/default.conf:ro"]
    networks: [internal]
networks: {internal: {}}
EOF
cat > "$T/sick.yml" <<EOF
services:
  sick:
    image: nginx:1.30-alpine
    volumes: ["$T/sick.conf:/etc/nginx/conf.d/default.conf:ro"]
    networks: {internal: {aliases: [web]}}
EOF
printf 'services:\n  w:\n    image: nginx:1.30-alpine\n    container_name: la_w\n' > "$T/cn.yml"

dc() { docker compose -p $P -f "$T/base.yml" "$@"; }
dcs() { docker compose -p $P -f "$T/base.yml" -f "$T/sick.yml" "$@"; }
hit() { curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null || echo CURLFAIL; }
load() { local end=$(( $(date +%s) + $1 )) t0=$(date +%s%3N); : > "$2"
  while [ "$(date +%s)" -lt "$end" ]; do echo "$(( $(date +%s%3N) - t0 + $3 )) $(hit)" >> "$2"; done; }
pct() { awk -v l="$1" '{t++; if($2!="200")b++} END{printf "  %-46s %5d/%-5d con error  %5.1f%%\n", l, b+0, t, (b*100.0)/t}' "$2"; }

echo "== CONTROL: compose se niega a escalar con container_name =="
docker compose -p ${P}cn -f "$T/cn.yml" up -d --scale w=2 2>&1 | grep -i 'custom container name' | sed 's/^/  /' \
  || echo "  SIN AVISO: comprobar, el comportamiento de compose ha cambiado"
docker compose -p ${P}cn -f "$T/cn.yml" down -v >/dev/null 2>&1

echo
echo "== REPARTO entre 3 replicas sanas (el mecanismo ya existe) =="
front ""; dc up -d --scale web=3 >/dev/null 2>&1
for i in $(seq 1 60); do curl -s --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null; done \
  | sort | uniq -c | sort -rn | sed 's/^/  /'

echo
echo "== JVM ATASCADA (viva, responde 503): replicar MEJORA o EMPEORA? =="
echo "   la comparacion honesta es contra UNA sola replica atascada, no contra cero fallos"
dcs up -d sick >/dev/null 2>&1
dc up -d --scale web=0 >/dev/null 2>&1; front ""; load 25 "$T/m1" 0
pct "A) 1 replica, y esta atascada (hoy, sin replicar)" "$T/m1"
dc up -d --scale web=2 >/dev/null 2>&1; front ""; load 30 "$T/m2" 0
pct "B) 3 replicas, 1 atascada, como esta hoy nginx" "$T/m2"
front "    proxy_connect_timeout 1s;
    proxy_read_timeout 5s;
    proxy_next_upstream error timeout http_502 http_503 http_504;"
load 30 "$T/m3" 0
pct "C) idem + proxy_next_upstream (sin bloque upstream)" "$T/m3"

echo
echo "== REPLICA PARADA LIMPIAMENTE (docker stop), el caso benigno =="
dcs rm -sf sick >/dev/null 2>&1; dc up -d --scale web=3 >/dev/null 2>&1
front "    proxy_connect_timeout 1s;
    proxy_next_upstream error timeout http_502 http_503 http_504;"
load 10 "$T/d1" 0; EV=$(tail -1 "$T/d1" | cut -d' ' -f1)
docker stop ${P}-web-2 >/dev/null 2>&1
load 40 "$T/d2" "$EV"; cat "$T/d1" "$T/d2" > "$T/d"
awk -v ev="$EV" '{if($1>=ev){q++; if($2!="200"){qb++; if(!f)f=$1; l=$1}}}
  END{printf "  D) tras la parada, con next_upstream   %5d/%-5d con error  %5.1f%%\n",qb+0,q+0,(qb*100.0)/q
      if(qb)printf "     los fallos duran hasta +%.1fs (la cache valid=30s del resolver)\n",(l-ev)/1000
      else  print  "     ningun fallo"}' "$T/d"
echo
echo "RECORDATORIO: autoheal selecciona por nombre (^la_, LA_AUTOHEAL_MATCH en"
echo "roles/la-compose/files/la-autoheal/la-autoheal). Sin container_name el"
echo "contenedor pasa a <proyecto>-<servicio>-N y autoheal DEJA de recuperarlo."
