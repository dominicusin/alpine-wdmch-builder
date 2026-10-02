#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_DIR="${RELEASE_DIR:-build/release}"
BUILD_DIR="${BUILD_DIR:-build/kernel}"

echo "=== Verifying WDMCH USB rescue artifacts ==="

# Check all required files exist
for f in sata.uImage rescue.sata.dtb rescue.root.sata.cpio.gz_pad.img SHA256SUMS manifest.json; do
    if [ ! -f "$RELEASE_DIR/$f" ]; then
        echo "FAIL: Missing $f" >&2
        exit 1
    fi
    if [ ! -s "$RELEASE_DIR/$f" ]; then
        echo "FAIL: $f is empty" >&2
        exit 1
    fi
done

# Verify checksums
cd "$RELEASE_DIR"
if sha256sum -c SHA256SUMS 2>&1; then
    echo "Checksums verified"
else
    echo "FAIL: Checksum verification failed" >&2
    exit 1
fi
cd -

# Verify uImage padding (kernel + exactly 512 KiB of zeros)
#
# This used to be wrapped in `if [ "$KERNEL_SIZE" -gt 0 ]`, so a missing
# build/kernel/Image silently disabled the whole check and the script still
# exited 0. Verified: with an empty kernel directory, "uImage padding" never
# appeared in the output and the run passed. That is the same shape as the
# closure bug - the run reported success without having checked the thing -
# and the padding is load-bearing: it is what the vendor loader reads past the
# kernel. So the size is now required, and the padding is held to its exact
# length rather than "whatever the difference happens to be".
UIMAGE_SIZE=$(stat -c '%s' "$RELEASE_DIR/sata.uImage")
KERNEL_SIZE=$(stat -c '%s' "$BUILD_DIR/Image" 2>/dev/null || echo "0")
if [ "$KERNEL_SIZE" -le 0 ]; then
    echo "FAIL: $BUILD_DIR/Image is missing or empty, so the uImage padding" >&2
    echo "      cannot be verified. Run the kernel build first; do not treat" >&2
    echo "      this as a passing verification." >&2
    exit 1
fi
EXPECTED_PADDING=524288
PADDING_SIZE=$((UIMAGE_SIZE - KERNEL_SIZE))
if [ "$PADDING_SIZE" -ne "$EXPECTED_PADDING" ]; then
    echo "FAIL: uImage padding is $PADDING_SIZE bytes, expected $EXPECTED_PADDING" >&2
    echo "      (uImage $UIMAGE_SIZE - Image $KERNEL_SIZE)" >&2
    exit 1
fi
ZERO_BYTES=$(tail -c "$PADDING_SIZE" "$RELEASE_DIR/sata.uImage" | tr -d '\0' | wc -c)
if [ "$ZERO_BYTES" -eq 0 ]; then
    echo "uImage padding: $PADDING_SIZE bytes, all zeros: OK"
else
    echo "FAIL: uImage padding contains $ZERO_BYTES non-zero bytes" >&2
    exit 1
fi

# Verify rescue rootfs size
RESCUE_SIZE=$(stat -c '%s' "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img")
if [ "$RESCUE_SIZE" -eq 4194304 ]; then
    echo "Rescue rootfs size == 4194304: OK"
else
    echo "FAIL: Rescue rootfs size is $RESCUE_SIZE, expected 4194304" >&2
    exit 1
fi

# Verify the shipped DTB. tools/check-fdt.py is the single implementation -
# an inline magic-only parse here would be a second copy that can only ever
# check less than the real validator.
python3 tools/check-fdt.py "$RELEASE_DIR/rescue.sata.dtb"

# Verify no private key material
if grep -rq 'BEGIN PRIVATE KEY\|BEGIN RSA PRIVATE KEY\|BEGIN OPENSSH PRIVATE KEY' "$RELEASE_DIR/" 2>/dev/null; then
    echo "FAIL: Private key material found in release artifacts" >&2
    exit 1
fi

echo "Image verification PASSED"
