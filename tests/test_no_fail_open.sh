#!/usr/bin/env bash
# install-alpine must never report success after failing to install something
# the installed system cannot boot or be reached without.
#
# Four instances of this class were found by auditing the checklist against the
# code, not by running anything:
#
#   1. the rescue-stick refusal was dead code (tests/test_rescue_refusal.sh)
#   2. the p1 firmware-table allowlist sat behind a filesystem probe
#      (tests/test_rescue_refusal.sh)
#   3. the p1 backup was read after mke2fs, and a failed read was a WARN
#      (tests/test_p1_backup.sh)
#   4. a missing authorized_keys, a missing kernel and a missing DTB were all
#      WARNs, so the install could finish and announce success while leaving a
#      system with no way in and nothing to boot.
#
# Each of those is the same shape: `log "WARN: ..."` and carry on, where the
# right answer is to stop. This test covers the fourth group, and guards the
# whole shape so the next one is caught here rather than on a serial console.
set -Eeuo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJ_DIR/rootfs/install-alpine"

test -f "$SRC" || { echo "FAIL: $SRC not found"; exit 1; }
sh -n "$SRC" || { echo "FAIL: install-alpine does not parse"; exit 1; }

FAILED=0
rc=0
check() { # $1 label, $2 rc
    if [ "$2" = "0" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n' "$1"; FAILED=1; fi
}
cond() { if "$@"; then rc=0; else rc=1; fi; }

echo "=== install-alpine: nothing boot-critical may be skipped with a warning ==="
echo

# --- 1. the SSH key ---------------------------------------------------------
# Anchored to the text install-alpine actually emits. This searched for
# "WARN: no authorized_keys" while the script writes
# "ERROR: no authorized_keys in the rescue image." - so the absence check passed
# against a string that was never there, whether or not the guard existed. The
# guard was real; the check reporting on it was not.
no_key_warn() { ! grep -qE 'WARN:.*no authorized_keys' "$SRC"; }
cond no_key_warn
check "a missing authorized_keys is not a warning" "$rc"

key_fatal() { grep -q 'ERROR: no authorized_keys in the rescue image' "$SRC"; }
cond key_fatal
check "a missing authorized_keys stops the install" "$rc"

# The key must be non-empty, not merely present: an empty file is as useless
# as none, and dropbear will accept it silently.
key_size() { grep -q '\[ -s "\$MNT/root/.ssh/authorized_keys" \]' "$SRC"; }
cond key_size
check "the installed key is checked non-empty" "$rc"

# --- 2. the kernel and the DTB ---------------------------------------------
no_kernel_warn() { ! grep -q 'WARN: .*sata.uImage not found' "$SRC"; }
cond no_kernel_warn
check "a missing kernel is not a warning" "$rc"

kernel_fatal() { grep -q 'die "\$USB_ROOT/sata.uImage not found' "$SRC"; }
cond kernel_fatal
check "a missing kernel stops the install" "$rc"

no_dtb_warn() { ! grep -q 'WARN: .*rescue.sata.dtb not found' "$SRC"; }
cond no_dtb_warn
check "a missing DTB is not a warning" "$rc"

dtb_fatal() { grep -q 'die "\$USB_ROOT/rescue.sata.dtb not found' "$SRC"; }
cond dtb_fatal
check "a missing DTB stops the install" "$rc"

# --- 3. nothing else warns its way past a boot-critical artifact -----------
# Count only EXECUTABLE warnings. The comments explaining the old defects also
# contain the word "WARN", and counting those made this test fail on a tree
# that is actually correct - the same "looks broken, is fine" trap in reverse.
# A warning only counts when it is a log call, never a comment.
warnings=$(grep -cE '^[[:space:]]*[^#]*log ".*WARN' "$SRC" || true)
echo
echo "  executable WARNs left in install-alpine: $warnings  (expected 1)"
grep -nE '^[[:space:]]*[^#]*log ".*WARN' "$SRC" | sed 's/^/    /'
echo
only_expected_warning() {
    [ "$warnings" -eq 1 ] || return 1
    grep -q 'is missing' "$SRC" || return 1
    # And it must not name anything that would leave the system unusable.
    if grep -qE '^[[:space:]]*[^#]*log ".*WARN.*(kernel|DTB|authorized_keys|firmware table|sata\.uImage|rescue\.sata)' "$SRC"; then
        return 1
    fi
    return 0
}
cond only_expected_warning
check "no WARN remains that could hide an unusable system" "$rc"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "install-alpine fail-open audit: PASSED"
else
    echo "install-alpine fail-open audit: FAILED" >&2
    exit 1
fi
