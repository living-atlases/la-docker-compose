#!/usr/bin/env bash
# Summary of the Jenkins `CA distrust check` stage: reads ca-distrust/<host>.tsv (the
# output of scripts/ca-distrust-ci-collect.sh on each host), prints every store that
# still trusts a distrusted root or could not be read, and exits 1 when any trusts one
# (the stage turns that into UNSTABLE). ERR alone does not fail: a distroless image
# has no bundle to read.
set -u
dir="${1:?usage: $0 <dir with <host>.tsv files>}"
shopt -s nullglob
files=("$dir"/*.tsv)
[ ${#files[@]} -gt 0 ] || { echo "ca-distrust: no reports in $dir"; exit 1; }
trusts=0
for f in "${files[@]}"; do
  host="$(basename "$f" .tsv)"
  n_ok=$(awk -F'\t' '$4 == "OK"' "$f" | wc -l)
  n_bad=$(awk -F'\t' '$4 == "TRUSTS"' "$f" | wc -l)
  n_err=$(awk -F'\t' '$4 == "ERR"' "$f" | wc -l)
  echo "ca-distrust: $host: $n_bad trusting, $n_ok ok, $n_err unreadable"
  awk -F'\t' -v h="$host" '$4 != "OK" {printf "  %-7s %s %s (%s) %s\n", $4, h, $1, $2, $3 ": " $5}' "$f"
  trusts=$((trusts + n_bad))
done
if [ "$trusts" -gt 0 ]; then
  echo "ca-distrust: $trusts trust store(s) still trust a distrusted root: rebuild or update those images"
  exit 1
fi
echo "ca-distrust: OK"
