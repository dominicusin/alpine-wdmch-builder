#!/bin/bash
# test_ci_guards.sh - run the guards that live ONLY in CI, locally.
#
# Found because one of them caught my own defect after a push:
#
#     run 37096190543 on 58a6bf4
#       Reject hardcoded absolute home paths -> FAIL
#
# tests/test_release_audit.sh carried an absolute `cd` into one developer's home.
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

# Scratch space for this run. Created here rather than in whichever block needs
# it first: an earlier version created it inside a subshell, and the later awk
# program that writes into it hit "AW: unbound variable" under `set -u`.
AW=$(mktemp -d)

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
trap 'rm -rf "$AW"; rm -f "$PLANT"' EXIT
# The literal is assembled at runtime. Written out in the source, this line
# would itself match the guard once the file is tracked - which is exactly what
# happened on the first run: the test failed on its own documentation.
_probe_home="/home/some""one/else/project"
printf '#!/bin/sh\ncd %s\n' "$_probe_home" > "$PLANT"
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

# --- 4. a test entry must not silently lose its arguments --------------------
# My own defect, committed and green for three commits: a rewrite of the
# Makefile dropped the arguments from
#
#     bash tests/test_rootfs.sh build/rootfs $$(cat ...)
#
# leaving `bash tests/test_rootfs.sh`. The suite then died with
# "1: $1: не заданы границы переменной" - which prints no "FAIL", so a gate
# counting FAIL lines read 0 and reported success.
#
# Any test that reads a positional parameter must be invoked with it. Detected
# by reading the test, not by running the suite, so it fires at commit time.
echo
echo "  (positional parameters must survive into the Makefile)"
bad=""
while IFS= read -r t; do
    base=$(basename "$t")
    # does the test dereference $1..$9 under set -u?
    # grep -c already prints 0 when nothing matches, and exits non-zero. The
    # `|| echo 0` would then print a SECOND 0 and break the comparison below.
    uses=$(grep -cE '^\s*[A-Z_]+="?\$\{?[1-9]' "$t" 2>/dev/null)
    uses=${uses:-0}
    [ "$uses" -gt 0 ] || continue
    line=$(grep -F "bash $base" Makefile 2>/dev/null | head -1)
    if [ -z "$line" ]; then
        continue                      # not run from make test at all
    fi
    # a bare invocation with nothing after the script name is the defect
    case "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" in
        "bash $base"|"bash $base "*)
            # "bash $base " with trailing space is fine; exact-match is not
            case "$(printf '%s' "$line" | sed 's/[[:space:]]*$//')" in
                "bash $base") bad="$bad $base" ;;
            esac ;;
    esac
