#!/bin/bash
# test_wdmch_layout.sh - does the installer refuse the REAL WDMCH layout?
#
# The synthetic indexes in test_in_use_partition.sh prove the guard's logic.
# This one proves the logic matches the machine the project is actually for.
#
# Measured 2026-10-02 over SSH as dietpi@192.168.1.2, read-only:
#
#   sda19  TYPE="swap"               PARTLABEL="SWAP"     3 GiB, 0 bytes used
#   sda20  TYPE="linux_raid_member"  PARTLABEL="SYSTEM"  20 GiB
#   sda21  TYPE="btrfs"              PARTLABEL="DATA"    7.3 TiB, 12 GiB used
#
#   md1 : active raid1 sda20[0]   [2/1] [U_]
#   findmnt: /dev/md1 on /
#
# So on this machine BOTH writable-by-allowlist partitions are unsafe, for
# different reasons: p20 is the root filesystem, p19 is the swap device. The
# installer must refuse both rather than pick one.
#
# The values come from tests/fixtures/wdmch-partitions-2026-10-02.txt, which is
# recorded output, not a guess. If the machine is ever repartitioned, update
# that file from a fresh blkid and this test will follow it.

set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT=rootfs/install-alpine
FIXTURE=tests/fixtures/wdmch-partitions-2026-10-02.txt
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "FAIL: $FIXTURE missing" >&2; exit 1; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# The recorded mdstat line, verbatim from /proc/mdstat.
cat > "$W/mdstat" <<'EOS'
Personalities : [raid1] [raid6] [raid5] [raid4]
md1 : active raid1 sda20[0]
      20954112 blocks super 1.2 [2/1] [U_]
      bitmap: 1/1 pages [4KB], 65536KB chunk

unused devices: <none>
EOS

# blkid for a device, read from the recorded fixture.
blkid_type() { awk -v d="$1" '$1 == d { print $2 }' "$FIXTURE"; }

# Run the real guard. Two substitutions, both unavoidable without privileges:
# the -b precondition, and the path to the md table. The decision logic is the
# installer's, untouched.
GUARD="$W/guard"
sed -n '/^# --- refuse a partition that is already in use/,/^fi$/p' "$SCRIPT" > "$GUARD"
grep -q 'cur_type' "$GUARD" || { echo "FAIL: guard not found in $SCRIPT" >&2; exit 1; }
sed -e 's|^if \[ -b "\$ROOT_DEV" \]; then$|if true; then|' \
    -e "s|/proc/mdstat|\$MDSTAT_PATH|g" "$GUARD" > "$W/g2"
cat > "$W/harness" <<'HARNESS'
blkid() { [ "${1:-}" = "-s" ] && { printf '%s' "$FAKE_TYPE"; return 0; }; return 1; }
HARNESS

refuse() { # $1 = partition number ; echoes the guard's output, returns its exit
    FAKE_TYPE="$(blkid_type "sda$1")" MDSTAT_PATH="$W/mdstat" \
    ROOT_DEV="/dev/sda$1" DISK=/dev/sda ROOT_PART="$1" \
    sh -c '. "$1"; . "$2"; eval "$(cat "$3")"' sh "$W/harness" "$GUARD" "$W/g2" 2>&1
}

echo "=== the real WDMCH layout (measured 2026-10-02) ==="

# --- p20: the root filesystem. Must be refused. -----------------------------
out=$(refuse 20); rc=$?
check "p20 SYSTEM_B is refused" \
      "$(cond '[ $rc -ne 0 ]'; echo $?)"
check "  ...and the RAID explanation is shown" \
      "$(cond 'echo "$out" | grep -q "RAID case seen on a real WDMCH"'; echo $?)"
check "  ...naming the measured type" \
      "$(cond 'echo "$out" | grep -q "linux_raid_member"'; echo $?)"

# --- p19: the swap device, 0 bytes used. Must ALSO be refused. --------------
# It looks free, and it is not: it is enabled as swap. Formatting it would
# remove the swap device under a running system.
out=$(refuse 19); rc=$?
check "p19 SWAP is refused" \
      "$(cond '[ $rc -ne 0 ]'; echo $?)"
check "  ...naming the measured type" \
      "$(cond 'echo "$out" | grep -q "\(swap\)"'; echo $?)"

# --- and the mdstat net catches p20 even if blkid were silent ---------------
out=$(FAKE_TYPE="" MDSTAT_PATH="$W/mdstat" ROOT_DEV=/dev/sda20 \
      DISK=/dev/sda ROOT_PART=20 \
      sh -c '. "$1"; . "$2"; eval "$(cat "$3")"' sh "$W/harness" "$GUARD" "$W/g2" 2>&1); rc=$?
check "p20 is refused from mdstat alone, with no blkid type" \
      "$(cond '[ $rc -ne 0 ]'; echo $?)"
check "  ...and quotes the mdstat line it found" \
      "$(cond 'echo "$out" | grep -q "active raid1 sda20"'; echo $?)"

# --- sda21 is not a candidate: not in the allowlist, and it is the data disk
out=$(refuse 21); rc=$?
check "p21 DATA is refused too" \
      "$(cond '[ $rc -ne 0 ]'; echo $?)"
check "  ...naming btrfs" \
      "$(cond 'echo "$out" | grep -q btrfs'; echo $?)"

# --- the conclusion the project has to record -------------------------------
# There is no writable partition on this machine. That is a finding about the
# hardware, not a bug, and it is the reason the install plan is blocked.
writable_refused=0
for p in 19 20 21; do
    refuse "$p" >/dev/null 2>&1 || writable_refused=$((writable_refused+1))
done
check "every partition on this machine is refused" \
      "$(cond "[ $writable_refused -eq 3 ]"; echo $?)"

echo
echo "  This machine has no safe target for an Alpine install."
echo "  p20 is the root filesystem; p19 is the swap device; p21 is the data"
echo "  disk. The project continues as a rescue and maintenance tool - see"
echo "  docs/measurements/2026-10-02-wdmch.md - not as a migration."
echo

if [ "$FAILED" -eq 0 ]; then
    echo "real WDMCH layout: PASSED"
else
    echo "real WDMCH layout: FAILED ($FAILED)" >&2
    exit 1
fi
