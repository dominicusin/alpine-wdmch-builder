#!/bin/bash
# test_verifiers.sh - do the verifiers actually verify?
#
# Two defects this session, both the same shape: a verification that reports
# success without having checked the thing.
#
# 1. tools/check-deps.sh was never invoked by the build at all. build-image.sh,
#    the Makefile and both build workflows contained zero references to it; the
#    only mention anywhere was a shellcheck line in validate.yml. A dependency
#    checker nobody runs is a comment.
#
# 2. It was also wrong. It omitted curl, which image/dl-packages.sh invokes
#    unguarded to fetch APKINDEX - without it the offline repository, which is
#    the entire point of the rescue image, cannot be built - and unzip, which
#    image/package-rescue.sh uses to read back the archive it just built.
#
# 3. image/verify-image.sh wrapped its uImage padding check in
#    `if [ "$KERNEL_SIZE" -gt 0 ]`, so a missing build/kernel/Image silently
#    disabled the check and the script still exited 0.
#
# The list in check-deps.sh is a claim about the build, so it is derived here
# from the build scripts themselves rather than being a second hand-kept list.

set -u
cd "$(dirname "$0")/.." || exit 1
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

echo "=== verifiers ==="

# --- 1. the dependency check must be reachable from the build ----------------
# A checker nothing calls cannot protect anything.
called=0
for entry in build-image.sh Makefile .github/workflows/build.yml .github/workflows/release.yml; do
    [ -f "$entry" ] || continue
    if grep -q 'check-deps' "$entry"; then
        echo "  ok    $entry runs the dependency check"
        called=$((called+1))
    fi
done
check "at least one build entry point invokes check-deps.sh" \
      "$(cond "[ $called -ge 1 ]"; echo $?)"

# --- 2. every unguarded tool the build uses must be on the list ---------------
# Derived from the build scripts, not from a second list kept by hand. A tool
# reached only through `command -v X` degrades gracefully and is not required.
DECLARED=$(sed -n '/^    for tool in/,/; do/p' tools/check-deps.sh \
           | tr -s ' \\\n' ' ' | grep -oE '[a-z0-9][a-z0-9-]*' | sort -u)

# Tools that are known-optional or provided by the project itself.
is_optional() {
    case "$1" in
        parted|sgdisk|losetup|qemu-aarch64-static|shellcheck|gh) return 0 ;;
        aarch64-linux-gnu-gcc|ccache|dtc) return 0 ;;   # listed, checked below
    esac
    return 1
}

BUILD_SCRIPTS=$(git ls-files '*.sh' build-image.sh | grep -vE '^tests/')
for tool in curl unzip zip gzip xz cpio tar; do
    # only count it if some build script calls it WITHOUT a command -v guard
    site=$(echo "$BUILD_SCRIPTS" | xargs grep -lE "(^|[^a-zA-Z0-9_-])${tool}([^a-zA-Z0-9_-]|\$)" 2>/dev/null \
           | while read -r f; do
                 # a line that only mentions it inside `command -v X` is optional
                 if grep -E "(^|[^a-zA-Z0-9_-])${tool}([^a-zA-Z0-9_-]|\$)" "$f" 2>/dev/null \
                    | grep -qv "command -v ${tool}"; then echo "$f"; fi
             done | head -1)
    [ -n "$site" ] || continue
    if echo "$DECLARED" | grep -qx "$tool"; then
        echo "  ok    $tool is declared (used unguarded in $site)"
    else
        echo "  FAIL  $tool is used unguarded in $site but is not in check-deps.sh"
        FAILED=$((FAILED+1))
    fi
done

# --- 3. the two that were actually missing ------------------------------------
for tool in curl unzip; do
    check "$tool is on the dependency list" \
          "$(cond 'echo "$DECLARED" | grep -qx '"$tool"; echo $?)"
done

# --- 4. it must fail when something is missing, and pass when it is not ------
out=$(bash tools/check-deps.sh 2>&1); rc=$?
check "check-deps.sh exits 0 on a machine that has the tools" \
      "$(cond '[ $rc -eq 0 ]'; echo $?)"
check "  ...and says so plainly" \
      "$(cond 'echo "$out" | grep -q "All dependencies satisfied"'; echo $?)"

# The failure path is exercised by planting a tool name that cannot exist, then
# reverting. An earlier version of this stubbed `command` and failed with an
# unbound variable under `set -u`, so the "exits non-zero" assertion passed for
# the wrong reason - which is the exact trap this repository keeps hitting.
# A test that passes because the harness broke is worse than no test.
CD="$PWD/tools/check-deps.sh"
cp "$CD" "$CD.orig"
trap 'mv -f "$CD.orig" "$CD" 2>/dev/null' EXIT
python3 - "$CD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = '                zip unzip curl sha256sum tar; do'
assert old in s, "anchor for planting moved"
open(p, 'w', encoding='utf-8').write(
    s.replace(old, '                zip unzip curl sha256sum tar no-such-tool-xyz; do', 1))
PY
out=$(bash "$CD" 2>&1); rc=$?
check "check-deps.sh exits non-zero when a tool is missing" \
      "$(cond '[ $rc -ne 0 ]'; echo $?)"
check "  ...and names the missing tool" \
      "$(cond 'echo "$out" | grep -q "MISSING: no-such-tool-xyz"'; echo $?)"
check "  ...and prints install hints" \
      "$(cond 'echo "$out" | grep -q "Installation hints"'; echo $?)"
check "  ...and does not claim success" \
      "$(cond '! echo "$out" | grep -q "All dependencies satisfied"'; echo $?)"
mv -f "$CD.orig" "$CD"
trap - EXIT

# --- 5. the padding check must not be skippable ------------------------------
# It used to be wrapped in a conditional on build/kernel/Image existing, so an
# absent kernel silently disabled it and the run still passed.
check "verify-image.sh fails when the kernel Image is absent" \
      "$(cond 'grep -qE "KERNEL_SIZE.*-le 0" image/verify-image.sh'; echo $?)"
check "  ...and says the run must not be treated as passing" \
      "$(cond 'grep -q "do not treat" image/verify-image.sh'; echo $?)"
# Comments are excluded: the fix documents the old form in prose, and a grep
# that matched its own explanation would report a bug that is not there.
check "  ...and the old silent conditional is gone" \
      "$(cond '! grep -vE "^[[:space:]]*#" image/verify-image.sh | grep -qF "KERNEL_SIZE\" -gt 0"'; echo $?)"
check "  ...the padding is held to its exact 512 KiB length" \
      "$(cond 'grep -q "EXPECTED_PADDING=524288" image/verify-image.sh'; echo $?)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "verifiers actually verify: PASSED"
else
    echo "verifiers actually verify: FAILED ($FAILED)" >&2
    exit 1
fi
