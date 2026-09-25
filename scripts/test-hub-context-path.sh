#!/usr/bin/env bash
# A data hub mounted under a path of a shared hostname (hub.l-a.site/records, /species,
# /regions) is proxied with that full path, but the Spring Boot 2 hub images ignore the
# server.contextPath (Grails 3 key) ala-install writes into their config, so they served
# at / and answered 404/500 (build #408). The compose fragments must pass
# -Dserver.servlet.context-path and probe health under it; the portal (empty context
# path) must render exactly as before.
set -eu
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re, sys, jinja2, yaml

env = jinja2.Environment(loader=jinja2.FileSystemLoader(["roles/la-compose/templates", "roles/la-compose/templates/docker-compose/services", "roles/la-compose/templates/docker-compose"]),
                         undefined=jinja2.ChainableUndefined, extensions=["jinja2.ext.do"],
                         trim_blocks=True)  # as ansible.builtin.template renders
env.filters["regex_replace"] = lambda s, p, r="": re.sub(p, r, str(s))
env.filters["bool"] = lambda v: str(v).lower() in ("1", "true", "yes", "on")
env.filters["to_json"] = env.filters["tojson"]
env.filters.setdefault("mandatory", lambda v: v)

cases = [("biocache-hub", "biocache_hub_context_path", "/records", "/actuator/health"),
         ("bie-hub", "bie_hub_context_path", "/species", "/"),
         ("regions", "regions_context_path", "/regions", "/")]
fail = []
for svc, var, path, probe in cases:
    t = env.get_template("docker-compose/services/%s.yml.j2" % svc)
    for ctx, want_opt, want_probe in (("", None, "8080" + probe), ("/", None, "8080" + probe),
                                      (path, "-Dserver.servlet.context-path=" + path, "8080" + path + probe)):
        out = t.render(**{var: ctx})
        try:
            yaml.safe_load(out)
        except yaml.YAMLError as e:
            fail.append("%s: rendered fragment is not valid YAML: %s" % ("%s %s=%r" % (svc, var, ctx), e)); continue
        java = [l for l in out.splitlines() if "JAVA_OPTS:" in l]
        health = [l for l in out.splitlines() if "curl" in l]
        label = "%s %s=%r" % (svc, var, ctx)
        if len(java) != 1:
            fail.append("%s: expected one JAVA_OPTS line, got %r" % (label, java)); continue
        if want_opt and want_opt not in java[0]:
            fail.append("%s: JAVA_OPTS lacks %s: %s" % (label, want_opt, java[0].strip()))
        if not want_opt and "context-path" in java[0]:
            fail.append("%s: portal JAVA_OPTS must not set a context path: %s" % (label, java[0].strip()))
        if not any(("localhost:" + want_probe) in l for l in health):
            fail.append("%s: healthcheck does not probe localhost:%s: %r" % (label, want_probe, health))
if fail:
    print("[FAIL] hub context path:", *fail, sep="\n  ", file=sys.stderr)
    sys.exit(1)
print("[PASS] hub fragments serve and probe under their context path; portal unchanged")
PY
