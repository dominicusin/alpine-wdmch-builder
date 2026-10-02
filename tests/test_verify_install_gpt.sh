#!/bin/bash
# test_verify_install_gpt.sh - does the factory-GPT check look at the right disk?
#
# This is the project's central safety property: if the partition count dropped,
# something wrote a partition table and the box is in the state the project
# exists to avoid. RUNBOOK.md tells the operator to stop and read RECOVERY.md
# when this line fails.
#
# The check used to count sda* unconditionally. But rootfs/init states that the
# rescue USB stick claims /dev/sda in this environment, and 99-disk-root tells
# the operator the stick can stay plugged in after the handover. So in the
# documented configuration the internal disk enumerates as sdb, sda holds the
# stick's single FAT32 partition, and the check reported
#
#     internal disk exposes only 1 partitions - the factory GPT was rewritten
#
# on a perfectly correct install - sending the operator to recover a machine
# that never broke. A false alarm on the one check that must not produce one.
#
# These drive the real script with a synthetic /proc/partitions, because the
# whole question is which device gets counted.

set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT=scripts/verify-install.sh
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }

W=$(mktemp -d)

# Build a synthetic /proc/partitions. $1 = letter of the internal disk
mkparts() {
    local internal=$1 stick=$2 count=$3
    : > "$W/partitions"
    local i
    for i in $(seq 1 "$count"); do
        printf '  259 %9d %8d %s%d\n' $((i*1000)) $((i*1000)) "$internal" "$i" >> "$W/partitions"
    done
    if [ -n "$stick" ]; then
        printf '   8 %9d %8d %s1\n' 100000 200000 "$stick" >> "$W/partitions"
    fi
    printf '  259 %9d %8d %s\n' 999999 1234567 "$internal" >> "$W/partitions"
}

# The selection is EXTRACTED from verify-install.sh and executed, never copied.
# The first version of this test reimplemented the awk here, and the mutation
# that put the whole-disk line back into the script's awk passed - because the
# test was checking its own copy, not the code. A test that verifies a
# reimplementation verifies nothing. The counting logic below is the script's.
# The selection is EXTRACTED from verify-install.sh and executed, never copied.
# The first version of this test reimplemented the awk here, and the mutation
# that put the whole-disk line back into the script's awk PASSED - because the
# test was checking its own copy rather than the code. A test that verifies a
# reimplementation verifies nothing.
#
# It is assembled into a runnable file rather than spliced into `sh -c`: the
# block contains an awk program in single quotes, and nesting that inside
# another single-quoted string silently truncates it.
# The two functions are EXTRACTED from verify-install.sh and executed, never
# copied. The first version of this test reimplemented the awk inline, and the
# mutation that put the whole-disk line back into the script's awk PASSED -
# because the test was checking its own copy rather than the code. A test that
# verifies a reimplementation verifies nothing.
#
# An earlier attempt extracted an inline `if` block, which is not a runnable
# shell fragment: the range ended on an `if ... then` with no `fi`. Making the
# logic two complete functions is what makes extraction honest.
FNS=$(mktemp)
trap 'rm -rf "$W" "$FNS"' EXIT
sed -n '/^count_partitions() {/,/^}/p;/^select_internal_disk() {/,/^}/p' "$SCRIPT" > "$FNS"
for fn in count_partitions select_internal_disk; do
    if ! grep -q "^${fn}() {" "$FNS"; then
        echo "FAIL: could not extract $fn() from $SCRIPT" >&2
        echo "      If it was renamed, this test must follow it, not be deleted." >&2
        exit 1
    fi
done
sh -n "$FNS" || { echo "FAIL: extracted functions are not valid shell" >&2; exit 1; }

# selected_disk [<partition-table>] -> "<disk> <count>" on one line, from the
# script's own code.
selected_disk() {
    PARTS=${1:-$W/partitions} sh -c '
        . "$1"
        d=$(select_internal_disk)
        printf "%s %s\n" "$d" "$(count_partitions "$d")"
    ' sh "$FNS" 2>/dev/null
}

# The old sda-only count, kept only to demonstrate the regression it caused.
old_sda_count() { awk '$4 ~ /^sda/ {c++} END{print c+0}' "$W/partitions"; }

echo "=== verify-install: which disk does the GPT check inspect? ==="

# --- the documented configuration: stick on sda, internal on sdb ------------
mkparts sdb sda 24
r=$(selected_disk)
check "with the stick on sda, the internal disk on sdb is chosen" \
      "$(cond '[ "$r" = "/dev/sdb 24" ]'; echo $?)"
check "  ...and 24 partitions passes the >=20 threshold" \
      "$(cond '[ "${r##* }" -ge 20 ]'; echo $?)"

# --- no stick plugged in: internal on sda -----------------------------------
mkparts sda "" 24
r=$(selected_disk)
check "with no stick, the internal disk on sda is chosen" \
      "$(cond '[ "$r" = "/dev/sda 24" ]'; echo $?)"

# --- internal on sdc, two other disks present -------------------------------
mkparts sdc sda 24
mkparts_dummy() { :; }
r=$(selected_disk)
check "the choice does not depend on the letter" \
      "$(cond '[ "$r" = "/dev/sdc 24" ]'; echo $?)"

# --- a genuinely broken disk must still be caught --------------------------
# 8 partitions is a repartitioned disk. The check must FAIL, not pass.
mkparts sdb sda 8
r=$(selected_disk)
check "a repartitioned disk (8 partitions) is below the threshold" \
      "$(cond '[ "${r##* }" -lt 20 ]'; echo $?)"

# --- the old sda-only behaviour would have got this wrong -------------------
# This is the regression itself: what the previous implementation computed.
old_sda_count() { awk '$4 ~ /^sda/ {c++} END{print c+0}' "$W/partitions"; }
mkparts sdb sda 24
check "the OLD sda-only count would have been 1 (the stick)" \
      "$(cond '[ "$(old_sda_count)" -eq 1 ]'; echo $?)"
check "  ...and would have FAILED a correct install" \
      "$(cond '[ "$(old_sda_count)" -lt 20 ]'; echo $?)"
check "  ...which is the false alarm this test exists to prevent" \
      "$(cond '[ "$(selected_disk | cut -d" " -f2)" -ge 20 ]'; echo $?)"

# --- the script must not hardcode sda for this check any more ---------------
check "verify-install.sh no longer counts sda* for the GPT check" \
      "$(cond '! grep -qE "\\\$4 ~ /\^sda/" scripts/verify-install.sh'; echo $?)"
check "  ...and names the disk it inspected in the output" \
      "$(cond 'grep -q "exposes .* partitions (factory GPT preserved)" scripts/verify-install.sh'; echo $?)"

# --- RUNBOOK must describe what the script now does ------------------------
check "RUNBOOK.md still flags the GPT line as the safety property" \
      "$(cond 'grep -q "factory GPT survived" docs/RUNBOOK.md'; echo $?)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "verify-install GPT check: PASSED"
else
    echo "verify-install GPT check: FAILED ($FAILED)" >&2
    exit 1
fi