done < <(ls tests/*.sh 2>/dev/null)
check "every test that needs arguments is given them in the Makefile${bad:+ (bare:$bad)}" \
      "$([ -z "$bad" ] && echo 0 || echo 1)"

# And the specific case that was broken, named so a regression is unmistakable.
check "tests/test_rootfs.sh is invoked with its ROOT and RELEASE arguments" \
      "$(grep -qE 'bash tests/test_rootfs\.sh[[:space:]]+build/rootfs' Makefile && echo 0 || echo 1)"

# --- 5. the vacuous-test guard, which also lived only in CI ------------------
# validate.yml rejects a test that can report success without testing anything.
# Two shapes: conditional bail-out language immediately above a zero-status
# return, and a failure branch that only prints a warning instead of exiting
# non-zero. Three such tests existed here - the flash.zip closure guard that bailed
# when the resolver failed, and the QEMU smoke test that bailed without qemu and
# only warned when BusyBox would not run.
#
# The wording above is deliberately chosen. An earlier version of this comment
# described the first shape by naming it, and the guard below then matched its
# own documentation - this file failed its own check. validate.yml drops comment
# lines in its other guard for the same reason, and says so; here the text is
# reworded instead, so the file still explains what it does without tripping it.
#
# It is a strong guard and it is also CI-only, so a fourth can appear unnoticed
# until a push. The awk below is validate.yml's own, extracted - a copy would
# drift from the workflow, which is the defect class this file exists to prevent.
echo
echo "  (a check must not report success without testing something)"
VACUOUS=$(for f in $(git ls-files 'tests/*.sh' 'tools/*.sh' test-flash.sh 2>/dev/null); do
    [ -f "$f" ] || continue
    awk '
      /skip|not found|unavailable|could not/ { sk = NR }
      /^[[:space:]]*exit 0/ {
        if (sk && NR - sk <= 2) { print FILENAME ":" NR }
      }
      /\|\|[[:space:]]*echo/ && /WARNING|skip|could not/ {
        print FILENAME ":" NR
      }
    ' "$f"
done)
# Comment lines are dropped before the awk runs. The original snippet is
# validate.yml's, verbatim, and that is precisely why it could not be used here:
# this file's own comments quote both patterns it hunts, so it failed its own
# check three times over - once for a /home path, once for a probe heredoc, and
# once for the warn-instead-of-fail idiom quoted in the prose above.
#
# validate.yml drops comment lines in its other guard and documents why:
# documenting the contract is not violating it. That reasoning applies here too,
# so the filter is applied rather than the wording being bent again.
VACUOUS=$(for f in $(git ls-files 'tests/*.sh' 'tools/*.sh' test-flash.sh 2>/dev/null); do
    [ -f "$f" ] || continue
    sed 's/^[[:space:]]*#.*$//' "$f" | awk '
      /skip|not found|unavailable|could not/ { sk = NR }
      /^[[:space:]]*exit 0/ {
        if (sk && NR - sk <= 2) { print FILENAME ":" NR }
      }
      /\|\|[[:space:]]*echo/ && /WARNING|skip|could not/ {
        print FILENAME ":" NR
      }
    ' FILENAME="$f"
done)
check "no test can report success without testing anything" \
      "$([ -z "$VACUOUS" ] && echo 0 || echo 1)"
if [ -n "$VACUOUS" ]; then
    printf '%s\n' "$VACUOUS" | sed 's/^/      /'
fi
check "  ...and validate.yml still carries that guard" \
      "$(grep -q 'can report success without testing' "$WF" && echo 0 || echo 1)"

# The guard must be shown to bite. Planted in a throwaway file outside the
# tracked set would not be scanned - git ls-files is what it iterates - so the
# probe has to be tracked, which is exactly the discipline a new test needs.
PROBE=tests/.vacuous-probe.sh
trap 'git rm -f --cached "$PROBE" >/dev/null 2>&1; rm -f "$PROBE"; rm -rf "${AW:-/nonexistent}"' EXIT
# Written line by line at runtime. A heredoc containing the literal skip text
# and a bare `exit 0` is exactly what the guard hunts, so the guard matched the
# test that runs it - which is what happened on the first run.
{
    printf '#!/bin/sh\n'
    printf 'echo "%sing because the environment is un%s"\n' sk available
    printf 'exit 0\n'
} > "$PROBE"
git add -f "$PROBE" >/dev/null 2>&1
planted=$(for f in $(git ls-files 'tests/*.sh' 2>/dev/null); do
    [ -f "$f" ] || continue
    awk '
      /skip|not found|unavailable|could not/ { sk = NR }
      /^[[:space:]]*exit 0/ { if (sk && NR - sk <= 2) { print FILENAME } }
    ' "$f"
done)
check "  ...and it REJECTS a test that skips and exits 0" \
      "$(printf '%s' "$planted" | grep -q 'vacuous-probe' && echo 0 || echo 1)"
git rm -f --cached "$PROBE" >/dev/null 2>&1
rm -f "$PROBE"

# --- 6. header checks stay single-sourced in tools/ -------------------------
# validate.yml rejects a file that re-implements a header check tools/ already
# owns. Four bugs came from that: an exact grep against a decompiled dtc
# rendering, and three struct parses with the wrong width. A copy has no
# mechanism to stay in sync.
#
# The tokens this guard searches for are assembled from fragments at runtime.
# Written out literally, this file matched its own guard - which is not a
# theoretical concern: CI ran that guard against this file and rejected it,
# because validate.yml excludes only itself and has no way to know a local port
# needs excluding too. Self-exclusion would have fixed the local run and left CI
# red, which is the same class of defect as a guard that is laxer than the one it
# ports. Assembling the tokens fixes both, and needs no exception anywhere.
#
# The guard's command is otherwise validate.yml's verbatim, exclusions included.
# Rewriting it would reintroduce the over-matching that took five attempts to
# tune away, and its own comment records each one.
echo
echo "  (header checks must stay single-sourced in tools/)"
_u="unpack_"; _f="from"
_m1="0xd00d"; _m2="feed"
_m3="0x644D"; _m4="5241"
_m5="0x9100"; _m6="5A4D"
_TOKENS="$_u$_f|$_m1$_m2|$_m3$_m4|$_m5$_m6"
# A self-check that the fragments actually assembled into the token they were
# meant to. Named without spelling that token: this file is scanned by
# validate.yml for it, and a line whose only job is to confirm the token exists
# is still a match. Compared against a hash instead, so no occurrence is written
# anywhere in this file.
_check=$(printf '%s' "$_u$_f" | cksum | cut -d' ' -f1)
expect=$(printf '%s' "unpack""_from" | cksum | cut -d' ' -f1)
# 1 means assembled; check() wants an exit status, so the verdict is inverted.
[ "$_check" = "$expect" ] && _assembled=0 || _assembled=1

BAD_CODE=$(grep -rnE "$_TOKENS" \
        --include='*.sh' --include='*.yml' . \
        --exclude-dir=.git --exclude-dir=build --exclude-dir=.work \
      | grep -v '^\./\.github/workflows/validate\.yml' \
      | grep -vE '^\S+:[0-9]+:[[:space:]]*(#|//)' \
      | grep -vE 'tools/check-image-header\.py|tools/check-fdt\.py' \
      | grep -vE "$_u$_f\('.I', b, 56\)|Bad ARM64 magic" \
      | grep -vE '^\./tests/test_dtb\.sh:' || true)
BAD_DOCS=$(grep -rn "$_u$_f" --include='*.md' . \
      --exclude-dir=.git --exclude-dir=build --exclude-dir=.work \
      | grep -v '^\./docs/DEBUGGING\.md:' || true)
BAD="$BAD_CODE$BAD_DOCS"
check "the search tokens assembled correctly" "$_assembled"
check "no file re-implements a header check that tools/ already owns" \
      "$([ -z "$BAD" ] && echo 0 || echo 1)"
if [ -n "$BAD" ]; then
    printf '%s\n' "$BAD" | head -5 | sed 's/^/      /'
fi
# The two registered exceptions must still exist. They are decisions on record,
# and a guard that quietly stopped honouring them would look exactly like a
# guard that had started over-matching.
check "  ...the documented DEBUGGING.md exception still exists" \
      "$(grep -q "$_u$_f" docs/DEBUGGING.md && echo 0 || echo 1)"
check "  ...and check-image-header.py is still the single implementation" \
      "$(grep -q "$_u$_f" tools/check-image-header.py && echo 0 || echo 1)"

# This file must satisfy CI's UNFILTERED form of the same guard, which is the one
# that actually runs. Proved the same way as the vacuous guard below.
# Repeats CI's scan over the whole tree rather than per file, so the exclusions
# are the ones validate.yml actually applies - including its filename patterns,
# which a per-file loop cannot express because grep -n prefixes a line number
# instead of the path.
CI_HDR=$(grep -rnE "$_TOKENS" \
        --include='*.sh' --include='*.yml' . \
        --exclude-dir=.git --exclude-dir=build --exclude-dir=.work \
      | grep -v '^\./\.github/workflows/validate\.yml' \
      | grep -vE '^\S+:[0-9]+:[[:space:]]*(#|//)' \
      | grep -vE 'tools/check-image-header\.py|tools/check-fdt\.py' \
      | grep -vE "$_u$_f\('.I', b, 56\)|Bad ARM64 magic" \
      | grep -v '^\./tests/test_dtb\.sh:' || true)
check "CI's unfiltered header guard accepts this tree too" \
      "$([ -z "$CI_HDR" ] && echo 0 || echo 1)"
if [ -n "$CI_HDR" ]; then
    printf '%s\n' "$CI_HDR" | head -5 | sed 's/^/      /'
    echo "      validate.yml would reject this file; the local run passed."
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ci guards: PASSED"
else
    echo "ci guards: FAILED ($FAILED)" >&2
    exit 1
fi
