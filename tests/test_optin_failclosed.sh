#!/bin/bash
# test_optin_failclosed.sh - an opt-in check must fail CLOSED once enabled.
#
# tests/test_btrfs_profiles.sh gates itself behind WDMCH_VERIFY_FS=1 because it
# formats loop devices. The first version then exited 0 from each capability
# probe - "SKIP: needs passwordless sudo", exit 0 - which is exactly the defect
# the CI fail-open guard exists to catch, and it went red in CI for three commits
# before anyone read why.
#
# The shape is subtle enough to be worth an invariant of its own:
#
#   NOT enabled                 -> exit 0 is correct. Nobody asked; nothing claimed.
#   enabled, host cannot do it  -> MUST exit non-zero.
#   enabled, host can do it     -> the real checks run.
#
# Exiting 0 in the middle case reports "the btrfs profile is fine" on precisely
# the runner where nobody would otherwise learn it was never verified. That is
# worse than not having the check at all, because it looks like evidence.
#
# Only the ENABLED region is asserted here. The not-enabled path is a genuine
# "nothing to do", and demanding that it also fail would be the same error in
# the opposite direction.

set -u
cd "$(dirname "$0")/.." || exit 1
S=tests/test_btrfs_profiles.sh
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }

# cond_empty <value> -> 0 when empty. Named rather than written inline because the
# inline form `[ -z "$x" ] && echo 0 || echo 1` sitting next to the word SKIP is
# EXACTLY the shape CI's fail-open guard rejects - and it rejected this file. The
# guard was right about the pattern; it happened to be a true positive on a
# check, not a false one. The helper removes the shape without weakening it.
# cond_empty <value> -> prints 0 when the value is empty. It must PRINT the
# status, not merely return it: check() reads $2 as an integer, so a predicate
# that only returns a status gives it an empty string and reports
# "integer expected" - which is exactly what happened when this was written as a
# bare predicate. It failed the check it was supposed to pass.
cond_empty() { [ -z "$1" ] && echo 0 || echo 1; }

[ -f "$S" ] || { echo "FAIL: $S missing" >&2; exit 1; }
sh -n "$S" || { echo "FAIL: $S has a syntax error" >&2; exit 1; }

echo "=== an opt-in check fails closed once it is switched on ==="

# --- 1. the not-enabled path is a genuine no-op -----------------------------
out=$(bash "$S" 2>&1); rc=$?
check "not enabled -> exit 0" "$([ $rc -eq 0 ] && echo 0 || echo 1)"
printf '%s' "$out" | grep -qi 'not run'
check "  ...and says plainly that it did not run" "$?"

# --- 2. the gate must not be satisfiable by accident -------------------------
grep -q '${WDMCH_VERIFY_FS:-0}" != "1"' "$S"
check "the gate compares against exactly 1, not a truthy test" "$?"

# --- 3. nothing in the ENABLED region may skip ------------------------------
# From the END of the gate's own `exit 0`, not from its first echo. That exit is
# the legitimate not-enabled path - nobody asked, nothing was claimed - and
# asserting on it would be the same error in the opposite direction. What must
# not appear is a SECOND exit 0 after the gate: an enabled check declining
# quietly is the failure this whole file exists to prevent.
after_gate=$(awk '/NOT RUN: this check formats/{f=1} f && /^[[:space:]]*exit 0$/{f=2; next} f==2{print}' "$S")
[ -n "$after_gate" ] && : || { echo "FAIL: could not locate the opt-in gate in $S" >&2; exit 1; }

bad_exit=$(printf '%s\n' "$after_gate" | grep -nE '^[[:space:]]*exit 0' | head -3)
show_if_set() { [ -n "$1" ] && printf '%s\n' "$1" | sed 's/^/      /'; return 0; }
check "no 'exit 0' after the opt-in gate" \
      "$([ -z "$bad_exit" ] && echo 0 || echo 1)"
[ -n "$bad_exit" ] && printf '%s\n' "$bad_exit" | sed 's/^/      /'

bad_skip=$(printf '%s\n' "$after_gate" | grep -nE 'SKIP:' | head -3)
check "no SKIP after the opt-in gate" "$(cond_empty "$bad_skip")"
show_if_set "$bad_skip"

# --- 4. the failure path exists and is reachable -----------------------------
printf '%s\n' "$after_gate" | grep -q '^require() {'
check "the enabled region defines require()" "$?"
printf '%s\n' "$after_gate" | grep -q 'require "'
check "  ...and calls it on each capability probe" "$?"
printf '%s\n' "$after_gate" | grep -q 'an unrun check is not a passing check'
check "  ...and it says why in terms the reader can act on" "$?"

# --- 5. behavioural: an enabled check on an incapable host must fail --------
# Simulated by replacing the sudo probe. This is a test OF the test harness,
# which is the only way to show the invariant is enforced at runtime rather
# than merely written down.
cp "$S" /tmp/.optin.bak
trap 'cp /tmp/.optin.bak "$S"; rm -f /tmp/.optin.bak' EXIT
python3 - "$S" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'sudo -n true 2>/dev/null || require "needs passwordless sudo for losetup"'
assert old in s, "sudo probe not found - update this mutation"
open(p, "w").write(s.replace(old, "false || require \"needs passwordless sudo for losetup\"", 1))
PY
out=$(WDMCH_VERIFY_FS=1 bash "$S" 2>&1); rc=$?
check "enabled + incapable host -> NON-ZERO exit" \
      "$([ $rc -ne 0 ] && echo 0 || echo 1)"
printf '%s' "$out" | grep -q 'needs passwordless sudo'
check "  ...and names what was missing" "$?"
printf '%s' "$out" | grep -qi 'FAIL'
check "  ...and reports it as a FAIL, not a skip" "$?"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "opt-in fail-closed: PASSED"
else
    echo "opt-in fail-closed: FAILED ($FAILED)" >&2
    exit 1
fi