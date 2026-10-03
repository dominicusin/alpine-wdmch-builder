#!/bin/bash
# test_btrfs_profiles.sh - prove the profile choice with the SHIPPED binary.
#
# OPT-IN. Requires WDMCH_VERIFY_FS=1 (or `make verify-fs`). Without it this
# prints why and exits 0 having done nothing.
#
# It creates filesystems, and that deserves an explicit switch. The agent
# terminal blocklists mkfs unconditionally, for good reason: formatting is
# destructive and the cost of being wrong is someone's data. This test does
# format - on loop devices backed by two temporary files, which is contained -
# but a check that formats is not something that should happen as a side effect
# of somebody running the suite. The default is therefore off, and a human who
# wants the answer asks for it. `make test` includes this file so the capability
# is visible; it does not include the environment variable, so it does not run.
#
# This exists because the profile rationale was wrong for one release. The
# installer chose `-m dup` and the comment above it said dup "keeps the metadata
# in two copies", which is not what dup does on a multi-device filesystem: it
# duplicates WITHIN a device. The btrfs docs say that "negates the purpose of
# increased redundancy and just wastes filesystem space", and btrfs-progs 6.11
# warns about it at mkfs time:
#
#     WARNING: DUP is not recommended on filesystem with multiple devices
#
# So the setting bought no cross-device protection, cost space, and the comment
# claimed the opposite. Nothing caught it, because every test asserted the
# setting the code already had - a change-detector, which cannot distinguish a
# justified value from a wrong one.
#
# This runs the real mkfs.btrfs out of the offline repo - the same bytes the
# stick ships - against two loop devices, and asserts the PROPERTIES rather than
# the profile names:
#
#   1. both members really end up in one filesystem
#   2. mkfs does not warn that the profile is unsuitable
#   3. `btrfs filesystem show` reports two devices (what verify-install counts)
#   4. the label is what the installer's guards compare against
#   5. losing a member is DETECTABLE (what verify-install's degraded check needs)
#
# Skips, loudly, when the host cannot do it - no sudo, no loop devices, no
# qemu-aarch64, or no offline repo. Never silently.

set -u
cd "$(dirname "$0")/.." || exit 1
W=${TMPDIR:-/tmp}/btrfs-profile-check
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }

# --- opt-in gate -------------------------------------------------------------
# Deliberately NOT phrased as a skip, and deliberately not one: this check was
# never enabled, so there is nothing to report a result for. When it IS enabled,
# everything below is a hard failure - see require().
if [ "${WDMCH_VERIFY_FS:-0}" != "1" ]; then
    echo "  NOT RUN: this check formats devices. It is opt-in on purpose."
    echo "          Deliberately: make verify-fs"
    exit 0
fi

# From here the caller asked for a real answer. Anything that stops this host
# from producing one is a FAILURE.
#
# The first version of this file exited 0 from each capability check, which is
# the defect the CI fail-open guard exists to catch: ask for the check, have it
# decline, and read the exit status as "the profile is fine". On a host without
# passwordless sudo - which is every CI runner - that is precisely the run where
# nobody would otherwise learn that the btrfs profile went unverified.
require() {
    echo "  FAIL  $1" >&2
    echo "        enabled via WDMCH_VERIFY_FS=1, so this is a failure, not a skip:" >&2
    echo "        an unrun check is not a passing check." >&2
    FAILED=$((FAILED+1))
    exit 1
}

sudo -n true 2>/dev/null || require "needs passwordless sudo for losetup"
command -v qemu-aarch64 >/dev/null 2>&1 || \
    require "qemu-aarch64 not present, cannot run the aarch64 mkfs.btrfs"
APK=$(ls build/usb-tree-root/apks/main/btrfs-progs-*.apk 2>/dev/null | head -1)
[ -n "$APK" ] || require "no btrfs-progs in build/usb-tree-root (run 'make package')"

echo "=== btrfs profiles, with the shipped binary: $(basename "$APK") ==="

# --- unpack the binary and every library the closure provides ----------------
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
PKGDIR=$OLDPWD
for p in btrfs-progs musl libblkid libuuid libeconf zstd-libs lzo zlib eudev-libs; do
    f=$(ls "$PKGDIR"/build/usb-tree-root/apks/main/$p-*.apk 2>/dev/null | head -1)
    [ -n "$f" ] || continue
    tar xzf "$f" 2>/dev/null
    for t in ./*.tar.gz; do [ -f "$t" ] && tar xzf "$t" 2>/dev/null; done
done
MKFS="$W/sbin/mkfs.btrfs"
BTRFS="$W/sbin/btrfs"
[ -x "$MKFS" ] || require "mkfs.btrfs did not unpack from the APK"
run() { sudo -n qemu-aarch64 -L "$W" "$@" 2>&1; }

# --- two loop devices --------------------------------------------------------
truncate -s 512M d1; truncate -s 512M d2
L1=$(sudo -n losetup -f --show "$W/d1" 2>/dev/null)
L2=$(sudo -n losetup -f --show "$W/d2" 2>/dev/null)
[ -n "$L1" ] && [ -b "$L1" ] || require "losetup could not attach a device"
cleanup() { sudo -n losetup -d "$L1" 2>/dev/null; sudo -n losetup -d "$L2" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

# --- create with the installer's profiles ------------------------------------
OUT=$(run "$MKFS" -f -d single -m raid1 -L wdmch-root "$L1" "$L2")
RC=$?

check "mkfs.btrfs -d single -m raid1 succeeds on two devices" "$([ $RC -eq 0 ] && echo 0 || echo 1)"
check "  ...and does not warn that the profile is unsuitable" \
      "$(printf '%s' "$OUT" | grep -qi 'not recommended' && echo 1 || echo 0)"
check "  ...and both members are recorded" \
      "$(printf '%s' "$OUT" | grep -q 'Number of devices:  2' && echo 0 || echo 1)"

SHOW=$(run "$BTRFS" filesystem show "$L1")
NDEV=$(printf '%s' "$SHOW" | grep -cE '^[[:space:]]*devid')
check "btrfs filesystem show reports 2 devices (verify-install's count)" \
      "$([ "$NDEV" -eq 2 ] && echo 0 || echo 1)"
check "the label is what the installer's guards compare" \
      "$(printf '%s' "$SHOW" | grep -q "wdmch-root" && echo 0 || echo 1)"
check "the filesystem is not reported degraded" \
      "$(printf '%s' "$SHOW" | grep -qi missing && echo 1 || echo 0)"

# both members share one filesystem UUID - what btrfs_is_ours() compares
U1=$(sudo -n blkid -s UUID -o value "$L1" 2>/dev/null)
U2=$(sudo -n blkid -s UUID -o value "$L2" 2>/dev/null)
check "both members carry the SAME filesystem UUID" \
      "$([ -n "$U1" ] && [ "$U1" = "$U2" ] && echo 0 || echo 1)"

# --- losing a member must be detectable --------------------------------------
sudo -n losetup -d "$L2" 2>/dev/null
MISS=$(run "$BTRFS" filesystem show "$L1" 2>/dev/null | grep -ci missing)
check "losing a member is DETECTABLE (verify-install's degraded check)" \
      "$([ "${MISS:-0}" -gt 0 ] && echo 0 || echo 1)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "btrfs profiles: PASSED"
else
    echo "btrfs profiles: FAILED ($FAILED)" >&2
    exit 1
fi