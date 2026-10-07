#!/usr/bin/env bash
# Renders geoserver-init.sh.j2 and drives the fallback-layers section against a fake curl.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fail=0
ok(){ echo "ok   $1"; }; ko(){ echo "FAIL $1"; fail=1; }
python3 - "$T" <<'PY' || { echo "FAIL render"; exit 1; }
import sys, jinja2
s = open("roles/la-compose/templates/geoserver-init.sh.j2").read()
open(sys.argv[1] + "/init.sh", "w").write(jinja2.Environment().from_string(s).render())
PY
bash -n "$T/init.sh" && ok "rendered script parses" || ko "rendered script parses"
mkdir "$T/bin"
# fake curl: layers listed in $EXIST answer 200, everything else 404; every POST is logged
cat > "$T/bin/curl" <<'F'
#!/usr/bin/env bash
args="$*"; echo "$args" >> "$LOG"
if [[ "$args" == *"-w"* ]]; then
  for l in $EXIST; do [[ "$args" == *"/rest/layers/ALA:$l"* ]] && { printf 200; exit 0; }; done
  printf 404
fi
F
chmod +x "$T/bin/curl"
cp "$T/init.sh" "$T/run.sh"
printf 'mcp_demo_ccaa cl1\nexisting_layer cl2\nbad;name cl3\n' > "$T/fallback-layers.txt"
LOG="$T/log" EXIST="existing_layer" PATH="$T/bin:$PATH" bash "$T/run.sh" >"$T/out" 2>&1
grep -q 'featuretypes' "$T/log" && grep -q 'fallback-mcp_demo_ccaa.xml' "$T/log" && ok "missing layer is published" || ko "missing layer is published"
grep -q 'fallback-existing_layer.xml' "$T/log" && ko "existing layer untouched" || ok "existing layer untouched"
grep -q 'unsafe name' "$T/out" && ok "unsafe name skipped" || ko "unsafe name skipped"
grep -q "fid = 'cl1'" "$T/fallback-mcp_demo_ccaa.xml" && ok "sql view filters by fid" || ko "sql view filters by fid"
rm -f "$T/fallback-layers.txt" "$T/log"; LOG="$T/log" EXIST="" PATH="$T/bin:$PATH" bash "$T/run.sh" >"$T/out" 2>&1
grep -q 'fallback-' "$T/log" && ko "no list, no fallback" || ok "no list, no fallback"
exit $fail
