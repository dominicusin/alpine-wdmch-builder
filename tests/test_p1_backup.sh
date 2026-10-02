#!/usr/bin/env bash
# Test the ordering and failure behaviour of install-alpine's p1 backup.
#
# RELEASE_CHECKLIST.md requires that the firmware table is "backed up before
# any write", and install-alpine's own header describes it as step 2. Both were
# false: the code read p1 at step 5, after mke2fs had already reformatted p20,
# and a failed read was a WARN that let the install continue. A backup taken
# after the write it was meant to precede is not a backup, and a backup that
# failed silently is worse than none - the operator is told it worked.
#
# This checks the ordering and the failure handling as source properties of the
# shipping script. It cannot run the real installer, because that needs the
# target disk; what it can prove is that the write cannot precede the read, and
# that a failed read cannot be ignored.
set -Eeuo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJ_DIR/rootfs/install-alpine"

test -f "$SRC" || { echo "FAIL: $SRC not found"; exit 1; }
sh -n "$SRC" || { echo "FAIL: install-alpine does not parse"; exit 1; }

FAILED=0
# Each condition is evaluated into $rc first. Writing `[ cond ]` directly as
# a command would trip `set -e` and abort the whole test on the FIRST failing
# condition, so the test would die silently and print nothing - which is how a
# broken check looks exactly like a working one.
rc=0
check() { # $1 label, $2 rc
    if [ "$2" = "0" ]; then
        printf '  ok    %s\n' "$1"
    else
        printf '  FAIL  %s\n' "$1"
        FAILED=1
    fi
}
cond() { # sets rc to 0 if all args hold, 1 otherwise
    if "$@"; then rc=0; else rc=1; fi
}

echo "=== p1 firmware table backup: ordering and failure handling ==="
echo

backup_line=$(grep -n 'backing up the firmware table' "$SRC" | head -1 | cut -d: -f1)
mke2fs_line=$(grep -n 'run_mke2fs "$ROOT_DEV" || die' "$SRC" | head -1 | cut -d: -f1)
fdisk_line=$(grep -n "fdisk \"\$DISK\"" "$SRC" | head -1 | cut -d: -f1)
place_line=$(grep -n 'firmware table backup placed at' "$SRC" | head -1 | cut -d: -f1)

echo "  p1 read: line ${backup_line:-?}"
echo "  mke2fs : line ${mke2fs_line:-?}"
echo "  fdisk  : line ${fdisk_line:-?}"
echo "  placed : line ${place_line:-?}"
echo

# 1. The read must precede every destructive write.
before_mke2fs() { [ -n "$backup_line" ] && [ -n "$mke2fs_line" ] && [ "$backup_line" -lt "$mke2fs_line" ]; }
cond before_mke2fs
check "p1 is read before mke2fs formats the target" "$rc"

if [ -n "$fdisk_line" ]; then
    before_fdisk() { [ "$backup_line" -lt "$fdisk_line" ]; }
    cond before_fdisk
    check "p1 is read before fdisk repartitions" "$rc"
fi

# 2. It must also precede the placement step, which is trivially true but
#    would catch someone moving the whole block to the end again.
before_place() { [ -n "$backup_line" ] && [ -n "$place_line" ] && [ "$backup_line" -lt "$place_line" ]; }
cond before_place
check "p1 is read before the copy is placed on the target" "$rc"

# 3. p1 must be read exactly once. A second read after the write would
#    reintroduce the defect in a subtler form.
dd_count=$(grep -c 'dd if="${DISK}1"' "$SRC" || true)
[ "$dd_count" = "1" ] && rc=0 || rc=1
check "p1 is read exactly once (dd invocations: $dd_count)" "$rc"

# 4. A failed read must be fatal, not a warning.
no_warn() { ! grep -q 'WARN: could not read' "$SRC"; }
cond no_warn
check "a failed p1 read is no longer a warning" "$rc"

stops() { grep -q 'Refusing to continue' "$SRC"; }
cond stops
check "a failed p1 read stops the install" "$rc"

# 5. The result must be checked for emptiness: dd can exit 0 having written
#    nothing, and a zero-byte "backup" is worse than an honest failure.
nonempty() { grep -q '&& \[ -s "\$FW_BACKUP" \]' "$SRC"; }
cond nonempty
check "the backup is verified non-empty" "$rc"

# 6. The backup must actually reach the target, and a failure to place it must
#    be fatal rather than silent.
places_pre_write() { grep -q 'cp -f "\$FW_BACKUP" "\$MNT/root/wdmch-fw-table-backup.bin"' "$SRC"; }
cond places_pre_write
check "the pre-write backup is what lands on the target" "$rc"

place_fatal() { grep -q 'die "could not place the firmware table backup on the target"' "$SRC"; }
cond place_fatal
check "a failure to place the backup is fatal" "$rc"

# 7. The destination path the docs and the runbook name must be the one used.
right_path() { grep -q 'root/wdmch-fw-table-backup.bin' "$SRC"; }
cond right_path
check "the backup path is /root/wdmch-fw-table-backup.bin" "$rc"

# Each refusal in install-alpine's header must exist in the code. The header
# is the contract an operator reads before running the step that can erase a
# firmware table, and it was found claiming things the code did not do.
require_claim() {
    if grep -qE "$2" rootfs/install-alpine; then rc=0; else rc=1; fi
    check "$1" "$rc"
}
echo
echo "install-alpine: the header's refusal list is enforced:"
require_claim "refuses the rescue stick (mount table)"  'media/usb'
require_claim "refuses the rescue stick (boot files)"  'rescue\.sata\.dtb'
require_claim "refuses the rescue stick (factory GPT)" 'does not look like a WDMCH disk'
require_claim "restricts writes to p19/p20"            'only p19 \(SYSTEM_A\) and p20'
require_claim "a failed p1 backup aborts"              'Refusing to continue\. The firmware table'
require_claim "a missing SSH key aborts"               'ERROR: no authorized_keys in the rescue image'
require_claim "a missing kernel aborts"                'die "\$USB_ROOT/sata\.uImage not found'
require_claim "a missing DTB aborts"                   'die "\$USB_ROOT/rescue\.sata\.dtb not found'

# No dangling file references in the header an operator reads first.
dangling=$(grep -oE 'README\.[a-z]+' rootfs/install-alpine | sort -u \
           | while read -r r; do [ -f "$r" ] || echo "$r"; done)
[ -z "$dangling" ]; rc=$?
check "install-alpine header references no missing files${dangling:+ (dangling: $dangling)}" "$rc"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "p1 backup ordering and failure handling: PASSED"
else
    echo "p1 backup ordering and failure handling: FAILED" >&2
    exit 1
fi
