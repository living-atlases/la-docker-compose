#!/usr/bin/env bash
#
# e2e-bie-import.sh — bie-index taxonomy import e2e.
#
# Imports a tiny FIXED taxonomy DwCA (e2e/fixtures/bie-taxonomy/, ~41 taxa) through the
# REAL bie-index import chain, promotes the result to the live index and asserts that a
# species search actually returns records.
#
# WHY THIS EXISTS
#
# Nothing in the deploy chain ever populated the bie index. The collections are created
# (roles/la-compose/tasks/init-solr.yml) and bie-index is wired to them, but ALA triggers
# the import by hand from /admin/import, so on a generated stack the index stays empty --
# and every probe we had stayed green over it, because on an empty index
#   GET /search?q=Acacia  ->  200 {"searchResults":{"totalRecords":0,...}}
# which satisfies both `[STATUS] < 400` and `has([BODY].searchResults) == true`.
# See living-atlases/la-toolkit#28, sections 3 and C.
#
# Runs ON the host where the stack's Docker daemon lives (the CI stage scp's this script
# plus the fixture and runs it over ssh). Stack access is via `docker exec`; only the CAS
# token exchange and the import trigger go over HTTP, because they have to cross the
# nginx vhost the OIDC client is registered against.
#
# It deliberately does NOT source e2e-airflow-lib.sh: those helpers all tunnel through
# la_airflow, and Airflow is opt-in (use_airflow=false by default) while bie-index is not.
#
# Exit codes: 0 = taxa indexed (or report-only) | 1 = import/verify failed | 2 = preconditions unmet
# Report-only by default (exits 0, prints WARN); pass --blocking to gate CI.
#
# Usage:
#   scripts/e2e-bie-import.sh [--blocking] [--report-only] [--timeout SEC]
#
# Credentials (the CI stage exports these; see the Jenkinsfile stage):
#   BIE_CLIENT_ID / BIE_CLIENT_SECRET   the bie-index OIDC client (bie_index_client_id/_secret)
#   BIE_ADMIN_USER / BIE_ADMIN_PASS     a ROLE_ADMIN account (cas_first_admin_email + its password)
#   BIE_ADMIN_TOKEN                     skip the exchange entirely and use this bearer
set -euo pipefail

LOG_TAG=bie-e2e
BLOCKING=false
TIMEOUT=1800

BIE_INDEX_CONTAINER="${BIE_INDEX_CONTAINER:-la_bie-index}"
# Base URL of Solr, e.g. http://la_solr:8983/solr. Resolved from bie-index's own config
# below when unset -- see the comment on the resolution step. NOT a container name: Solr is
# routinely on a different host from bie-index (measured: bie-index on 2023-3, Solr on
# 2023-2), so `docker exec la_solr` only works by luck of the topology.
SOLR_BASE="${SOLR_BASE:-}"
BIE_INDEX_CONFIG="${BIE_INDEX_CONFIG:-/data/bie-index/config/bie-index-config.yml}"
# The public vhost of bie-index, e.g. https://species-ws.l-a.site. Required: the import
# trigger is authenticated and the OIDC client is registered against this URL, and the final
# assertion deliberately goes the same way the monitoring does.
BIE_PUBLIC_URL="${BIE_PUBLIC_URL:-}"
CAS_TOKEN_URL="${CAS_TOKEN_URL:-}"            # e.g. https://auth.l-a.site/cas/oidc/oidcAccessToken
OIDC_SCOPE="${OIDC_SCOPE:-openid profile email ala roles}"
DWCA_NAME="${DWCA_NAME:-la-e2e-taxonomy}"
FIXTURE_DIR="${FIXTURE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/e2e/fixtures/bie-taxonomy}"
EXPECTED_MIN="${EXPECTED_MIN:-20}"
CURL_OPTS=(-s --max-time 60)
[[ "${BIE_INSECURE:-false}" == true ]] && CURL_OPTS+=(-k)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --blocking)    BLOCKING=true ;;
    --report-only) BLOCKING=false ;;
    --timeout)     TIMEOUT="$2"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '%s %s\n' "[$LOG_TAG]" "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

