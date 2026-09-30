#!/usr/bin/env python3
"""Copy a bundle adding one harmless file to one watched config dir (TASK-50 apply spike).

A controlled config change for the CI: host-apply.sh must restart that service and only
that one; applying the original bundle afterwards must delete the file again (dropped by
the render) and restart it once more, leaving the host as it was.

Picks the first config_watch entry of the bundle's .bundle-meta.json whose dir the bundle
carries files for (so the host hashes it). Never reads or prints any file content.

Usage: add-marker.py SRC.tgz DST.tgz   ->  prints "<service> <marker path>"
"""
import io
import json
import os
import sys
import tarfile
import time

src, dst = sys.argv[1], sys.argv[2]
with tarfile.open(src) as t:
    members = t.getmembers()
    metas = [m for m in members if m.name.endswith("/.bundle-meta.json")]
    if len(metas) != 1:
        sys.exit("the bundle must carry exactly one .bundle-meta.json")
    meta = json.load(t.extractfile(metas[0]))
    files = [m.name for m in members if m.isfile()]
    pick = None
    for e in meta["config_watch"]:
        d = e["path"].rstrip("/") + "/"
        if any(f.startswith(d) for f in files):
            pick = e
            break
    if pick is None:
        sys.exit("no watched config dir in the bundle")
    marker = pick["path"].rstrip("/") + "/.la-bundle-apply-spike"
    data = ("bundle apply spike marker %d\n" % time.time()).encode()
    old = os.umask(0o077)
    try:
        with tarfile.open(dst, "w:gz") as o:
            for m in members:
                o.addfile(m, t.extractfile(m) if m.isfile() else None)
            info = tarfile.TarInfo(marker)
            info.size, info.mode, info.mtime = len(data), 0o644, int(time.time())
            info.uid, info.gid, info.uname, info.gname = 0, 0, "root", "root"
            o.addfile(info, io.BytesIO(data))
    finally:
        os.umask(old)
print(pick["service"], marker)
