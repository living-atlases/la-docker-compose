#!/usr/bin/env bash
# Atasca UNA replica de un servicio replicado de un portal DESPLEGADO: la deja viva,
# corriendo y escuchando, pero respondiendo 5xx. Es el modo de fallo que docker nunca
# retira del DNS (el contenedor no para) y el unico para el que existen el drop-in de
# nginx y la-autoheal. TASK-115 AC#4.
#
# Por que no sirve el banco (scripts/experiments/measure-replica-failover.sh): ese
# levanta su PROPIO proyecto compose con nginx de juguete, pega a 127.0.0.1 y su
# cleanup() hace `docker compose down -v` del proyecto que se le pase. Apuntarlo a un
# portal lo destruiria. Este script, al contrario, no crea ni borra nada del portal: solo
# anade un contenedor auxiliar al NETNS de una replica y le quita las reglas al acabar.
#
# Como atasca sin `docker pause` ni `kill -STOP` (que es justo lo que el criterio excluye,
# porque congelan el proceso en vez de dejarlo contestar mal):
#   - un contenedor auxiliar comparte el netns de la replica (--network container:<id>)
#     y sirve un 503 constante en :19179;
#   - dentro de ese netns, iptables redirige a ese 503 el puerto del servicio (9179, que
#     es por donde entra nginx) y el del admin de Dropwizard (9180, que es a donde pega
#     el healthcheck del compose, `curl --fail http://localhost:9180/healthcheck`).
#     Sin redirigir 9180 el contenedor seguiria healthy y autoheal no tendria nada que
#     ver: health=unhealthy es su unica senal (mas las etiquetas de compose, que es como
#     encuentra replicas sin container_name).
#   El JVM sigue vivo, escuchando y sin recibir una sola senal. Lo que ve nginx es un 5xx.
#
# Las reglas viven en el netns de la replica, asi que un restart del contenedor las borra
# solas: la recuperacion es observable sin deshacer nada a mano.
#
# Uso (en el HOST desplegado, con docker):
#   stick-replica.sh status                 que replicas hay y que contesta cada una
#   stick-replica.sh inject                 atasca una (la primera, o LA_SR_TARGET)
#   stick-replica.sh measure [n]            n peticiones por el nginx del portal, % de error
#   stick-replica.sh clear                  quita las reglas y el contenedor auxiliar
#   stick-replica.sh marker-age | marker-now  envejece/restaura el marcador de deploy
#
# El marcador: la-autoheal sale callado mientras /run/la-compose-deploy.marker tenga menos
# de docker_autoheal_deploy_marker_max_age_min (360) minutos, asi que recien desplegado el
# experimento mediria un autoheal dormido. `marker-age` lo envejece para que el timer (cada
# minuto) actue de verdad; `marker-now` lo deja como estaba.
set -u

SERVICE="${LA_SR_SERVICE:-namematching-service}"
PORT="${LA_SR_PORT:-9179}"
ADMIN_PORT="${LA_SR_ADMIN_PORT:-9180}"
SICK_PORT="${LA_SR_SICK_PORT:-19179}"
COMPOSE_DIR="${LA_SR_COMPOSE_DIR:-/data/docker-compose}"
# Imagen del auxiliar: necesita iptables, socat y curl YA DENTRO. Nada de `apk add` en el
# netns de la replica: la red `internal` del portal puede no tener salida, y el experimento
# fallaria por eso y no por lo que mide. Se construye aqui a partir de alpine (el build y
# el pull pasan en el host, con su salida, no en ese netns), para no depender de que una
# imagen de terceros este disponible en la maquina del CI.
SICK_IMAGE="${LA_SR_SICK_IMAGE:-la-stick-replica:local}"
SICK_BASE="${LA_SR_SICK_BASE:-alpine:3.22}"
SICK_NAME="${LA_SR_SICK_NAME:-la_sick_${SERVICE}}"
MARKER="${LA_SR_MARKER:-/run/la-compose-deploy.marker}"
# Que se considera una respuesta buena. El mismo par (ruta, condicion) que el chequeo
# `namematching search` del grupo Deep checks de gatus, que es la senal de portal real:
# un 200 con `success:false` no vale, porque un indice que no se descargo contesta eso.
PATH_Q="${LA_SR_PATH:-/api/search?q=Acacia}"
MATCH="${LA_SR_MATCH:-scientificName}"
VHOST="${LA_SR_VHOST:-}"
REQUESTS="${LA_SR_REQUESTS:-200}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

