#!/usr/bin/env bash
# GeoServer >= 2.27 refuses the file: URL spatial-service sends in PUT .../external.shp unless a URL check
# allows it (400 "Failed to locate the input file"): geoserver-init.sh.j2 must create that rule, only when it
# is missing, and the regex must match what GeoServer actually checks (URL.toString() -> file:/path).
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
# fake curl: $EXIST_CHECK=1 -> the URL check exists (200), else 404; every call is logged
cat > "$T/bin/curl" <<'F'
#!/usr/bin/env bash
args="$*"; echo "$args" >> "$LOG"
if [[ "$args" == *"-w"* ]]; then
  [[ "$args" == *"/rest/urlchecks/la-compose-data"* && "${EXIST_CHECK:-0}" == 1 ]] && { printf 200; exit 0; }
  printf 404
fi
F
chmod +x "$T/bin/curl"
LOG="$T/log" EXIST_CHECK=0 PATH="$T/bin:$PATH" bash "$T/init.sh" >"$T/out" 2>&1
grep -q -- '-XPOST.*regexUrlCheck.*rest/urlchecks' "$T/log" && ok "missing check is created" || ko "missing check is created"
rx=$(sed -n 's|.*<regex>\(.*\)</regex>.*|\1|p' "$T/log" | head -1)
[ -n "$rx" ] && ok "regex extracted: $rx" || ko "regex extracted"
for u in file:/data/spatial-data/uploads/1/1.shp file:///data/spatial-data/uploads/1/1.shp file:/data/geoserver_data_dir/data/x.tif; do
  python3 -c "import re,sys; sys.exit(0 if re.fullmatch(sys.argv[1], sys.argv[2]) else 1)" "$rx" "$u" && ok "allowed: $u" || ko "allowed: $u"
done
for u in file:/etc/passwd file:/data/other/x.shp file:/data/spatial-data/../../etc/passwd.x http://example.org/data/spatial-data/x; do
  python3 -c "import re,sys; sys.exit(1 if re.fullmatch(sys.argv[1], sys.argv[2]) else 0)" "$rx" "$u" && ok "refused: $u" || ko "refused: $u"
done
: > "$T/log"; LOG="$T/log" EXIST_CHECK=1 PATH="$T/bin:$PATH" bash "$T/init.sh" >"$T/out" 2>&1
grep -q 'regexUrlCheck' "$T/log" && ko "existing check untouched" || ok "existing check untouched"
exit $fail
