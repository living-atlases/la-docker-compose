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
# juguete. Necesita docker y docker compose.
#
# Uso:
#   measure-replica-failover.sh [puerto]           mide y describe, ~3 min, no falla nunca
#   measure-replica-failover.sh --check [puerto]   CHECK del CI: mide A, B, D y autoheal,
#                                                  compara contra umbrales y sale != 0, ~2 min
# LA_BENCH_PROJECT fija el nombre del proyecto compose (por defecto lareplicas), para que dos
# builds en el mismo agente no choquen.
#
# El modo --check se salta los casos C (directivas en el location, informativo: el drop-in
# se despliega a nivel http) y E (replica parada limpiamente, que no admite umbral porque
# los fallos duran lo que la cache valid=30s del resolver). Umbrales abajo, en CHECK.
set -u
CHECK=""
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
PORT="${1:-18099}"
# El nombre del proyecto compose y el puerto se pueden fijar desde fuera: dos builds a la vez
# en el mismo agente del CI chocarian con un nombre y un puerto fijos, y el check saldria
# rojo por el choque y no por el drop-in.
P="${LA_BENCH_PROJECT:-lareplicas}"
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
# $3 (opcional) = clave; deja el porcentaje en $T/pct.<clave> para los umbrales de --check.
pct() { awk -v l="$1" -v k="${3:-}" -v d="$T" '{t++; if($2!="200")b++}
  END{printf "  %-46s %5d/%-5d con error  %5.1f%%\n", l, b+0, t, (b*100.0)/t
      if (k != "") printf "%.4f\n", (b*100.0)/t > (d "/pct." k)}' "$2"; }

echo "== CONTROL: compose se niega a escalar con container_name =="
if docker compose -p ${P}cn -f "$T/cn.yml" up -d --scale w=2 2>&1 | grep -i 'custom container name' | sed 's/^/  /'; then
  : > "$T/control.ok"
else
  echo "  SIN AVISO: comprobar, el comportamiento de compose ha cambiado"
fi
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
pct "A) 1 replica, y esta atascada (hoy, sin replicar)" "$T/m1" A
dc up -d --scale web=2 >/dev/null 2>&1; front "" ""; load 30 "$T/m2" 0
pct "B) 3 replicas, 1 atascada, como esta hoy nginx" "$T/m2" B
if [ -z "$CHECK" ]; then
  front "$RETRY" ""; load 30 "$T/m3" 0
  pct "C) idem, directivas en el location" "$T/m3"
fi
front "" "$RETRY"; load 30 "$T/m4" 0
pct "D) idem, directivas en http (el drop-in que se despliega)" "$T/m4" D

if [ -z "$CHECK" ]; then
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
fi
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
if [ "$n" -ge 2 ]; then
  echo "  OK autoheal recuperaria las $n replicas por la etiqueta de compose"; : > "$T/heal.ok"
else
  echo "  FALLA autoheal NO las ve:"; printf '%s\n' "$out" | sed 's/^/    /'
fi
# Y que no se lleva por delante contenedores de otro proyecto compose del mismo host.
if printf '%s\n' "$out" | grep -q "would restart ${P}-"; then
  echo "  FALLA toca contenedores de otro proyecto compose"
else
  echo "  OK no toca los del proyecto $P, que tiene otro working_dir"; : > "$T/scope.ok"
fi
docker compose -p ${P}heal -f "$T/heal.yml" down -v >/dev/null 2>&1

echo
echo "NOTA: sin container_name el contenedor pasa a <proyecto>-<servicio>-N, que no casa"
echo "con el ^la_ con el que autoheal seleccionaba. Por eso la-autoheal anade ahora los"
echo "contenedores etiquetados con com.docker.compose.project.working_dir (test:"
echo "scripts/test-la-autoheal.sh, caso 6b)."

# ---------------------------------------------------------------------------
# CHECK del CI (--check). Los umbrales son anchos a proposito: lo que tiene que
# fallar es que el drop-in deje de servir, no que la maquina vaya cargada.
#   A >= 50  una sola replica y atascada: casi todo falla. Mide que el banco mide.
#   B >= 10  el problema existe sin el drop-in (medido ~34% con 1 de 3 atascada).
#   D <=  1  con el drop-in no falla nada (medido 0 de 2083 y 0 de 2076).
#   D <  B   y el drop-in tiene que mejorarlo, no solo quedar bajo el umbral.
# Mas los tres veredictos binarios: el aviso de compose, autoheal viendo las dos
# replicas por la etiqueta, y autoheal NO tocando otro proyecto del mismo host.
# ---------------------------------------------------------------------------
[ -n "$CHECK" ] || exit 0

echo
echo "== CHECK =="
fail=0
say() { echo "  $1"; }
num() { [ -s "$T/pct.$1" ] && cat "$T/pct.$1" || echo ""; }
thr() { # $1=clave $2=operador $3=umbral $4=texto
  local v; v=$(num "$1")
  if [ -z "$v" ]; then say "FAIL $1 no se midio ($4)"; fail=1; return; fi
  if awk -v v="$v" -v t="$3" "BEGIN{exit !(v $2 t)}"; then
    say "PASS $4 ($1 = $v%)"
  else
    say "FAIL $4 ($1 = $v%, se esperaba $2 $3)"; fail=1
  fi
}
flag() { # $1=fichero $2=texto
  if [ -e "$T/$1" ]; then say "PASS $2"; else say "FAIL $2"; fail=1; fi
}

flag control.ok "compose se niega a escalar un servicio con container_name, y lo avisa"
thr A ">=" 50 "una sola replica atascada falla casi todo: el banco mide de verdad"
thr B ">=" 10 "sin el drop-in, una replica atascada se come parte del trafico"
thr D "<=" 1  "con el drop-in a nivel http no falla practicamente nada"
a=$(num B); b=$(num D)
if [ -n "$a" ] && [ -n "$b" ] && awk -v a="$a" -v b="$b" 'BEGIN{exit !(b < a)}'; then
  say "PASS el drop-in mejora lo que habia (D $b% < B $a%)"
else
  say "FAIL el drop-in no mejora lo que habia (D ${b:-?}% vs B ${a:-?}%)"; fail=1
fi
flag heal.ok  "autoheal ve las dos replicas sin container_name por la etiqueta de compose"
flag scope.ok "autoheal no toca los contenedores de otro proyecto compose del mismo host"

echo
if [ "$fail" -eq 0 ]; then echo "  CHECK OK"; else echo "  CHECK FALLA"; fi
exit "$fail"