# Deja lista la imagen del auxiliar y escribe su nombre. Si ya esta, no hace nada; si es
# una imagen de terceros, la baja; si es la local, la construye desde alpine.
ensure_image() {
  if docker image inspect "$SICK_IMAGE" >/dev/null 2>&1; then printf '%s\n' "$SICK_IMAGE"; return; fi
  if [ "$SICK_IMAGE" != "la-stick-replica:local" ]; then
    docker pull "$SICK_IMAGE" >/dev/null 2>&1 || die "no puedo bajar $SICK_IMAGE"
    printf '%s\n' "$SICK_IMAGE"; return
  fi
  local d; d=$(mktemp -d)
  {
    echo "FROM $SICK_BASE"
    echo "RUN apk add --no-cache iptables socat curl"
  } > "$d/Dockerfile"
  docker build -q -t "$SICK_IMAGE" "$d" >/dev/null 2>&1 || { rm -rf "$d"; die "no puedo construir $SICK_IMAGE desde $SICK_BASE"; }
  rm -rf "$d"
  printf '%s\n' "$SICK_IMAGE"
}

command -v docker >/dev/null || die "no hay docker aqui; este script corre en el host desplegado"

# El proyecto compose: se deduce del directorio donde corre `docker compose up`, que es la
# misma etiqueta por la que la-autoheal encuentra las replicas. Asi no hay que acertar el
# nombre del proyecto a mano.
project() {
  if [ -n "${LA_SR_PROJECT:-}" ]; then printf '%s\n' "$LA_SR_PROJECT"; return; fi
  docker ps --filter "label=com.docker.compose.project.working_dir=${COMPOSE_DIR%/}" \
            --format '{{.Label "com.docker.compose.project"}}' | sort -u | head -1
}

# Replicas por ETIQUETA, nunca por nombre: con replicas > 1 la plantilla quita el
# container_name, asi que `la_namematching_service` no existe.
replicas() {
  local p; p=$(project)
  [ -n "$p" ] || die "no encuentro ningun proyecto compose con working_dir=$COMPOSE_DIR"
  docker ps --filter "label=com.docker.compose.project=$p" \
            --filter "label=com.docker.compose.service=$SERVICE" \
            --format '{{.ID}} {{.Names}}'
}

# Red del portal por la que nginx llega al servicio, para poder sondear desde fuera del
# contenedor (desde dentro, una regla de OUTPUT no prueba el camino real).
net_of() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" | awk '{print $1}'
}
ip_of() {
  local net; net=$(net_of "$1")
  docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$1"
}

# Codigo HTTP de una replica vista DESDE LA RED, que es como la ve nginx.
probe() {
  local cid="$1" net ip img
  net=$(net_of "$cid"); ip=$(ip_of "$cid"); img=$(ensure_image)
  docker run --rm --network "$net" "$img" \
    curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${ip}:${PORT}${PATH_Q}" 2>/dev/null
}

cmd_status() {
  local p; p=$(project)
  echo "proyecto compose: $p   (working_dir=$COMPOSE_DIR)"
  local n=0
  while read -r cid name; do
    [ -n "${cid:-}" ] || continue
    n=$((n + 1))
    local health code
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")
    code=$(probe "$cid")
    info "$name  id=${cid:0:12}  health=$health  restarts=$(docker inspect -f '{{.RestartCount}}' "$cid")  HTTP ${PORT}=${code:-sin respuesta}"
  done <<EOF
$(replicas)
EOF
  echo "replicas de $SERVICE: $n"
  if docker ps -a --format '{{.Names}}' | grep -qx "$SICK_NAME"; then
    echo "auxiliar $SICK_NAME: PRESENTE (hay una replica atascada)"
  else
    echo "auxiliar $SICK_NAME: ausente"
  fi
  [ "$n" -ge 2 ] || echo "AVISO: con menos de 2 replicas atascar una deja el servicio sin nadie; inject se negara"
}

