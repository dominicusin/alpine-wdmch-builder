#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Full Release Audit ==="

failures=0

# Run dependency check
echo "[Dependencies]"
bash tools/check-deps.sh || failures=$((failures + 1))

# Run image header check
echo ""
echo "[Image Header]"
if [ -f "build/release/sata.uImage" ]; then
    python3 tools/check-image-header.py build/release/sata.uImage || failures=$((failures + 1))
fi

# Run FDT check
echo ""
echo "[FDT Validation]"
if [ -f "build/release/rescue.sata.dtb" ]; then
    python3 tools/check-fdt.py build/release/rescue.sata.dtb || failures=$((failures + 1))
fi

# Run artifact check
echo ""
echo "[Artifact Validation]"
bash tools/check-artifacts.sh build/release || failures=$((failures + 1))

# Run all tests
echo ""
echo "[Test Suite]"
bash tests/test_repo_layout.sh || failures=$((failures + 1))
# NOTE: test_kernel_metadata.sh takes exactly two args (<Image> <kernel-release.txt>).
# Passing a third arg (a stale build/kernel/modules path) shifted the release file
# out of position and made the test read a directory.
bash tests/test_kernel_metadata.sh build/kernel/Image build/kernel/kernel-release.txt || failures=$((failures + 1))
bash tests/test_dtb.sh build/kernel/rtd1295-wd-mycloud-home.dtb build/kernel/rtd1295-wd-mycloud-home.dts || failures=$((failures + 1))
bash tests/test_rootfs.sh build/rootfs "$(cat build/kernel/kernel-release.txt 2>/dev/null || echo none)" || failures=$((failures + 1))
bash tests/test_tools.sh || failures=$((failures + 1))

# Check no floating kernel ref
echo ""
echo "[Source Lock]"
# A pinned ref is a full git commit SHA (7-40 lowercase hex chars). Use grep -m1
# so a second appended KERNEL_REF= line cannot turn this into a multi-line value
# and false-pass the "HEAD" test.
KERNEL_REF=$(grep -m1 '^KERNEL_REF=' config/source-lock.env | cut -d= -f2 || true)
if echo "$KERNEL_REF" | grep -Eq '^[0-9a-f]{7,40}$'; then
    echo "Kernel reference pinned: OK ($KERNEL_REF)"
else
    echo "WARNING: Floating kernel reference detected: KERNEL_REF='${KERNEL_REF}'"
    echo "         A pinned reference must be a full git commit SHA (7-40 hex chars),"
    echo "         e.g. KERNEL_REF=4b825dc642cb6eb9a060e54bf8d69288fbee4904. 'HEAD',"
    echo "         a branch name, or an empty/multi-line value is NOT pinned."
    failures=$((failures + 1))
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

# Check for non-zero padding where zero is required
echo ""
echo "[Padding Check]"
if [ -f "build/release/sata.uImage" ]; then
    IMG_SIZE=$(stat -c '%s' build/release/sata.uImage)
    KERNEL_SIZE=$(stat -c '%s' build/kernel/Image 2>/dev/null || echo "0")
    if [ "$KERNEL_SIZE" -gt 0 ]; then
        PAD_SIZE=$((IMG_SIZE - KERNEL_SIZE))
        ZERO_COUNT=$(tail -c "$PAD_SIZE" build/release/sata.uImage | tr -d '\0' | wc -c)
        if [ "$ZERO_COUNT" -eq 0 ]; then
            echo "uImage padding all zeros: OK"
        else
            echo "FAIL: uImage padding contains non-zero bytes"
            failures=$((failures + 1))
        fi
    fi
fi

# Check rescue rootfs size
echo ""
echo "[Rescue Rootfs Size]"
if [ -f "build/release/rescue.root.sata.cpio.gz_pad.img" ]; then
    RESCUE_SIZE=$(stat -c '%s' build/release/rescue.root.sata.cpio.gz_pad.img)
    if [ "$RESCUE_SIZE" -eq 4194304 ]; then
        echo "Rescue rootfs == 4194304 bytes: OK"
    else
        echo "FAIL: Rescue rootfs is $RESCUE_SIZE bytes, expected 4194304"
        failures=$((failures + 1))
    fi
fi

# Check CI workflow
echo ""
echo "[CI Check]"
if [ -f ".github/workflows/build.yml" ]; then
    echo "CI workflow present: OK"
else
    echo "FAIL: CI workflow missing"
    failures=$((failures + 1))
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
