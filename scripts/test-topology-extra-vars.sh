#!/usr/bin/env bash
#
# test-topology-extra-vars.sh — the Jenkinsfile's topologyExtraVars() helper, run for real.
#
# A placement may carry an optional "extra_vars" map (today only topologies/1host-replicas,
# with namematching_service_replicas and docker_nginx_replica_failover). 'Resolve topology'
# flattens it to key=value pairs in TOPOLOGY_EXTRA_VARS and topologyExtraVars() parses them
# back into the map that goes to ansible as --extra-vars JSON.
#
# Why this is worth a test: the types. ansible reads that JSON typed, and the role compares
# `namematching_service_replicas | int` in an assert and reads
# `docker_nginx_replica_failover | bool` in a `when:`. A string "2" or "false" coming out of
# this helper would deploy a portal that differs from the one the placement asked for, three
# hours into a build. And an empty TOPOLOGY_EXTRA_VARS must give an EMPTY map, which is what
# keeps the default 3-host build byte-identical (TASK-115, criterion 5).
#
# The function is SLICED OUT OF THE REAL Jenkinsfile, not copied here, so this cannot pass
# against a helper that no longer exists or was edited.
#
# Usage: bash scripts/test-topology-extra-vars.sh    Exits 0 if every assertion holds.
# Needs the same groovy jar + java as scripts/check-jenkinsfile.sh; skips (0) without them.
set -uo pipefail
cd "$(dirname "$0")/.."

GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
FAILURES=0
pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*" >&2; FAILURES=$((FAILURES + 1)); }

find_groovy_jar() {
  for j in "${GROOVY_JAR:-}" \
           "$HOME/.m2/repository/org/codehaus/groovy/groovy/3.0.3/groovy-3.0.3.jar" \
           "$HOME/.sdkman/candidates/groovy/current/lib/groovy-"*.jar; do
    [[ -n "$j" && -f "$j" ]] && { printf '%s\n' "$j"; return 0; }
  done
  find "$HOME/.m2" "$HOME/.sdkman" -name 'groovy-[0-9]*.jar' 2>/dev/null | head -1
}
JAR="$(find_groovy_jar)"
[[ -n "$JAR" ]] || { echo "WARNING: no groovy jar; skipping (see scripts/check-jenkinsfile.sh)." >&2; exit 0; }
JAVA_CMD="${JAVA_CMD:-}"
if [[ -z "$JAVA_CMD" ]]; then
  for c in "$HOME/.sdkman/candidates/java/11"*/bin/java "$HOME/.sdkman/candidates/java/17"*/bin/java java; do
    [[ -x "$c" || "$c" == java ]] && { JAVA_CMD="$c"; break; }
  done
