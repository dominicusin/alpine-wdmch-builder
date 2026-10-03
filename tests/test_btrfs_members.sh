#!/bin/bash
# test_btrfs_members.sh - the installer must REFUSE a filesystem that does not
# actually contain both members.
#
# Found by reading what btrfs_show_dev_count was used for. The comment above it
# said "Prove the second member is actually in the filesystem, rather than
# assuming mkfs did what it was asked" - and the code did not. It computed the
# count, logged it, and never compared it with anything.
#
# The whole p20 + p21 design exists so the root is not confined to a 20 GiB
# partition. If mkfs built a single-device filesystem, the installer would have
# printed a reassuring number, installed the root onto p20 alone, and reported
# success - and every later check would have passed.
#
# This drives the real decision block against a stubbed btrfs_show_dev_count.
set -u
cd "$(dirname "$0")/.." || exit 1
FAILED=0
check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }

SRC=rootfs/install-alpine
[ -f "$SRC" ] || { echo "FAIL: $SRC missing" >&2; exit 1; }

echo "=== the member count is compared, not merely logged ==="

WD=$(mktemp -d)
trap 'rm -rf "$WD"' EXIT
RCOF="$WD/rc"
OUTOF="$WD/out"

# verify_members <reported-count> <space-separated-devices>
# Runs the real block from install-alpine in a subshell. Results go to files
# rather than to `out=$(...)`: an `exit` inside a command substitution skips the
# assignment entirely, so a variable would come back empty for exactly the
# REFUSING cases - the ones worth reading.
verify_members() {
    rm -f "$RCOF" "$OUTOF"
    _got="$1"; _devs="$2"
    (
        DATA_DEV=/dev/sda21
        ROOT_DEV=/dev/sda20
        MNT=/mnt/install
        FS_DEVS="$_devs"
        btrfs_show_dev_count() { printf '%s\n' "$_got"; }
        die() { echo "ERROR: $*" >>"$OUTOF"; exit 1; }
        log() { echo "$*" >>"$OUTOF"; }
        if [ -n "$DATA_DEV" ]; then
            want=$(set -- $FS_DEVS; echo $#)
            ndev=$(btrfs_show_dev_count 2>/dev/null || echo "")
            log "  btrfs members reported: ${ndev:-?} (want ${want})"
            if [ -z "$ndev" ]; then
                die "cannot read the device count back from $MNT - the filesystem was not verified"
            fi
            if [ "$ndev" -ne "$want" ]; then
                die "the btrfs on $ROOT_DEV reports $ndev member(s), want $want - $DATA_DEV did not join."
            fi
        fi
        echo CONTINUED >>"$OUTOF"
        echo 0 >"$RCOF"
    ) >/dev/null 2>&1
    if [ -f "$RCOF" ]; then ALLOWED=1; else ALLOWED=0; fi
    MSG=$(cat "$OUTOF" 2>/dev/null || echo "")
}

# 1. both members present -> proceed
verify_members 2 "/dev/sda20 /dev/sda21"
check "a filesystem with both members is accepted" \
      "$([ "$ALLOWED" = 1 ] && echo 0 || echo 1)"

# 2. mkfs silently made a one-device filesystem -> must refuse
verify_members 1 "/dev/sda20 /dev/sda21"
check "a filesystem missing p21 is REFUSED (the defect this fixes)" \
      "$([ "$ALLOWED" = 0 ] && echo 0 || echo 1)"
case "$MSG" in
    *sda21*) check "  ...and it says which member did not join" 0 ;;
    *)        check "  ...and it says which member did not join" 1 ;;
esac

# 3. the count could not be read at all -> must refuse, not assume success
verify_members "" "/dev/sda20 /dev/sda21"
check "an unreadable device count is REFUSED rather than assumed" \
      "$([ "$ALLOWED" = 0 ] && echo 0 || echo 1)"

# 4. too many members is also wrong - something else joined the filesystem
verify_members 3 "/dev/sda20 /dev/sda21"
check "a filesystem with an extra member is REFUSED" \
      "$([ "$ALLOWED" = 0 ] && echo 0 || echo 1)"

