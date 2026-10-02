#!/bin/bash
# test_mutate.sh - tools/mutate.sh is invoked by nothing, so nothing would tell
# us when it stops working. It is the tool every other claim in this repository
# rests on: "this check fires on that defect" is only meaningful if the mutation
# genuinely landed, and the whole reason mutate.sh exists is that a mutation
# which fails to apply looks exactly like a check which fails to fire.
#
# So the harness needs a harness. Each mode is driven both ways: it must accept
# the state it is supposed to accept and refuse the one it is supposed to catch.

set -u
cd "$(dirname "$0")/.." || exit 1
M=tools/mutate.sh
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
runs()  { bash "$M" "$@" >"$W/out" 2>&1; }

[ -f "$M" ] || { echo "FAIL: $M missing" >&2; exit 1; }
bash -n "$M" || { echo "FAIL: $M has a syntax error" >&2; exit 1; }

echo "=== mutate.sh can tell a mutation that landed from one that did not ==="

printf 'alpha\nbeta\ngamma\n' > "$W/f"

# --- verdict modes -----------------------------------------------------------
runs "$W/f" expect-present 'alpha'
check "expect-present accepts a string that is there" "$?"
runs "$W/f" expect-absent 'delta'
check "expect-absent accepts a string that is not" "$?"
runs "$W/f" expect-count 'beta::1'
check "expect-count accepts the exact count" "$?"

# The failure that matters: a verdict that passes when it should not is a false
# receipt. Each of these MUST exit non-zero.
runs "$W/f" expect-absent 'alpha'
check "expect-absent REJECTS a string that is present" "$([ $? -ne 0 ] && echo 0 || echo 1)"
runs "$W/f" expect-present 'delta'
check "expect-present REJECTS a string that is absent" "$([ $? -ne 0 ] && echo 0 || echo 1)"
runs "$W/f" expect-count 'beta::2'
check "expect-count REJECTS a wrong count" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# --- the marker must be unambiguous -------------------------------------------
# Two mutations earlier in this release reported "0 test failures" because the
# marker matched nothing. That is the exact failure mutate.sh was written to
# prevent, so it has to be prevented here too.
# The marker must be ambiguous to be refused. `one` twice, on two lines - the
# first version of this fixture used "one\ntwo", where "one" appears once, so
# the tool was right to accept it and the test was wrong.
cp "$W/f" "$W/two"
printf 'alpha one\nbeta one\n' > "$W/two"
runs "$W/two" replace-block 'one|||1|||ONE'
check "replace-block REFUSES a marker matching two lines" "$([ $? -ne 0 ] && echo 0 || echo 1)"

cp "$W/f" "$W/three"
printf 'alpha\nbeta\nalpha\n' > "$W/three"
runs "$W/three" replace-block 'alpha|||1||X'
check "replace-block REFUSES a marker matching twice" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# --- and it must actually apply ----------------------------------------------
cp "$W/f" "$W/one"
runs "$W/one" replace-block 'beta|||1|||BETA'
check "replace-block accepts an unambiguous marker" "$?"
grep -q '^BETA$' "$W/one"
check "  ...and the replacement really landed" "$([ $? -eq 0 ] && echo 0 || echo 1)"
grep -q '^beta$' "$W/one"
check "  ...replacing one line did not eat its neighbours" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# --- multi-line spans --------------------------------------------------------
cp "$W/f" "$W/span"
printf 'keep1\nkeep2\nkeep3\n' > "$W/span"
runs "$W/span" replace-block 'keep1|||2|||merged'
check "replace-block accepts a two-line span" "$?"
[ "$(grep -c . "$W/span")" -eq 2 ]
check "  ...and replaced exactly two lines" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# --- unknown modes must not pass quietly -------------------------------------
runs "$W/f" expect-nonsense 'alpha'
check "an unknown mode is REFUSED" "$([ $? -ne 0 ] && echo 0 || echo 1)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "mutate.sh: PASSED"
else
    echo "mutate.sh: FAILED ($FAILED)" >&2
    exit 1
fi