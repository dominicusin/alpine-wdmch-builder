#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_DIR="${KERNEL_DIR:-.work/monarch-6.18}"
BUILD_DIR="${BUILD_DIR:-build/kernel}"

echo "=== Building WDMCH DTB ==="

# Find WDMCH DTS in kernel source
DTS_PATH=""
for candidate in \
    "$KERNEL_DIR/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dts" \
    "$KERNEL_DIR/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dtsi" ; do
    if [ -f "$candidate" ]; then
        DTS_PATH="$candidate"
        break
    fi
done

if [ -z "$DTS_PATH" ]; then
    echo "ERROR: WDMCH DTS not found in $KERNEL_DIR" >&2
    echo "Searching for any rtd1295 DTS..."
    found=$(find "$KERNEL_DIR/arch/arm64/boot/dts" -name "*rtd1295*" -name "*.dts" 2>/dev/null | head -5)
    echo "$found" >&2
    exit 1
fi

echo "Using DTS: $DTS_PATH"

# DTB is built by kernel/build-kernel.sh (make Image dtbs)
# or compiled from the DTS if not found
echo "Looking for DTB in build output..."
BUILT_DTB=""
# Search for the built DTB
for candidate in \
    "$BUILD_DIR/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dtb" ; do
    if [ -f "$candidate" ]; then
        BUILT_DTB="$candidate"
        break
    fi
done

if [ -z "$BUILT_DTB" ]; then
    echo "DTB not found in build output, compiling from DTS..."
    # Compile the DTB directly from the DTS
    dtc -@ -p 16384 -I dts -O dtb \
        -o "$BUILD_DIR/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dtb" \
        "$DTS_PATH" 2>&1 || {
        echo "ERROR: Failed to compile DTB from $DTS_PATH" >&2
        exit 1
    }
    BUILT_DTB="$BUILD_DIR/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dtb"
fi

# Copy/normalize to final artifact name
cp "$BUILT_DTB" "$BUILD_DIR/rtd1295-wd-mycloud-home.dtb"

# Also extract DTS for round-trip validation
dtc -I dtb -O dts \
    -o "$BUILD_DIR/rtd1295-wd-mycloud-home.dts" \
    "$BUILD_DIR/rtd1295-wd-mycloud-home.dtb"

echo "DTB build complete: $BUILD_DIR/rtd1295-wd-mycloud-home.dtb"