#!/usr/bin/env bash
# The portal's i18n overlay (i18n_custom_dir / i18n_custom_apps, roles/la-compose/defaults/main.yml):
# what the apps read at /var/opt/atlas/i18n/<app>/ before the ala-i18n pack.
#   1. the 14 service fragments that include _i18n_volumes.yml.j2 render byte for byte as before
#      when the portal has no overlay (no compose recreate on upgrade), and with one each service
#      mounts read-only exactly the <app> dirs it reads and the inventory fills;
#   2. under Ansible, with the list as an .ini gives it (a string), the partial resolves its
#      {% with %} service and the role defaults;
#   3. the config hash (config-restart-detect.yml and scripts/bundle/host-apply.sh, which must
#      agree): a service without overlay hashes as before; one with it, including a hub
#      instance, changes when its overlay file changes, and the others do not.
# ~20s, no Docker, no root.
set -u
cd "$(dirname "$0")/.."
ROLES="$PWD/roles"
ANSIBLE_PLAYBOOK="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}ansible-playbook"
command -v "$ANSIBLE_PLAYBOOK" >/dev/null || ANSIBLE_PLAYBOOK=ansible-playbook
PY="${VENV_MOLECULE:+$VENV_MOLECULE/bin/}python3"
command -v "$PY" >/dev/null || PY=python3
T=$(mktemp -d); [ -n "${KEEP:-}" ] && echo "kept: $T" || trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "[PASS] $1"; }
bad() { echo "[FAIL] $1" >&2; fail=1; }