fi
command -v "$JAVA_CMD" >/dev/null 2>&1 || [[ -x "$JAVA_CMD" ]] || {
  echo "WARNING: no java; skipping." >&2; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The helper, straight out of the Jenkinsfile.
awk '/^def topologyExtraVars\(\) \{/{p=1} p{print} p && /^\}/{exit}' Jenkinsfile > "$WORK/helper.groovy"
if ! grep -q 'def topologyExtraVars' "$WORK/helper.groovy"; then
  fail "topologyExtraVars() is not in the Jenkinsfile any more (or was renamed)"
  exit 1
fi
pass "topologyExtraVars() sliced out of the real Jenkinsfile ($(wc -l < "$WORK/helper.groovy") lines)"

# What the placement itself yields, through the SAME python the Jenkinsfile runs.
PAIRS="$(python3 -c "import json; d = json.load(open('topologies/1host-replicas.placement.json')).get('extra_vars', {}); print(','.join('%s=%s' % (k, str(v).lower() if isinstance(v, bool) else v) for k, v in d.items()))")"

{
  echo 'env = [:]'  # binding, not a script local: a method cannot see a local
  cat "$WORK/helper.groovy"
  cat <<GROOVY
// Rendered by hand, with the same groovy jar as scripts/check-jenkinsfile.sh and nothing
// else on the classpath: groovy-json is a separate jar and mixing versions is its own
// failure. What is under test is the TYPES in the map; JsonOutput's rendering of an
// Integer or a Boolean is not in question.
def asJson
asJson = { v -> v instanceof String ? '"' + v + '"'
                : v instanceof Map ? '{' + v.collect { k, x -> '"' + k + '":' + asJson(x) }.join(',') + '}'
                : String.valueOf(v) }
def check = { String name, Object got, Object want ->
    println((got == want && got.getClass() == want.getClass() ? "OK   " : "BAD  ") +
            name + ": got " + asJson(got) + " (" + got.getClass().simpleName + ")")
}
env.TOPOLOGY_EXTRA_VARS = null
check("unset gives an empty map", topologyExtraVars(), [:])
env.TOPOLOGY_EXTRA_VARS = '   '
check("blank gives an empty map", topologyExtraVars(), [:])
env.TOPOLOGY_EXTRA_VARS = '${PAIRS}'
def m = topologyExtraVars()
check("the placement's replicas is an Integer", m.namematching_service_replicas, 2)
check("the placement's drop-in flag is a Boolean", m.docker_nginx_replica_failover, true)
println("JSON " + asJson(m))
env.TOPOLOGY_EXTRA_VARS = 'a=false,b=-3,c=some-string,d=,=x,nonsense'
def n = topologyExtraVars()
check("false is a Boolean, not a truthy string", n.a, false)
check("a negative number is an Integer", n.b, -3)
check("anything else stays a String", n.c, "some-string")
println("KEYS " + n.keySet().join(","))
GROOVY
} > "$WORK/Test.groovy"

OUT="$("$JAVA_CMD" -cp "$JAR" groovy.ui.GroovyMain "$WORK/Test.groovy" 2>&1)" || {
  fail "the helper did not run:"; printf '%s\n' "$OUT" >&2; exit 1; }

while IFS= read -r line; do
  case "$line" in
    "OK   "*) pass "${line#OK   }" ;;
    "BAD  "*) fail "${line#BAD  }" ;;
  esac
done <<< "$OUT"

# The JSON that reaches ansible: numbers and booleans unquoted, or `| int` and `| bool` see
# strings. This is the line that would make a three-hour build deploy the wrong portal.
# (Rendered from the map's own types, see the note in the groovy above.)
json="$(printf '%s\n' "$OUT" | sed -n 's/^JSON //p')"
if [[ "$json" == *'"namematching_service_replicas":2'* && "$json" == *'"docker_nginx_replica_failover":true'* ]]; then
  pass "--extra-vars JSON keeps them unquoted: $json"
else
  fail "--extra-vars JSON would quote them: $json"
fi

# A pair with no value, no key, or no '=' at all is dropped rather than passed to ansible.
keys="$(printf '%s\n' "$OUT" | sed -n 's/^KEYS //p')"
if [[ "$keys" == "a,b,c,d" ]]; then
  pass "an empty value is kept, and a keyless or '='-less pair is dropped: $keys"
else
  fail "malformed pairs are not handled as expected: $keys"
fi

# The default topology must contribute nothing at all (criterion 5).
for t in topologies/*.placement.json; do
  name="$(basename "$t" .placement.json)"
  [[ "$name" == "1host-replicas" ]] && continue
  if [[ -n "$(python3 -c "import json; print(','.join(json.load(open('$t')).get('extra_vars', {})))")" ]]; then
    fail "$name declares extra_vars: the only variant meant to is 1host-replicas"
  fi
done
[[ "$FAILURES" -eq 0 ]] && pass "no other topology declares extra_vars (the default build is untouched)"

echo
if [[ "$FAILURES" -eq 0 ]]; then echo "All checks passed."; else echo "$FAILURES check(s) failed." >&2; fi
exit $((FAILURES > 0))
