#!/usr/bin/env bash
# The hubs' healthchecks must go red when the app serves 500s. After a Docker restart
# (gbif.es, 2026-10-21) biocache-hub answered 500 on every page (i18n race) while its old
# check, /actuator/health, stayed green, so neither Docker nor la-autoheal ever restarted it.
#
# Renders the real compose fragments and EXECUTES each healthcheck command, as Docker would,
# against a fake curl that answers a given HTTP code. Catches what a string match cannot: an
# unquoted `&` in the URL sends curl to the background and the check exits 0 whatever the
# page says. ~1s, no Docker.
set -eu
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# Fake curl: honours -w '%{http_code}' and --fail like the real one, answering $FAKE_CODE.
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_CALLS"
fail=0; w=0
for a in "$@"; do
  case "$a" in --fail|-f|-fsS) fail=1 ;; -w) w=1 ;; esac
done
[ "$w" = 1 ] && printf '%s' "$FAKE_CODE"
[ "$FAKE_CODE" = 000 ] && exit 7  # no connection: curl fails whatever the flags
[ "$fail" = 1 ] && [ "$FAKE_CODE" -ge 400 ] && exit 22
exit 0
EOF
chmod +x "$tmp/bin/curl"

python3 - "$tmp" <<'PY'
import json, re, subprocess, sys, jinja2, yaml

tmp = sys.argv[1]
env = jinja2.Environment(loader=jinja2.FileSystemLoader(["roles/la-compose/templates", "roles/la-compose/templates/docker-compose/services", "roles/la-compose/templates/docker-compose"]),
                         undefined=jinja2.ChainableUndefined, extensions=["jinja2.ext.do"],
                         trim_blocks=True)  # as ansible.builtin.template renders
env.filters["regex_replace"] = lambda s, p, r="": re.sub(p, r, str(s))
env.filters["bool"] = lambda v: str(v).lower() in ("1", "true", "yes", "on")
env.filters["to_json"] = env.filters["tojson"]
env.filters.setdefault("mandatory", lambda v: v)

# (fragment, path the probe must hit, extra render vars)
cases = [("biocache-hub", "/occurrences/search?q=*:*&pageSize=1", {}),
         ("biocache-hub", "/records/occurrences/search?q=*:*&pageSize=1", {"biocache_hub_context_path": "/records"}),
         ("bie-hub", "/", {}),
         ("collectory", "/", {"datastore_endpoints": {}})]
fail = []
for svc, path, ctx in cases:
    doc = yaml.safe_load(env.get_template("docker-compose/services/%s.yml.j2" % svc).render(**ctx))
    test = next(iter(doc["services"].values()))["healthcheck"]["test"]
    if test[0] == "CMD-SHELL":
        cmd = ["sh", "-c", test[1]]
    elif test[:3] == ["CMD", "sh", "-c"]:
        cmd = test[1:]
    else:
        fail.append("%s: unexpected healthcheck form %r" % (svc, test)); continue
    label = "%s %r" % (svc, ctx or "portal")
    for code, want_ok in (("200", True), ("302", True), ("404", None), ("500", False), ("503", False), ("000", False)):
        calls = "%s/calls" % tmp
        open(calls, "w").close()
        rc = subprocess.run(cmd, env={"PATH": "%s/bin:/usr/bin:/bin" % tmp, "FAKE_CODE": code, "FAKE_CALLS": calls},
                            capture_output=True, timeout=10).returncode
        urls = open(calls).read()
        if ("localhost:8080" + path) not in urls:
            fail.append("%s: curl was not called with localhost:8080%s (got %r)" % (label, path, urls.strip()))
            break
        if want_ok is True and rc != 0:
            fail.append("%s: HTTP %s must be healthy, the check exited %d" % (label, code, rc))
        if want_ok is False and rc == 0:
            fail.append("%s: HTTP %s must be UNHEALTHY, the check exited 0" % (label, code))
if fail:
    print("[FAIL] hub healthchecks:", *fail, sep="\n  ", file=sys.stderr)
    sys.exit(1)
print("[PASS] hub healthchecks go red on 5xx / no answer and stay green on 2xx/3xx")
PY
