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
                # provider: name=version. Shared objects appear here as
                # so:libfoo.so.1=1.2 - APKINDEX v2 has no separate So: line
                # (S: is the installed size), so this is the only place
                # sonames exist.
                parts = line[2:].split('=', 1)
                if len(parts) == 2:
                    provides[parts[0]] = parts[1]
                elif parts and parts[0]:
                    provides[parts[0]] = ''
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
    
    # Index by soname/provider.
    #
    # APKINDEX v2 has no `So:` line at all - `S:` is the installed size and
    # every shared object arrives as `p:so:<soname>=<version>`. The keys
    # stored here MUST therefore be the BARE soname, because that is what the
    # dependency walk below looks up (it strips the `so:` prefix off a `D:`
    # entry). Indexing the prefixed form makes every `so:` dependency
    # unresolvable and silently truncates the closure - which is how
    # e2fsprogs ended up on the USB stick without e2fsprogs-libs, libblkid,
    # libuuid and libcom_err, so mke2fs could not run at all.
    soname_to_pkg = {}
    for pkgname, info in all_pkgs.items():
        for prov, ver in info.get('provides', {}).items():
            key = prov[3:] if prov.startswith('so:') else prov
            if not key:
                continue
            soname_to_pkg.setdefault(key, [])
            if pkgname not in soname_to_pkg[key]:
                soname_to_pkg[key].append(pkgname)
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
                    if pkgname not in soname_to_pkg[cmdname]:
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
            # APKINDEX v2 encodes conflicts in D: with a leading '!', e.g.
            # "D:!vlan". That is a negative constraint, not a dependency -
            # treating it as a package name makes the resolver look for a
            # package called "!vlan" and report it missing.
            if dep.startswith('!'):
                continue
            # Skip virtual deps like so:libc.musl-aarch64.so.1
            if dep.startswith('so:'):
                # The version suffix is stripped even though current Alpine
                # does not emit one here (all 6411 so: entries in the pinned
                # index are bare). The provides side is split on '=' and
                # indexed by bare soname, so leaving the version attached here
                # would look up a key that can never exist - and a key that
                # never exists is silently skipped three lines below, which is
                # precisely the e2fsprogs failure described above: a truncated
                # closure that still looks complete. If a future index format
                # versions these, the cost of being wrong is an unbootable
                # install and the cost of being ready is one split.
                soname = re.split(r'[><=]', dep[3:])[0]
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
            # Skip virtual provides that are paths
            pkg = re.split(r'[><=]', dep)[0]
            if pkg.startswith('/'):
                continue
            if pkg not in processed and pkg not in missing:
                # A dependency name is either a real package or a virtual
                # satisfied through a provider. Try the real package first,
                # then the provider index - never guess a hardcoded package
                # name. (The old code mapped `ifupdown-any` to
                # "ifupdown-ng-openrc", which is a *virtual* provided by
                # openrc, not a package; the real one is `ifupdown-ng`.)
                if pkg in all_pkgs or pkg not in soname_to_pkg:
                    to_process.append(pkg)
                else:
                    for provider in soname_to_pkg[pkg]:
                        if provider not in processed and provider not in missing:
                            to_process.append(provider)
                            break
                    else:
                        to_process.append(pkg)
    
    return sorted(filenames), missing

def main():
    parser = argparse.ArgumentParser(description='Resolve Alpine package dependencies')
    parser.add_argument('--main', required=True, help='Path to main APKINDEX.tar.gz')
    parser.add_argument('--community', required=True, help='Path to community APKINDEX.tar.gz')
    parser.add_argument('--tsv', action='store_true',
                        help='emit "repo<TAB>name<TAB>version<TAB>filename" instead of bare filenames')
    parser.add_argument('seeds', nargs='+', help='Seed package names')
    args = parser.parse_args()

    main_index = parse_apkindex(args.main)
    community_index = parse_apkindex(args.community)

    filenames, missing = resolve_closure(main_index, community_index, args.seeds)

    # Track which repo each selected package actually lives in, so a downloader
    # never has to re-derive the package name from the filename (which is
    # ambiguous for names containing dashes and version-like segments).
    origin = {}
    for pkg, info in community_index.items():
        origin[pkg] = 'community'
    for pkg, info in main_index.items():
        origin.setdefault(pkg, 'main')

    by_filename = {}
    for pkg, info in community_index.items():
        by_filename[info['filename']] = ('community', pkg, info['version'])
    for pkg, info in main_index.items():
        by_filename.setdefault(info['filename'], ('main', pkg, info['version']))

    if args.tsv:
        for f in filenames:
            repo, pkg, ver = by_filename.get(f, ('main', '?', '?'))
            print(f"{repo}\t{pkg}\t{ver}\t{f}")
    else:
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
        # An unresolved dependency is fatal, and it is fatal AFTER the closure
        # is printed above, which is deliberate: the partial closure is what
        # makes the failure debuggable, and nothing consumes stdout when the
        # exit status is non-zero.
        #
        # This used to be a WARNING with exit 0. The caller checked for a
        # non-zero status and for an empty closure, and a partial closure is
        # neither - so a stick was built missing a library, apk add failed on
        # the WDMCH after the disk was already being written, and the only
        # clue was a warning in a build log. Same class as the nine other
        # defects in this series: the run said it worked and it had not.
        print(f"ERROR: {len(missing)} packages could not be resolved: "
              f"{', '.join(missing)}", file=sys.stderr)
        print(f"       The closure above is INCOMPLETE and must not be packaged.",
              file=sys.stderr)
        print(f"       Missing names recorded in {fail_file}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

if __name__ == '__main__':
    main()
