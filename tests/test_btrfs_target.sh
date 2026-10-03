#!/bin/bash
# test_btrfs_target.sh - is the btrfs target actually what the project makes?
#
# The install target is ONE btrfs spanning p20 + p21, with no md anywhere.
# These assert the properties that make that true, from the installer's own
# text, because every one of them is a way the feature can silently not happen:
#
#   - the second partition defaults to 21 and is allowlisted with the first
#   - both members are created on, not just the first
#   - the profiles are single/dup, which is the only combination that does not
#     cap the filesystem at the size of the small disk
#   - nothing anywhere creates an md array
#   - the rescue kernel can actually mount btrfs
#   - fstab names the label, not both devices, so mount(8) does not mount the
#     same filesystem twice
#   - the handover mounts btrfs, or a btrfs install could never hand over

set -u
cd "$(dirname "$0")/.." || exit 1
INST=rootfs/install-alpine
HAND=rootfs/init.d/99-disk-root
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

for f in "$INST" "$HAND"; do
    [ -f "$f" ] || { echo "FAIL: $f missing" >&2; exit 1; }
    sh -n "$f" || { echo "FAIL: $f has a syntax error" >&2; exit 1; }
done

echo "=== the btrfs target: p20 + p21, one filesystem, no md ==="

# --- the target is two partitions, and both are allowlisted ------------------
check "the data partition defaults to 21 (DATA)" \
      "$(cond 'grep -qE "^DATA_PART=21$" "$INST"'; echo $?)"
check "  ...and is overridable" \
      "$(cond 'grep -q -- "--data-part" "$INST"'; echo $?)"
check "the allowlist covers BOTH members" \
      "$(cond 'grep -q "for part in .ROOT_PART .DATA_PART" "$INST"'; echo $?)"
check "  ...and includes 21" \
      "$(cond 'grep -qE "19\|20\|21\)" "$INST"'; echo $?)"

# --- both devices are passed to mkfs, not just one ----------------------------
check "the filesystem members are collected in FS_DEVS" \
      "$(cond 'grep -q "FS_DEVS=" "$INST"'; echo $?)"
check "  ...and both are passed to mkfs.btrfs" \
      "$(cond 'grep -q "run_mkbtrfs .FS_DEVS" "$INST"'; echo $?)"
check "  ...so a two-device filesystem is actually created" \
      "$(cond 'grep -q "creating ONE btrfs across" "$INST"'; echo $?)"

# --- the profiles, which the sizes force -------------------------------------
check "the data profile is single" \
      "$(cond 'grep -qE "^BTRFS_DATA_PROFILE=single$" "$INST"'; echo $?)"
# raid1, not dup: dup duplicates metadata WITHIN a device, which the btrfs docs
# say "negates the purpose of increased redundancy", and btrfs-progs 6.11 warns
# about it at mkfs time. Measured both on loop devices with the shipped binary.
check "the metadata profile is raid1 (cross-device, not dup)" \
      "$(cond 'grep -qE "^BTRFS_META_PROFILE=raid1$" "$INST"'; echo $?)"
check "  ...and the superseded dup profile is gone" \
      "$(cond '! grep -qE "^BTRFS_META_PROFILE=dup$" "$INST"'; echo $?)"
check "  ...with the measurement that decided it recorded" \
      "$(cond 'grep -q "DUP is not recommended" "$INST"'; echo $?)"
check "  ...and both are passed to mkfs" \
      "$(cond 'grep -q -- "-d \"\$BTRFS_DATA_PROFILE\"" "$INST" && grep -q -- "-m \"\$BTRFS_META_PROFILE\"" "$INST"'; echo $?)"
check "  ...a redundant data profile would cap the fs at 20 GB" \
      "$(cond 'grep -q "capped by the smallest device" "$INST"'; echo $?)"

# --- no md anywhere -----------------------------------------------------------
# Scoped to md CREATION. The installer legitimately reads /proc/mdstat to
# REFUSE an md member - naming md1 there is the guard working, not a raid
# being built. mdadm --create is what would actually assemble one.
check "the installer creates no md array" \
      "$(cond '! grep -qE "mdadm[[:space:]]+--create|mdadm[[:space:]]+-[[:space:]]*C" "$INST"'; echo $?)"
