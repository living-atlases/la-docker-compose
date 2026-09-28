#!/usr/bin/env python3
"""Remove the directories Docker leaves where a bind-mounted FILE should be.

When `docker compose up` runs while the source of a file bind mount is missing, Docker
creates a root-owned DIRECTORY at that path. From then on the Ansible template that
should write the file is handed a directory as dest and writes its output INSIDE it
(nginx.conf/nginx.conf.j2, testhub-hub-config.properties/config.properties), so the
container keeps failing to start ("not a directory") or reads no config, build after
build. Seen on docker-1 for nginx.conf and a data hub's config (#417-#419).

Reads the compose files already rendered under COMPOSE_DIR (the previous run's; this
runs before anything is rendered again), and for each bind mount whose source looks
like a file (it has an extension) but is a directory, removes it -- only when it holds
nothing but a few stray files, which is all such an artifact ever contains. The
template run that follows then writes the real file.

Usage: remove-file-mount-artifacts.py COMPOSE_DIR [--dry-run]
Prints one "removed <path>" line per artifact, then "removed N".
"""
import glob
import os
import re
import shutil
import sys

FILE_LIKE = re.compile(r"\.(properties|conf|xml|ya?ml|json|txt|ini|sh|js|css|html|pem|key|crt)$")
MAX_STRAY_ENTRIES = 3


# Short-syntax bind mounts, which is all the rendered compose files use:
#   - /data/x/config/x-config.properties:/data/ala-hub/config/ala-hub-config.properties:ro
# Parsed as text on purpose: the compose hosts need not have PyYAML.
BIND = re.compile(r"""^\s*-\s*["']?(/[^:"'\s]+):/""")


def bind_sources(compose_dir):
    files = [os.path.join(compose_dir, "docker-compose.yml")]
    files += glob.glob(os.path.join(compose_dir, "**", "*.yml"), recursive=True)
    for path in sorted(set(files)):
        try:
            lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        for line in lines:
            m = BIND.match(line)
            if m:
                yield m.group(1)


def is_artifact(path):
    if not (FILE_LIKE.search(path) and os.path.isdir(path) and not os.path.islink(path)):
        return False
    entries = os.listdir(path)
    return len(entries) <= MAX_STRAY_ENTRIES and all(
        os.path.isfile(os.path.join(path, e)) for e in entries
    )


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    compose_dir, dry_run = argv[1], "--dry-run" in argv[2:]
    removed = 0
    for src in sorted(set(bind_sources(compose_dir))):
        if is_artifact(src):
            if not dry_run:
                shutil.rmtree(src)
            print("removed %s" % src)
            removed += 1
    print("removed %d" % removed)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