# Same contract as the airflow harnesses: the exit code always reflects reality, and only
# this wrapper decides whether that gates the build.
finish() {
  local code="$1"
  if [[ "$BLOCKING" == true ]]; then exit "$code"; fi
  [[ "$code" -ne 0 ]] && warn "report-only mode: exiting 0 despite the failure above (pass --blocking to gate)"
  exit 0
}

# Every Solr call goes through the bie-index CONTAINER, not through a Solr container and
# not from the host. bie-index reaches Solr by definition -- that is the connection it
# serves every search on -- so it works whatever the topology: co-located, split across
# hosts, or an external Solr on a VM. Going through `docker exec la_solr` instead assumed
# co-location and broke the moment Solr and bie-index landed on different hosts.
solr() { docker exec "$BIE_INDEX_CONTAINER" curl -s --max-time 60 "$@"; }

solr_admin() {  # solr_admin <query-string> — raw JSON from the collections API
  solr "$SOLR_BASE/admin/collections?$1&wt=json"
}

# JSON readers. The key travels in argv and is never interpolated into code, so a name
# from the wire can never turn into an expression.
alias_target() {  # alias_target <alias> -> the collection it resolves to, or empty
  solr_admin "action=LISTALIASES" | python3 -c 'import sys,json
print(json.load(sys.stdin).get("aliases",{}).get(sys.argv[1],""))' "$1" 2>/dev/null
}

num_found() {  # num_found <collection-or-alias> -> document count, or -1 if unreadable
  solr "$SOLR_BASE/$1/select?q=*:*&rows=0&wt=json" \
    | python3 -c 'import sys,json
print(json.load(sys.stdin)["response"]["numFound"])' 2>/dev/null \
    || echo -1
}

taxon_total() {  # taxon_total <bie-index search url> -> totalRecords, or -1
  curl "${CURL_OPTS[@]}" "$1" \
    | python3 -c 'import sys,json
print(json.load(sys.stdin)["searchResults"]["totalRecords"])' 2>/dev/null \
    || echo -1
}

# ---------------------------------------------------------------- preconditions
docker inspect "$BIE_INDEX_CONTAINER" >/dev/null 2>&1 \
  || { err "$BIE_INDEX_CONTAINER is not present; bie-index is not part of this deployment"; exit 2; }
[[ -d "$FIXTURE_DIR" ]] || { err "fixture not found at $FIXTURE_DIR"; exit 2; }

# Take the Solr endpoint from bie-index's own configuration rather than guessing it. That
# file is the single authority on where this deployment's bie index lives, it is already
# correct for every topology the generator emits, and using anything else means the harness
# can quietly verify a different Solr from the one bie-index serves.
if [[ -z "$SOLR_BASE" ]]; then
  SOLR_BASE=$(docker exec "$BIE_INDEX_CONTAINER" sh -c "sed -n 's|^[[:space:]]*connection:[[:space:]]*\(http[^[:space:]]*\)/bie-offline[[:space:]]*$|\1|p; s|^[[:space:]]*connection:[[:space:]]*\(http[^[:space:]]*\)/bie[[:space:]]*$|\1|p' $BIE_INDEX_CONFIG" 2>/dev/null | head -1)
fi
[[ -n "$SOLR_BASE" ]] \
  || { err "could not resolve the Solr base URL from $BIE_INDEX_CONFIG inside $BIE_INDEX_CONTAINER."
       err "Pass it explicitly, e.g. SOLR_BASE=http://la_solr:8983/solr"; exit 2; }
log "solr: $SOLR_BASE (via $BIE_INDEX_CONTAINER)"

# Prove it answers before relying on it, so a routing problem is reported as itself.
solr_admin "action=LIST" | grep -q '"collections"' \
  || { err "$SOLR_BASE does not answer the collections API from inside $BIE_INDEX_CONTAINER."
       err "bie-index cannot reach its own Solr; nothing downstream can work."; exit 2; }

LIVE_TARGET="$(alias_target bie || true)"
OFFLINE_TARGET="$(alias_target bie-offline || true)"
if [[ -z "$LIVE_TARGET" || -z "$OFFLINE_TARGET" ]]; then
  err "bie / bie-offline are not published as aliases (live='$LIVE_TARGET' offline='$OFFLINE_TARGET')."
  err "This deployment predates the alias model, so the offline index cannot be promoted:"
  err "bie-index does that with a SolrCloud SWAP on literal core names, which cannot work here."
  err "See the 'bie is still a collection' message in roles/la-compose/tasks/init-solr.yml."
  exit 2
