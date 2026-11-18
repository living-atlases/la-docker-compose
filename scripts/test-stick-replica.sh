#!/usr/bin/env bash
# Prueba scripts/experiments/stick-replica.sh con CONTENEEDORES DE VERDAD, pero en un
# proyecto compose de juguete: dos replicas sin container_name que imitan la forma del
# servicio real (puerto de servicio 9179, admin de Dropwizard 9180, healthcheck contra
# localhost:9180) detras de un nginx con el patron del portal y el drop-in de replicas.
#
# Lo que afirma, que es lo que el AC#4 de TASK-115 necesita antes de tocar un portal:
#  1. encuentra las replicas por etiqueta (no por nombre: con replicas>1 no hay uno)
#  2. la victima contesta 5xx DESDE LA RED y sigue CORRIENDO, con el mismo PID (ni pause
#     ni senales: eso es lo que el criterio excluye)
#  3. el healthcheck del compose la pasa a unhealthy (es la unica senal de autoheal)
#  4. la-autoheal, tal como se instala, la reiniciaria (y no toca otro proyecto compose)
#  5. con el drop-in puesto, el trafico por el nginx del "portal" no se cae
#  6. clear deja las reglas, el contenedor auxiliar y el proyecto como estaban
#
# Necesita docker y docker compose. No deja nada: trap de limpieza y --rm.
set -u
cd "$(dirname "$0")/.."
SCRIPT="scripts/experiments/stick-replica.sh"
P="sticktest$$"
T=$(mktemp -d); chmod 700 "$T"
FRONT_PORT="${FRONT_PORT:-$((19000 + ($$ % 900)))}"
fail=0
pass() { echo -e "\033[0;32m[PASS]\033[0m $*"; }
bad()  { echo -e "\033[0;31m[FAIL]\033[0m $*"; fail=1; }

cleanup() {
  docker rm -f la_sick_nm >/dev/null 2>&1
  (cd "$T" && docker compose -p "$P" down -v >/dev/null 2>&1)
  (cd "$T/otro" && docker compose -p "${P}otro" down -v >/dev/null 2>&1)
  rm -f /tmp/.stick-replica.nm.target
  rm -rf "$T"
}
trap cleanup EXIT

# El backend de juguete: contesta como el servicio real en 9179 (un JSON con
# scientificName, que es lo que el chequeo de gatus exige) y expone 9180 como admin.
cat > "$T/nm.conf" <<'EOF'
server {
  listen 9179;
  location / { default_type application/json; return 200 '{"success":true,"scientificName":"Acacia dealbata"}'; }
}
server {
  listen 9180;
  location /healthcheck { default_type application/json; return 200 '{"ok":true}'; }
}
EOF

# El nginx de delante, con el patron que el portal emite de verdad: resolver de docker,
# proxy_pass con variable y cero bloques upstream. El drop-in va en conf.d a nivel http,
# como lo despliega el rol (nginx.conf incluye conf.d/*.conf dentro de http).
cat > "$T/front.conf" <<'EOF'
server {
  listen 80;
  resolver 127.0.0.11 valid=30s ipv6=off;
  location / {
    set $backend "http://nm:9179";
    proxy_read_timeout 10m;
    proxy_pass $backend$request_uri;
  }
}
EOF
cat > "$T/00-replicas.conf" <<'EOF'
proxy_connect_timeout 1s;
proxy_next_upstream error timeout http_502 http_503 http_504;
EOF

cat > "$T/docker-compose.yml" <<EOF
services:
  nm:
    image: nginx:1.30-alpine
    volumes: ["$T/nm.conf:/etc/nginx/conf.d/default.conf:ro"]
    healthcheck:
      # Como el real: curl desde DENTRO del contenedor contra el puerto de admin.
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://localhost:9180/healthcheck || exit 1"]
      interval: 3s
      timeout: 3s
      retries: 1
    deploy: {replicas: 2}
  front:
    image: nginx:1.30-alpine
    ports: ["127.0.0.1:${FRONT_PORT}:80"]
    volumes:
      - "$T/front.conf:/etc/nginx/conf.d/default.conf:ro"
      - "$T/00-replicas.conf:/etc/nginx/conf.d/00-replicas.conf:ro"
EOF

# Un segundo proyecto en el mismo host, para comprobar que nada se lo lleva por delante.
mkdir -p "$T/otro"
cat > "$T/otro/docker-compose.yml" <<EOF
services:
  ajeno:
    image: nginx:1.30-alpine
    healthcheck: {test: ["CMD-SHELL", "exit 1"], interval: 3s, timeout: 2s, retries: 1}
EOF

