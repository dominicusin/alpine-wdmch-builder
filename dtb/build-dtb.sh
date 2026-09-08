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
    # shellcheck disable=SC2066
    echo "$found" >&2
    exit 1
fi

echo "Using DTS: $DTS_PATH"
mkdir -p "$BUILD_DIR"

# Build DTB using kernel build system
echo "Building DTB via kernel build system..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 dtbs 2>&1

# Find the built DTB
BUILT_DTB=""
for candidate in \
    "$BUILD_DIR/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dtb" ; do
    if [ -f "$candidate" ]; then
        BUILT_DTB="$candidate"
        break
    fi
done

if [ -z "$BUILT_DTB" ]; then
    # Fallback: compile directly with dtc
    echo "Kernel build did not produce DTB, compiling directly..."
    dtc -@ -p 16384 -I dts -O dtb \
        -o "$BUILD_DIR/rtd1295-wd-mycloud-home.dtb" \
        "$DTS_PATH"
    BUILT_DTB="$BUILD_DIR/rtd1295-wd-mycloud-home.dtb"
fi

# Copy/normalize to final artifact name
cp "$BUILT_DTB" "$BUILD_DIR/rtd1295-wd-mycloud-home.dtb"

# Also extract DTS for round-trip validation
dtc -I dtb -O dts \
    -o "$BUILD_DIR/rtd1295-wd-mycloud-home.dts" \
    "$BUILD_DIR/rtd1295-wd-mycloud-home.dtb"

echo "DTB build complete: $BUILD_DIR/rtd1295-wd-mycloud-home.dtb"
