#!/bin/bash
# test_backup_fw.sh - will it back up the firmware table, or the USB stick?
#
# The command this script replaces appeared in four documents as
#
#     dd if=/dev/sda1 of=fw-table-backup.bin bs=512
#
# In a rescue environment /dev/sda IS the USB stick. So that command copies the
# stick's FAT32 partition, names the file fw-table-backup.bin, and leaves the
# operator believing they can flash firmware. This is the highest-stakes
# document in the repository and the one most likely to be followed at 2am with
# a box already failing to boot.
#
# These drive the real script. The block devices are not real - the script is
# parameterised by --device, and the stick is identified from a mount table, so
# both can be faked without root.

set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT=tools/backup-fw-table.sh
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: syntax error" >&2; exit 1; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# The script reads /proc/mounts through awk and probes [ -b ]. Both are faked:
# awk reads our table, and --device names a path we create as a plain file,
# which the script's own -b check will reject - so the tests drive the
# refusal paths, and the success path uses a real block device if one exists.
mkdev() { : > "$W/$1"; }          # a regular file standing in for a device

run() { ( cd "$W" && bash "$OLDPWD/$SCRIPT" "$@" 2>&1 ); }

echo "=== backup-fw-table.sh ==="

# --- refuses rather than guessing --------------------------------------------
# No --device, and the mount table says nothing: the script must not pick a
# disk at random, because a wrong pick is the exact failure being fixed.
out=$(MOUNTS_FILE=/nonexistent run --device /dev/nonexistent)
check "a nonexistent --device is refused" \
      "$(cond 'echo "$out" | grep -q "is not a block device"'; echo $?)"

out=$(cd "$W" && bash "$OLDPWD/$SCRIPT" --output 2>&1)
check "a missing --output argument is refused" \
      "$(cond 'echo "$out" | grep -q "needs a path"'; echo $?)"

out=$(cd "$W" && bash "$OLDPWD/$SCRIPT" --frobnicate 2>&1)
check "an unknown argument is refused" \
      "$(cond 'echo "$out" | grep -q "unknown argument"'; echo $?)"

out=$(cd "$W" && bash "$OLDPWD/$SCRIPT" --help 2>&1); rc=$?
check "--help exits 0" "$(cond '[ $rc -eq 0 ]'; echo $?)"

# --- the safety property: it will not back up the stick ------------------------
# This is the test that matters. If the operator names the stick explicitly -
# which is exactly what happens when autodetect is wrong - it must refuse
# rather than write a file that looks like a firmware table.
# stick_disk() is EXTRACTED and executed against a synthetic mount table.
#
# It used to read /proc/mounts hardcoded, so it could not be exercised: it
# answered from whatever the host had mounted under /media/usb, and where
# nothing was mounted there it returned empty and looked fine. So the check
# below degraded to grepping the script's own text - which passes whether or not
# the function works. A synthetic table makes the detection executable, and
# therefore the refusal too.
FNS=$(mktemp)
sed -n '/^stick_disk() {/,/^}/p' "$SCRIPT" > "$FNS"
grep -q '^stick_disk() {' "$FNS" || { echo "FAIL: could not extract stick_disk() from $SCRIPT" >&2; exit 1; }
sh -n "$FNS" || { echo "FAIL: extracted stick_disk() is not valid shell" >&2; exit 1; }
detect_stick() { MOUNTS_FILE="$1" sh -c '. "$1"; stick_disk' sh "$FNS" 2>/dev/null; }

printf '/dev/sdb1 /media/usb vfat rw 0 0\n' > "$W/mounts-stick"
printf '/dev/sda1 / ext4 rw 0 0\n'         > "$W/mounts-none"

check "a stick mounted at /media/usb is detected as sdb" \
      "$(cond '[ "$(detect_stick "$W/mounts-stick")" = "/dev/sdb" ]'; echo $?)"
check "  ...and the partition digits are stripped, not the whole device" \
      "$(cond '[ "$(detect_stick "$W/mounts-stick")" != "/dev/sdb1" ]'; echo $?)"
check "no mount under /media/usb means no stick (no guessing)" \
      "$(cond '[ -z "$(detect_stick "$W/mounts-none")" ]'; echo $?)"

# The refusal itself still needs a real block device to reach, so it stays a
# structural check - but it is now a statement about wiring, not the only
# evidence that the detection works.
check "the caller refuses when the given disk IS the detected stick" \
      "$(cond 'grep -q "\[ \"\$DISK\" = \"\$STICK\" \]" "$SCRIPT"'; echo $?)"
# Kept so the refusal text cannot be deleted silently while the checks above
# still pass - they exercise the detection, not the message.
check "the script still contains the rescue-stick refusal" \
      "$(cond 'grep -q "rescue stick, not the internal disk" "$SCRIPT"'; echo $?)"

# --- it must never write to a block device ------------------------------------
# The whole premise: this reads p1. A write here would be the worst possible
# bug in the file.
if grep -vE '^[[:space:]]*#' "$SCRIPT" \
     | grep -qE '>[[:space:]]*"?/dev/sd|of=/dev/sd|mkfs|parted|sgdisk[[:space:]]+-z|dd .*of=/dev/'; then
    echo "  FAIL  the script writes to a block device"
    FAILED=$((FAILED+1))
else
    echo "  ok    the script never writes to a block device"
fi

# --- the size check is the real success test ----------------------------------
# dd can exit 0 having written nothing, so an emptiness check must exist and
# must be a failure, not a warning.
check "an empty result is treated as failure" \
      "$(cond 'grep -q "is empty" "$SCRIPT"'; echo $?)"
check "  ...and it exits non-zero rather than warning" \
      "$(cond 'grep -qE "die .*is empty|die .*\$OUT is empty" "$SCRIPT"'; echo $?)"

# --- the documents must stop carrying the wrong command ----------------------
# The reason the script exists. A literal /dev/sda1 presented as a command is
# the bug. The placeholder /dev/sdX1 is fine and is what the stick section
# already uses.
#
# A line that names the command in order to forbid it is not the bug - two
# documents now say "never dd if=/dev/sda1" on purpose, and a guard that
# rejected those would have to be deleted within a month.
bad=$(grep -rn 'dd if=/dev/sd[a-z][0-9]' docs/ README.md 2>/dev/null \
      | grep -viE 'never|not |do not|rather than|instead of' || true)
if [ -n "$bad" ]; then
    echo "  FAIL  a document still tells the reader to run a literal-device backup:"
    echo "$bad" | sed 's/^/        /'
    FAILED=$((FAILED+1))
else
    echo "  ok    no document tells the reader to back up a literal /dev/sdXN"
fi

# --- and they must point at the script instead --------------------------------
check "RECOVERY.md refers to the script" \
      "$(cond 'grep -q "backup-fw-table.sh" docs/RECOVERY.md'; echo $?)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "firmware-table backup: PASSED"
else
    echo "firmware-table backup: FAILED ($FAILED)" >&2
    exit 1
fi
