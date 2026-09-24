#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_DIR="${BUILD_DIR:-build/kernel}"
RELEASE_FILE="$BUILD_DIR/kernel-release.txt"
IMAGE="$BUILD_DIR/Image"
UNPATCHED="$BUILD_DIR/Image.unpatched"

echo "=== Verifying kernel build ==="

# Check kernel release
if [ ! -f "$RELEASE_FILE" ]; then
    echo "ERROR: kernel-release.txt not found" >&2
    exit 1
fi
release=$(cat "$RELEASE_FILE")
echo "Kernel release: $release"

# Check Image exists
if [ ! -s "$IMAGE" ]; then
    echo "ERROR: Image not found or empty" >&2
    exit 1
fi

# Validate ARM64 magic on the pristine (unpatched) Image
python3 - "$UNPATCHED" <<'PY'
import struct, sys
p = sys.argv[1]
b = open(p, 'rb').read(64)
assert len(b) == 64, f'Expected 64 bytes, got {len(b)}'
magic = struct.unpack_from('<I', b, 56)[0]
assert magic == 0x644D5241, f'Bad ARM64 magic: 0x{magic:08X}'
print(f'ARM64 Image magic verified: 0x{magic:08X}')
PY

# Validate the PATCHED Image header (monarch contract)
python3 - "$IMAGE" <<'PY'
import struct, sys
p = sys.argv[1]
b = open(p, 'rb').read(64)
code0 = struct.unpack_from('<I', b, 0)[0]
text_offset = struct.unpack_from('<Q', b, 8)[0]
pe_offset = struct.unpack_from('<I', b, 60)[0]
assert code0 == 0x91005A4D, f'code0 not patched: 0x{code0:08X}'
assert text_offset == 0x200000, f'text_offset not patched: 0x{text_offset:X}'
assert pe_offset == 0x40, f'pe_offset not patched: 0x{pe_offset:X}'
print(f'Patched Image header verified: code0=0x{code0:08X} text_offset=0x{text_offset:X} pe_offset=0x{pe_offset:X}')
PY

# Verify built-in drivers the rescue initramfs depends on (no modules!)
echo "Verifying built-in rescue drivers in .config..."
MISSING=0
for sym in CONFIG_AHCI_RTD1295 CONFIG_R8169SOC CONFIG_PHY_RTK_RTD_SATAPHY \
           CONFIG_USB_STORAGE CONFIG_USB_DWC3 CONFIG_EXT4_FS CONFIG_VFAT_FS \
           CONFIG_BLK_DEV_INITRD CONFIG_RD_GZIP CONFIG_BINFMT_SCRIPT CONFIG_PACKET; do
    if ! grep -q "^${sym}=y" "$BUILD_DIR/.config" 2>/dev/null; then
        echo "ERROR: $sym not built-in - rescue image would be non-functional" >&2
        MISSING=1
    fi
done
[ "$MISSING" -eq 0 ] || exit 1
echo "All rescue drivers are built-in"

echo "Kernel verification passed."
