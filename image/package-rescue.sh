#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="${KERNEL_DIR:-.work/monarch-6.18}"
BUILD_DIR="${BUILD_DIR:-build/kernel}"
RELEASE_DIR="${RELEASE_DIR:-build/release}"

KERNEL_RELEASE=$(cat "$BUILD_DIR/kernel-release.txt")

echo "=== Packaging WDMCH USB rescue artifacts ==="

mkdir -p "$RELEASE_DIR"

# Copy patched kernel Image as sata.uImage
# This is a RAW Image + 512 KiB zero padding per the WDMCH rescue contract
cp "$BUILD_DIR/Image" "$RELEASE_DIR/sata.uImage"

# Append 512 KiB (524288 bytes) of zero padding
dd if=/dev/zero bs=524288 count=1 >> "$RELEASE_DIR/sata.uImage" 2>/dev/null

# Verify padding is all zeros
echo "Verifying uImage padding..."
FILE_SIZE=$(stat -c '%s' "$RELEASE_DIR/sata.uImage")
KERNEL_SIZE=$(stat -c '%s' "$BUILD_DIR/Image")
PADDING_SIZE=$((FILE_SIZE - KERNEL_SIZE))
echo "  Kernel size: $KERNEL_SIZE"
echo "  Padding: $PADDING_SIZE bytes"

# Check last 512 KiB is all zeros
tail -c 524288 "$RELEASE_DIR/sata.uImage" | xxd | grep -v '0000 0000 0000 0000 0000 0000 0000 0000' && {
    echo "FAIL: Padding contains non-zero bytes" >&2
    exit 1
} || true

echo "sata.uImage packaged (${FILE_SIZE} bytes)"

# Copy DTB
cp "$BUILD_DIR/rtd1295-wd-mycloud-home.dtb" "$RELEASE_DIR/rescue.sata.dtb"
echo "rescue.sata.dtb packaged"

# Copy rescue rootfs (must be exactly 4 MiB)
RESCUE_SIZE=4194304
RESCUE_SRC="$BUILD_DIR/rescue.root.sata.cpio.gz_pad.img"
if [ ! -f "$RESCUE_SRC" ]; then
    echo "Building rescue rootfs..."
    bash rootfs/build-rootfs.sh
fi

# Pad/cut to exactly 4 MiB
cp "$RESCUE_SRC" "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img"
CURRENT_SIZE=$(stat -c '%s' "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img")

if [ "$CURRENT_SIZE" -lt "$RESCUE_SIZE" ]; then
    dd if=/dev/zero bs=1 count=$((RESCUE_SIZE - CURRENT_SIZE)) >> "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img" 2>/dev/null
elif [ "$CURRENT_SIZE" -gt "$RESCUE_SIZE" ]; then
    echo "WARNING: Rescue rootfs exceeds 4 MiB, truncating" >&2
    truncate -s "$RESCUE_SIZE" "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img"
fi

FINAL_SIZE=$(stat -c '%s' "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img")
echo "rescue.root.sata.cpio.gz_pad.img packaged (${FINAL_SIZE} bytes)"

# Generate SHA256SUMS
cd "$RELEASE_DIR"
sha256sum sata.uImage rescue.sata.dtb rescue.root.sata.cpio.gz_pad.img > SHA256SUMS
echo "SHA256SUMS generated"

# Generate manifest.json
cd -
cat > "$RELEASE_DIR/manifest.json" <<MANIFEST
{
  "device": "WD My Cloud Home single-bay",
  "soc": "Realtek RTD1295",
  "arch": "aarch64",
  "kernel": "Linux 6.18.x",
  "kernel_commit": "$(git -C "$KERNEL_DIR" rev-parse HEAD)",
  "kernel_release": "$KERNEL_RELEASE",
  "dtb": "rtd1295-wd-mycloud-home.dtb",
  "boot_artifacts": [
    "sata.uImage",
    "rescue.sata.dtb",
    "rescue.root.sata.cpio.gz_pad.img"
  ]
}
MANIFEST
echo "manifest.json generated"

echo "Artifact packaging complete."