echo "== levantando el proyecto de juguete ($P, front en 127.0.0.1:$FRONT_PORT) =="
(cd "$T" && docker compose -p "$P" up -d --quiet-pull) >/dev/null 2>&1 || { echo "no pude levantar el proyecto"; exit 1; }
(cd "$T/otro" && docker compose -p "${P}otro" up -d) >/dev/null 2>&1
for _ in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FRONT_PORT/api/search?q=Acacia")" = "200" ] && break
  sleep 1
done
# Y esperar a que el healthcheck haya corrido: con health=starting el paso 3 no mediria
# nada (el salto a unhealthy ya habria pasado por si solo).
for _ in $(seq 1 30); do
  [ "$(docker ps --filter "label=com.docker.compose.project=$P" --filter "label=com.docker.compose.service=nm" --filter health=healthy -q | grep -c .)" -eq 2 ] && break
  sleep 2
done

export LA_SR_COMPOSE_DIR="$T" LA_SR_SERVICE=nm LA_SR_PROJECT="$P"
export LA_SR_URL="http://127.0.0.1:$FRONT_PORT/api/search?q=Acacia"
IMG=$(bash "$SCRIPT" image) || { echo "no hay imagen auxiliar"; exit 1; }

echo
echo "== 1. status: dos replicas por etiqueta, ambas a 200 =="
out=$(bash "$SCRIPT" status 2>&1); echo "$out" | sed 's/^/    /'
if [ "$(printf '%s\n' "$out" | grep -c 'HTTP 9179=200')" -eq 2 ]; then
  pass "encuentra las 2 replicas por etiqueta y las dos contestan 200"
else
  bad "no ve dos replicas sanas"
fi
if printf '%s\n' "$out" | grep -E '^ +la_' | grep -q 'HTTP'; then
  bad "los nombres de replica casan con ^la_: no se esta probando el caso sin container_name"
else
  pass "las replicas no casan con ^la_ (sin container_name, como en el portal replicado)"
fi
nh=$(docker ps --filter "label=com.docker.compose.project=$P" --filter "label=com.docker.compose.service=nm" --filter health=healthy -q | grep -c .)
[ "$nh" -eq 2 ] && pass "las dos arrancan healthy (la linea base del paso 3 vale)" || bad "esperaba 2 healthy antes de inyectar, hay $nh"

