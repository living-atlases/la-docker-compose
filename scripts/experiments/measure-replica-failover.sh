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
# Lo que anade el drop-in de conf.d (roles/la-compose/templates/nginx-replicas.conf.j2).
# Sin read_timeout: bajarlo a nivel global cortaria las descargas largas del portal,
# que es justo para lo que el location pone 10m.
RETRY='proxy_connect_timeout 1s;
proxy_next_upstream error timeout http_502 http_503 http_504;' 
cleanup() {
  docker compose -p $P -f "$T/base.yml" -f "$T/sick.yml" down -v >/dev/null 2>&1 || true
  docker compose -p ${P}cn -f "$T/cn.yml" down -v >/dev/null 2>&1
  docker compose -p ${P}heal -f "$T/heal.yml" down -v >/dev/null 2>&1 || true || true
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
# $1 = directivas dentro del location; $2 = directivas a nivel http, que es como se
# despliegan de verdad: un drop-in en conf.d, que nginx.conf incluye DENTRO de http
# (ala-install/.../nginx/templates/nginx.conf.j2:89-90) y antes de sites-enabled.
# El location lleva siempre proxy_read_timeout 10m porque es lo que pone el portal
# (fragment_73_location.j2:98-101) y un location gana al http que lo contiene.
front() {
cat > "$T/http.conf" <<EOF
${2:-}
EOF
cat > "$T/front.conf" <<EOF
server {
  listen 80;
  location / {
    resolver 127.0.0.11 valid=30s ipv6=off;
    proxy_read_timeout 10m;
    set \$backend_proto "http";
    set \$backend_host "web";
    set \$backend_port "9180";
${1:-}
    proxy_pass \$backend_proto://\$backend_host:\$backend_port;
  }
}
EOF
docker compose -p $P -f "$T/base.yml" restart front >/dev/null 2>&1
# Solo cuando front ya existe: la primera llamada es antes del primer up.
if [ -n "$(docker compose -p $P -f "$T/base.yml" ps -q front 2>/dev/null)" ]; then
  docker compose -p $P -f "$T/base.yml" exec -T front nginx -t 2>&1 | grep -q "syntax is ok" \
    || echo "  AVISO: nginx -t NO pasa con esta configuracion"
fi
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
    volumes:
      - "$T/front.conf:/etc/nginx/conf.d/default.conf:ro"
      - "$T/http.conf:/etc/nginx/conf.d/00-replicas.conf:ro"
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
: > "$T/http.conf"
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
dc up -d --scale web=0 >/dev/null 2>&1; front "" ""; load 25 "$T/m1" 0
pct "A) 1 replica, y esta atascada (hoy, sin replicar)" "$T/m1"
dc up -d --scale web=2 >/dev/null 2>&1; front "" ""; load 30 "$T/m2" 0
pct "B) 3 replicas, 1 atascada, como esta hoy nginx" "$T/m2"
front "$RETRY" ""; load 30 "$T/m3" 0
pct "C) idem, directivas en el location" "$T/m3"
front "" "$RETRY"; load 30 "$T/m4" 0
pct "D) idem, directivas en http (el drop-in que se despliega)" "$T/m4"

echo
echo "== REPLICA PARADA LIMPIAMENTE (docker stop), el caso benigno =="
dcs rm -sf sick >/dev/null 2>&1; dc up -d --scale web=3 >/dev/null 2>&1
front "" "$RETRY"
load 10 "$T/d1" 0; EV=$(tail -1 "$T/d1" | cut -d' ' -f1)
docker stop ${P}-web-2 >/dev/null 2>&1
load 40 "$T/d2" "$EV"; cat "$T/d1" "$T/d2" > "$T/d"
awk -v ev="$EV" '{if($1>=ev){q++; if($2!="200"){qb++; if(!f)f=$1; l=$1}}}
  END{printf "  E) tras la parada, con el drop-in      %5d/%-5d con error  %5.1f%%\n",qb+0,q+0,(qb*100.0)/q
      if(qb)printf "     los fallos duran hasta +%.1fs (la cache valid=30s del resolver)\n",(l-ev)/1000
      else  print  "     ningun fallo"}' "$T/d"
echo
echo
echo "== AUTOHEAL contra replicas DE VERDAD (no el docker de mentira del test) =="
# El unico sitio donde se puede comprobar que el selector nuevo funciona con contenedores
# reales: etiquetas de compose reales, nombres <proyecto>-<servicio>-N reales y el script
# tal cual se instala. El test unitario usa un docker falso, asi que esto es complementario.
cat > "$T/heal.yml" <<EOF
services:
  enferma:
    image: nginx:1.30-alpine
    volumes: ["$T/sick.conf:/etc/nginx/conf.d/default.conf:ro"]
    healthcheck:
      test: ["CMD-SHELL", "exit 1"]
      interval: 2s
      timeout: 2s
      retries: 1
    deploy: {replicas: 2}
EOF
docker compose -p ${P}heal -f "$T/heal.yml" up -d >/dev/null 2>&1
for _ in $(seq 1 20); do
  [ "$(docker ps --filter health=unhealthy --filter "label=com.docker.compose.project.working_dir=$T" -q | grep -c .)" -ge 2 ] && break
  sleep 1
done
names=$(docker ps --filter "label=com.docker.compose.project.working_dir=$T"   --filter name=enferma --format '{{.Names}}' | sort | tr '\n' ' ')
echo "  contenedores sin container_name: $names"
case "$names" in *_*) echo "  OJO: casan con ^la_, el caso no se esta probando" ;; esac
mkdir -p "$T/state"
out=$(LA_AUTOHEAL_STATE="$T/state" LA_AUTOHEAL_DEFAULTS=/dev/null       LA_AUTOHEAL_COMPOSE_DIR="$T" LA_AUTOHEAL_DEPLOY_MARKER="$T/nohay"       bash roles/la-compose/files/la-autoheal/la-autoheal --dry-run 2>&1)
n=$(printf '%s\n' "$out" | grep -c "would restart ${P}heal-enferma")
[ "$n" -ge 2 ]   && echo "  OK autoheal recuperaria las $n replicas por la etiqueta de compose"   || { echo "  FALLA autoheal NO las ve:"; printf '%s\n' "$out" | sed 's/^/    /'; }
# Y que no se lleva por delante contenedores de otro proyecto compose del mismo host.
printf '%s\n' "$out" | grep -q "would restart ${P}-"   && echo "  FALLA toca contenedores de otro proyecto compose"   || echo "  OK no toca los del proyecto $P, que tiene otro working_dir"
docker compose -p ${P}heal -f "$T/heal.yml" down -v >/dev/null 2>&1

echo
echo "NOTA: sin container_name el contenedor pasa a <proyecto>-<servicio>-N, que no casa"
echo "con el ^la_ con el que autoheal seleccionaba. Por eso la-autoheal anade ahora los"
echo "contenedores etiquetados con com.docker.compose.project.working_dir (test:"
echo "scripts/test-la-autoheal.sh, caso 6b)."