sidecar_cmd() {
  cat <<'SH'
set -e
cat > /tmp/503.sh <<'EOS'
#!/bin/sh
printf 'HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\nSICK\n'
EOS
chmod +x /tmp/503.sh
# Primero el que contesta, despues las reglas: al contrario, entre una cosa y la otra las
# conexiones se rechazarian (RST), que es otro modo de fallo y no el que se quiere medir.
socat -T5 TCP-LISTEN:__SICK__,reuseaddr,fork EXEC:/tmp/503.sh &
sleep 1
for p in __PORT__ __ADMIN__; do
  # PREROUTING: lo que entra por la veth, o sea nginx y cualquier consumidor del stack.
  iptables -t nat -A PREROUTING -p tcp --dport "$p" -j REDIRECT --to-port __SICK__
  # OUTPUT sobre lo: el healthcheck del compose, que corre DENTRO del contenedor contra
  # localhost y no pasa por PREROUTING. Sin esto el contenedor seguiria healthy.
  iptables -t nat -A OUTPUT -o lo -p tcp --dport "$p" -j REDIRECT --to-port __SICK__
done
echo STUCK
wait
SH
}

cmd_inject() {
  docker ps -a --format '{{.Names}}' | grep -qx "$SICK_NAME" \
    && die "$SICK_NAME ya existe: ya hay una replica atascada (clear primero)"
  local list; list=$(replicas)
  local n; n=$(printf '%s\n' "$list" | grep -c .)
  [ "$n" -ge 2 ] || die "hay $n replica(s) de $SERVICE; atascar una dejaria el servicio sin nadie"
  local cid name
  if [ -n "${LA_SR_TARGET:-}" ]; then
    cid=$(printf '%s\n' "$list" | awk -v t="$LA_SR_TARGET" '$2==t || index($1,t)==1 {print $1; exit}')
    [ -n "$cid" ] || die "LA_SR_TARGET=$LA_SR_TARGET no esta entre las replicas"
  else
    cid=$(printf '%s\n' "$list" | awk 'NR==1{print $1}')
  fi
  name=$(docker inspect -f '{{.Name}}' "$cid" | sed 's|^/||')
  info "replicas: $n   victima: $name (${cid:0:12})"
  local img; img=$(ensure_image) || exit 1
  local cmd
  cmd=$(sidecar_cmd | sed -e "s/__SICK__/$SICK_PORT/g" -e "s/__PORT__/$PORT/g" -e "s/__ADMIN__/$ADMIN_PORT/g")
  docker run -d --name "$SICK_NAME" --network "container:$cid" \
    --cap-add NET_ADMIN --cap-add NET_RAW "$img" sh -c "$cmd" >/dev/null \
    || die "no puedo arrancar el auxiliar en el netns de $name"
  # Esperar a que el 5xx se vea DESDE LA RED, no desde dentro.
  local code=""
  for _ in $(seq 1 20); do
    code=$(probe "$cid"); [ "$code" = "503" ] && break; sleep 1
  done
  [ "$code" = "503" ] || { docker logs "$SICK_NAME" 2>&1 | sed 's/^/    /'; die "la replica no contesta 503 (HTTP=${code:-nada})"; }
  info "$name contesta 503 en $PORT y $ADMIN_PORT, y SIGUE corriendo: $(docker inspect -f '{{.State.Status}} pid={{.State.Pid}}' "$cid")"
  info "el healthcheck tardara ~$(docker inspect -f '{{if .Config.Healthcheck}}{{.Config.Healthcheck.Interval}}x{{.Config.Healthcheck.Retries}}{{else}}?{{end}}' "$cid") en pasar a unhealthy"
  printf '%s\n' "$cid" > "/tmp/.stick-replica.${SERVICE}.target"
}

# URL por la que medir. Por defecto el nginx del PORTAL en este host, con --resolve para
# que el SNI y el Host sean los de verdad: eso ejercita el vhost real y sus locations de
# resolucion dinamica sin depender del proxy frontal externo.
measure_url() {
  if [ -n "${LA_SR_URL:-}" ]; then printf '%s\n' "$LA_SR_URL"; return; fi
  [ -n "$VHOST" ] || die "no se con que vhost medir: pasa LA_SR_VHOST=namematching.l-a.site o LA_SR_URL"
  printf 'https://%s%s\n' "$VHOST" "$PATH_Q"
}

