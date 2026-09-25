#!/usr/bin/env bash
# refresh-biocache-fields.sh restarts a biocache-hub whose search page 500s (the
# <alatag:message> NPE) once records-ws serves fields. #411 showed data hubs need it too:
# la_biocache-hub-testhub stayed at 500 while the portal was restarted back to 200.
# docker and curl are stubbed; each hub's search page answers 500 until it is restarted.
set -eu
cd "$(dirname "$0")/.."
script="$PWD/scripts/refresh-biocache-fields.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"

cat > "$tmp/targets.json" <<'JSON'
{"services": {"records": "https://records.test", "recordsWs": "https://records-ws.test"},
 "hubs": [{"key": "testhub", "services": {"records": "https://hub.test/records/"}},
          {"key": "nohere", "services": {"records": "https://other.test/records"}},
          {"key": "specieshub", "services": {"species": "https://hub.test/species"}}]}
JSON

# Running containers: the service, the portal hub and testhub's hub. nohere lives elsewhere.
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
state="$tmp/state"
case "\$1" in
  inspect) name="\${@: -1}"
           case "\$name" in la_biocache-service|la_biocache-hub|la_biocache-hub-testhub) echo true ;; *) exit 1 ;; esac ;;
  compose) echo "\$3" >> "\$state/restarted" ;;   # compose restart <service>
  restart) echo "\$2" >> "\$state/restarted-docker" ;;
esac
EOF

cat > "$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
state="$tmp/state"
url="\${@: -1}"
restarted() { grep -qx "\$1" "\$state/restarted" 2>/dev/null; }
case "\$url" in
  https://records-ws.test/index/fields) echo '[{"name":"a"},{"name":"b"}]' ;;
  https://records-ws.test/occurrences/search*) echo '{"totalRecords": 8}' ;;
  https://records.test/occurrences/search*) restarted biocache-hub && echo 200 || echo 500 ;;
  https://hub.test/records/occurrences/search*) restarted biocache-hub-testhub && echo 200 || echo 500 ;;
  *) echo "unexpected curl \$url" >> "\$state/unexpected"; echo 000 ;;
esac
EOF
chmod +x "$tmp/bin/docker" "$tmp/bin/curl"

fail=0
out=$(PATH="$tmp/bin:$PATH" TARGETS_FILE="$tmp/targets.json" POLL_INTERVAL=0 TIMEOUT=5 bash "$script" 2>&1) || {
  echo "[FAIL] script exited non-zero:"; echo "$out"; fail=1; }

restarted=$(sort "$tmp/state/restarted" 2>/dev/null | tr '\n' ' ')
[[ "$restarted" == "biocache-hub biocache-hub-testhub " ]] || {
  echo "[FAIL] expected restarts of biocache-hub and biocache-hub-testhub, got: '${restarted}'"; fail=1; }
grep -q "no la_biocache-hub-nohere on this host" <<<"$out" || {
  echo "[FAIL] a hub whose container is elsewhere must be skipped, not restarted"; fail=1; }
[[ ! -s "$tmp/state/unexpected" ]] || { echo "[FAIL] unexpected URLs:"; cat "$tmp/state/unexpected"; fail=1; }

# Second run: everything already serves 200, so nothing is restarted again.
: > "$tmp/state/restarted.before"; cp "$tmp/state/restarted" "$tmp/state/restarted.before"
PATH="$tmp/bin:$PATH" TARGETS_FILE="$tmp/targets.json" POLL_INTERVAL=0 TIMEOUT=5 bash "$script" >/dev/null 2>&1
cmp -s "$tmp/state/restarted" "$tmp/state/restarted.before" || {
  echo "[FAIL] a hub already serving 200 was restarted again"; fail=1; }

[[ $fail -eq 0 ]] || { echo "$out"; exit 1; }
echo "[PASS] refresh-biocache-fields restarts the portal and data-hub biocache-hubs that 500, and only those"
