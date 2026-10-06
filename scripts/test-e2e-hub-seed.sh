#!/usr/bin/env bash
# The e2e ingest must put its dataResource in every data hub the deployment serves, or the
# hub front-ends (hub.l-a.site...) query records-ws with qc=data_hub_uid:dhN and show "No
# records found": no map, no species, no regions. A fresh collectory has no data hubs, so the
# harness creates them (collectory assigns dh1, dh2... itself) and adds the dataResource to
# memberDataResources, a JSON list encoded as a STRING. Runs the program embedded in
# e2e-airflow-ingest.sh against a stand-in collectory, so what is tested is what ships.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
fail=0
ok()  { printf '[PASS] %s\n' "$1"; }
bad() { printf '[FAIL] %s\n' "$1" >&2; fail=1; }

# the python the harness runs, between its heredoc markers
sed -n "/^  IFS= read -r -d '' HUB_SEED_PY/,/^PY\$/p" scripts/e2e-airflow-ingest.sh | sed '1d;$d' > "$tmp/seed.py"
[ -s "$tmp/seed.py" ] || { echo "[FAIL] hub seeding program not found in e2e-airflow-ingest.sh" >&2; exit 1; }

# `docker exec <container> curl <args>` -> the stand-in
cat > "$tmp/collectory.py" <<'PY'
import json, os, sys
st = os.path.join(os.path.dirname(os.path.abspath(__file__)), "state.json")
S = json.load(open(st)) if os.path.exists(st) else {"hubs": {}, "refuse_update": False}
a = sys.argv[1:]
m, url = a[a.index("-X") + 1], a[-1]
body = json.loads(a[a.index("-d") + 1]) if "-d" in a else None
path = url.split("/ws", 1)[1]
def out(code, hdr="", b=""):
    sys.stdout.write("HTTP/1.1 %d X\r\n%s\r\n%s" % (code, hdr, b)); json.dump(S, open(st, "w"))
if m == "GET" and path.startswith("/dataHub/"):
    u = path.split("/")[-1]
    out(200, "", json.dumps({"uid": u, "memberDataResources": [{"uid": x} for x in S["hubs"][u]]})) if u in S["hubs"] else out(404)
elif m == "POST" and path == "/dataHub":
    u = "dh%d" % (len(S["hubs"]) + 1); S["hubs"][u] = []; out(201, "Location: https://c/ws/dataHub/%s\r\n" % u)
elif m == "POST" and path.startswith("/dataHub/"):
    if not S["refuse_update"]:
        S["hubs"][path.split("/")[-1]] = json.loads(body["memberDataResources"])
    out(200)
elif m == "GET" and path.startswith("/dataResource/"):
    dr = path.split("/")[-1]
    out(200, "", json.dumps({"hubMembership": [{"uid": u} for u, v in S["hubs"].items() if dr in v]}))
PY
printf '#!/bin/sh\n[ "$1" = exec ] && shift 3 && exec python3 %s/collectory.py "$@"\n' "$tmp" > "$tmp/bin/docker"
chmod +x "$tmp/bin/docker"

run() {  # run <targets-json>
  printf '%s' "$1" > "$tmp/targets.json"
  PATH="$tmp/bin:$PATH" COLLECTORY_WS_URL=https://c/ws COLLECTORY_KEY=k PIPELINES_CONTAINER=p \
    DR_UID=dr0 TARGETS_JSON="$tmp/targets.json" python3 "$tmp/seed.py"
}
hubs() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["hubs"],sort_keys=True))' "$tmp/state.json"; }

two='{"hubs":[{"key":"a","queryContext":"data_hub_uid:dh2"},{"key":"b","queryContext":"data_hub_uid:dh1"}]}'
out=$(run "$two") || bad "run on an empty collectory failed: $out"
[ "$(hubs)" = '{"dh1": ["dr0"], "dh2": ["dr0"]}' ] && ok "empty collectory: dh1 and dh2 created, both hold dr0" || bad "state after first run: $(hubs)"
printf '%s\n' "$out" | grep -qx 'HUBS:dh1 dh2' && ok "reports the hub uids it seeded, in order" || bad "no HUBS line: $out"

out=$(run "$two") || bad "second run failed: $out"
[ "$(hubs)" = '{"dh1": ["dr0"], "dh2": ["dr0"]}' ] && ok "second run changes nothing" || bad "state after second run: $(hubs)"
printf '%s\n' "$out" | grep -q 'created' && bad "second run created a hub again" || ok "second run creates no hub"

# an existing hub with other members keeps them
printf '{"hubs": {"dh1": ["dr9"]}, "refuse_update": false}' > "$tmp/state.json"
run '{"hubs":[{"key":"a","queryContext":"data_hub_uid:dh1"}]}' >/dev/null || bad "existing hub run failed"
[ "$(hubs)" = '{"dh1": ["dr0", "dr9"]}' ] && ok "existing members are kept" || bad "members after merge: $(hubs)"

# no hub in the manifest: nothing to do, and no collectory call at all
rm -f "$tmp/state.json"
out=$(run '{"hubs":[]}') && [ "$out" = "HUBS:" ] && [ ! -e "$tmp/state.json" ] && ok "no hubs: no collectory calls" || bad "no-hub run: $out"

# a collectory that ignores the update must fail loudly, not report success
printf '{"hubs": {"dh1": []}, "refuse_update": true}' > "$tmp/state.json"
if out=$(run '{"hubs":[{"key":"a","queryContext":"data_hub_uid:dh1"}]}'); then bad "an update that did not take passed: $out"
else printf '%s\n' "$out" | grep -q 'update did not take' && ok "an update that did not take fails with a reason" || bad "no reason given: $out"; fi

# the harness wires it in: runs before the ingest, verifies each hub through biocache after
grep -q 'count_biocache_query "\$BIOCACHE_WS" "data_hub_uid:' scripts/e2e-airflow-ingest.sh \
  && ok "the ingest verifies every seeded hub through biocache" || bad "no per-hub verification in the ingest"
[ "$(grep -n 'HUB_SEED_PY' scripts/e2e-airflow-ingest.sh | head -1 | cut -d: -f1)" -lt "$(grep -n 'trigger_dag "\$DAG_ID"' scripts/e2e-airflow-ingest.sh | head -1 | cut -d: -f1)" ] \
  && ok "hubs are seeded before the DAG is triggered" || bad "hubs are seeded after the DAG"
exit $fail
