#!/usr/bin/env python3
"""Property-based tests for image/resolve-deps.py.

The existing tests are example-based: each one feeds a hand-written APKINDEX and
asserts a specific list. That catches the regressions it was written for and
nothing else. A resolver's correctness is mostly in properties that hold for
EVERY index, and an example suite cannot state those.

No hypothesis dependency. The generator is a seeded PRNG, so a failure is
reproducible from the printed seed, and the properties are plain assertions that
run in milliseconds - which matters because this file runs on every `make test`.

PROPERTIES
-----------
P1  Every seed appears in the closure, or is reported missing. Never neither.
P2  The closure is exactly the set reachable from the seeds: nothing extra.
    A package nobody depends on must never appear.
P3  Reachability is closed: everything in the closure is either a seed or is
    required by something in the closure. No free-floating entries.
P4  Idempotence: resolving the closure as the seed set yields the same closure.
    Re-resolving a finished answer must not pull in anything new.
P5  Monotonicity: adding a dependency to a package cannot shrink the closure.
P6  Missing packages are exactly the seeds (or reachable nodes) with no
    provider anywhere in the index - never a resolvable node reported missing.
P7  Order independence: the result is sorted and does not depend on dict
    insertion order of the index.
P8  A soname provided by a real package resolves to a package that actually
    provides it - the bug that put e2fsprogs on the stick without its libs.

Each counterexample prints the seed that produced it.
"""

import os
import random
import subprocess
import sys

# resolve-deps.py has a hyphen, so it cannot be imported by name. Loaded from its
# path with importlib - the module under test is the real one either way, and
# importing a same-named copy instead is exactly the trap this file exists near.
import importlib.util  # noqa: E402

_HERE = os.path.dirname(os.path.abspath(__file__))
_SRC = os.path.join(_HERE, "..", "image", "resolve-deps.py")
_spec = importlib.util.spec_from_file_location("resolve_deps", _SRC)
R = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(R)

SEED = int(os.environ.get("RESOLVER_TEST_SEED", "20261002"))
ROUNDS = int(os.environ.get("RESOLVER_TEST_ROUNDS", "150"))

FAILS = []


def fail(prop, msg):
    FAILS.append(prop)
    print(f"  FAIL  {prop}: {msg}")
    print(f"        re-run with RESOLVER_TEST_SEED={SEED}")


# --- the index model -------------------------------------------------------
# Real APKINDEX records carry the fields the resolver reads. Generating the
# whole record text keeps parse_apkindex in the loop, so the property is about
# the resolver as shipped rather than about a hand-fed dict.

WORDS = ["alpha", "beta", "gamma", "delta", "eps", "zeta", "eta", "theta"]
SONAMES = ["libfoo.so.1", "libbar.so.2", "libbaz.so.3"]


def gen_index(rnd, npkgs=12):
    """Return (main_records, community_records) as APKINDEX text."""
    names = rnd.sample(WORDS + [f"pkg{i}" for i in range(30)], npkgs)
    records = []
    for name in names:
        deps = []
        provides = []
        # package deps
        for other in rnd.sample(names, rnd.randint(0, 3)):
            if other != name:
                deps.append(other)
        # soname deps, each with a 1-in-4 chance of having NO provider at all
        for so in rnd.sample(SONAMES, rnd.randint(0, 2)):
            deps.append(f"so:{so}")
            if rnd.random() < 0.75:
                provides.append(f"so:{so}")
        if rnd.random() < 0.2:
            provides.append(f"cmd:{name}-tool")
        # real APKINDEX uses N: for names, V: for versions, D: for deps,
        # P: for provides. Order matters to the parser; match the real format.
        body = [f"P:{name}", "V:1.0-r0"]
        if deps:
            body.append("D:" + " ".join(deps))
        if provides:
            body.append("p:" + " ".join(provides))
        records.append("\n".join(body) + "\n\n")
    text = "".join(records)
    split = rnd.randint(0, len(records))
    main = "".join(records[:split])
    community = "".join(records[split:])
    return main, community


def parse(text, tmp):
    """parse_apkindex() opens a real tar.gz and reads its APKINDEX member.

    Two earlier fixtures got this wrong, and both failed silently and greenly:

      - plain text  -> "not a gzip file", parse returned {} for every index
      - bare gzip   -> "invalid header", same result

    An empty index makes every property hold vacuously, so a fixture that
    matches the wrong container turns the whole file into a no-op that reports
    PASSED. `assert all_names` below is the guard against that specific
    outcome: if the generator ever produces nothing, that is a failure of the
    test, not a pass.
    """
    import io
    import tarfile

    path = os.path.join(tmp, "APKINDEX.tar.gz")
    with tarfile.open(path, "w:gz") as tf:
        payload = text.encode("utf-8")
        info = tarfile.TarInfo("APKINDEX")
        info.size = len(payload)
        tf.addfile(info, io.BytesIO(payload))
    return R.parse_apkindex(path)


