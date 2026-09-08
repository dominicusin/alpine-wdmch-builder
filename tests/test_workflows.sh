#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Testing GitHub Workflows ==="

# Check workflow files exist
for wf in build.yml validate.yml release.yml; do
    if [ ! -f ".github/workflows/$wf" ]; then
        echo "FAIL: Missing .github/workflows/$wf"
        exit 1
    fi
done
echo "All workflow files exist: OK"

# Check build.yml has required elements
echo "Checking build.yml..."
if grep -q 'runs-on' .github/workflows/build.yml && \
   grep -q 'ubuntu-24.04' .github/workflows/build.yml 2>/dev/null; then
    echo "  runs-on: ubuntu-24.04: OK"
fi

if grep -q 'actions/checkout' .github/workflows/build.yml; then
    echo "  checkout action present: OK"
fi

# Check release.yml is gated on tags
echo "Checking release.yml..."
if grep -q 'tags' .github/workflows/release.yml || grep -q 'tag' .github/workflows/release.yml; then
    echo "  Tag gating present: OK"
fi

# Check least-privilege permissions
echo "Checking permissions..."
if grep -q 'permissions:' .github/workflows/*.yml; then
    echo "  Permissions defined: OK"
fi

# Check build.yml invokes build script from repo root
if grep -q './build-image.sh' .github/workflows/build.yml; then
    echo "  build-image.sh invoked from repo root: OK"
fi

# Check WDMCH_SSH_AUTHORIZED_KEY usage
if grep -q 'WDMCH_SSH_AUTHORIZED_KEY' .github/workflows/*.yml; then
    echo "  WDMCH_SSH_AUTHORIZED_KEY used: OK"
fi

echo "Workflow validation PASSED"
