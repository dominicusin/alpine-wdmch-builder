#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="${KERNEL_DIR:-.work/monarch-6.18}"
BUILD_DIR="${BUILD_DIR:-build/kernel}"

echo "=== Creating WDMCH USB tree ==="

# This script creates the USB filesystem tree structure
# The actual USB writing is a separate operation

USB_TREE="${USB_TREE:-build/usb-tree}"
RELEASE_DIR="${RELEASE_DIR:-build/release}"

mkdir -p "$USB_TREE/boot"

cp "$RELEASE_DIR/sata.uImage" "$USB_TREE/boot/sata.uImage"
cp "$RELEASE_DIR/rescue.sata.dtb" "$USB_TREE/boot/rescue.sata.dtb"
cp "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img" "$USB_TREE/boot/rescue.root.sata.cpio.gz_pad.img"
cp "$RELEASE_DIR/SHA256SUMS" "$USB_TREE/boot/SHA256SUMS"
cp "$RELEASE_DIR/manifest.json" "$USB_TREE/boot/manifest.json"

echo "USB tree created at $USB_TREE"
echo "Files:"
ls -la "$USB_TREE/boot/"
