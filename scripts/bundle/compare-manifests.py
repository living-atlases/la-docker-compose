#!/usr/bin/env python3
"""Compare a rendered bundle's manifest with a deployed host's (see manifest.py).

Prints counts, then the paths per class: only on the host, only in the render, different
content, different mode/owner. Paths and hashes only, never content. Directories grouped two
levels under /data so runtime state (app data inside bind-mounted dirs) reads at a glance.
Usage: compare-manifests.py RENDER.manifest HOST.manifest [--label NAME] [--limit N]
Always exits 0: it reports, the reader judges.
"""
import argparse
import collections


def load(path):
    d = {}
    with open(path) as f:
        for line in f:
            parts = line.rstrip('\n').split('\t')
            if len(parts) == 4:
                d[parts[0]] = tuple(parts[1:])
    return d


def group(paths):
    c = collections.Counter('/'.join(p.split('/')[:4]) for p in paths)
    return ', '.join(f"{k} ({v})" for k, v in c.most_common())


ap = argparse.ArgumentParser()
ap.add_argument('render')
ap.add_argument('host')
ap.add_argument('--label', default='')
ap.add_argument('--limit', type=int, default=40)
a = ap.parse_args()
r, h = load(a.render), load(a.host)
common = set(r) & set(h)
only_h = sorted(set(h) - set(r))
only_r = sorted(set(r) - set(h))
content = sorted(p for p in common if r[p][0] != h[p][0] and r[p][0] != 'dir')
perm = sorted(p for p in common if r[p][0] == h[p][0] and r[p][1:] != h[p][1:])
same = len(common) - len(content) - len(perm)
print(f"BUNDLE-COMPARE {a.label} render={len(r)} host={len(h)} identical={same} "
      f"content-diff={len(content)} perm-diff={len(perm)} only-host={len(only_h)} only-render={len(only_r)}")
print(f"  only on the host, by dir: {group(only_h) or '-'}")
print(f"  only in the render, by dir: {group(only_r) or '-'}")
for p in content[:a.limit]:
    print(f"  content-diff {p}")
for p in perm[:a.limit]:
    print(f"  perm-diff {p} render={'/'.join(r[p][1:])} host={'/'.join(h[p][1:])}")