check "  ...it only READS /proc/mdstat, to refuse" \
      "$(cond 'grep -q "/proc/mdstat" "$INST"'; echo $?)"
check "  ...and the header says so" \
      "$(cond 'grep -qi "no md" "$INST"'; echo $?)"
check "the handover assembles no md array" \
      "$(cond '! grep -qE "mdadm|mdadm --assemble" "$HAND"'; echo $?)"
check "btrfs is the only raid the project uses" \
      "$(cond 'grep -qi "btrfs raid\|raid0\|raid1" "$INST"'; echo $?)"

# --- the rescue kernel can mount it ------------------------------------------
check "CONFIG_BTRFS_FS is built in, not a module" \
      "$(cond 'grep -qE "^CONFIG_BTRFS_FS=y$" config/kernel.config'; echo $?)"
check "  ...and the build fails without it" \
      "$(cond 'grep -q "CONFIG_BTRFS_FS" kernel/verify-kernel.sh'; echo $?)"

# --- btrfs-progs is reachable offline ----------------------------------------
check "btrfs-progs is a seed in the offline closure" \
      "$(cond 'grep -q "btrfs-progs" image/dl-packages.sh'; echo $?)"
check "  ...and the installer unpacks it like e2fsprogs" \
      "$(cond 'grep -q "load_btrfs" "$INST" && grep -q "btrfs-progs" "$INST"'; echo $?)"

# --- fstab names the label, not both devices --------------------------------
check "fstab mounts by label" \
      "$(cond 'grep -qE "^LABEL=\\\$ROOT_LABEL  /      btrfs" "$INST"'; echo $?)"
check "  ...and does NOT list both members" \
      "$(cond '! grep -qE "^LABEL=.*\\\$FS_DEVS" "$INST"'; echo $?)"

# --- the handover can actually mount it --------------------------------------
check "the handover mounts -t btrfs" \
      "$(cond 'grep -q "mount -t btrfs" "$HAND"'; echo $?)"
check "  ...and mounts the top-level subvolume" \
      "$(cond 'grep -q "subvol=" "$HAND"'; echo $?)"
check "  ...with an ext4 fallback for older installs" \
      "$(cond 'grep -q "mount -t ext4" "$HAND"'; echo $?)"
check "  ...and reports a degraded filesystem" \
      "$(cond 'grep -qi "DEGRADED" "$HAND"'; echo $?)"

# --- acceptance checks the thing it is meant to check -----------------------
check "verify-install asserts the device count" \
      "$(cond 'grep -q "btrfs spans" scripts/verify-install.sh'; echo $?)"
check "  ...and fails a single-device root" \
      "$(cond 'grep -q "only ONE device" scripts/verify-install.sh'; echo $?)"

# --- the kexec handoff, which boots with NO rescue stick --------------------
# boot-full-alpine is the one boot path with no fallback: it kexecs /boot/Image
# straight into the installed root, so a wrong rootfstype there takes the box
# down with nothing to fall back to. It used to hardcode ext4.
check "the kexec cmdline does NOT hardcode rootfstype=ext4" \
      "$(cond '! grep -q "rootfstype=ext4" "$INST"'; echo $?)"
check "  ...it uses the recorded filesystem type" \
      "$(cond 'grep -q "rootfstype=\$ROOT_FS" "$INST"'; echo $?)"
check "  ...read from /etc/wdmch-installed, not assumed" \
      "$(cond 'grep -q "s/\^root_fs=//p" "$INST"'; echo $?)"
check "  ...probed off the device when that file predates it" \
      "$(cond 'grep -q "blkid -s TYPE -o value \"\$ROOT_DEV\"" "$INST"'; echo $?)"
check "the subvol option is passed for btrfs only" \
      "$(cond 'grep -q "ROOT_OPTS=\"rootflags=subvol=" "$INST" && grep -q "if \[ \"\$ROOT_FS\" = \"btrfs\" \]" "$INST"'; echo $?)"
