# Lifecycle: how this image ages

Covers `STRATEGY.md` §4 (kernel pin policy) and §5.3 (upstream tracking).
Both are the same question asked of two dependencies: the kernel, which is
pinned to a commit, and the Alpine series, which is pinned to a version.

Everything here is derived from the current implementation, and every claim
names the code it came from.

---

## 1. Sequencing constraint that overrides the rest

**Validate the current pin on hardware before re-pinning anything.**

The box has never booted this image. If a re-pin and a first boot happen in
the same session, a failure has two possible causes and the session cannot
distinguish them. That is a two-variable experiment on the only measurement
that matters.

So the order is fixed: stages 1-4 of `ROADMAP.md` with the *current* pin,
then re-pin, then a second hardware session. The cost of this ordering is one
extra hardware session. The cost of ignoring it is an afternoon spent
bisecting a kernel by booting boards.

---

## 2. The kernel pin

### Where it lives

One place: `KERNEL_REF` in `config/source-lock.env`, currently
`9c6044def2992244f167753803d9a3aa0c0410b8` (Linux v6.18.52 base plus the
RTD1295 board port and the `/memreserve/` + `linux,initrd-*` rescue contract
that places the 4 MiB initramfs at `0x02200000`).

`kernel/fetch-kernel.sh` already enforces the invariants that matter:

- refuses a floating reference (`HEAD`, `main`, empty) — `fetch-kernel.sh:25-34`
- refuses anything that is not a commit SHA — `fetch-kernel.sh:37`
- verifies after checkout that the tree is actually on the pin, and fails if
  not — `fetch-kernel.sh:67-73`
- explains what to do if the upstream history was rewritten and the old
  commit is unreachable — `fetch-kernel.sh:60-61`

`validate.yml` additionally rejects any workflow or script that *writes*
`KERNEL_REF`, and `tools/release-audit.sh` refuses to pass on a floating
reference. The resulting commit is recorded in `manifest.json` as
`kernel_commit`, populated at package time from the checked-out tree
(`image/package-rescue.sh:97`), so every release states exactly what it
contains.

### When to re-pin

Trigger on one of these, not on a schedule:

- a CVE in the kernel or in dropbear that matters for this use (a LAN node
  with public-key SSH);
- the pinned series reaching end of life (§4);
- a board-relevant upstream fix worth taking.

Deliberately **not** a quarterly cadence. A commitment to a cadence that
fires when nothing is wrong produces churn: every re-pin is a full rebuild
and a new hardware session, and both cost real time.

### How

1. Choose the commit. Read the upstream log between the current pin and the
   candidate; check that the changes touch the board port, the `ahci_rtd1295`
   or `phy-rtk-sata` driver, or the rescue boot contract. A re-pin that moves
   an unrelated subsystem is a free re-pin; one that moves the storage
   drivers is a re-test.
2. Put the full 40-character SHA in `config/source-lock.env`.

   Branches are rejected — `fetch-kernel.sh:29-34` refuses `HEAD`, `main` and
   `master`, and the `^[0-9a-f]{7,40}$` check at `:36` refuses anything with a
   non-hex character. **A short SHA is not rejected**, though: seven hex
   characters satisfy both the length check and the prefix comparison the
   script makes after checkout (`:70`, `"$PINNED_REF"*) :`). It will usually
   still fail at fetch time, because servers commonly refuse an abbreviated
   SHA, but that is luck rather than enforcement.

   This is why the full-length form is a rule here rather than a convention:
   a prefix is ambiguous in a file whose entire purpose is to be immutable.
3. Update the comment above `KERNEL_REF` if the reason for the pin changed.
   The comment is the record of *why* this commit, which is the part a future
   reader cannot reconstruct.
4. Build and run the full suite. `make test` is the gate; it now runs in both
   publishing workflows, so a regression fails before a release exists.
5. Publish, and record the new commit in the release notes.
6. Hardware session. A kernel change moves the storage and network drivers,
   so this session is not optional.

### If the new kernel does not boot

Revert `KERNEL_REF` to the previous SHA and publish again. The cost is one
build and one release; the cost of leaving a bad pin committed is that every
future build produces the same unbootable image and the failure looks like a
new problem each time.

This is why the pin lives in exactly one file. Rollback is a one-line revert,
and that is a property of the layout, not a coincidence.

---

## 3. The Alpine series

### Where it lives

`config/alpine.env`:

```
ALPINE_VERSION=3.21      # series; used for the mirror path
ALPINE_RELEASE=3.21.8    # point release; must prefix the VERSION file
```

Both are single-sourced. `build.yml` reads them for its cache key rather than
hardcoding its own copy, and `validate.yml` fails the build if `VERSION` stops
tracking `ALPINE_RELEASE` or if a workflow reintroduces a literal
`ALPINE_VERSION:`.

### The end-of-life problem

The offline closure is fetched from

```
$ALPINE_MIRROR/v$ALPINE_VERSION/{main,community}/$ALPINE_ARCH
```

defaulting to `https://dl-cdn.alpinelinux.org/alpine`. When a series reaches
end of life, Alpine stops publishing it on the CDN. The default mirror then
returns 404 and the build fails with a download error that says nothing about
end of life.

Two things make this survivable, and both must be remembered at the moment it
happens rather than invented under pressure:

- **The escape hatch exists.** `ALPINE_MIRROR` overrides the mirror in both
  `image/dl-packages.sh:39-40` and `rootfs/build-rootfs.sh:31`. Setting it to
  Alpine's archive host keeps the same `/v$ALPINE_VERSION/` path layout, so
  no other file changes.
- **The pin is what makes it recoverable.** The closure is resolved from
  whatever `APKINDEX` that series serves, and pinned by name and version. A
  series frozen in the archive keeps serving the same index it served the
  day before it was frozen.

### The real risk is not the mirror, it is the index format

`image/resolve-deps.py` is written against **APKINDEX v2**, and the bugs fixed
earlier in this project were in exactly this area: it read a `So:` field
that v2 does not have, and it did not handle `p:so:` providers or virtual
providers. Those fixes are pinned to this index format.

So a new series carries a risk that has nothing to do with the mirror:

- if the index format changes, the resolver mis-parses it, and the failure
  mode is a **silently incomplete closure** — packages missing from the
  offline repo, discovered only on the WDMCH, when `apk add` cannot find a
  dependency.
- the same applies to virtual providers: `ifupdown-any` resolves through
  providers, and a format change there would remove a package the installer
  needs.

The mitigation already exists: `tests/test_rootfs.sh` asserts that
`flash.zip` contains **exactly** the resolver's closure, no more and no
fewer. If a new series makes the resolver wrong, the closure in the zip will
disagree with what `apk add` actually demands, and the guard is the place
where a format change gets noticed — on a build machine, rather than on the
box.

Before adopting a new series, therefore:

1. Build once with the new `ALPINE_VERSION` and read the closure size. A
   sudden drop means the resolver is no longer seeing something it used to.
2. Confirm the guard reports the closure, and that `mke2fs` and `alpine-base`
   are still in it. Both are load-bearing and both failed in this project
   before.
3. Only then bump `ALPINE_RELEASE` and `VERSION`.

### What is deliberately not automated

Nothing here watches Alpine or the kernel and opens an issue when something
moves. For a single-device maintenance tool, an updater is infrastructure
without a consumer, and `STRATEGY.md` §5.3 rules it out. The trigger is a
person noticing a CVE or a failing build.