cmd_measure() {
  local n="${1:-$REQUESTS}" url; url=$(measure_url)
  local resolve=()
  if [ -z "${LA_SR_URL:-}" ]; then resolve=(--resolve "${VHOST}:443:127.0.0.1"); fi
  local ok=0 bad=0 nomatch=0 codes=""
  local i body code
  for i in $(seq 1 "$n"); do
    body=$(curl -sk -m 10 "${resolve[@]}" -w '\n%{http_code}' "$url" 2>/dev/null)
    code=$(printf '%s' "$body" | tail -1)
    if [ "$code" = "200" ]; then
      if printf '%s' "$body" | grep -q "$MATCH"; then ok=$((ok + 1)); else nomatch=$((nomatch + 1)); fi
    else
      bad=$((bad + 1)); codes="$codes $code"
    fi
  done
  echo "peticiones=$n  ok=$ok  error=$bad  200-sin-$MATCH=$nomatch"
  awk -v b="$bad" -v m="$nomatch" -v n="$n" 'BEGIN{printf "  error = %.2f%%  (umbral del banco con el drop-in: <= 1%%)\n", (b+m)*100/n}'
  [ -n "$codes" ] && echo "  codigos no-200:$(printf '%s' "$codes" | tr ' ' '\n' | sort | uniq -c | awk '{printf " %sx%s", $1, $2}')"
  echo "  url: $url"
  # El % es el veredicto del AC#4: con el drop-in puesto, una replica atascada no debe
  # comerse trafico (en el banco de juguete: 0% con el drop-in, ~33% sin el).
  awk -v b="$bad" -v m="$nomatch" -v n="$n" 'BEGIN{exit ((b+m)*100/n > 1) ? 1 : 0}'
}

cmd_clear() {
  local cid=""
  [ -f "/tmp/.stick-replica.${SERVICE}.target" ] && cid=$(cat "/tmp/.stick-replica.${SERVICE}.target")
  if docker ps --format '{{.Names}}' | grep -qx "$SICK_NAME"; then
    # Borrar EXACTAMENTE las reglas puestas, no vaciar la tabla: el netns es compartido
    # con la replica y un -F se llevaria lo que docker haya puesto ahi.
    for p in "$PORT" "$ADMIN_PORT"; do
      docker exec "$SICK_NAME" iptables -t nat -D PREROUTING -p tcp --dport "$p" -j REDIRECT --to-port "$SICK_PORT" 2>/dev/null
      docker exec "$SICK_NAME" iptables -t nat -D OUTPUT -o lo -p tcp --dport "$p" -j REDIRECT --to-port "$SICK_PORT" 2>/dev/null
    done
    info "reglas quitadas"
  fi
  docker rm -f "$SICK_NAME" >/dev/null 2>&1 && info "auxiliar $SICK_NAME borrado"
  rm -f "/tmp/.stick-replica.${SERVICE}.target"
  # Si autoheal reinicio la replica, el netns se recreo y las reglas ya no estaban: nada
  # que deshacer. Se comprueba igual que vuelve a contestar.
  if [ -n "$cid" ] && docker inspect "$cid" >/dev/null 2>&1; then
    local code=""
    for _ in $(seq 1 30); do code=$(probe "$cid"); [ "$code" = "200" ] && break; sleep 2; done
    info "la victima contesta HTTP ${code:-nada} (restarts=$(docker inspect -f '{{.RestartCount}}' "$cid"))"
  fi
  cmd_status
}

cmd_marker_age() {
  [ -e "$MARKER" ] || die "no existe $MARKER (sin marcador, autoheal ya actua)"
  cp -p "$MARKER" "${MARKER}.stick-replica.bak" 2>/dev/null || true
  touch -d '7 hours ago' "$MARKER" || die "no puedo tocar $MARKER (root?)"
  info "$MARKER envejecido a $(date -r "$MARKER" '+%F %T'): autoheal (cada minuto) ya puede actuar"
}

cmd_marker_now() {
  touch "$MARKER" || die "no puedo tocar $MARKER"
  rm -f "${MARKER}.stick-replica.bak"
  info "$MARKER puesto en ahora: autoheal vuelve a callarse $((360 / 60)) h"
}

case "${1:-}" in
  image) ensure_image ;;
  status) cmd_status ;;
  inject) cmd_inject ;;
  measure) shift; cmd_measure "${1:-}" ;;
  clear) cmd_clear ;;
  marker-age) cmd_marker_age ;;
  marker-now) cmd_marker_now ;;
  *) sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
