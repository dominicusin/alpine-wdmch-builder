#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_DIR="${RELEASE_DIR:-build/release}"

echo "=== Full Release Audit ==="

failures=0

# Run dependency check
echo ""
echo "[Dependencies]"
bash tools/check-deps.sh || failures=$((failures + 1))

# Run image header check
echo ""
echo "[Image Header]"
if [ -f "$RELEASE_DIR/sata.uImage" ]; then
    python3 tools/check-image-header.py "$RELEASE_DIR/sata.uImage" || failures=$((failures + 1))
fi

# Run FDT check
echo ""
echo "[FDT Validation]"
if [ -f "$RELEASE_DIR/rescue.sata.dtb" ]; then
    python3 tools/check-fdt.py "$RELEASE_DIR/rescue.sata.dtb" || failures=$((failures + 1))
fi

# Run artifact check
echo ""
echo "[Artifact Validation]"
bash tools/check-artifacts.sh "$RELEASE_DIR" || failures=$((failures + 1))

# Run all tests
echo ""
echo "[Test Suite]"
bash tests/test_repo_layout.sh || failures=$((failures + 1))
bash tests/test_kernel_metadata.sh build/kernel/Image build/kernel/modules build/kernel/kernel-release.txt || failures=$((failures + 1))
bash tests/test_dtb.sh build/kernel/rtd1295-wd-mycloud-home.dtb build/kernel/rtd1295-wd-mycloud-home.dts || failures=$((failures + 1))
bash tests/test_rootfs.sh build/rootfs "$(cat build/kernel/kernel-release.txt 2>/dev/null || echo none)" || failures=$((failures + 1))
bash tests/test_image.sh build/release || failures=$((failures + 1))
bash tests/test_tools.sh || failures=$((failures + 1))

# Check no floating kernel ref
echo ""
echo "[Source Lock]"
KERNEL_REF=$(grep KERNEL_REF config/source-lock.env | cut -d= -f2)
if [ "$KERNEL_REF" = "HEAD" ] || [ -z "$KERNEL_REF" ]; then
    echo "WARNING: Floating kernel reference detected"
    failures=$((failures + 1))
else
    echo "Kernel reference pinned: OK"
fi

# Check for private keys in build/
echo ""
echo "[Security Check]"
if grep -rq 'BEGIN PRIVATE KEY\|BEGIN RSA PRIVATE KEY\|BEGIN OPENSSH PRIVATE KEY' build/ 2>/dev/null; then
    echo "FAIL: Private key material found in build/"
    failures=$((failures + 1))
else
    echo "No private key material in build/: OK"
fi

# Final result
echo ""
echo "========================================="
if [ "$failures" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
    exit 0
else
    echo "$failures CHECK(S) FAILED"
    exit 1
fi
