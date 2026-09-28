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
nothing but a few stray files, which is all such an artifact ever contains, and leaves an
empty file in its place (a restarting container would otherwise recreate the directory
before the template runs). The template run that follows then writes the real file.

The same happens one level removed: a file mounted at a destination INSIDE another bind
mount of the service (/data/testhub-hub:/data/ala-hub plus a properties file at
/data/ala-hub/config/...) needs a mountpoint there, and Docker creates it on the HOST, in
the parent mount's source. Created while the file was still missing, it is a directory,
and the file mount then fails with "not a directory" forever (#421). Those host
mountpoints are cleaned the same way.

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
BIND = re.compile(r"""^\s*-\s*["']?(/[^:"'\s]+):(/[^:"'\s]*)""")


def binds(compose_dir):
    """Yields the (source, destination) bind mounts of each compose file, as a list."""
    files = [os.path.join(compose_dir, "docker-compose.yml")]
    files += glob.glob(os.path.join(compose_dir, "**", "*.yml"), recursive=True)
    for path in sorted(set(files)):
        try:
            lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        yield [m.groups() for m in map(BIND.match, lines) if m]


def nested_mountpoints(mounts):
    """Host paths of the mountpoints Docker needs for file mounts nested in a dir mount."""
    dirs = [(s, d.rstrip("/")) for s, d in mounts if os.path.isdir(s) and not FILE_LIKE.search(s)]
    for src, dst in mounts:
        if not (os.path.isfile(src) or is_artifact(src)):
            continue
        parents = [(s, d) for s, d in dirs if dst.startswith(d + "/")]
        if parents:
            psrc, pdst = max(parents, key=lambda p: len(p[1]))
            yield psrc + dst[len(pdst):]


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
    candidates = set()
    for mounts in binds(compose_dir):
        candidates.update(s for s, _ in mounts)
        candidates.update(nested_mountpoints(mounts))
    for src in sorted(candidates):
        if is_artifact(src):
            if not dry_run:
                parent = os.stat(os.path.dirname(src))
                shutil.rmtree(src)
                # Leave an empty FILE, not nothing: a crash-looping container that mounts
                # this path restarts within seconds, and Docker would recreate the
                # directory before the template gets to write the file (#420).
                open(src, "w").close()
                os.chmod(src, 0o644)
                try:
                    os.chown(src, parent.st_uid, parent.st_gid)
                except PermissionError:
                    pass
            print("removed %s" % src)
            removed += 1
    print("removed %d" % removed)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