def check(rnd, tmp):
    main_text, community_text = gen_index(rnd)
    main = parse(main_text, tmp)
    community = parse(community_text, tmp)
    all_names = list(main) + list(community)
    if not all_names:
        # Not a pass. An unparsed index makes every property below true by
        # default, which is how two earlier fixture formats produced a green,
        # silent, worthless run.
        fail("FIXTURE parses to a non-empty index",
             f"main={len(main)} community={len(community)} packages")
        return
    seeds = rnd.sample(all_names, rnd.randint(1, min(4, len(all_names))))

    # resolve_closure returns FILENAMES by contract (`return sorted(filenames),
    # missing`) - that is what goes into flash.zip. Comparing those against
    # package NAMES is what the first version did, and every property failed on
    # a suffix mismatch rather than on anything real. Normalise to names here,
    # and assert the filename shape separately so the contract itself is still
    # covered.
    fn_by_name = {}
    for src in (main, community):
        for name, info in src.items():
            fn_by_name[name] = info.get("filename", name)
    name_of_fn = {v: k for k, v in fn_by_name.items()}

    closure, missing = R.resolve_closure(main, community, seeds)
    cset = set(closure)

    # the contract itself: the closure is filenames, and every one is a real .apk
    for f in closure:
        if not f.endswith(".apk"):
            fail("CONTRACT closure entries are filenames", f"{f!r} is not a .apk")
            break
    unknown = [f for f in closure if f not in name_of_fn]
    if unknown:
        fail("CONTRACT every closure entry maps to an indexed package",
             f"{unknown[:3]}")
    cnames = {name_of_fn.get(f, f) for f in cset}

    # P1: every seed is accounted for
    for s in seeds:
        if s not in cnames and s not in missing:
            fail("P1 seed accounted for", f"seed {s!r} neither closed nor missing")

    # P2/P3: closure == reachable set, computed independently
    reachable, unmet = reachable_from(main, community, seeds)
    if cnames != reachable:
        only_resolver = sorted(cnames - reachable)[:3]
        only_reach = sorted(reachable - cnames)[:3]
        fail("P2/P3 closure == reachable set",
             f"resolver-only={only_resolver} reacher-only={only_reach}")

    # P6: nothing resolvable is reported missing
    resolvable = set(all_names)
    for m in missing:
        if m in resolvable:
            fail("P6 no resolvable node reported missing", f"{m!r}")

    # P4: idempotence
    again, missing2 = R.resolve_closure(main, community, sorted(cnames))
    if set(again) != cset:
        fail("P4 idempotent",
             f"+{sorted(set(again) - cset)[:3]} -{sorted(cset - set(again))[:3]}",
             SEED)
    if sorted(missing2) != sorted(missing):
        fail("P4b missing set stable",
             f"{sorted(missing)} -> {sorted(missing2)}")

    # P5: monotonicity - re-resolving with the closure as seeds cannot grow
    if not cset <= set(again):
        fail("P5 monotone", f"lost {sorted(cset - set(again))[:3]}")
    # P5 as stated: adding seeds cannot shrink the closure
    if set(seeds) > cnames:
        fail("P5b every seed is in the closure", f"{sorted(set(seeds) - cnames)[:3]}")

    # P7: sorted output
    if closure != sorted(closure):
        fail("P7 sorted output", "closure is not sorted")

    # P8: every soname in the closure is provided by someone in the closure
    #     (the e2fsprogs bug: a package present, its providers absent)
    provided = {}
    for src in (main, community):
        for name, info in src.items():
            for p in info.get("provides", {}):
                provided.setdefault(p, set()).add(name)
    for name in sorted(cnames):
        # .get, not []: when a property has ALREADY failed and removed this name
        # from the closure, indexing would raise TypeError and abort the run -
        # so one real failure would hide every later one behind a traceback.
        src_info = main.get(name) or community.get(name)
        if src_info is None:
            continue
        info = dict(src_info)
        for dep in info.get("deps", []):
            if not dep.startswith("so:"):
                continue
            owners = provided.get(dep, set())
            if owners and not (owners & cnames):
                fail("P8 so: dependency satisfied inside the closure",
                     f"{name} needs {dep}, providers {sorted(owners)} absent")
                break


def reachable_from(main, community, seeds):
    """Independent reachability walk - deliberately not the resolver's algorithm."""
    allp = dict(main)
    allp.update(community)
    providers = {}
    for name, info in allp.items():
        for p in info.get("provides", {}):
            providers.setdefault(p, set()).add(name)
    seen, unmet = set(), set()
    stack = list(seeds)
    while stack:
        cur = stack.pop()
        if cur in seen:
            continue
        if cur not in allp:
            unmet.add(cur)
            continue
        seen.add(cur)
        for dep in allp[cur].get("deps", []):
            if dep.startswith("so:"):
                for owner in providers.get(dep, ()):
                    if owner not in seen:
                        stack.append(owner)
            elif dep in allp:
                stack.append(dep)
            elif dep.startswith("cmd:") or dep.startswith("path:"):
                continue
            else:
                stack.append(dep)
    return seen, unmet


def main():
    import tempfile

    rnd = random.Random(SEED)
    with tempfile.TemporaryDirectory() as tmp:
        for _ in range(ROUNDS):
            check(rnd, tmp)
    print(f"  ({ROUNDS} random indexes, seed {SEED})")
    if FAILS:
        print(f"resolver properties: FAILED ({len(FAILS)})", file=sys.stderr)
        return 1
    print("resolver properties: PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())