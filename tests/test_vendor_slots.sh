#!/bin/bash
# test_vendor_slots.sh - can the boot handover enter a vendor slot?
#
# 99-disk-root decides what the box boots. Its fallback scan runs when no
# wdmch-root label is found - and on the real WDMCH there is none, because the
# root filesystem is labelled SYSTEM (it is the md1 RAID1 array on p20). So the
# fallback is the PRIMARY path on this machine, not an edge case.
#
# That scan used to include /dev/sda9, which is ROOTFS_GOLD, while
# docs/RECOVERY.md says in capitals:
#
#     DO NOT boot the GOLD partition. GOLD is a factory-reset appliance,
#     not a safe fallback.
#
# So the one script whose job is choosing what to boot implemented the action
# the documentation forbids. The installer's refusal to write GOLD is a
# different script and does not run here.
#
# These execute the real policy extracted from 99-disk-root. The loop cannot run
# on a test host - it needs block devices that only exist on the box - so what
# is tested is the decision each candidate label receives, which is the part
# that decides whether GOLD can be entered.

set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT=rootfs/init.d/99-disk-root
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }
sh -n "$SCRIPT" || { echo "FAIL: $SCRIPT has a syntax error" >&2; exit 1; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# Extract the real case statement that decides a candidate.
POLICY="$W/policy"
sed -n '/^    case "\$plabel" in$/,/^    esac$/p' "$SCRIPT" > "$POLICY"
if ! grep -q 'vendor slot' "$POLICY"; then
    echo "FAIL: could not extract the vendor-slot policy from $SCRIPT" >&2
    echo "      If it was renamed, this test must follow it, not be deleted." >&2
    exit 1
fi
sh -n "$POLICY" || { echo "FAIL: extracted policy is not valid shell" >&2; exit 1; }

# Decide a label using the SCRIPT'S OWN case statement.
#
# Only the action verb is substituted - `continue` becomes "print skip", the
# no-op becomes "print keep". The labels being tested, and which of them are
# rejected, come entirely from the extracted text. Writing a second copy of
# this logic here would be the defect this repository spent a series removing:
# a test that verifies its own reimplementation.
#
# Built as a file rather than spliced into `sh -c`: the block contains a `say`
# call in double quotes, and nesting that inside another quoted string breaks.
RUN="$W/run"
{
    echo 'say() { :; }'
    echo 'p=probe'
    echo 'plabel=$1'
    # No `break`: it is only meaningful inside a loop, and the case arm ends
    # by itself. Using it made the assembled script exit with an error and
    # print nothing, which read as "skip" for every label including the two
    # that are allowed.
    #
    # The keep arm is matched to end of line because the source has spaces
    # between `;;` and its trailing comment.
    sed 's/^    //' "$POLICY" \
      | sed 's|: ;;.*$|echo keep ;;|' \
      | sed 's|continue ;;.*$|echo skip ;;|'
} > "$RUN"
sh -n "$RUN" || { echo "FAIL: the assembled policy is not valid shell" >&2; exit 1; }

# keep_if_not_vendor <PARTLABEL> -> keep | skip, from 99-disk-root itself.
keep_if_not_vendor() { sh "$RUN" "$1" 2>/dev/null | grep -q keep && echo keep || echo skip; }

echo "=== handover: vendor slots must never be entered ==="

# --- the case that started this ---------------------------------------------
check "ROOTFS_GOLD is skipped" \
      "$(cond '[ "$(keep_if_not_vendor ROOTFS_GOLD)" = skip ]'; echo $?)"

# --- every other vendor slot the factory map defines -------------------------
# Labels measured on the real machine (docs/measurements/2026-10-02-wdmch.md).
for lbl in FW_TABLE KERNEL_A ROOTFS_A ROOTFS_B FDT_A FDT_B AFW_A KERNEL_B \
          ROOTFS_GOLD FDT_GOLD AFW_B BOOTCODE32 BOOTCODE64 BL31 BL32 \
          KERNEL_GOLD AFW_GOLD CONFIG SWAP DATA; do
    check "$lbl is treated as a vendor slot" \
          "$(cond '[ "$(keep_if_not_vendor "$lbl")" = skip ]'; echo $?)"
done

# --- and the two slots that are legitimately candidates ----------------------
check "SYSTEM_A is allowed as a candidate" \
      "$(cond '[ "$(keep_if_not_vendor SYSTEM_A)" = keep ]'; echo $?)"
check "SYSTEM_B is allowed as a candidate" \
      "$(cond '[ "$(keep_if_not_vendor SYSTEM_B)" = keep ]'; echo $?)"
check "an unlabelled partition is allowed" \
      "$(cond '[ "$(keep_if_not_vendor "" )" = keep ]'; echo $?)"

# --- the static facts about the scan itself ---------------------------------
check "the fallback scan no longer lists sda9" \
      "$(cond '! grep -qE "for p in [^\n]*sda9" "$SCRIPT"'; echo $?)"
check "  ...no other line adds sda9 back as a candidate" \
      "$(cond '[ "$(grep -cE "(^|[[:space:]])sda9([^0-9]|$)" "$SCRIPT")" -eq 0 ]'; echo $?)"
check "the scan consults PARTLABEL" \
      "$(cond 'grep -q "blkid -s PARTLABEL" "$SCRIPT"'; echo $?)"
check "  ...and skips, saying why" \
      "$(cond 'grep -q "is a vendor slot" "$SCRIPT"'; echo $?)"

# --- the documentation and the code must not contradict each other ----------
if grep -q 'DO NOT boot the GOLD partition' docs/RECOVERY.md; then
    if grep -qE "for p in [^\n]*sda9" "$SCRIPT"; then
        echo "  FAIL  RECOVERY.md forbids GOLD and the handover scan still includes sda9"
        FAILED=$((FAILED+1))
    else
        echo "  ok    the code agrees with RECOVERY.md about GOLD"
    fi
else
    echo "  FAIL  the GOLD prohibition is no longer in RECOVERY.md"
    FAILED=$((FAILED+1))
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "vendor-slot exclusion: PASSED"
else
    echo "vendor-slot exclusion: FAILED ($FAILED)" >&2
    exit 1
fi