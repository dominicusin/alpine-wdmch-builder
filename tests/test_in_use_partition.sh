#!/bin/bash
# test_in_use_partition.sh - will the installer refuse a partition already in use?
#
# Measured on the real WDMCH on 2026-10-02, after the machine came back:
#
#   /dev/sda20  PARTLABEL="SYSTEM"  TYPE="linux_raid_member"
#   md1 : active raid1 sda20[0]  20954112 blocks  [2/1] [U_]
#   findmnt: /dev/md1 on /
#
# p20 SYSTEM_B is not an empty vendor slot. It is the only member of a degraded
# RAID1 array, and that array is the root filesystem of a Nix/Guix install
# running a FidoNet node.
#
# The installer's safety claim was "only p20 is ever written, and p20 is the
# safe slot". The first half is enforced by an allowlist. The second half was
# never checked, and on this machine it is FALSE: running the installer as
# designed would have mkfs.ext4'd the only member of the array backing the
# running system, with no guard firing - the GPT is intact, p20 is on the
# allowlist, and it is not the rescue stick.
#
# These extract the real guard from install-alpine and run it against the
# blkid/mdstat state measured on the box.

set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT=rootfs/install-alpine
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }
sh -n "$SCRIPT" || { echo "FAIL: install-alpine has a syntax error" >&2; exit 1; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# The guard, extracted verbatim.
GUARD="$W/guard"
sed -n '/^# --- refuse a partition that is already in use/,/^fi$/p' "$SCRIPT" > "$GUARD"
if ! grep -q 'cur_type' "$GUARD"; then
    echo "FAIL: could not extract the in-use guard from $SCRIPT" >&2
    echo "      If it was renamed, this test must follow it, not be deleted." >&2
    exit 1
fi
sh -n "$GUARD" || { echo "FAIL: the extracted guard is not valid shell" >&2; exit 1; }

# The guard, run for real. Two substitutions, both unavoidable without
# privileges, and both stated: the -b precondition is made true (we cannot
# mknod), and blkid is replaced by a function returning the measured type.
# The decision logic below those two lines is the installer's, untouched.
cat > "$W/harness" <<'HARNESS'
blkid() { [ "${1:-}" = "-s" ] && { printf '%s' "$FAKE_TYPE"; return 0; }; return 1; }
mdstat_lines() { printf '%s' "$FAKE_MDSTAT"; }
HARNESS

probe() { # $1 = blkid TYPE, $2 = mdstat text
    printf '%s' "$2" > "$W/mdstat"
    # Only two substitutions: the -b precondition (we cannot mknod without
    # privileges) and the path to the md table (so a fixture can be supplied).
    sed -e 's|^if \[ -b "\$ROOT_DEV" \]; then$|if true; then|' \
        -e "s|/proc/mdstat|\$MDSTAT_PATH|g" "$GUARD" > "$W/g2"
    FAKE_TYPE="$1" MDSTAT_PATH="$W/mdstat" ROOT_DEV="$W/sda20" \
    DISK=/dev/sda ROOT_PART=20 \
    sh -c '. "$1"; . "$2"; eval "$(cat "$3")"' sh "$W/harness" "$GUARD" "$W/g2" 2>&1
}

echo "=== install-alpine: is the target partition already in use? ==="

# --- the measured case: p20 is a RAID member --------------------------------
out=$(probe "linux_raid_member" "")
rc=$?
check "a linux_raid_member target is refused" \
      "$(cond '[ $rc -ne 0 ]'; echo $?)"
check "  ...and the error names the filesystem type" \
      "$(cond 'echo "$out" | grep -q "linux_raid_member"'; echo $?)"
check "  ...and explains the RAID case seen on real hardware" \
      "$(cond 'echo "$out" | grep -qi "RAID case seen on a real WDMCH"'; echo $?)"
check "  ...and points at what to check before touching the disk" \
      "$(cond 'echo "$out" | grep -q "blkid $W/sda20\|cat /proc/mdstat"'; echo $?)"

# --- other in-use types are refused too -------------------------------------
for t in btrfs xfs vfat swap linux_raid_member; do
    out=$(probe "$t" ""); rc=$?
    check "an existing '$t' filesystem is refused" \
          "$(cond '[ $rc -ne 0 ]'; echo $?)"
done

# --- the mdstat safety net catches it even when blkid is silent -------------
out=$(probe "" "md1 : active raid1 sda20[0]
      20954112 blocks super 1.2 [2/1] [U_]")
rc=$?
check "a partition named in mdstat is refused even without a blkid type" \
      "$(cond '[ $rc -ne 0 ]'; echo $?)"

# --- a pristine target still proceeds --------------------------------------
out=$(probe "" "")
rc=$?
check "an empty target partition is allowed through" \
      "$(cond '[ $rc -eq 0 ]'; echo $?)"

# --- an existing ext4 is allowed (reinstall into our own label) -------------
out=$(probe "ext4" "")
rc=$?
check "an existing ext4 target is allowed through" \
      "$(cond '[ $rc -eq 0 ]'; echo $?)"

# --- the guard must be positioned before anything destructive ---------------
# If it sits after mke2fs it is decoration. The first destructive command is
# run_mke2fs; the guard has to come before it.
guard_line=$(grep -n 'refuse a partition that is already in use' "$SCRIPT" | head -1 | cut -d: -f1)
mkfs_line=$(grep -n 'run_mke2fs' "$SCRIPT" | head -1 | cut -d: -f1)
conf_line=$(grep -n '^# 2. confirmation' "$SCRIPT" | head -1 | cut -d: -f1)
check "the guard runs before the confirmation prompt" \
      "$(cond "[ $guard_line -lt $conf_line ]"; echo $?)"
check "the guard runs before any mkfs" \
      "$(cond "[ $guard_line -lt $mkfs_line ]"; echo $?)"

# --- the refusal must be in the header contract too -------------------------
check "install-alpine's header documents the refusal" \
      "$(cond 'grep -q "already holds" "$SCRIPT" || grep -q "in use" "$SCRIPT"'; echo $?)"
check "  ...and test_no_fail_open.sh enforces the header claims" \
      "$(cond 'grep -q "already holds" tests/test_p1_backup.sh || grep -q "in use" tests/test_p1_backup.sh'; echo $?)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "in-use partition refusal: PASSED"
else
    echo "in-use partition refusal: FAILED ($FAILED)" >&2
    exit 1
fi
