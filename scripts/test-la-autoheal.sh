#!/usr/bin/env bash
# roles/la-compose/files/la-autoheal/la-autoheal (docker_autoheal) with a fake docker and
# logger: no host, no root. The settings file is the role's real template rendered with the
# role defaults, so a quoting slip in it (the dependent regex) breaks this test too.
#   1. nothing unhealthy: no restart;          6. only la_* containers;
#   2. biocache-service before the hubs;      7. application probes (3 strikes, reset, 000);
#   3. 10 min grace between restarts;          8. --dry-run restarts nothing (nor counts probes);
#   4. the hub once biocache-service is fine;  9. a data hub instance (la_bie-hub-<hub>) waits too;
#   5. at most 3 restarts an hour, then ERROR; 10. a deploy in progress (fresh marker) is left alone,
#                                                  a stale one (dead deploy) is not.
# ~5s.
set -u
cd "$(dirname "$0")/.."
SCRIPT="$PWD/roles/la-compose/files/la-autoheal/la-autoheal"
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
PYARG='ansible_python_interpreter={{ ansible_playbook_python }}'
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
fail=0
ok()  { echo "[PASS] $1"; }
bad() { echo "[FAIL] $1" >&2; fail=1; }

# The role's settings file, rendered from the real template and defaults.
cat >"$T/play.yml" <<YML
- hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - $PWD/roles/la-compose/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/roles/la-compose/templates/la-autoheal/la-autoheal.default.j2
        dest: $T/role-defaults
YML
ANSIBLE_LOCALHOST_WARNING=false "$ANSIBLE_PLAYBOOK" -i localhost, -e "$PYARG" "$T/play.yml" \
  -e "docker_autoheal_deploy_marker=$T/deploy.marker" >"$T/render.log" 2>&1 ||
  { cat "$T/render.log" >&2; echo "[FAIL] the settings template did not render" >&2; exit 1; }
bash -n "$T/role-defaults" || { echo "[FAIL] the rendered settings are not valid shell" >&2; exit 1; }
cp "$T/role-defaults" "$T/defaults"

# fake docker: state in $T/unhealthy (names), $T/healthy (names), $T/code.<c> (probe http code)
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
T=${FAKE_T}
case "$1" in
  ps) cat "$T/unhealthy" 2>/dev/null ;;
  inspect) c=${!#}; grep -qx "$c" "$T/healthy" 2>/dev/null && echo healthy || echo unhealthy ;;
  exec) c=$2; cat "$T/code.$c" 2>/dev/null || echo 200 ;;
  restart) echo "$2" >> "$T/restarts" ;;
esac
EOF
printf '#!/bin/bash\nshift 2; echo "$*" >> "%s/log"\n' "$T" > "$T/bin/logger"
chmod +x "$T/bin/"*

run() { # run <now> [--dry-run]
  : > "$T/restarts"
  FAKE_T=$T PATH="$T/bin:$PATH" LA_AUTOHEAL_STATE="$T/state" LA_AUTOHEAL_DEFAULTS="$T/defaults" \
    LA_AUTOHEAL_NOW="$1" bash "$SCRIPT" ${2:-}
}
restarted() { sort "$T/restarts" | tr '\n' ' ' | sed 's/ $//'; }

grep -q "^LA_AUTOHEAL_GRACE=600$" "$T/defaults" && grep -q "^LA_AUTOHEAL_MAX=3$" "$T/defaults" &&
  ok "role defaults: 600 s grace, 3 restarts an hour" || bad "role defaults: $(grep -E 'GRACE|MAX=' "$T/defaults")"

# 1. nothing unhealthy
: > "$T/unhealthy"; : > "$T/healthy"
run 100000; [ -z "$(restarted)" ] && ok "nothing unhealthy, no restart" || bad "restarted with nothing unhealthy: $(restarted)"

# 2. biocache-service and bie-hub unhealthy: only biocache-service; bie-hub waits
printf 'la_biocache-service\nla_bie-hub\n' > "$T/unhealthy"
run 100000; [ "$(restarted)" = "la_biocache-service" ] && ok "biocache-service first, the hub waits" || bad "order: $(restarted)"
grep -q "la_bie-hub unhealthy: waiting for la_biocache-service" "$T/log" && ok "the wait is logged" || bad "the wait is not logged"

# 3. within the grace period, no second restart
run 100100; [ -z "$(restarted)" ] && ok "10 min grace respected" || bad "restarted within the grace: $(restarted)"

