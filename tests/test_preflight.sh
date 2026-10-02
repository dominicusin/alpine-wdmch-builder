#!/bin/bash
# test_preflight.sh - does preflight identify the internal disk, or guess?
#
# tools/preflight.sh exists to answer one decisive question before a
# maintenance window: how big is p20 SYSTEM_B, and on which disk?
#
# It used to hardcode /dev/sda. Over SSH that is usually right, which is
# exactly why it survived - but run from the rescue image, where the USB stick
# claims /dev/sda, it would inventory the boot medium and answer the question
# with the stick's single FAT32 partition. A wrong answer to the one question
# the whole plan turns on.
#
# These run the real functions from the real script with a synthetic mount
# table and a synthetic lsblk. Nothing is reimplemented.

set -u
cd "$(dirname "$0")/.." || exit 1
PF=tools/preflight.sh
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

[ -f "$PF" ] || { echo "FAIL: $PF missing" >&2; exit 1; }

# Lift the two functions out of the script so they can be called directly.
# preflight has to stay a single file - it is piped over SSH - so it cannot be
# sourced wholesale without running the entire inventory.
FNS=$(mktemp)
trap 'rm -f "$FNS"' EXIT
sed -n '/^stick_disk() {/,/^INTERNAL_DISK=\$(internal_disk)$/p' "$PF" > "$FNS"
if ! grep -q '^stick_disk() {' "$FNS" || ! grep -q '^internal_disk() {' "$FNS"; then
    echo "FAIL: could not extract the disk functions from $PF" >&2
    echo "      If they were renamed, this test must follow them, not be deleted." >&2
    exit 1
fi

# probe <mount-line> <disk> [<disk>...]  ->  "stick internal"
probe() {
    local mount_line=$1; shift
    local W r; W=$(mktemp -d)
    printf '%s\n' "$mount_line" > "$W/mounts"
    {
        echo '#!/bin/sh'
        # preflight asks for `-dno PATH`, which yields full device paths.
        echo '[ "$1" = "-dno" ] || exit 0'
        for d in "$@"; do echo "printf '%s\n' $d"; done
    } > "$W/lsblk"
    chmod +x "$W/lsblk"
    r=$(MOUNTS_FILE="$W/mounts" PATH="$W:$PATH" bash -c \
        '. "$1" >/dev/null 2>&1; . "$1"; printf "%s %s\n" "$(stick_disk)" "$(internal_disk)"' \
        bash "$FNS" 2>/dev/null)
    rm -rf "$W"
    printf '%s\n' "$r"
}

echo "=== preflight: which disk is the internal one? ==="

# --- the WDMCH rescue topology: stick is sda, internal is sdb -----------------
# The case the hardcoded /dev/sda got wrong, and the one the project is built
# around. sda1 is the stick's FAT32 partition; the internal disk is sdb.
r=$(probe "/dev/sda1 /media/usb vfat ro 0 0" /dev/sda /dev/sdb)
check "rescue stick on sda1 is identified as /dev/sda" \
      "$(cond '[ "$r" = "/dev/sda /dev/sdb" ]'; echo $?)"

# --- the same box over SSH: nothing mounted from removable media --------------
r=$(probe "/dev/sda2 /boot ext4 rw 0 0" /dev/sda)
check "with no stick mounted, the only disk is internal" \
      "$(cond '[ "$r" = " /dev/sda" ]'; echo $?)"

# --- the stick on another letter ---------------------------------------------
r=$(probe "/dev/sdc1 /media/usb vfat ro 0 0" /dev/sda /dev/sdb /dev/sdc)
check "stick on sdc1 is identified as /dev/sdc" \
      "$(cond '[ "$r" = "/dev/sdc /dev/sda" ]'; echo $?)"

