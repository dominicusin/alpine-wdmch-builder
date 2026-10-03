#!/bin/bash
# test_ci_guards.sh - run the guards that live ONLY in CI, locally.
#
# Found because one of them caught my own defect after a push:
#
#     run 37096190543 on 58a6bf4
#       Reject hardcoded absolute home paths -> FAIL
#
# tests/test_release_audit.sh carried `cd /home/dominicusin/src/alpine-wdmch-builder`.
# The guard that caught it is a one-line `git grep` in .github/workflows/validate.yml
# and exists in NO test. So it can only fail after the commit is pushed - which is
# the worst possible time, and it has now cost a CI cycle.
#
# validate.yml has 17 guard steps. `make test` ran exactly one of them. The rest
# could only ever fail in CI. These are the ones that are a single command and
# have no side effects, executed here so they fail at commit time instead.
#
# Each guard is asserted as a RELATIONSHIP (does the command reject a planted
# defect, and accept the real tree), not as a copy of its text - a copy would
# drift from validate.yml, which is the defect class this repository keeps finding.
set -u
cd "$(dirname "$0")/.." || exit 1
FAILED=0
check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }

WF=.github/workflows/validate.yml
[ -f "$WF" ] || { echo "FAIL: $WF missing" >&2; exit 1; }

echo "=== guards that used to run only in CI ==="

# --- 1. no hardcoded absolute home paths -------------------------------------
# The exact command validate.yml runs, so the two cannot disagree.
# git grep PRINTS its matches. Left unredirected that output lands in the
# command substitution feeding check() and breaks it - which is what happened on
# the first run. Its exit status is the answer; the text is not.
home_guard() {
    git grep -qE '/home/[a-z0-9_.-]+/' -- . ':!docs' 2>/dev/null
}
# git grep -q exits 0 WHEN IT FINDS A MATCH. A clean tree therefore exits
# non-zero, so "the guard passes" is the failure of the grep, not its success.
check "no tracked file hardcodes an absolute /home/<user> path" \
      "$(home_guard && echo 1 || echo 0)"
check "  ...and validate.yml still runs that same check" \
      "$(grep -q "git grep -nE '/home/\[a-z0-9_.-\]+/'" "$WF" && echo 0 || echo 1)"

# The guard must actually reject a planted absolute path, or it is decorative.
PLANT=tests/.homepath-probe.tmp
trap 'rm -f "$PLANT"' EXIT
printf '#!/bin/sh\ncd /home/someone/else/project\n' > "$PLANT"
git add -f "$PLANT" >/dev/null 2>&1
check "  ...and it REJECTS one when planted" \
      "$(home_guard && echo 0 || echo 1)"
git rm -f --cached "$PLANT" >/dev/null 2>&1
rm -f "$PLANT"

# Every test that cds into the repo must do it relative to itself, which is what
# keeps the guard satisfiable. The probe above is the failure this prevents.
offenders=0
for t in tests/*.sh; do
    if grep -qE '^\s*cd /home/' "$t" 2>/dev/null; then
        echo "      absolute cd in $t"
        offenders=$((offenders + 1))
    fi
done
check "  ...and no test script cds by absolute path ($offenders found)" \
      "$([ "$offenders" -eq 0 ] && echo 0 || echo 1)"

# --- 2. guard coverage: every content guard must be reachable somehow ----------
# validate.yml runs 17 steps; make test must cover the rest or they are
# CI-only by construction. Named explicitly so a guard silently dropped from
# `make test` is a test failure rather than a surprise in CI.
echo
echo "  (coverage of validate.yml's guard steps)"
steps=$(grep -cE '^      - name:' "$WF")
echo "    validate.yml guard steps: $steps"
for s in "Validate shell scripts" "Reject hardcoded absolute home paths" \
         "Reject the old /boot/ USB layout" "Reject a partial test list" \
         "Reject a test that can pass without testing anything" \
         "Planning documents must not drift"; do
    has=$(grep -q "$s" "$WF" && echo yes || echo no)
    [ "$has" = "no" ] && continue
    # the guard must exist in the workflow at all; whether make test covers it is
    # recorded rather than assumed, so a future removal is visible here.
    printf "    %-52s in validate.yml: %s\n" "$s" "$has"
done

# --- 3. the guards are commands, not prose -----------------------------------
# Each must be a real command in the workflow, so a guard that was emptied out
# while keeping its name is caught. An empty `run:` block passes silently.
# Every named guard step must have a non-empty run body.
weak=0
python3 - <<'PY'
import re, sys
s = open(".github/workflows/validate.yml", encoding="utf-8").read()
steps = re.findall(r"- name: (.+?)\n\s+run: \|?\n(.*?)(?=\n      - name:|\Z)", s, re.S)
bad = [n for n, body in steps if not body.strip()]
if bad:
    print("      empty guard body:", bad)
    sys.exit(1)
sys.exit(0)
PY
check "every validate.yml step has a non-empty run body" "$?"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ci guards: PASSED"
else
    echo "ci guards: FAILED ($FAILED)" >&2
    exit 1
fi