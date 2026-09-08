#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_DIR="${RELEASE_DIR:-build/release}"

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

# Verify uImage size (kernel + 512 KiB padding)
UIMAGE_SIZE=$(stat -c '%s' "$RELEASE_DIR/sata.uImage")
KERNEL_SIZE=$(stat -c '%s' "$BUILD_DIR/Image" 2>/dev/null || echo "0")
if [ "$KERNEL_SIZE" -gt 0 ]; then
    PADDING_SIZE=$((UIMAGE_SIZE - KERNEL_SIZE))
    ZERO_BYTES=$(tail -c "$PADDING_SIZE" "$RELEASE_DIR/sata.uImage" | tr -d '\0' | wc -c)
    if [ "$ZERO_BYTES" -eq 0 ]; then
        echo "uImage padding is all zeros: OK"
    else
        echo "FAIL: uImage padding contains non-zero bytes" >&2
        exit 1
    fi
fi

# Verify rescue rootfs size
RESCUE_SIZE=$(stat -c '%s' "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img")
if [ "$RESCUE_SIZE" -eq 4194304 ]; then
    echo "Rescue rootfs size == 4194304: OK"
else
    echo "FAIL: Rescue rootfs size is $RESCUE_SIZE, expected 4194304" >&2
    exit 1
fi

# Verify DTB FDT magic
python3 -c "
import struct
b = open('$RELEASE_DIR/rescue.sata.dtb', 'rb').read()
magic = struct.unpack_from('<I', b, 0)[0]
assert magic == 0xd00dfeed, f'Bad FDT magic: 0x{magic:08X}'
print('DTB FDT magic verified')
"

# Verify no private key material
if grep -rq 'BEGIN PRIVATE KEY\|BEGIN RSA PRIVATE KEY\|BEGIN OPENSSH PRIVATE KEY' "$RELEASE_DIR/" 2>/dev/null; then
    echo "FAIL: Private key material found in release artifacts" >&2
    exit 1
fi

echo "Image verification PASSED"
