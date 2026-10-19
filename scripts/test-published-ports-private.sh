#!/usr/bin/env bash
# Every port a compose template publishes must name the host address it binds to. A bare
# "{{ port }}:N" binds 0.0.0.0, and Docker's NAT rules run before ufw: on a host with a
# public IP that service is open to the internet whatever the firewall says. 2026-10-19:
# sensitive-data-service and namematching published their service AND Dropwizard admin
# ports (9180/9190: metrics, thread dump, tasks) that way. Static, ~1s.
set -eu
cd "$(dirname "$0")/.."
fail=0
# A ports entry: - "host:port:port", - "port:port" or - "port" (expose-like, random host port).
while IFS= read -r hit; do
  echo "[FAIL] published without a bind address: $hit"; fail=1
done < <(grep -rnE '^\s*-\s*"\{\{\s*[a-z_]+\s*(\|[^}]*)?\}\}:[0-9]+"' roles/la-compose/templates/docker-compose || true)
while IFS= read -r hit; do
  echo "[FAIL] Dropwizard admin port published: $hit"; fail=1
done < <(grep -rnE '^\s*-\s*".*:(9180|9190)"' roles/la-compose/templates/docker-compose || true)
[ "$fail" = 0 ] && echo "[PASS] every published port names its bind address; no admin port published"
exit $fail
