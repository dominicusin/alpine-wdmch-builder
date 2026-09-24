#!/usr/bin/env python3
"""Resolve the full transitive dependency closure for a set of Alpine packages.

Reads APKINDEX.tar.gz (main + community) and computes which .apk files are
needed to install the given seed packages. Outputs a sorted list of filenames.

Usage:
  python3 tools/resolve-apk-closure.py \
      --main  build/usb-tree/apks/main/APKINDEX.tar.gz \
      --community build/usb-tree/apks/community/APKINDEX.tar.gz \
      alpine-base alpine-keys musl busybox-static busybox openrc ...

This is used by image/package-rescue.sh to populate the offline apk pool
on the USB rescue stick.
"""
import argparse
import subprocess
import sys
import tarfile
import re

def parse_apkindex(path):
    """Return dict: pkg_name -> {'version': str, 'depends': [str], 'filename': str}."""
    idx = {}
    try:
        tf = tarfile.open(path, 'r:gz')
    except Exception as e:
        print(f"WARNING: cannot open {path}: {e}", file=sys.stderr)
        return idx
    for member in tf.getmembers():
        if not member.name.endswith('APKINDEX'):
            continue
        f = tf.extractfile(member)
        if f is None:
            continue
        raw = f.read().decode('utf-8', errors='replace')
        # Split into per-package records by double-newline (Alpine APKINDEX format)
        records = re.split(r'\n\n+', raw.strip())
        for rec in records:
            lines = rec.split('\n')
            name = version = filename = None
            depends = []
            for line in lines:
                if line.startswith('P:'):
                    name = line[2:]
                elif line.startswith('V:'):
                    version = line[2:]
                elif line.startswith('F:'):
                    filename = line[2:]
                elif line.startswith('D:'):
                    # D: followed by space-separated dependencies, possibly with
                    # relational operators like 'apk-tools'=2.14.6-r3
                    dep_str = line[2:]
                    for d in dep_str.split():
                        # strip relational suffix like =2.14.6-r3
                        m = re.match(r'^([A-Za-z0-9_\.\-]+)', d)
                        if m:
                            depends.append(m.group(1))
                elif line.startswith('i:'):
                    pass  # installable arch — ignore
            if name and version and filename:
                idx[name] = {'version': version, 'depends': depends, 'filename': filename}
    return idx

def resolve_closure(main_idx, community_idx, seeds):
    """BFS transitive closure over both indexes."""
    combined = {}
    combined.update(main_idx)
    combined.update(community_idx)  # community overrides main on name clash (rare)

    want = set(seeds)
    seen = set()
    queue = list(seeds)
    missing = []

    while queue:
        pkg = queue.pop()
        if pkg in seen:
            continue
        seen.add(pkg)
        entry = combined.get(pkg)
        if entry is None:
            missing.append(pkg)
            continue
        for dep in entry['depends']:
            dep = dep.replace('_', '-')  # normalize
            if dep not in seen and dep not in want:
                want.add(dep)
                queue.append(dep)

    filenames = []
    for pkg in sorted(want):
        entry = combined.get(pkg)
        if entry:
            filenames.append(entry['filename'])
        elif pkg not in missing:
            missing.append(pkg)
    return filenames, missing

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--main', required=True, help='path to main/APKINDEX.tar.gz')
    parser.add_argument('--community', required=True, help='path to community/APKINDEX.tar.gz')
    parser.add_argument('seeds', nargs='+', help='package names to resolve')
    args = parser.parse_args()

    main_idx = parse_apkindex(args.main)
    community_idx = parse_apkindex(args.community)

    filenames, missing = resolve_closure(main_idx, community_idx, args.seeds)

    for fn in filenames:
        print(fn)
    if missing:
        print(f"\n# WARNING: {len(missing)} seed/package(s) not found in indexes:", file=sys.stderr)
        for m in missing:
            print(f"#   {m}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