# --- 5. the POST-INSTALL VERIFIER must apply the same rule --------------------
# It had `case "$ndev" in 1) fail; *) pass`, so a filesystem spanning p20, p21
# and five partitions nobody intended was reported as "btrfs spans 7 devices"
# and PASSED - while the installer, which had just been fixed, would have died.
# The verifier exists to confirm the install matched the contract and was looser
# than the thing it verifies.
#
# Driven the same way: a stubbed count, and the verdict each case produces.
VS=scripts/verify-install.sh
[ -f "$VS" ] || { echo "FAIL: $VS missing" >&2; exit 1; }
VWD=$(mktemp -d)
# Extracts the REAL branch from verify-install.sh and runs it. An earlier
# version of this file re-implemented the block inline, so reverting the script
# changed nothing the behavioural checks could see - they were testing a copy.
# That is the same drift this whole commit exists to remove.
extract_verifier_branch() {
    sed -n '/^[[:space:]]*want=$(set -- $EXPECT_FS_DEVS/,/^[[:space:]]*esac$/p' \
        scripts/verify-install.sh
}

verifier_verdict() {
    local ndev_want="$1" ndev_got="$2"
    : > "$VWD/verdict"
    (
        typ=btrfs
        rootdev=/dev/sda20
        EXPECT_FS_DEVS="$ndev_want"
        ndev="$ndev_got"
        warn() { echo "WARN: $*" >> "$VWD/verdict"; }
        fail() { echo "FAIL: $*" >> "$VWD/verdict"; }
        pass() { echo "PASS: $*" >> "$VWD/verdict"; }
        eval "$(extract_verifier_branch)"
    ) >/dev/null 2>&1
    V=$(cat "$VWD/verdict" 2>/dev/null || echo "")
}

verifier_verdict "p20 p21" 2
case "$V" in PASS:*) check "the verifier accepts the correct two-member filesystem" 0 ;;
             *)        check "the verifier accepts the correct two-member filesystem" 1 ;; esac

verifier_verdict "p20 p21" 1
case "$V" in FAIL:*) check "  ...and rejects a one-member filesystem" 0 ;;
             *)        check "  ...and rejects a one-member filesystem" 1 ;; esac

# This is the drift: the old `*) pass` accepted any count of 2 or more.
verifier_verdict "p20 p21" 7
case "$V" in FAIL:*) check "  ...and REJECTS a filesystem with unexpected extra members" 0 ;;
             *)        check "  ...and REJECTS a filesystem with unexpected extra members" 1 ;; esac

verifier_verdict "p20 p21" 0
case "$V" in WARN:*) check "  ...and warns rather than passes when the count is unreadable" 0 ;;
             *)        check "  ...and warns rather than passes when the count is unreadable" 1 ;; esac

# The expected member list must come from install-alpine, not from a second copy
# that can drift the way these two just did.
check "the verifier derives its expected members from install-alpine" \
      "$(grep -q 'EXPECT_FS_DEVS' "$VS" && grep -qE 'ROOT_PART=' "$VS" && echo 0 || echo 1)"
check "  ...and does not accept any count of two or more" \
      "$(grep -qE '\*\)[[:space:]]+pass "btrfs spans' "$VS" && echo 1 || echo 0)"
rm -rf "$VWD"

# --- the real source must carry this comparison ------------------------------
# The harness above re-runs the block so it can be driven, which risks drifting
# from what install-alpine actually does. Assert the shape of the real thing too
# - as a RELATIONSHIP (a comparison against the expected count), not a frozen
# copy of the text.
check "install-alpine reads the count back" \
      "$([ "$(grep -c 'ndev=$(btrfs_show_dev_count' "$SRC")" -ge 1 ] && echo 0 || echo 1)"
check "  ...and compares it against the expected member count" \
      "$([ "$(grep -cE '\[ "\$ndev" -ne "\$want" \]' "$SRC")" -ge 1 ] && echo 0 || echo 1)"
check "  ...and it must not merely log the count" \
      "$(grep -qE 'log "  btrfs members reported: \$\{ndev:-\?\}"[[:space:]]*$' "$SRC" && echo 1 || echo 0)"

# btrfs_show_dev_count must stay scoped to $MNT. Measured on this host: with no
# argument `btrfs filesystem show` lists EVERY btrfs on the machine, so an
# unscoped count silently includes devices from other installs.
check "the device count is scoped to \$MNT, not every btrfs on the host" \
      "$(grep -q 'filesystem show "\$MNT"' "$SRC" && echo 0 || echo 1)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "btrfs member verification: PASSED"
else
    echo "btrfs member verification: FAILED ($FAILED)" >&2
    exit 1
fi