#!/usr/bin/env bash
# Prove that every healthcheck command is a binary its image actually ships.
#
# Why this exists: on 2026-09-09 tiredofit/db-backup:latest was replaced upstream by a
# distroless retirement stub with no shell and no coreutils. db-backup's healthcheck,
# ["CMD", "test", "-d", "/backup"], could no longer even be exec'd -- Docker reports
#   exec: "test": executable file not found in $PATH
# and sets the container unhealthy forever. wait-for-health.sh has no ignore list, so the
# two hosts carrying db-backup burned the whole converge budget and the deploy failed.
# Nothing in the repo could have caught it: the compose file is valid, the template
# renders, the include exists. Only asking the IMAGE can.
#
# What it checks, per service of a rendered compose project:
#   healthcheck.test == ["CMD", <argv...>]       -> is <argv[0]> executable in the image?
#   healthcheck.test == ["CMD-SHELL", "..."]     -> is a shell present? (implicit /bin/sh)
# It probes with `docker run --rm --entrypoint`, so it is exact rather than heuristic, and
# it only reads. Images absent from the local cache are reported SKIP unless --pull.
#
# Usage:
#   scripts/validate-healthcheck-commands.sh [--compose-dir DIR] [--pull] [--service NAME]
# Default DIR is /data/docker-compose (the single runtime, local and CI).
set -uo pipefail

COMPOSE_DIR="/data/docker-compose"
PULL=false
ONLY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --compose-dir) COMPOSE_DIR="$2"; shift 2 ;;
        --service)     ONLY="$2"; shift 2 ;;
        --pull)        PULL=true; shift ;;
        -h|--help)     sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
    echo "SKIP: no rendered compose project at $COMPOSE_DIR/docker-compose.yml"
    echo "      (this check reads a RENDERED project; generate one with ansiblew first)"
    exit 0
fi

if ! docker version >/dev/null 2>&1; then
    echo "SKIP: docker is not available, cannot ask images what they ship"
    exit 0
fi

# (service, image, test[0], test[1]) for every healthcheck that execs something.
mapfile -t ROWS < <(
    docker compose -f "$COMPOSE_DIR/docker-compose.yml" config --format json 2>/dev/null |
    python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception as exc:                       # noqa: BLE001 - message, not a traceback
    print("PARSE-ERROR", exc, file=sys.stderr)
    sys.exit(1)
for name, svc in sorted((doc.get("services") or {}).items()):
    hc = svc.get("healthcheck") or {}
    test = hc.get("test") or []
    if isinstance(test, str):
        test = ["CMD-SHELL", test]
    if not test or test[0] in ("NONE",) or len(test) < 2:
        continue
    image = svc.get("image")
    if not image:
        continue
    binary = "/bin/sh" if test[0] == "CMD-SHELL" else test[1]
    print("\t".join((name, image, test[0], binary)))
'
) || { echo "FAIL: could not read $COMPOSE_DIR/docker-compose.yml" >&2; exit 1; }

if [[ ${#ROWS[@]} -eq 0 ]]; then
    echo "SKIP: no exec-style healthchecks found in $COMPOSE_DIR"
    exit 0
fi

fail=0 ok=0 skipped=0
for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r service image kind binary <<< "$row"
    [[ -n "$ONLY" && "$service" != "$ONLY" ]] && continue

    if ! docker image inspect "$image" >/dev/null 2>&1; then
        if [[ "$PULL" == true ]]; then
            docker pull --quiet "$image" >/dev/null 2>&1 || true
        fi
        if ! docker image inspect "$image" >/dev/null 2>&1; then
            echo "SKIP  $service ($image not in the local cache; re-run with --pull)"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    # `--entrypoint <binary>` with no command: the container init fails BEFORE the binary
    # runs if it is missing, which is exactly the signal we want. A binary that exists but
    # dislikes its (absent) arguments exits non-zero with its own message, and passes.
    # timeout(1): a binary that exists and happens to IGNORE the unknown argument would
    # otherwise run as long as its normal entrypoint does. 20s is generous for a probe that
    # only has to get past container init, and a timeout counts as "the binary is there".
    err=$(timeout 20 docker run --rm --entrypoint "$binary" "$image" --dbb-healthcheck-probe 2>&1 >/dev/null)
    if grep -qE 'executable file not found|no such file or directory|exec format error' <<< "$err"; then
        echo "FAIL  $service: healthcheck runs '$binary' ($kind) but $image does not ship it"
        echo "        $(head -1 <<< "$err")"
        fail=$((fail + 1))
    else
        echo "ok    $service: $binary present in $image"
        ok=$((ok + 1))
    fi
done

echo
echo "healthcheck commands: ${ok} ok, ${fail} missing, ${skipped} skipped"
[[ $fail -eq 0 ]]
