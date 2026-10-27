#!/usr/bin/env bash
# infrastructure/postfix.yml.j2 renders every environment value quoted, with `$` doubled:
#   - the Postfix relay form [smtp.example.org]:587 and passwords with ': ', ' #', or a leading
#     '*', '&', '!', '%' or '@' parse as the same string, not as a YAML sequence/comment/alias;
#   - an empty value is left out, not rendered "" (HOSTNAME="" lost the relay, see the template);
#   - `docker compose config` accepts the file and hands the container the literal value
#     (a broken postfix.yml fails every compose command of its host, not only postfix's).
# ~2s with Docker's compose plugin, the YAML half alone without it.
set -u
cd "$(dirname "$0")/.."
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

"$PY" - "$T" <<'PY' || { echo "[FAIL] the rendered postfix.yml is not the YAML it should be" >&2; exit 1; }
import json, sys, jinja2, yaml
from ansible.plugins.filter.core import FilterModule as Core
out = sys.argv[1]
e = jinja2.Environment(loader=jinja2.FileSystemLoader("roles/la-compose/templates/docker-compose/infrastructure"),
                       trim_blocks=True)
e.filters.update({k: f for k, f in Core().filters().items() if k in ("to_json", "regex_replace")})  # Ansible's default() needs its own Undefined
cases = {
    "bracketed": {"email_sender_server": "[smtp.gbif.es]:587", "email_sender_password": "a#b: c",
                  "email_sender": "noreply@gbif.es", "email_hostname": "gbif.es"},
    "symbols":   {"email_sender_server": "smtp.example.org:25", "email_sender_password": "*x&y !z %w @v $HOME ü \"q\" 'q'",
                  "email_sender": "a@b.org", "email_hostname": "h"},
    "defaults":  {},
}
want_env = {}
for name, v in cases.items():
    txt = e.get_template("postfix.yml.j2").render(v, docker_network="la_internal", docker_extra_hosts_dict={})
    # base.yml declares the shared network; compose config needs it to validate the fragment.
    open(f"{out}/{name}.yml", "w").write(txt + "\nnetworks:\n  la_internal: {}\n")
    env = yaml.safe_load(txt)["services"]["postfix"]["environment"]
    exp = {"RELAYHOST": v.get("email_sender_server", ""), "RELAYHOST_PASSWORD": v.get("email_sender_password", ""),
           "RELAYHOST_USERNAME": v.get("email_sender", ""), "HOSTNAME": v.get("email_hostname", ""),
           "ALLOWED_SENDER_DOMAINS": v.get("email_sender", "").split("@")[-1] if v.get("email_sender") else "",
           "TZ": "UTC"}
    for k, x in exp.items():
        if x == "":
            # Unset, never "": HOSTNAME="" makes boky drop relayhost and smtp_sasl_auth_enable
            # (its myhostname delete also eats the two lines after it; gbif.es -3).
            assert k not in env, f"{name}: empty {k} rendered as {env[k]!r} instead of left out"
            continue
        # YAML sees the compose-escaped string; compose turns $$ back into $.
        got = env[k]
        assert isinstance(got, str) and got.replace("$$", "$") == x, f"{name}: {k} = {got!r}, want {x!r}"
    want_env[name] = exp
json.dump(want_env, open(f"{out}/want.json", "w"))
print("[PASS] every postfix environment value parses as the literal string ([host]:port, ': ', '#', '*', '&', '$', unicode, quotes); empty ones are left out")
PY

if docker compose version >/dev/null 2>&1; then
  for name in bracketed symbols defaults; do
    docker compose -f "$T/$name.yml" --profile mail config --format json >"$T/$name.json" 2>"$T/$name.err" ||
      { echo "[FAIL] docker compose config rejects the $name render: $(cat "$T/$name.err")" >&2; fail=1; continue; }
  done
  [ "$fail" = 0 ] && "$PY" - "$T" <<'PY' || fail=1
import json, sys
d = sys.argv[1]
want = json.load(open(f"{d}/want.json"))
for name, exp in want.items():
    env = json.load(open(f"{d}/{name}.json"))["services"]["postfix"]["environment"]
    for k, x in exp.items():
        # config prints $ re-escaped as $$ (so its output stays valid input); the container gets
        # one $ -- checked by hand with `docker compose run` on alpine.
        assert (env.get(k) or "").replace("$$", "$") == x, f"{name}: compose gives {k} = {env.get(k)!r}, want {x!r}"
print("[PASS] docker compose config accepts the file and passes each value through literally")
PY
else
  echo "[SKIP] no docker compose here: only the YAML half ran"
fi
exit $fail
