#!/usr/bin/env bash
# la_postgres ran with the image defaults (shared_buffers 128MB, work_mem 4MB) on every host,
# including a spatial host whose PostGIS layersdb serves intersects and area reports to a whole
# workshop. postgres_settings adds "-c key=value" per host and postgres_shm_size sizes /dev/shm.
# Runs real ansible so inventory precedence is exercised.
set -eu
cd "$(dirname "$0")/.."
repo=$PWD
ANSIBLE_PLAYBOOK=${ANSIBLE_PLAYBOOK:-$(command -v ansible-playbook || echo .venv-molecule/bin/ansible-playbook)}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/roles/r/tasks"
ln -s "$repo/roles/la-compose/defaults" "$tmp/roles/r/defaults"
ln -s "$repo/roles/la-compose/templates" "$tmp/roles/r/templates"
cat > "$tmp/roles/r/tasks/main.yml" <<'EOF'
- ansible.builtin.template:
    src: docker-compose/infrastructure/postgres.yml.j2
    dest: "{{ out }}/pg.yml"
EOF
cat > "$tmp/play.yml" <<'EOF'
- hosts: all
  gather_facts: false
  vars: {data_dir: /data, datastore_endpoints: {}}
  roles: [r]
EOF

fail=0
run() {  # label, inventory host vars, expected command json, expected shm_size
  printf 'localhost ansible_connection=local ansible_python_interpreter=%s %s\n' "$(command -v python3)" "$2" > "$tmp/inv.ini"
  if ! "$ANSIBLE_PLAYBOOK" -i "$tmp/inv.ini" "$tmp/play.yml" -e out="$tmp" > "$tmp/log" 2>&1; then
    echo "[FAIL] $1: render failed"; tail -20 "$tmp/log"; fail=1; return
  fi
  local got; got=$(python3 -c 'import sys,yaml,json; s=yaml.safe_load(open(sys.argv[1]))["services"]["postgres"]; print(json.dumps(s["command"]), s.get("shm_size", ""))' "$tmp/pg.yml")
  if [ "$got" = "$3 $4" ]; then echo "[PASS] $1 -> $got"; else echo "[FAIL] $1: want '$3 $4', got '$got'"; fail=1; fi
}

run "default" "" '["postgres", "-c", "password_encryption=md5"]' ""
run "settings" "postgres_settings='{\"work_mem\": \"32MB\", \"shared_buffers\": \"4GB\"}' postgres_shm_size=1g" \
  '["postgres", "-c", "password_encryption=md5", "-c", "shared_buffers=4GB", "-c", "work_mem=32MB"]' "1g"
exit $fail