echo
echo "== 2. inject: una replica a 503, viva y con el mismo PID =="
victim=$(docker ps --filter "label=com.docker.compose.project=$P" --filter "label=com.docker.compose.service=nm" --format '{{.ID}}' | head -1)
pid_before=$(docker inspect -f '{{.State.Pid}}' "$victim")
out=$(bash "$SCRIPT" inject 2>&1); echo "$out" | sed 's/^/    /'
code=$(docker run --rm --network "${P}_default" $IMG \
        curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$(docker inspect -f '{{(index .NetworkSettings.Networks "'"${P}"'_default").IPAddress}}' "$victim"):9179/api/search?q=Acacia" 2>/dev/null)
[ "$code" = "503" ] && pass "la victima contesta 503 desde la red" || bad "esperaba 503 desde la red, dio '$code'"
st=$(docker inspect -f '{{.State.Status}}' "$victim")
pid_after=$(docker inspect -f '{{.State.Pid}}' "$victim")
[ "$st" = "running" ] && pass "sigue corriendo (status=$st)" || bad "deberia seguir corriendo, esta '$st'"
[ "$pid_before" = "$pid_after" ] && pass "mismo PID ($pid_after): ni pause ni senales, el proceso no se ha tocado" \
  || bad "el PID cambio ($pid_before -> $pid_after): el proceso se reinicio"
other=$(docker ps --filter "label=com.docker.compose.project=$P" --filter "label=com.docker.compose.service=nm" --format '{{.ID}}' | tail -1)
ocode=$(docker run --rm --network "${P}_default" $IMG \
        curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$(docker inspect -f '{{(index .NetworkSettings.Networks "'"${P}"'_default").IPAddress}}' "$other"):9179/" 2>/dev/null)
[ "$ocode" = "200" ] && pass "la otra replica sigue a 200 (el netns compartido no se contagia)" || bad "la otra replica dio '$ocode'"

echo
echo "== 3. el healthcheck la pasa a unhealthy =="
health=""
for _ in $(seq 1 30); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$victim"); [ "$health" = "unhealthy" ] && break; sleep 2
done
[ "$health" = "unhealthy" ] && pass "unhealthy: autoheal tiene senal" || bad "sigue '$health': autoheal no se enteraria"

echo
echo "== 4. la-autoheal (como se instala) la reiniciaria, y no toca otro proyecto =="
mkdir -p "$T/state"
out=$(LA_AUTOHEAL_STATE="$T/state" LA_AUTOHEAL_DEFAULTS=/dev/null \
      LA_AUTOHEAL_COMPOSE_DIR="$T" LA_AUTOHEAL_DEPLOY_MARKER="$T/nohay" \
      bash roles/la-compose/files/la-autoheal/la-autoheal --dry-run 2>&1)
printf '%s\n' "$out" | sed 's/^/    /'
printf '%s\n' "$out" | grep -q "would restart ${P}-nm" \
  && pass "la ve por la etiqueta de compose y la reiniciaria" || bad "autoheal NO ve la replica atascada"
printf '%s\n' "$out" | grep -q "would restart ${P}otro" \
  && bad "toca contenedores de otro proyecto compose" || pass "no toca el otro proyecto del mismo host"

echo
echo "== 5. measure: con el drop-in, el trafico no se cae =="
out=$(bash "$SCRIPT" measure 60 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ $rc -eq 0 ] && pass "error <= 1% con una replica atascada (el drop-in hace su trabajo)" \
  || bad "el trafico se cae con una replica atascada"

echo
echo "== 6. clear no deja nada =="
out=$(bash "$SCRIPT" clear 2>&1); echo "$out" | sed 's/^/    /'
docker ps -a --format '{{.Names}}' | grep -qx la_sick_nm && bad "el auxiliar sigue ahi" || pass "auxiliar borrado"
code=""
for _ in $(seq 1 20); do
  code=$(docker run --rm --network "${P}_default" $IMG \
          curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$(docker inspect -f '{{(index .NetworkSettings.Networks "'"${P}"'_default").IPAddress}}' "$victim"):9179/" 2>/dev/null)
  [ "$code" = "200" ] && break; sleep 2
done
[ "$code" = "200" ] && pass "la victima vuelve a 200 sin reiniciarla" || bad "sigue sin contestar bien (HTTP '$code')"
h=""
for _ in $(seq 1 15); do h=$(docker inspect -f '{{.State.Health.Status}}' "$victim"); [ "$h" = "healthy" ] && break; sleep 2; done
[ "$h" = "healthy" ] && pass "y vuelve a healthy sola" || bad "se queda en '$h' despues de clear"

echo
echo "== 7. recuperacion: un restart (lo que hace autoheal) borra las reglas con el auxiliar puesto =="
# La otra mitad del AC#4, y el caso raro del diseno: la-autoheal hace `docker restart`
# (la-autoheal:134) de un contenedor cuyo netns tiene cogido el auxiliar. El netns se
# recrea, asi que las reglas se van solas -- pero el auxiliar se queda en el netns viejo y
# hay que comprobar que ni impide el restart ni deja el servicio roto.
out=$(bash "$SCRIPT" inject 2>&1); echo "$out" | sed 's/^/    /'
rules_before=$(docker exec la_sick_nm iptables -t nat -S PREROUTING 2>/dev/null | grep -c REDIRECT)
[ "${rules_before:-0}" -ge 2 ] && pass "reglas puestas otra vez ($rules_before)" || bad "no veo las reglas antes del restart"
docker restart "$victim" >/dev/null 2>&1 || bad "docker restart fallo con el auxiliar en el netns"
h=""
for _ in $(seq 1 30); do h=$(docker inspect -f '{{.State.Health.Status}}' "$victim"); [ "$h" = "healthy" ] && break; sleep 2; done
[ "$h" = "healthy" ] && pass "la victima vuelve a healthy tras el restart" || bad "despues del restart sigue '$h'"
code=""
for _ in $(seq 1 15); do
  ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "'"${P}"'_default").IPAddress}}' "$victim")
  code=$(docker run --rm --network "${P}_default" $IMG curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${ip}:9179/" 2>/dev/null)
  [ "$code" = "200" ] && break; sleep 2
done
[ "$code" = "200" ] && pass "y contesta 200: el restart se llevo las reglas, no hubo que deshacerlas" \
  || bad "despues del restart sigue sin contestar bien (HTTP '$code')"
out=$(bash "$SCRIPT" clear 2>&1); echo "$out" | sed 's/^/    /'
docker ps -a --format '{{.Names}}' | grep -qx la_sick_nm && bad "el auxiliar huerfano sigue ahi" \
  || pass "clear borra el auxiliar aunque su netns ya no exista"

echo
if [ "$fail" -eq 0 ]; then echo "Todo en verde."; else echo "HAY FALLOS."; fi
exit "$fail"