# 4. biocache-service fine now: the hub
printf 'la_bie-hub\n' > "$T/unhealthy"
run 100200; [ "$(restarted)" = "la_bie-hub" ] && ok "hub restarted once biocache-service is healthy" || bad "hub: $(restarted)"

# 5. at most 3 an hour
printf 'la_regions\n' > "$T/unhealthy"
run 200000; run 200700; run 201400; run 202100
n=$(grep -c "restarting la_regions" "$T/log"); [ "$n" = 3 ] && ok "at most 3 restarts an hour" || bad "regions restarts: $n"
grep -q "ERROR la_regions still unhealthy after 3" "$T/log" && ok "ERROR logged at the cap" || bad "no ERROR at the cap"
run 205000; [ "$(restarted)" = "la_regions" ] && ok "after the hour it tries again" || bad "after the hour: $(restarted)"

# 6. names outside ^la_ are not touched
printf 'cadvisor\n' > "$T/unhealthy"
run 300000; [ -z "$(restarted)" ] && ok "only la_* containers" || bad "touched another container: $(restarted)"

# 7. probe: healthy but 500 -> restarted on the 3rd pass; a 200 resets the count
: > "$T/unhealthy"; echo la_biocache-hub > "$T/healthy"
{ cat "$T/role-defaults"; printf "LA_AUTOHEAL_PROBES='\nla_biocache-hub http://localhost:8080/occurrences/search?q=*:*\n'\n"; } > "$T/defaults"
echo 500 > "$T/code.la_biocache-hub"
run 400000; a=$(restarted); run 400060; b=$(restarted); run 400120; c=$(restarted)
[ -z "$a$b" ] && [ "$c" = "la_biocache-hub" ] && ok "probe: restart after 3 failures in a row" || bad "probe: '$a' '$b' '$c'"
echo 500 > "$T/code.la_biocache-hub"; run 401000; echo 200 > "$T/code.la_biocache-hub"; run 401060
echo 500 > "$T/code.la_biocache-hub"; run 401120; run 401180
[ -z "$(restarted)" ] && ok "probe: a 200 resets the count" || bad "probe not reset: $(restarted)"
rm -f "$T/state/la_biocache-hub.probe"; echo 000 > "$T/code.la_biocache-hub"; run 402000; run 402060; run 402120
[ "$(restarted)" = "la_biocache-hub" ] && ok "probe: no answer counts as a failure" || bad "probe 000: $(restarted)"
# a dry run of a failing probe reports the attempt but does not count it (seen on gbif.es: a
# --dry-run took the count from 1 to 2 of 3)
rm -f "$T/state/"*; echo 500 > "$T/code.la_biocache-hub"; run 403000
out=$(run 403060 --dry-run); out2=$(run 403070 --dry-run)
[ "$(cat "$T/state/la_biocache-hub.probe")" = 1 ] && echo "$out$out2" | grep -q "(2 of 3)" && ! echo "$out2" | grep -q "(3 of 3)" &&
  ok "probe: --dry-run reports the attempt but leaves the count" || bad "dry-run probe count: $(cat "$T/state/la_biocache-hub.probe") / $out / $out2"
cp "$T/role-defaults" "$T/defaults"; : > "$T/healthy"

# 8. --dry-run restarts nothing
printf 'la_regions\n' > "$T/unhealthy"; rm -f "$T/state/"*
out=$(run 500000 --dry-run)
[ ! -s "$T/restarts" ] && echo "$out" | grep -q "(dry) would restart la_regions" && ok "--dry-run restarts nothing" || bad "dry-run: $out / $(restarted)"

# 9. a data hub instance waits for biocache-service like the portal's hub
printf 'la_biocache-service\nla_bie-hub-testhub\nla_biocache-hub-testhub\n' > "$T/unhealthy"; rm -f "$T/state/"*
run 600000; [ "$(restarted)" = "la_biocache-service" ] && ok "data hub instances wait for biocache-service" || bad "hub instances: $(restarted)"

# 10. deploy marker: fresh -> nothing; stale (a deploy that died) -> acts again
printf 'la_regions\n' > "$T/unhealthy"; rm -f "$T/state/"*
touch "$T/deploy.marker"
run 700000; [ -z "$(restarted)" ] && ok "a deploy in progress is left alone" || bad "acted during a deploy: $(restarted)"
touch -d '7 hours ago' "$T/deploy.marker"
run 700000; [ "$(restarted)" = "la_regions" ] && ok "a stale deploy marker stops blocking" || bad "stale marker: $(restarted)"

exit $fail
