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

# Check kernel config has RCU options
echo ""
echo "[Kernel Config Check]"
for opt in CONFIG_PSI CONFIG_PREEMPT_BUILD CONFIG_PREEMPT CONFIG_PREEMPT_RCU CONFIG_RCU_EXPERT CONFIG_RCU_BOOST CONFIG_RCU_NOCB_CPU; do
    if grep -q "^${opt}=y" config/kernel.config; then
        echo "  $opt: OK"
    else
        echo "  $opt: MISSING"
        failures=$((failures + 1))
    fi
done

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
