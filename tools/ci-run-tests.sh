#!/usr/bin/env bash
# ci-run-tests.sh - run `make test` and make a failure DIAGNOSABLE.
#
# Motivation, from a real incident this release: run 37069902973 failed at the
# test step with exit code 2, and GitHub returned an EMPTY log for both jobs -
# 0 bytes from the API, across repeated retries. The only annotation available
# was "Process completed with exit code 2". Which of 20+ test scripts failed, and
# why, was unrecoverable without re-running the whole 30-minute kernel build.
#
# The raw log is not a reliable place to keep the answer to "what broke". So the
# failing output is also written to the job summary, which is always retrievable
# through the API, and saved as an artifact. Three call sites share this one
# implementation rather than repeating a tee in each.
#
# Exit status is the suite's, unchanged. `pipefail` is deliberately NOT relied on:
# with a pipeline the status is read from PIPESTATUS immediately, because `rc=$?`
# after a pipeline reports tee's status and would turn a failing suite green.

set -uo pipefail
cd "$(dirname "$0")/.."

LOG="${CI_TEST_LOG:-/tmp/make-test.log}"

echo "=== make test ==="
make test 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

if [ "$rc" -eq 0 ]; then
    echo "make test: PASS"
    exit 0
fi

# --- say what failed, in the places a person will actually look -------------
{
    echo "## make test FAILED (exit $rc)"
    echo
    echo "Full output is in the \`make-test-log\` artifact. Summary of the failures:"
    echo
    echo '```'
    grep -E '^\s*FAIL|FAIL:|^Error|Error [0-9]|make: \*\*\*' "$LOG" | head -60
    echo '```'
    echo
    echo "Last 40 lines:"
    echo
    echo '```'
    tail -40 "$LOG"
    echo '```'
} > "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo
echo "make test FAILED (exit $rc). Failure summary:"
grep -E '^\s*FAIL|FAIL:' "$LOG" | head -30 || true

exit "$rc"