check "  ...and omitted otherwise, since subvol is btrfs-only" \
      "$(cond 'grep -q "ROOT_OPTS=\"\"" "$INST"'; echo $?)"
check "the resolved boot parameters are printed" \
      "$(cond 'grep -q "rootfstype=\$ROOT_FS  \${ROOT_OPTS" "$INST"'; echo $?)"

# --- the text the operator reads on the stick itself ------------------------
check "the on-stick README describes the btrfs target" \
      "$(cond 'grep -q "btrfs spanning both" image/package-rescue.sh'; echo $?)"
check "  ...and warns that both partitions are destroyed" \
      "$(cond 'grep -qi "back up p21" image/package-rescue.sh'; echo $?)"

# --- the documentation must not still describe ext4-on-p20 -------------------
bad=$(grep -rln 'ext4' docs/*.md README.md 2>/dev/null | while read -r d; do
        grep -qiE 'ext4.{0,40}wdmch-root|wdmch-root.{0,40}ext4|root filesystem is ext4|/` is ext4' "$d" && echo "$d"
      done || true)
if [ -n "$bad" ]; then
    echo "  FAIL  documentation still describes the root as ext4:"
    echo "$bad" | sed 's/^/        /'
    FAILED=$((FAILED+1))
else
    echo "  ok    no document describes the root filesystem as ext4"
fi

# --- the runbook and install doc must state the CURRENT contract --------------
# docs/RUNBOOK.md opened with "Applies after install-alpine has written p20
# SYSTEM_B" - the pre-btrfs, single-partition contract - while the body had
# already been updated to describe a two-device btrfs. A reader who trusted the
# first line would look for a filesystem that is no longer what gets created.
#
# Existence and path checks cannot catch that: the file was present, and every
# path in it was real. So the check here is a RELATIONSHIP - each doc that
# describes the install target must name the label and both partitions, read
# from install-alpine rather than restated, so the doc cannot drift from the
# installer by going stale in a different direction.
label=$(sed -n 's/^ROOT_LABEL="\(.*\)"/\1/p' rootfs/install-alpine | head -1)
rpart=$(sed -n 's/^ROOT_PART=\([0-9]*\)/\1/p' rootfs/install-alpine | head -1)
dpart=$(sed -n 's/^DATA_PART=\([0-9]*\)/\1/p' rootfs/install-alpine | head -1)
[ -n "$label" ] && [ -n "$rpart" ] && [ -n "$dpart" ] || {
    echo "  FAIL  could not read the contract out of install-alpine"; FAILED=$((FAILED+1)); }

for doc in docs/RUNBOOK.md docs/INSTALL.md; do
    [ -f "$doc" ] || { echo "  FAIL  $doc missing"; FAILED=$((FAILED+1)); continue; }
    # A doc that describes the target must name the label and BOTH partitions.
    # Only the lines that talk about the target are considered, so prose about
    # unrelated partitions cannot satisfy or break this by accident.
    scope=$(grep -nE 'p2[01]|wdmch-root|SYSTEM_B' "$doc" | head -20)
    if [ -z "$scope" ]; then
        check "$doc describes the install target" 1
        continue
    fi
    check "$doc names the filesystem label the installer creates ($label)" \
          "$(printf '%s' "$scope" | grep -q "$label" && echo 0 || echo 1)"
    check "  ...and both member partitions (p$rpart + p$dpart)" \
          "$(printf '%s' "$scope" | grep -qE "p$rpart" && printf '%s' "$scope" | grep -qE "p$dpart" && echo 0 || echo 1)"
    check "  ...and does not still describe the old p$rpart-only contract" \
          "$(printf '%s' "$scope" | grep -qE "written .p$rpart SYSTEM_B" && echo 1 || echo 0)"
done

echo
if [ "$FAILED" -eq 0 ]; then
    echo "btrfs target: PASSED"
else
    echo "btrfs target: FAILED ($FAILED)" >&2
    exit 1
fi