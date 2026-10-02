#!/bin/bash
# test_btrfs_profiles.sh - prove the profile choice with the SHIPPED binary.
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
# Skipped, loudly, when the host cannot do it - no sudo, no loop devices, no
# qemu-aarch64, or no offline repo. Never silently.

set -u
cd "$(dirname "$0")/.." || exit 1
W=${TMPDIR:-/tmp}/btrfs-profile-check
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }

# --- can this host do the test at all? ---------------------------------------
if ! sudo -n true 2>/dev/null; then
    echo "  SKIP: needs passwordless sudo for losetup"
    echo "        (the profile rationale is then unverified on this host)"
    exit 0
fi
if ! command -v qemu-aarch64 >/dev/null 2>&1; then
    echo "  SKIP: qemu-aarch64 not present, cannot run the aarch64 mkfs.btrfs"
    exit 0
fi
APK=$(ls build/usb-tree-root/apks/main/btrfs-progs-*.apk 2>/dev/null | head -1)
[ -n "$APK" ] || { echo "  SKIP: no btrfs-progs in build/usb-tree-root (run 'make package')"; exit 0; }

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
[ -x "$MKFS" ] || { echo "  SKIP: mkfs.btrfs not unpacked from the APK"; exit 0; }
run() { sudo -n qemu-aarch64 -L "$W" "$@" 2>&1; }

# --- two loop devices --------------------------------------------------------
truncate -s 512M d1; truncate -s 512M d2
L1=$(sudo -n losetup -f --show "$W/d1" 2>/dev/null)
L2=$(sudo -n losetup -f --show "$W/d2" 2>/dev/null)
if [ -z "$L1" ] || [ ! -b "$L1" ]; then
    echo "  SKIP: losetup could not attach a device"
    exit 0
fi
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