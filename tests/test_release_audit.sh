#!/bin/bash
# Does tools/release-audit.sh actually FAIL when one of its children fails?
#
# I have reported "audit PASS" every iteration without ever testing that the
# audit fails. It is invoked by no test and no workflow, so nothing else would
# have caught it quietly passing forever - the same failure mode as the migration
# plan that contradicted the contract while every check stayed green.
set -u
cd /home/dominicusin/src/alpine-wdmch-builder
FAILED=0
check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }

echo "=== the release audit fails when a child fails ==="

AUDIT=tools/release-audit.sh
[ -f "$AUDIT" ] || { echo "FAIL: $AUDIT missing" >&2; exit 1; }

# Every script the audit invokes must exist. An audit that invokes a script which
# was renamed away is an audit that silently checks less than it claims.
missing=""
for s in $(grep -oE '(tools|tests|image|rootfs|scripts)/[a-z0-9_-]+\.(sh|py)' "$AUDIT" | sort -u); do
    [ -f "$s" ] || missing="$missing $s"
done
check "every script the audit invokes exists${missing:+ (missing:$missing)}" \
      "$([ -z "$missing" ] && echo 0 || echo 1)"

# The audit must count a child's failure and exit non-zero for it. Verified by
# running it against a sabotaged child rather than by reading the arithmetic.
if ! bash tools/check-deps.sh >/dev/null 2>&1; then
    echo "  (check-deps already fails on this host; using a different sabotage)"
fi

# The audit is sabotaged on a COPY, never on the real file. The first version
# edited tools/release-audit.sh in place and restored it from a trap - which a
# SIGKILL between the two would leave behind a sabotaged audit in the working
# tree, and `make test` has been SIGKILLed before in this session. A copy has
# nothing to restore and nothing to leave behind.
AW=$(mktemp -d)
trap 'rm -rf "$AW"' EXIT
cp "$AUDIT" "$AW/audit.sh"

python3 - "$AW/audit.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "bash tools/check-deps.sh || failures=$((failures + 1))"
assert old in s, "ANCHOR MISSING in release-audit.sh"
open(p, "w").write(s.replace(old, "false || failures=$((failures + 1))", 1))
print("    sabotage applied to a COPY: check-deps step replaced with `false`")
PY

out=$(timeout 300 bash "$AW/audit.sh" 2>&1)
rc=$?
check "the audit exits non-zero when a child fails" \
      "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
case "$out" in
    *"ALL CHECKS PASSED"*) check "  ...and does not claim ALL CHECKS PASSED" 1 ;;
    *)                      check "  ...and does not claim ALL CHECKS PASSED" 0 ;;
esac
case "$out" in
    *"CHECK(S) FAILED"*) check "  ...and names the failure count" 0 ;;
    *)                   check "  ...and names the failure count" 1 ;;
esac

# The real file must be untouched by all of this.
check "the real audit script was never modified" \
      "$(grep -q 'bash tools/check-deps.sh' "$AUDIT" && echo 0 || echo 1)"
check "  ...and no .bak was left in the tree" \
      "$([ ! -e "$AUDIT.bak" ] && echo 0 || echo 1)"

out2=$(timeout 300 bash "$AUDIT" 2>&1)
rc2=$?
check "the real audit still passes" \
      "$([ "$rc2" -eq 0 ] && echo 0 || echo 1)"
check "  ...and says so" \
      "$(printf '%s' "$out2" | grep -q 'ALL CHECKS PASSED' && echo 0 || echo 1)"

check "release-audit.sh is syntactically valid" \
      "$(bash -n "$AUDIT" && echo 0 || echo 1)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "release audit integrity: PASSED"
else
    echo "release audit integrity: FAILED ($FAILED)" >&2
    exit 1
fi