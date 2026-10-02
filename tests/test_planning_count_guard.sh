#!/bin/bash
# Prove the planning-drift count guard fires in BOTH directions.
#
# A guard that only proves "passes on the current tree" is worth nothing: it is
# indistinguishable from a guard that has stopped checking. This plants each
# defect in turn and requires the guard to notice, then restores and requires
# it to stay quiet.
#
# The count under test is the one in .github/workflows/validate.yml:
#     sed -n '/^test:/,/^$/p' Makefile | grep -cE '^[[:space:]]+bash '
set -u
cd "$(dirname "$0")/.." || exit 1

count_tests() { sed -n '/^test:/,/^$/p' Makefile | grep -cE '^[[:space:]]+bash '; }
stated_count() { grep -oE '[0-9]+ тестовых' ROADMAP.md | head -1 | grep -oE '[0-9]+'; }

FAILED=0
expect() { # $1 = label, $2 = 0 when the guard should fire / stay quiet as asked
    if [ "$2" -eq "$3" ]; then echo "  ok    $1"
    else echo "  FAIL  $1 (got $3, wanted $2)"; FAILED=$((FAILED+1)); fi
}

cp ROADMAP.md /tmp/gdr.bak; cp Makefile /tmp/gdm.bak
trap 'cp /tmp/gdr.bak ROADMAP.md; cp /tmp/gdm.bak Makefile; rm -f /tmp/gdr.bak /tmp/gdm.bak' EXIT

guard_fires() { [ "$(count_tests)" != "$(stated_count)" ] && echo 1 || echo 0; }

echo "=== planning-drift count guard ==="
n=$(count_tests); s=$(stated_count)
echo "  Makefile test target runs $n; ROADMAP states $s"

# 1. the current tree must be clean, or the guard cries wolf again
expect "the current tree is consistent (no false alarm)" 0 "$(guard_fires)"

# 2. a wrong number in ROADMAP must be caught
python3 - <<'PY'
import re
p = "ROADMAP.md"; s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(re.sub(r"[0-9]+ тестовых", "99 тестовых", s, count=1))
PY
expect "a stale count in ROADMAP is caught" 1 "$(guard_fires)"
cp /tmp/gdr.bak ROADMAP.md

# 3. a new test added to the Makefile but not to ROADMAP must be caught
python3 - <<'PY'
p = "Makefile"; s = open(p, encoding="utf-8").read()
assert "\tbash test-flash.sh" in s, "anchor for the extra test is missing"
open(p, "w", encoding="utf-8").write(
    s.replace("\tbash test-flash.sh", "\tbash test-flash.sh\n\tbash tests/test_btrfs_target.sh", 1))
PY
expect "an uncounted new test is caught" 1 "$(guard_fires)"
cp /tmp/gdm.bak Makefile

# 4. a test at the repo ROOT must be inside the count. This is the bug the
#    guard had: it counted `bash tests/`, so test-flash.sh - which lives at the
#    repository root - was invisible, and it reported 20 for a target running
#    21. Asserted by removing that one line and requiring the count to drop.
#    (Appending a line instead would land after the blank line that ends the
#    target, and prove nothing - the first version of this check did that and
#    passed for the wrong reason.)
with_root=$(count_tests)
python3 - <<'PY'
p = "Makefile"; s = open(p, encoding="utf-8").read()
assert "\tbash test-flash.sh\n" in s, "the root-level test invocation is missing"
open(p, "w", encoding="utf-8").write(s.replace("\tbash test-flash.sh\n", "", 1))
PY
without_root=$(count_tests)
expect "the root-level test-flash.sh IS counted" \
       1 "$([ "$with_root" -eq $((without_root+1)) ] && echo 1 || echo 0)"
cp /tmp/gdm.bak Makefile

echo
[ "$FAILED" -eq 0 ] && echo "planning-drift count guard: PASSED" || { echo "FAILED ($FAILED)" >&2; exit 1; }