fi
[[ "$LIVE_TARGET" != "$OFFLINE_TARGET" ]] \
  || { err "bie and bie-offline both resolve to '$LIVE_TARGET'; promoting would be a no-op"; exit 2; }
log "aliases: bie -> $LIVE_TARGET | bie-offline -> $OFFLINE_TARGET"

[[ -n "$BIE_PUBLIC_URL" ]] \
  || { err "BIE_PUBLIC_URL is unset; the import trigger is authenticated and must cross the vhost"; exit 2; }

# Everything from here on goes over the public vhost, from THIS host: the token exchange,
# the trigger, and the final assertion. Prove it is reachable now, with a plain unauthenticated
# GET, so a DNS or firewall problem is reported as itself instead of surfacing later as a
# mystery 000 from the token endpoint. The host normally reaches its own nginx through public
# DNS; where it does not, run the harness from a host that does, or set BIE_INSECURE=true if
# the only obstacle is certificate validation.
probe_code=$(curl "${CURL_OPTS[@]}" -o /dev/null -w '%{http_code}' "$BIE_PUBLIC_URL/search?q=*:*&pageSize=0" || echo 000)
[[ "$probe_code" == 200 ]] \
  || { err "$BIE_PUBLIC_URL is not reachable from this host (HTTP $probe_code)."
       err "The trigger and the final assertion both go this way; fix reachability first."
       exit 2; }
log "$BIE_PUBLIC_URL reachable"

# ---------------------------------------------------------------- stage the archive
# ImportService.retrieveAvailableDwCAPaths() lists DIRECTORIES under import.taxonomy.dir,
# so the archive goes in expanded, not zipped.
#
# Streamed through `tar | docker exec -i` rather than written to the host path or pushed
# with `docker cp`, for the reason init-solr.yml documents at length: `docker cp` writes
# into the container's graph layer, which is masked wherever the destination sits under a
# mount, so a later `docker exec` looking at the same path sees an empty directory. Piping
# into a tar running INSIDE the container extracts in the same mount namespace the import
# will read from, whatever the mount topology is. It also means no sudo on the host.
IMPORT_DIR_CTR="${IMPORT_DIR_CTR:-/data/bie/import}"
log "staging $FIXTURE_DIR into $BIE_INDEX_CONTAINER:$IMPORT_DIR_CTR/$DWCA_NAME"
docker exec -u 0 "$BIE_INDEX_CONTAINER" rm -rf "$IMPORT_DIR_CTR/$DWCA_NAME"
docker exec -u 0 "$BIE_INDEX_CONTAINER" mkdir -p "$IMPORT_DIR_CTR/$DWCA_NAME"
tar -C "$FIXTURE_DIR" -cf - meta.xml eml.xml taxon.txt vernacularname.txt \
  | docker exec -i -u 0 "$BIE_INDEX_CONTAINER" tar -C "$IMPORT_DIR_CTR/$DWCA_NAME" -xf -
# Fail loudly here rather than let the import "succeed" over an empty directory.
docker exec "$BIE_INDEX_CONTAINER" test -r "$IMPORT_DIR_CTR/$DWCA_NAME/meta.xml" \
  || { err "the archive is not readable inside $BIE_INDEX_CONTAINER at $IMPORT_DIR_CTR/$DWCA_NAME."
       err "If the directory itself is missing, the {{ data_dir }}/bie bind mount is absent from"
       err "the generated compose (bie-index.yml.j2) -- re-run ansiblew and redeploy."
       exit 2; }

