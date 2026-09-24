#!/usr/bin/env bash
set -Eeuo pipefail

# Package WDMCH USB rescue artifacts + the full USB stick tree.
#
# Structure (FIXED): all boot files at root of USB stick, NO boot/ directory.
#   sata.uImage                      — patched RAW kernel Image + 512 KiB padding
#   rescue.sata.dtb                 — WDMCH device tree
#   rescue.root.sata.cpio.gz_pad.img — exactly 4194304 bytes (gzip'd cpio, padded)
#   SHA256SUMS                      — checksums of the 3 boot files
#   manifest.json                   — metadata
#   README.txt                      — instructions for the user
#   apks/main/                      — Alpine main repo packages (offline install)
#   apks/community/                 — Alpine community repo packages
#
# Contract (symops/monarch-6.18 README, "Building and booting"):
#   sata.uImage = RAW patched ARM64 Image (header patched by
#                 tools/monarch/patch-header.py: code0=0x91005A4D,
#                 text_offset=0x200000) + 512 KiB zeros.
#                 Never gzip the Image: this U-Boot's built-in gunzip is
#                 unreliable above a few MB.
#   rescue.sata.dtb                 = WDMCH device tree blob
#   rescue.root.sata.cpio.gz_pad.img = exactly 4194304 bytes (from
#                 rootfs/build-rootfs.sh; the loader reads that fixed size)

KERNEL_DIR="${KERNEL_DIR:-.work/monarch-6.18}"
BUILD_DIR="${BUILD_DIR:-build/kernel}"
RELEASE_DIR="${RELEASE_DIR:-build/release}"
USB_TREE="${USB_TREE:-build/usb-tree-root}"

KERNEL_RELEASE=$(cat "$BUILD_DIR/kernel-release.txt")

echo "=== Packaging WDMCH USB rescue artifacts ==="
echo "  Kernel release: $KERNEL_RELEASE"
echo "  USB tree: $USB_TREE (root-level files, NO boot/ subdir)"

mkdir -p "$RELEASE_DIR"

# ---- 1. patch the Image header (vendor U-Boot text_offset requirement) --------
# Keep the pristine unpatched Image so re-runs never double-patch.
if [ ! -s "$BUILD_DIR/Image.unpatched" ]; then
    cp "$BUILD_DIR/Image" "$BUILD_DIR/Image.unpatched"
fi
cp "$BUILD_DIR/Image.unpatched" "$BUILD_DIR/Image"
python3 "$KERNEL_DIR/tools/monarch/patch-header.py" "$BUILD_DIR/Image"

# ---- 2. sata.uImage = raw patched Image + 512 KiB zeros -------------------------
cp "$BUILD_DIR/Image" "$RELEASE_DIR/sata.uImage"
dd if=/dev/zero bs=524288 count=1 >> "$RELEASE_DIR/sata.uImage" 2>/dev/null

echo "Verifying uImage padding..."
FILE_SIZE=$(stat -c '%s' "$RELEASE_DIR/sata.uImage")
KERNEL_SIZE=$(stat -c '%s' "$BUILD_DIR/Image")
PADDING_SIZE=$((FILE_SIZE - KERNEL_SIZE))
echo "  Kernel size: $KERNEL_SIZE"
echo "  Padding: $PADDING_SIZE bytes"
ZERO_BYTES=$(tail -c 524288 "$RELEASE_DIR/sata.uImage" | tr -d '\0' | wc -c)
[ "$ZERO_BYTES" -eq 0 ] || { echo "FAIL: padding contains non-zero bytes" >&2; exit 1; }
echo "sata.uImage packaged (${FILE_SIZE} bytes)"

# ---- 3. DTB ----------------------------------------------------------------------
cp "$BUILD_DIR/rtd1295-wd-mycloud-home.dtb" "$RELEASE_DIR/rescue.sata.dtb"
echo "rescue.sata.dtb packaged"

# ---- 4. rescue initramfs (must be exactly 4 MiB; built by build-rootfs.sh) --------
RESCUE_SRC="$BUILD_DIR/rescue.root.sata.cpio.gz_pad.img"
RESCUE_DST="$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img"
RESCUE_SIZE=4194304
if [ ! -f "$RESCUE_SRC" ] || [ "$(stat -c '%s' "$RESCUE_SRC" 2>/dev/null || echo 0)" -eq 0 ]; then
    echo "Building rescue rootfs..."
    bash rootfs/build-rootfs.sh build/rootfs "$KERNEL_RELEASE"
fi
cp "$RESCUE_SRC" "$RESCUE_DST"
CURRENT_SIZE=$(stat -c '%s' "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img")
if [ "$CURRENT_SIZE" -gt "$RESCUE_SIZE" ]; then
    echo "ERROR: rescue rootfs is $CURRENT_SIZE bytes (> 4 MiB fixed budget)" >&2
    exit 1
fi
PAD=$((RESCUE_SIZE - CURRENT_SIZE))
if [ "$PAD" -gt 0 ]; then
    dd if=/dev/zero bs=1 count="$PAD" >> "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img" 2>/dev/null
