#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_DIR="${1:-build/release}"

echo "=== Artifact Validation ==="

# Check all expected files exist
for f in sata.uImage rescue.sata.dtb rescue.root.sata.cpio.gz_pad.img SHA256SUMS manifest.json; do
    if [ ! -f "$RELEASE_DIR/$f" ]; then
        echo "FAIL: Missing $f"
        exit 1
    fi
    if [ ! -s "$RELEASE_DIR/$f" ]; then
        echo "FAIL: $f is empty"
        exit 1
    fi
done
echo "All expected files exist and non-empty: OK"

# Check SHA256SUMS
cd "$RELEASE_DIR"
if sha256sum -c SHA256SUMS >/dev/null 2>&1; then
    echo "Checksums match: OK"
else
    echo "FAIL: Checksums do not match"
    exit 1
fi
cd -

# Check uImage padding is zero
UIMAGE_SIZE=$(stat -c '%s' "$RELEASE_DIR/sata.uImage")
KERNEL_SIZE=$(stat -c '%s' "$BUILD_DIR/Image" 2>/dev/null || echo "0")
if [ "$KERNEL_SIZE" -gt 0 ]; then
    PADDING_SIZE=$((UIMAGE_SIZE - KERNEL_SIZE))
    ZERO_BYTES=$(tail -c "$PADDING_SIZE" "$RELEASE_DIR/sata.uImage" | tr -d '\0' | wc -c)
    if [ "$ZERO_BYTES" -eq 0 ]; then
        echo "uImage padding is all zeros: OK"
    else
        echo "FAIL: uImage padding contains non-zero bytes"
        exit 1
    fi
fi

# Check rescue rootfs size
RESCUE_SIZE=$(stat -c '%s' "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img")
if [ "$RESCUE_SIZE" -eq 4194304 ]; then
    echo "Rescue rootfs size == 4194304: OK"
else
    echo "FAIL: Rescue rootfs size is $RESCUE_SIZE, expected 4194304"
    exit 1
fi

# Check files are regular files, not symlinks
for f in sata.uImage rescue.sata.dtb rescue.root.sata.cpio.gz_pad.img; do
    if [ -L "$RELEASE_DIR/$f" ]; then
        echo "FAIL: $f is a symlink to host path"
        exit 1
    fi
done
echo "No symlinks to host paths: OK"

# Check no private key material
if grep -rq 'BEGIN PRIVATE KEY\|BEGIN RSA PRIVATE KEY\|BEGIN OPENSSH PRIVATE KEY' "$RELEASE_DIR/" 2>/dev/null; then
    echo "FAIL: Private key material found in release artifacts"
    exit 1
fi
echo "No private key material: OK"

echo "Artifact validation PASSED"
