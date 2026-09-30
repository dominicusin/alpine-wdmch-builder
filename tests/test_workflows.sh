#!/usr/bin/env bash
# Validate the workflow files.
#
# This test previously could not fail. Every assertion had the shape
#
#     if grep -q '<property>' <file>; then echo "  <property>: OK"; fi
#
# with no else branch, followed by an unconditional
# `echo "Workflow validation PASSED"`. A missing property therefore printed
# nothing and the test still exited 0.
#
# Verified by mutation: removing `runs-on`, `ubuntu-24.04`, the checkout
# action, the build-image.sh invocation, the SSH key reference and the
# `permissions:` block - six deliberate breakages - produced zero failures.
# The output simply had one fewer "OK" line each time.
#
# Every check here is mandatory: a missing property names the file and fails.
set -Eeuo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_DIR"

FAILED=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s: %s\n' "$1" "$2"; FAILED=1; }

# require <label> <file> <pattern>
require() {
    if grep -q -- "$3" "$2" 2>/dev/null; then
        ok "$1"
    else
        bad "$1" "expected '$3' in $2"
    fi
}

# forbid <label> <file> <pattern>
forbid() {
    if grep -q -- "$3" "$2" 2>/dev/null; then
        bad "$1" "unexpected '$3' in $2"
    else
        ok "$1"
    fi
}

echo "=== Testing GitHub Workflows ==="

echo "Workflow files exist:"
for wf in build.yml validate.yml release.yml; do
    p=".github/workflows/$wf"
    if [ -s "$p" ]; then ok "$wf"; else bad "$wf" "missing or empty"; fi
done

echo
echo "build.yml:"
require "runs on an explicit runner"  .github/workflows/build.yml 'runs-on:'
require "pinned to ubuntu-24.04"      .github/workflows/build.yml 'ubuntu-24.04'
require "uses actions/checkout"       .github/workflows/build.yml 'actions/checkout@'
require "references the SSH key"      .github/workflows/build.yml 'WDMCH_SSH_AUTHORIZED_KEY'
require "runs the full suite"         .github/workflows/build.yml 'make test'
# release.yml is the only publisher; a build workflow that also published would
# be two writers racing to the same tag.
forbid  "build.yml does not publish"  .github/workflows/build.yml 'gh release create'

echo
echo "release.yml:"
require "gated on tags"              .github/workflows/release.yml 'tags:'
require "invokes build-image.sh"     .github/workflows/release.yml './build-image.sh'
require "publishes a GitHub release" .github/workflows/release.yml 'gh release'
require "runs the full suite"        .github/workflows/release.yml 'make test'

echo
echo "permissions:"
# Scoped per file, not to .github/workflows/*.yml. The old check matched any
# workflow, so deleting permissions from two of the three files still passed.
for wf in build.yml validate.yml release.yml; do
    require "$wf declares permissions" ".github/workflows/$wf" 'permissions:'
done

echo
if [ "$FAILED" -eq 0 ]; then
    echo "Workflow validation PASSED"
else
    echo "Workflow validation FAILED ($FAILED check(s))" >&2
    exit 1
fi