fi
FINAL_SIZE=$(stat -c '%s' "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img")
[ "$FINAL_SIZE" -eq "$RESCUE_SIZE" ] || { echo "FAIL: rescue rootfs size $FINAL_SIZE != $RESCUE_SIZE" >&2; exit 1; }
echo "rescue.root.sata.cpio.gz_pad.img packaged (${FINAL_SIZE} bytes)"

# ---- 5. checksums + manifest --------------------------------------------------------
( cd "$RELEASE_DIR" && sha256sum sata.uImage rescue.sata.dtb rescue.root.sata.cpio.gz_pad.img > SHA256SUMS )
echo "SHA256SUMS generated"

cat > "$RELEASE_DIR/manifest.json" <<MANIFEST
{
  "device": "WD My Cloud Home single-bay",
  "soc": "Realtek RTD1295",
  "arch": "aarch64",
  "kernel": "Linux $KERNEL_RELEASE",
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

# ---- 6. the full USB stick tree: ALL files at root + apks/ (offline Alpine install) ---
echo ""
echo "=== Building USB stick tree ($USB_TREE) ==="
echo "  Structure: ALL boot files at root (NO boot/ directory)"
rm -rf "$USB_TREE"
mkdir -p "$USB_TREE/apks/main" "$USB_TREE/apks/community"

# Boot files at root (NOT in boot/)
cp "$RELEASE_DIR/sata.uImage" "$USB_TREE/"
cp "$RELEASE_DIR/rescue.sata.dtb" "$USB_TREE/"
cp "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img" "$USB_TREE/"
cp "$RELEASE_DIR/SHA256SUMS" "$USB_TREE/"
cp "$RELEASE_DIR/manifest.json" "$USB_TREE/"

# README (UPDATED for root-level structure)
cat > "$USB_TREE/README.txt" <<'READMEEOF'
WDMCH Rescue USB - WD My Cloud Home (RTD1295)
==============================================

IMPORTANT: All files must be copied to the ROOT of a FAT32 USB stick.
NO subdirectories except apks/ (which has apks/main/ and apks/community/).

COPY THESE FILES TO USB STICK ROOT:
  sata.uImage                      patched kernel Image + 512 KiB padding
  rescue.sata.dtb                  device tree
  rescue.root.sata.cpio.gz_pad.img 4 MiB rescue initramfs (SSH inside)
  SHA256SUMS                       checksums
  manifest.json                    metadata
  README.txt                       this file
  apks/                            Alpine package repository (offline install)

VERIFY: after copying, run: sha256sum -c SHA256SUMS

PREPARE THE STICK
  1. Format a USB stick as FAT32 (MBR, single partition)
  2. Copy EVERYTHING from this directory onto the stick ROOT:
     cp -r * /media/<stick>/
  3. Verify: cd /media/<stick> && sha256sum -c SHA256SUMS

BOOT THE BOX
  1. Power off the WD My Cloud Home
  2. Insert the stick into the front USB port
  3. Hold the reset button, power on, keep holding ~10 seconds
  4. The rescue kernel boots; it prints its IP on the serial console
     and announces itself on the network (DHCP)
  5. ssh root@<ip>   (public-key only - the key baked into the image;
     no password login)

INSTALL ALPINE TO THE INTERNAL DISK (offline, no network needed)
  ssh root@<ip>
  install-alpine /dev/sda          # interactive; add --yes to skip prompts
  # packages come from apks/ on this stick - no network needed

SAFETY
  - The vendor flash (A/B/GOLD slots) is never touched
  - install-alpine ERASES the internal disk - all data will be lost
  - To return to stock firmware: remove the USB stick, power cycle
READMEEOF
echo "README.txt written"

# ---- 7. Alpine packages (use dl-packages.sh) ----------------------------------------
set -a
# shellcheck disable=SC1091
source config/alpine.env
set +a

echo ""
echo "=== Downloading Alpine packages (via dl-packages.sh) ==="
if bash image/dl-packages.sh; then
    echo "Package download complete"
else
    echo "WARNING: package download had errors, continuing with what we have"
fi

# Ensure APKINDEX files are in apks/ (dl-packages.sh already copies them)
if [ ! -f "$USB_TREE/apks/main/APKINDEX.tar.gz" ]; then
    cp ".work/apk-cache-offline/main-APKINDEX.tar.gz" "$USB_TREE/apks/main/APKINDEX.tar.gz" 2>/dev/null || true
fi
if [ ! -f "$USB_TREE/apks/community/APKINDEX.tar.gz" ]; then
    cp ".work/apk-cache-offline/community-APKINDEX.tar.gz" "$USB_TREE/apks/community/APKINDEX.tar.gz" 2>/dev/null || true
fi

echo ""
echo "=== USB tree ready: $USB_TREE ==="
echo ""
echo "Files at USB stick root (copy these to FAT32 stick):"
find "$USB_TREE" -maxdepth 2 -type f | sort | while read f; do echo "  $f ($(du -h "$f" | cut -f1))"; done
echo ""
echo "To copy to USB stick:"
echo "  mount /dev/sdX1 /mnt && cp -r $USB_TREE/* /mnt/ && sync"
echo ""
echo "Artifact packaging complete."

# ---- 8. flash.zip at build/flash.zip (for test-flash.sh) --------------------------
PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
( cd "$USB_TREE" && zip -r "$PROJ_DIR/build/flash.zip" . )
echo "flash.zip created at build/flash.zip"
