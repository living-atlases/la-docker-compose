#!/usr/bin/env python3
"""Print path, short sha256, mode and owner of every member of a bundle tgz, sorted.

Hashes only: the bundle holds secrets, the manifest does not, so manifests are what two
bundles are compared by (TASK-50 bundle spike). Usage: manifest.py BUNDLE.tgz
"""
import hashlib
import sys
import tarfile

rows = []
with tarfile.open(sys.argv[1], 'r:gz') as t:
    for m in t:
        if m.isfile():
            h = hashlib.sha256(t.extractfile(m).read()).hexdigest()[:16]
        elif m.issym():
            h = 'link:' + m.linkname
        elif m.isdir():
            h = 'dir'
        else:
            h = 'type:' + str(m.type)
        rows.append(f"{m.name}\t{h}\t{oct(m.mode)}\t{m.uname or m.uid}:{m.gname or m.gid}")
print('\n'.join(sorted(rows)))
