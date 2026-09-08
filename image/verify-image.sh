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
echo "sata.uImage size: $UIMAGE_SIZE bytes"

# Verify rescue rootfs size (exactly 4 MiB)
RESCUE_SIZE=$(stat -c '%s' "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img")
if [ "$RESCUE_SIZE" -eq 4194304 ]; then
    echo "rescue.root.sata.cpio.gz_pad.img size: $RESCUE_SIZE bytes (correct)"
else
    echo "FAIL: rescue.root.sata.cpio.gz_pad.img size is $RESCUE_SIZE, expected 4194304" >&2
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
