#!/usr/bin/env bash
# Summary of the Jenkins `CA distrust check` stage: reads ca-distrust/<host>.tsv (the
# output of scripts/ca-distrust-ci-collect.sh on each host), prints every store that
# still trusts a distrusted root or could not be read, and exits 1 when any trusts one
# (the stage turns that into UNSTABLE). ERR alone does not fail: an image may ship no
# bundle at all.
#
# EXEMPT below holds the images triaged as not worth chasing, each with its reason and a
# review date. A trust store is only ever consulted when the container connects OUT, and
# most of what this check flags is a third-party SERVER image: it accepts TLS and never
# initiates it, so the revoked root sits there unused. Those tags are also pinned and
# immutable, built before the distrust, so no pull can carry the fix and "updating" them
# means changing a datastore's version in production. Our own images are NOT exempt: they
# are ours to rebuild, and the ones that are TLS clients are exactly the ones that matter.
# An exemption that outlives its `until` fails again, so none of this is permanent.
set -u
dir="${1:?usage: $0 <dir with <host>.tsv files>}"
today="${CA_DISTRUST_TODAY:-$(date -u +%Y-%m-%d)}"

# CA_DISTRUST_EXEMPT overrides the table below (tests only), and CA_DISTRUST_TODAY the
# date the review dates are compared against.
#
# image (as `docker ps` names it) | until | reason
EXEMPT="${CA_DISTRUST_EXEMPT-$(cat <<'TSV'
mailhog/mailhog:v1.0.1|2027-05-12|Mail catcher with no relay: the stack sets MH_HOSTNAME and no MH_OUTGOING_SMTP, so it accepts SMTP and never dials out. Upstream image frozen since 2020-08-11.
ghcr.io/google/cadvisor:v0.60.6|2027-05-12|Reads the local docker socket and serves metrics; no remote storage driver is configured anywhere in this repo, so it is never a TLS client. Tag built 2026-09-18, before the distrust.
solr:8.11.4|2027-05-12|Server role here: it accepts TLS and never initiates it. Pinned immutable tag built 2024-09-24, so no pull can carry the fix. Revisit if replication or remote streaming to an outside host is ever configured.
docker.elastic.co/elasticsearch/elasticsearch:7.17.29|2027-05-12|Server role here (DOI storage): it accepts TLS and never initiates it. Pinned immutable tag built 2025-06-19, before the distrust. Revisit if a remote snapshot repository or reindex-from-remote is ever configured.
postgis/postgis:16-3.4-alpine|2027-05-12|Server role here: it accepts TLS and never initiates it. Pinned immutable tag built 2024-10-14. Revisit if postgres_fdw or dblink to an outside host is ever configured.
cassandra:5.0.6|2027-05-12|Server role here: it accepts TLS and never initiates it. Pinned immutable tag built 2026-03-17, before the distrust.
TSV
)}"

w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT

shopt -s nullglob
files=("$dir"/*.tsv)
[ ${#files[@]} -gt 0 ] || { echo "ca-distrust: no reports in $dir"; exit 1; }

trusts=0
exempt=0
for f in "${files[@]}"; do
  host="$(basename "$f" .tsv)"
  # Reclassify TRUSTS -> EXEMPT for a listed image whose review date has not passed.
  # Matched with or without a registry prefix, as the trivy image ignores are.
  awk -F'\t' -v OFS='\t' -v tbl="$EXEMPT" -v today="$today" '
    BEGIN {
      n = split(tbl, rows, "\n")
      for (i = 1; i <= n; i++) {
        if (rows[i] == "") continue
        split(rows[i], c, "|")
        until_[c[1]] = c[2]; why[c[1]] = c[3]
        short = c[1]; sub(/^[^\/]*\.[^\/]*\//, "", short)
        if (short != c[1]) { until_[short] = c[2]; why[short] = c[3] }
      }
    }
    $4 == "TRUSTS" && ($2 in until_) {
      if (today <= until_[$2]) { $4 = "EXEMPT"; $5 = $5 " -- " why[$2] }
      else { $5 = $5 " -- EXEMPTION EXPIRED " until_[$2] ": " why[$2] }
    }
    { print }
  ' "$f" >"$w/cls"

  n_ok=$(awk -F'\t' '$4 == "OK"' "$w/cls" | wc -l)
  n_bad=$(awk -F'\t' '$4 == "TRUSTS"' "$w/cls" | wc -l)
  n_ex=$(awk -F'\t' '$4 == "EXEMPT"' "$w/cls" | wc -l)
  n_err=$(awk -F'\t' '$4 == "ERR"' "$w/cls" | wc -l)
  echo "ca-distrust: $host: $n_bad trusting, $n_ex exempt, $n_ok ok, $n_err unreadable"
  awk -F'\t' -v h="$host" '$4 != "OK" {printf "  %-7s %s %s (%s) %s\n", $4, h, $1, $2, $3 ": " $5}' "$w/cls"
  trusts=$((trusts + n_bad))
  exempt=$((exempt + n_ex))
done

if [ "$trusts" -gt 0 ]; then
  echo "ca-distrust: $trusts trust store(s) still trust a distrusted root: rebuild or update those images"
  exit 1
fi
if [ "$exempt" -gt 0 ]; then
  echo "ca-distrust: OK ($exempt exempt, each with its reason above)"
else
  echo "ca-distrust: OK"
fi