# ---------------------------------------------------------------- authenticate
# /api/services/all is @RequireApiKey(roles=['ROLE_ADMIN']), so it needs a bearer that
# actually carries the role. ImportController (/admin/import/*) is @AlaSecured and only
# accepts a browser session, which is why it is not the route used here.
#
# `Accept: application/json` is load-bearing, not decoration. CAS content-negotiates this
# endpoint and, with no Accept header, answers in YAML:
#
#   $ curl -u fake:fake -d grant_type=client_credentials .../oidcAccessToken
#   --- !<java.util.LinkedHashMap>
#   status: 401
#
# so a JSON parser sees garbage and every grant looks like "no token", whatever the real
# reason was. Verified against the live CAS on 2026-08-25.
get_token() {  # get_token <label> <curl -d flags...> -> token on stdout, diagnosis on stderr
  local label="$1" body; shift
  body=$(curl "${CURL_OPTS[@]}" -H 'Accept: application/json' \
              -u "$BIE_CLIENT_ID:$BIE_CLIENT_SECRET" "$@" \
              --data-urlencode "scope=$OIDC_SCOPE" "$CAS_TOKEN_URL" || true)
  printf '%s' "$body" | LABEL="$label" python3 -c 'import sys,json,os
raw=sys.stdin.read()
label=os.environ["LABEL"]
try:
    d=json.loads(raw)
except Exception:
    print(f"[{label}] token endpoint did not answer JSON: {raw[:200]!r}", file=sys.stderr)
    sys.exit(1)
t=d.get("access_token")
if not t:
    # Report what CAS actually said. "no token" on its own sends you looking at roles when
    # the problem is the client secret, the grant, or the scope.
    print(f"[{label}] no access_token: {json.dumps({k: d[k] for k in d if k != \"access_token\"})[:300]}",
          file=sys.stderr)
    sys.exit(1)
print(t)'
}

TOKEN="${BIE_ADMIN_TOKEN:-}"
GRANT="${BIE_ADMIN_TOKEN:+preset}"
if [[ -z "$TOKEN" ]]; then
  [[ -n "${CAS_TOKEN_URL:-}" && -n "${BIE_CLIENT_ID:-}" && -n "${BIE_CLIENT_SECRET:-}" ]] \
    || { err "no BIE_ADMIN_TOKEN and no CAS_TOKEN_URL/BIE_CLIENT_ID/BIE_CLIENT_SECRET to obtain one"; exit 2; }
  # Resource-owner password FIRST, and it is not a preference -- client_credentials cannot
  # work here. Measured against the CI on 2026-08-25: the grant succeeds and returns a
  # perfectly good token, but with `roles: []`, and CAS logs
  #   No person records were fetched from attribute repositories for
  #   [{credentialClass=[OAuth20ClientIdClientSecretCredential], username=<client_id>}]
  # because there is no user principal for a client id to take attributes from. The
  # endpoint then answers 403. Only a user-bound grant carries a role.
  # client_credentials stays as a fallback for a deployment that attaches a static role to
  # the client itself, which ours does not.
  if [[ -n "${BIE_ADMIN_USER:-}" && -n "${BIE_ADMIN_PASS:-}" ]]; then
    TOKEN=$(get_token password -d grant_type=password \
              --data-urlencode "username=$BIE_ADMIN_USER" \
              --data-urlencode "password=$BIE_ADMIN_PASS" || true)
    if [[ -n "$TOKEN" ]]; then GRANT=password; log "obtained a token via grant_type=password"; fi
  fi
  if [[ -z "$TOKEN" ]]; then
    TOKEN=$(get_token client_credentials -d grant_type=client_credentials || true)
    if [[ -n "$TOKEN" ]]; then GRANT=client_credentials; log "obtained a token via grant_type=client_credentials"; fi
  fi
fi
[[ -n "$TOKEN" ]] || { err "could not obtain an access token from $CAS_TOKEN_URL"; exit 2; }

# ---------------------------------------------------------------- trigger the import
BEFORE_OFFLINE=$(num_found "$OFFLINE_TARGET")
log "offline index ($OFFLINE_TARGET) holds $BEFORE_OFFLINE documents before the import"

http_code=$(curl "${CURL_OPTS[@]}" -o /tmp/bie-import-trigger.json -w '%{http_code}' \
              -H 'Accept: application/json' -H "Authorization: Bearer $TOKEN" \
              "$BIE_PUBLIC_URL/api/services/all" || echo 000)
