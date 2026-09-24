#!/usr/bin/env python3
"""
Resolve Alpine package dependency closure.

Given a set of seed package names and APKINDEX.tar.gz files, compute the
transitive closure of all dependencies and output package filenames.

Usage:
    python3 resolve-deps.py --main APKINDEX.tar.gz --community APKINDEX.tar.gz \
        pkg1 pkg2 pkg3 ...
"""
import argparse
import tarfile
import sys
import re
import os

def parse_apkindex(path):
    """Parse an APKINDEX.tar.gz and return dict {pkgname: {version, arch, deps, provides, filename}}."""
    result = {}
    try:
        tf = tarfile.open(path, 'r:gz')
    except Exception as e:
        print(f"ERROR: cannot open {path}: {e}", file=sys.stderr)
        return result
    
    data = None
    for member in tf.getmembers():
        if not member.name.endswith('APKINDEX'):
            continue
        f = tf.extractfile(member)
        if f is None:
            continue
        data = f.read().decode('utf-8', errors='replace')
        tf.close()
        break
    
    if data is None:
        print(f"WARNING: no APKINDEX found in {path}", file=sys.stderr)
        return result
    
    # APKINDEX format: records separated by blank lines
    # Each record has fields like:
    # C:checksum
    # P:name
    # V:version
    # A:arch
    # S:size
    # I:instantiated
    # T:description
    # U:url
    # L:license
    # o:origin
    # m:maintainer
    # t:timestamp
    # c:checksum (package)
    # D:dep1 dep2 ...
    # p:provider=version
    # So:soname=version
    # FILENAME:filename.apk  (optional, may be absent)
    records = re.split(r'\n\n+', data.strip())
    
    for rec in records:
        lines = rec.split('\n')
        name = version = arch = None
        deps = []
        provides = {}
        filename = None
        
        for line in lines:
            if line.startswith('P:'):
                name = line[2:]
            elif line.startswith('V:'):
                version = line[2:]
            elif line.startswith('A:'):
                arch = line[2:]
            elif line.startswith('D:'):
                deps.extend(line[2:].split())
            elif line.startswith('p:'):
                # provider: providername=version
                parts = line[2:].split('=', 1)
                if len(parts) == 2:
                    provides[parts[0]] = parts[1]
            elif line.startswith('So:'):
                # soname: libname=version
                parts = line[2:].split('=', 1)
                if len(parts) == 2:
                    provides[parts[0]] = parts[1]
            elif line.startswith('FILENAME:'):
                filename = line[9:]
        
        if name and version:
            # Construct filename: Alpine servers use {name}-{version}.apk
            # (no arch suffix in filename, arch is implicit in the repo path)
            if not filename:
                filename = f"{name}-{version}.apk"
            result[name] = {
                'version': version,
                'arch': arch,
                'deps': deps,
                'provides': provides,
                'filename': filename,
            }
    
    return result

def resolve_closure(main_index, community_index, seeds):
    """
    Compute transitive dependency closure.
    Returns (sorted_list_of_filenames, missing_packages).
    """
    # Merge indexes
    all_pkgs = {}
    all_pkgs.update(main_index)
    all_pkgs.update(community_index)
    
    # Index by soname/provider for So: resolution
    soname_to_pkg = {}
    for pkgname, info in all_pkgs.items():
        for soname, ver in info.get('provides', {}).items():
            if soname not in soname_to_pkg:
                soname_to_pkg[soname] = []
            soname_to_pkg[soname].append(pkgname)
        # Index by provided cmd: and file paths
        for dep in info.get('deps', []):
            if dep.startswith('p:'):
                parts = dep[2:].split('=', 1)
                if len(parts) == 2:
                    cmdname = parts[0]
                    if cmdname.startswith('cmd:'):
                        cmdname = cmdname[4:]
                    if cmdname not in soname_to_pkg:
                        soname_to_pkg[cmdname] = []
                    soname_to_pkg[cmdname].append(pkgname)
    
    # Also index /bin/sh provider
    for pkgname, info in all_pkgs.items():
        for dep in info.get('deps', []):
            if dep.startswith('/bin/sh'):
                if '/bin/sh' not in soname_to_pkg:
                    soname_to_pkg['/bin/sh'] = []
                soname_to_pkg['/bin/sh'].append(pkgname)
    
    # BFS closure
    to_process = list(seeds)
    processed = set()
    filenames = set()
    missing = []
    
    while to_process:
        pkgname = to_process.pop(0)
        if pkgname in processed:
            continue
        processed.add(pkgname)
        
        info = all_pkgs.get(pkgname)
        if info is None:
            # Try to find by soname/cmd
            if pkgname in soname_to_pkg:
                found = False
                for candidate in soname_to_pkg[pkgname]:
                    if candidate not in processed and candidate not in missing:
                        to_process.append(candidate)
                        found = True
                        break
                if not found:
                    missing.append(pkgname)
            else:
                missing.append(pkgname)
            continue
        
        if info.get('filename'):
            filenames.add(info['filename'])
        
        # Add dependencies
        for dep in info.get('deps', []):
            # Skip virtual deps like so:libc.musl-aarch64.so.1
            if dep.startswith('so:'):
                soname = dep[3:]
                if soname in soname_to_pkg:
                    for provider in soname_to_pkg[soname]:
                        if provider not in processed and provider not in missing:
                            to_process.append(provider)
                            break
                continue
            # Skip cmd: deps (these are virtual, resolved via soname_to_pkg)
            if dep.startswith('cmd:'):
                continue
            # Skip pc: deps (pkg-config)
            if dep.startswith('pc:'):
                continue
            # Skip virtual provides that are paths or special virtuals
            pkg = re.split(r'[><=]', dep)[0]
            if pkg.startswith('/') or pkg in ('ifupdown-any',):
                if pkg == 'ifupdown-any':
                    if 'ifupdown-ng-openrc' not in processed and 'ifupdown-ng-openrc' not in missing:
                        to_process.append('ifupdown-ng-openrc')
                continue
            if pkg not in processed and pkg not in missing:
                to_process.append(pkg)
    
    return sorted(filenames), missing

def main():
    parser = argparse.ArgumentParser(description='Resolve Alpine package dependencies')
    parser.add_argument('--main', required=True, help='Path to main APKINDEX.tar.gz')
    parser.add_argument('--community', required=True, help='Path to community APKINDEX.tar.gz')
    parser.add_argument('seeds', nargs='+', help='Seed package names')
    args = parser.parse_args()
    
    main_index = parse_apkindex(args.main)
    community_index = parse_apkindex(args.community)
    
    filenames, missing = resolve_closure(main_index, community_index, args.seeds)
    
    # Output filenames
    for f in filenames:
        print(f)
    
    if missing:
        fail_dir = os.environ.get('APK_CACHE', '.work/apk-cache-offline')
        if not fail_dir:
            fail_dir = '.work/apk-cache-offline'
        os.makedirs(fail_dir, exist_ok=True)
        fail_file = os.path.join(fail_dir, 'closure-fail.txt')
        with open(fail_file, 'w') as f:
            for m in missing:
                f.write(f"{m}\n")
        print(f"WARNING: {len(missing)} packages not found: {', '.join(missing)}", file=sys.stderr)

if __name__ == '__main__':
    main()