# --- 1: the compose fragments -------------------------------------------------------------
SVC=roles/la-compose/templates/docker-compose/services
mkdir -p "$T/base"
# The fragments as they were before the overlay: the parent of the commit that added it, or
# HEAD while it is not committed yet.
added=$(git log --format=%H -S i18n_svc -- "$SVC/_i18n_volumes.yml.j2" | tail -1)
base_ref=HEAD
[ -n "$added" ] && base_ref="$added~1"
# A shallow clone may not have that parent: compare against HEAD (only the mounts are tested).
git rev-parse -q --verify "$base_ref^{commit}" >/dev/null || { echo "[INFO] no $base_ref here (shallow clone?): no before/after comparison"; base_ref=HEAD; }
for f in $(grep -l "_i18n_volumes" "$SVC"/*.j2) "$SVC/_i18n_volumes.yml.j2"; do
  git show "$base_ref:$f" > "$T/base/$(basename "$f")" || bad "no base for $f"
done
"$PY" - "$T/base" "$SVC" <<'PY' && ok "no overlay: the 14 fragments render as before; with one, each mounts only its <app> dirs" || bad "compose fragments"
import re, sys, jinja2, yaml
from ansible.plugins.filter.core import FilterModule as Core
base, new = sys.argv[1], sys.argv[2]
defaults = yaml.safe_load(open("roles/la-compose/defaults/main.yml"))
class Undef(jinja2.ChainableUndefined):  # the fragments call .get() on facts this test leaves out
    def __call__(self, *a, **k):
        return self
def env(d):
    e = jinja2.Environment(loader=jinja2.FileSystemLoader(d), undefined=Undef,
                           trim_blocks=True, extensions=["jinja2.ext.do", "jinja2.ext.loopcontrols"])
    e.filters.update(Core().filters())
    return e
v = {"data_dir": "/data", "i18n": {"enabled": True, "strategy": "volume", "volume": {"name": "ala-i18n-data"}},
     "i18n_custom_dir": "/data/i18n-custom", "i18n_custom_apps": defaults["i18n_custom_apps"]}
names = sorted(n for n in env(new).list_templates() if n != "_i18n_volumes.yml.j2"
               and "_i18n_volumes" in open(f"{new}/{n}").read())
assert len(names) == 14, names
mounts = {}
for n in names:
    before = env(base).get_template(n).render(v, i18n_custom_present=[])
    after = env(new).get_template(n).render(v, i18n_custom_present=[])
    assert before == after, f"{n} renders differently without overlay"
    out = env(new).get_template(n).render(v, i18n_custom_present=["biocache-hubs", "regions", "cas"])
    m = re.findall(r"^\s+- (\S+):/var/opt/atlas/i18n/(\S+)$", out, re.M)
    assert "- ala-i18n-data:/opt/atlas/i18n/:ro" in after, f"{n}: the pack mount is not rendered"
    if m:
        mounts[n] = m
want = {"biocache-hub.yml.j2": [("/data/i18n-custom/biocache-hubs", "biocache-hubs:ro")],
        "regions.yml.j2": [("/data/i18n-custom/regions", "regions:ro")],
        "cas.yml.j2": [("/data/i18n-custom/cas", "cas:ro")]}
assert mounts == want, mounts
PY

# --- 2 + 3: Ansible, the role's hash and the bundle's -------------------------------------
# hub_instances is a fact setup-hub-facts.yml computes, so it goes in as an extra var.
D="$T/data"
mkdir -p "$D/ala-hub/config" "$D/ala-hub-testhub/config" "$D/collectory/config" "$D/i18n-custom/biocache-hubs" \
  "$D/docker-compose" "$T/tpl"
echo 'hub' > "$D/ala-hub/config/ala-hub-config.yml"
echo 'hub2' > "$D/ala-hub-testhub/config/ala-hub-config.yml"
echo 'coll' > "$D/collectory/config/collectory-config.properties"
echo 'species_subgroup.Accipitriformes=Rapaces diurnas' > "$D/i18n-custom/biocache-hubs/messages_es.properties"
cp "$SVC/_i18n_volumes.yml.j2" "$T/tpl/"
printf "services:\n  x:\n    volumes:\n{%% with i18n_svc = 'ala_hub' %%}{%% include '_i18n_volumes.yml.j2' %%}{%% endwith %%}\n" > "$T/tpl/wrap.yml.j2"

cat > "$T/hosts.ini" <<INI
[docker_compose]
localhost ansible_connection=local data_dir=$D docker_compose_data_dir=$D/docker-compose

[docker_compose:vars]
docker_config_files = [{"src": "files/m.properties", "dest": "$D/i18n-custom/biocache-hubs/messages_es.properties"}]
INI
cat > "$T/play.yml" <<YML
- hosts: docker_compose
  gather_facts: false
  tasks:
    - ansible.builtin.include_role:
        name: la-compose
        tasks_from: config-restart-detect.yml
        public: true
    - ansible.builtin.template:
        src: $T/tpl/wrap.yml.j2
        dest: $T/wrap.yml
    - ansible.builtin.copy:
        dest: $T/role-hashes
        content: "{{ config_hashes_now.stdout }}\n"
    - ansible.builtin.copy:
        dest: $T/meta.json
        content: >-
          {{ config_watch | map('dict2items') | map('selectattr', 'key', 'in', ['service', 'path', 'extra_paths'])
             | map('items2dict') | list | to_json }}
YML
run() { ANSIBLE_ROLES_PATH="$ROLES" ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_NOCOLOR=1 \
  "$ANSIBLE_PLAYBOOK" -i "$T/hosts.ini" -e ansible_become=false \
  -e '{"services_enabled": ["ala_hub", "collectory"], "hub_instances": [{"is_portal": false, "suffix": "-testhub",
       "use_records": true, "use_species": false, "use_regions": false, "biocache_hub": "ala-hub-testhub"}]}' \
  -e 'ansible_python_interpreter={{ ansible_playbook_python }}' "$T/play.yml" >"$T/run.log" 2>&1 ||
  { cat "$T/run.log" >&2; bad "ansible run failed"; }; }
# host-apply.sh's own hashes(), with its meta() reading the config_watch the role computed.
bundle_hashes() { bash -c "set -euo pipefail; meta() { [ \"\$1\" = config_watch ] && cat '$T/meta.json'; }
$(sed -n '/^hashes() {/,/^}/p' scripts/bundle/host-apply.sh)
hashes"; }
old_hash() { find "$1" -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}'; }

run
grep -q -- "- $D/i18n-custom/biocache-hubs:/var/opt/atlas/i18n/biocache-hubs:ro" "$T/wrap.yml" &&
  ! grep -q downloads-plugin "$T/wrap.yml" &&
  ok "under Ansible, from an .ini string, the partial mounts the filled <app> dir of its service" ||
  bad "Ansible render: $(cat "$T/wrap.yml")"
bundle_hashes > "$T/bundle-hashes" 2>"$T/bundle.err" || { cat "$T/bundle.err" >&2; bad "host-apply hashes() failed"; }
cmp -s "$T/role-hashes" "$T/bundle-hashes" && [ "$(wc -l < "$T/role-hashes")" = 3 ] &&
  ok "the role and the bundle applier hash the same" || bad "hashes differ: $(diff "$T/role-hashes" "$T/bundle-hashes")"
grep -qx "collectory $(old_hash "$D/collectory/config")" "$T/role-hashes" &&
  ok "a service without overlay hashes exactly as before" || bad "collectory hash changed: $(cat "$T/role-hashes")"
cp "$T/role-hashes" "$T/hashes-1"

echo 'species_subgroup.Accipitriformes=Rapaces' > "$D/i18n-custom/biocache-hubs/messages_es.properties"
run
changed=$(diff <(sort "$T/hashes-1") <(sort "$T/role-hashes") | awk '/^>/ {print $2}' | sort | tr '\n' ' ')
[ "$changed" = "biocache-hub biocache-hub-testhub " ] &&
  ok "a changed overlay file changes the hash of the services that mount it, hub included, only" ||
  bad "changed after an overlay edit: '$changed'"

exit $fail