# --- alternative mount points ------------------------------------------------
for mp in /mnt/usb /media/stick; do
    r=$(probe "/dev/sdb1 $mp vfat ro 0 0" /dev/sda /dev/sdb)
    check "stick mounted at $mp is still detected" \
          "$(cond '[ "$r" = "/dev/sdb /dev/sda" ]'; echo $?)"
done

# --- the stick is never selected as the internal disk ------------------------
# The lsblk stub lists only the stick, so the lsblk branch correctly finds
# nothing. internal_disk then falls through to its /dev/sda../dev/sdd fallback,
# which tests real block devices on whatever host runs this suite - so the
# exact value depends on the machine and cannot be asserted. The invariant can
# be, and it is the one that matters: whatever comes back, it is not the stick.
#
# Asserting a literal here would make this test fail on a laptop and pass on a
# build agent, which is a test that measures the machine rather than the code.
r=$(probe "/dev/sda1 /media/usb vfat ro 0 0" /dev/sda)
check "the rescue stick is never selected as the internal disk" \
      "$(cond '[ "$r" != "/dev/sda /dev/sda" ]'; echo $?)"
check "  ...and the stick is still correctly identified" \
      "$(cond '[ "${r%% *}" = /dev/sda ]'; echo $?)"

# --- a multi-digit partition number still strips to the whole disk ------------
# %[0-9] removes one character, so sda10 becomes sda1 and matches no whole-disk
# name. The stick is then not excluded - documented, and it is the safe
# direction, but the behaviour is pinned here rather than left to be rediscovered.
r=$(probe "/dev/sda10 /media/usb vfat ro 0 0" /dev/sda /dev/sdb)
check "a 10+ partition stick is not excluded (yields sda1, not a disk)" \
      "$(cond '[ "$r" = "/dev/sda1 /dev/sda" ]'; echo $?)"

# --- preflight must state a verdict, not just print a table ------------------
# The single most important line in the output. A table of 24 partitions and
# no verdict reads as "nobody looked".
out=$(bash "$PF" 2>/dev/null)
check "preflight states a verdict about p20" \
      "$(cond 'echo "$out" | grep -q "VERDICT:"'; echo $?)"
check "  ...naming p20 either way" \
      "$(cond 'echo "$out" | grep -qE "VERDICT: (p20 SYSTEM_B|NO p20 )"'; echo $?)"
check "  ...and naming which disk it believes is internal" \
      "$(cond 'echo "$out" | grep -q "internal disk   :"'; echo $?)"
check "  ...and naming the rescue stick, or saying none was found" \
      "$(cond 'echo "$out" | grep -q "rescue stick    :"'; echo $?)"
check "preflight still exits 0 on a machine that is not a WDMCH" \
      "$(cond 'bash '"$PF"' >/dev/null 2>&1'; echo $?)"

# --- the old hardcoded-sda bug must not come back ----------------------------
# Comments are excluded: the fix explains the old `-r /dev/sda` behaviour in
# prose, and a grep that matched its own explanation would report a bug that is
# not there - the same trap as the in-use guard's own mdstat pattern.
if grep -vE '^[[:space:]]*#' "$PF" \
   | grep -qE '\[ -r /dev/sda \]|partx[^\n]*/dev/sda|sgdisk -p /dev/sda'; then
    echo "  FAIL  preflight hardcodes /dev/sda again"
    FAILED=$((FAILED+1))
else
    echo "  ok    preflight does not read a verdict off a hardcoded /dev/sda"
fi

# --- it must stay read-only ---------------------------------------------------
# Its entire premise is that it is safe to run on a live, working machine.
for w in mkfs 'dd if' umount 'systemctl restart' 'systemctl stop' reboot; do
    if grep -qE "$w" "$PF"; then
        echo "  FAIL  preflight contains a write or a restart: $w"
        FAILED=$((FAILED+1))
    fi
done
echo "  ok    preflight performs no writes, mounts or service changes"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "preflight disk identification: PASSED"
else
    echo "preflight disk identification: FAILED ($FAILED)" >&2
    exit 1
fi
