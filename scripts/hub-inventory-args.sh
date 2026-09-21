#!/usr/bin/env bash
# Prints the `-i <file>` arguments for the data-hub inventories that sit next to the
# portal's, so the CI's ansible-playbook run loads them the way the generated
# ansiblew does for the compose leg.
#
# Why: the portal inventory declares each hub's groups (biocache-hub-<pkg>, ...) EMPTY
# on purpose; only <pkg>-inventories/<pkg>-inventory.ini gives them hosts. la-compose
# includes a hub only when one of those groups holds the current host, so a run that
# loads just the portal inventory resolves no alias and silently renders no hub.
#
# Usage: hub-inventory-args.sh <inventories-parent-dir> <portal-inventories-dir>
# Prints nothing when there are no hubs, so a portal without hubs runs unchanged.
set -eu

parent=${1:?usage: hub-inventory-args.sh <parent-dir> <portal-inventories-dir>}
portal=${2:?usage: hub-inventory-args.sh <parent-dir> <portal-inventories-dir>}

args=""
for f in "${parent}"/*-inventories/*-inventory.ini; do
    [ -f "$f" ] || continue
    dir=$(dirname "$f")
    [ "$dir" = "${portal%/}" ] && continue                # the portal's own
    pkg=$(basename "$dir" -inventories)
    [ "$(basename "$f")" = "${pkg}-inventory.ini" ] || continue  # not a *-dev-docker- twin
    args="${args:+$args }-i $f"
done
printf '%s\n' "$args"