if [[ "$http_code" == 401 || "$http_code" == 403 ]]; then
  err "the token was rejected by /api/services/all (HTTP $http_code, grant=${GRANT:-unknown})."
  if [[ "$http_code" == 403 ]]; then
    err "403 means it authenticated and simply carries no ROLE_ADMIN. Two known causes:"
    err "  * grant=client_credentials: expected and unfixable this way. There is no user"
    err "    principal, so no attributes are resolved and roles are always empty. Supply"
    err "    BIE_ADMIN_USER/BIE_ADMIN_PASS so the harness can use the password grant."
    err "  * grant=password: check the CAS service registry actually releases the role"
    err "    attribute. cas_oidc_released_attributes in roles/la-compose/defaults/main.yml"
    err "    feeds attributeReleasePolicy.allowedAttributes; an empty list there releases"
    err "    nothing and every token comes back role-less. Inspect the live value with"
    err "    db.services.find({}, {name:1, 'attributeReleasePolicy.allowedAttributes':1})"
    err "    in the cas-service-registry database."
  fi
  finish 1
fi
[[ "$http_code" == 200 ]] || { err "trigger returned HTTP $http_code: $(head -c 400 /tmp/bie-import-trigger.json)"; finish 1; }
log "import triggered: $(head -c 300 /tmp/bie-import-trigger.json)"

# ---------------------------------------------------------------- wait, then COUNT
# Deliberately not gated on the job status. ImportService.importDwcA() catches every
# exception, logs it and returns normally, so a run that imported nothing at all still
# ends "successfully" -- the exact failure mode section 1 of the upstream report is about.
# The document count is the only trustworthy criterion.
deadline=$(( SECONDS + TIMEOUT ))
after=0
while (( SECONDS < deadline )); do
  sleep 15
  solr "$SOLR_BASE/$OFFLINE_TARGET/update?commit=true" \
       -H 'Content-Type: text/xml' --data-binary '<commit/>' >/dev/null || true
  after=$(num_found "$OFFLINE_TARGET")
  log "offline index ($OFFLINE_TARGET): $after documents"
  # `if`, not `cond && break`: under set -e a false compound as the last statement of the
  # loop body kills the script instead of going round again.
  if (( after >= EXPECTED_MIN )); then break; fi
done

if (( after < EXPECTED_MIN )); then
  err "the offline index holds $after documents, expected at least $EXPECTED_MIN."
  err "Check the bie-index log: an import that finds no archive, or one whose core rowType"
  err "is not dwc:Taxon, logs the problem and reports success."
  docker logs --tail 60 "$BIE_INDEX_CONTAINER" 2>&1 | sed 's/^/    | /' >&2 || true
  finish 1
fi

# ---------------------------------------------------------------- promote
# bie-index's own promote step (import.sequence's `swap`) is a SolrCloud SWAP on the
# literal core names and cannot work here, so it is not in the sequence we render. Cross
# the two aliases instead: atomic, and it leaves the previous live index intact as the
# next offline one, so the model ping-pongs across imports.
log "promoting: bie -> $OFFLINE_TARGET, bie-offline -> $LIVE_TARGET"
for pair in "bie:$OFFLINE_TARGET" "bie-offline:$LIVE_TARGET"; do
  a="${pair%%:*}"; t="${pair##*:}"
  out=$(solr -X POST "$SOLR_BASE/admin/collections?action=CREATEALIAS&name=$a&collections=$t&wt=json")
  case "$out" in *'"failure"'*) err "CREATEALIAS $a -> $t failed: $out"; finish 1 ;; esac
done

new_live=$(alias_target bie)
[[ "$new_live" == "$OFFLINE_TARGET" ]] \
  || { err "the live alias did not move: bie still points at '$new_live'"; finish 1; }

live_docs=$(num_found bie)
log "live index (bie -> $new_live) holds $live_docs documents"
(( live_docs >= EXPECTED_MIN )) || { err "live index holds $live_docs documents after the swap"; finish 1; }

# ---------------------------------------------------------------- end-to-end assertion
# Through bie-index over the PUBLIC vhost, not through Solr and not over the container
# network: this is the exact request the gatus check and the Cypress species spec make, and
# the one that was answering 200 with totalRecords:0. Anything closer to Solr would prove
# less than the checks it is meant to make honest.
total=$(taxon_total "$BIE_PUBLIC_URL/search?q=Acacia&pageSize=0")
log "bie-index /search?q=Acacia -> totalRecords=$total"
if (( total < 1 )); then
  err "Solr holds the taxa but bie-index returns none. Its live connection is index_live_url"
  err "in bie-index-config.yml; check it resolves to the 'bie' ALIAS and not to a collection."
  finish 1
fi

log "OK: $live_docs documents live, /search?q=Acacia returns $total"
exit 0
