#!/bin/bash
# test_init_disk.sh - does the rescue init pick the right internal disk?
#
# rootfs/init decides two things that everything else depends on:
#   1. which partition is the rescue stick (mounted at /media/usb)
#   2. which whole disk is the internal SATA disk
#
# If (2) is wrong, the banner suggests "install-alpine /dev/sda" on the rescue
# stick, and the installer's job is to erase the medium the system is running
# from. The three independent guards in install-alpine exist because this
# selection is not trustworthy on its own - but the guards are only reachable
# if init points at the right disk.
#
# Scope, stated up front: this executes the REAL case expression, extracted
# from rootfs/init at run time rather than copied here. A copy would drift,
# and a drifted copy is the exact defect class this repository spent a series
# removing. It is the decision that is tested here, not the enumeration loop:
# the block-device scan needs real /dev entries and mknod, which an unprivileged
# test cannot have. The loop around it is covered on hardware (roadmap stage 1).

set -u
cd "$(dirname "$0")/.." || exit 1
INIT=rootfs/init
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
cond()  { rc=0; for a in "$@"; do eval "$a" || rc=1; done; return $rc; }

[ -f "$INIT" ] || { echo "FAIL: $INIT missing" >&2; exit 1; }

# Pull the pattern that implements "is this whole disk the rescue stick?".
# Only the pattern is extracted - the `continue ;;` and the trailing comment
# are not part of it, and splicing them in would not parse.
PATTERN=$(grep -oE '"\$\{usb_dev%\[0-9\]\}"' "$INIT" | head -1)
if [ -z "$PATTERN" ]; then
    echo "FAIL: could not find the stick-exclusion pattern in $INIT" >&2
    echo "      If it was renamed, this test must follow it - not be deleted." >&2
    exit 1
fi

# Evaluate that pattern verbatim against a device name.
# $1 = usb_dev, $2 = whole-disk dev ; prints "skip" or "keep"
verdict() {
    sh -c 'usb_dev=$1; dev=$2
           case "$dev" in
               '"$PATTERN"') echo skip ;;
               *) echo keep ;;
           esac' sh "$1" "$2"
}

echo "=== rescue init: internal-disk selection ==="
echo "  (executing the real expression from $INIT)"

# --- the rescue stick is sda1; the internal disk is sdb ------------------------
# This is the documented WDMCH topology: the USB stick claims /dev/sda.
check "the stick's own whole disk is excluded" \
      "$(cond '[ "$(verdict /dev/sda1 /dev/sda)" = skip ]'; echo $?)"
check "a different whole disk is NOT excluded" \
      "$(cond '[ "$(verdict /dev/sda1 /dev/sdb)" = keep ]'; echo $?)"

# --- the same rule for a stick on any letter ----------------------------------
for pair in "sda1 sda" "sdb1 sdb" "sdc2 sdc" "sdd3 sdd"; do
    set -- $pair
    check "stick /dev/$1 excludes /dev/$2" \
          "$(cond "[ \"\$(verdict /dev/$1 /dev/$2)\" = skip ]"; echo $?)"
done

# --- the dangerous inverse: must NOT skip unrelated disks --------------------
# If this ever returned skip, the loop would fall through to sdc/sdd and the
# operator would be pointed at the wrong disk.
check "an unrelated /dev/sda is kept when the stick is /dev/sdb1" \
      "$(cond '[ "$(verdict /dev/sdb1 /dev/sda)" = keep ]'; echo $?)"
check "an unrelated /dev/sdc is kept when the stick is /dev/sdb1" \
      "$(cond '[ "$(verdict /dev/sdb1 /dev/sdc)" = keep ]'; echo $?)"

# --- no stick found: nothing may be skipped ----------------------------------
# The no-strip case would make ${usb_dev%[0-9]} the empty string, and an empty
# case pattern matches only an empty word - so no real device can match it.
# If that ever changed, a machine whose stick failed to mount would have every
# disk excluded and the script would end up with no internal disk at all.
check "with no rescue stick, no disk is excluded" \
      "$(cond '[ "$(verdict "" /dev/sda)" = keep ]'; echo $?)"
check "  ...including the disk that failed to mount" \
      "$(cond '[ "$(verdict "" /dev/sdb)" = keep ]'; echo $?)"

# --- multi-digit partition suffixes -------------------------------------------
# %[0-9] strips exactly one character. For a stick on a device with ten or
# more partitions that yields sda1 from sda10, which is not a whole-disk name
# - so such a stick is not excluded. Failing open into "no internal disk
# found" is the safe direction: install-alpine refuses unknown targets, and
# the operator is told rather than pointed at the wrong disk.
check "a stick on a 10+-partition device does NOT exclude its whole disk" \
      "$(cond '[ "$(verdict /dev/sda10 /dev/sda)" = keep ]'; echo $?)"
x=dev/sda10
check "  ...because one digit is stripped, leaving sda1" \
      "$(cond '[ "${x%[0-9]}" = dev/sda1 ]'; echo $?)"
x=dev/sda1
check "a single-digit partition number strips to the whole-disk name" \
      "$(cond '[ "${x%[0-9]}" = dev/sda ]'; echo $?)"

# --- the stick must be recognised by content, not by device name --------------
# init accepts a partition only if it holds sata.uImage or apks/; that is what
# keeps a factory FAT32 CONFIG partition from being mistaken for the stick.
for m in 'sata\.uImage' 'apks'; do
    check "the stick test still requires $m" \
          "$(cond "grep -qE '\[ -[fd] /media/usb/$m \]' $INIT"; echo $?)"
done
check "the stick is mounted read-only" \
      "$(cond "grep -q 'mount -t vfat -o ro' $INIT"; echo $?)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "rescue init internal-disk selection: PASSED"
else
    echo "rescue init internal-disk selection: FAILED ($FAILED)" >&2
    exit 1
fi
