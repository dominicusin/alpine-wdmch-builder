#!/usr/bin/env bash
set -Eeuo pipefail

# Load source locks
set -a
source config/source-lock.env
set +a

KERNEL_DIR="${KERNEL_DIR:-.work/monarch-6.18}"
BUILD_DIR="${BUILD_DIR:-build/kernel}"
JOBS="${JOBS:-$(nproc)}"

CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
CC="${CC:-ccache ${CROSS_COMPILE}gcc}"

if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    echo "ERROR: aarch64-linux-gnu-gcc not found" >&2
    echo "Install gcc-aarch64-linux-gnu package" >&2
    exit 1
fi

echo "=== Building WDMCH kernel with GCC cross-compiler ==="
echo "Kernel source: $KERNEL_DIR"
echo "Build output:  $BUILD_DIR"

if [ ! -f "$KERNEL_DIR/Makefile" ]; then
    echo "ERROR: Kernel source not found at $KERNEL_DIR" >&2
    echo "Run fetch-kernel.sh first" >&2
    exit 1
fi

export ARCH=arm64
export SUBARCH=arm64

# make -C resolves O= relative to the source tree, so use an absolute path
ABS_BUILD_DIR="$(pwd)/$BUILD_DIR"

# Incremental build: keep .config between runs; (re)configure only when the
# config fragment changed or no .config exists yet.
mkdir -p "$BUILD_DIR"

CONFIG_MD5="$(md5sum config/kernel.config | cut -d' ' -f1)"
CONFIG_STAMP="$BUILD_DIR/.config.fragment.md5"

needs_config=0
if [ ! -f "$BUILD_DIR/.config" ]; then
    needs_config=1
elif [ ! -f "$CONFIG_STAMP" ] || [ "$(cat "$CONFIG_STAMP")" != "$CONFIG_MD5" ]; then
    needs_config=1
fi

if [ "$needs_config" -eq 1 ]; then
    echo "Configuring kernel (defconfig + WDMCH fragment merge)..."
    # 1. defconfig into the output dir
    make -C "$KERNEL_DIR" O="$ABS_BUILD_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" CC="$CC" defconfig
    # 2. merge the WDMCH fragment on top (merge_config.sh resolves deps)
    "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m "$BUILD_DIR/.config" config/kernel.config
    # 3. settle dependencies into the final .config
    make -C "$KERNEL_DIR" O="$ABS_BUILD_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" CC="$CC" olddefconfig
    echo "$CONFIG_MD5" > "$CONFIG_STAMP"
else
    echo "Kernel .config unchanged - skipping configuration (incremental build)"
fi

# Verify WDMCH-critical config symbols are actually enabled
echo "Verifying WDMCH-critical kernel config symbols..."
MISSING=0
for sym in \
    CONFIG_ARCH_REALTEK CONFIG_ARCH_RTD129x CONFIG_AHCI_RTD1295 \
    CONFIG_R8169SOC CONFIG_PHY_RTK_RTD_SATAPHY CONFIG_USB_STORAGE \
    CONFIG_EXT4_FS CONFIG_VFAT_FS CONFIG_DEVTMPFS CONFIG_DEVTMPFS_MOUNT \
    CONFIG_BLK_DEV_INITRD CONFIG_RD_GZIP CONFIG_KEXEC; do
    if ! grep -q "^${sym}=y" "$BUILD_DIR/.config" 2>/dev/null; then
        echo "ERROR: $sym not enabled - rescue image would be non-functional" >&2
        MISSING=1
    fi
done
if [ "$MISSING" -ne 0 ]; then
    exit 1
fi
echo "All WDMCH-critical symbols enabled"

# Build only what the rescue image needs: kernel Image + board DTBs.
# No 'modules' target: the rescue initramfs relies on built-in drivers only,
# and defconfig modules (~15k) dominate the build time.
echo "Building kernel Image and DTBs..."
make -C "$KERNEL_DIR" O="$ABS_BUILD_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" CC="$CC" -j"$JOBS" Image dtbs

# Save kernel release
echo "Saving kernel release..."
make -C "$KERNEL_DIR" O="$ABS_BUILD_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" CC="$CC" kernelrelease 2>/dev/null | grep -E '^[0-9]' > "$BUILD_DIR/kernel-release.txt" || true

# Copy Image to build dir for packaging
if [ -f "$BUILD_DIR/arch/arm64/boot/Image" ]; then
    cp "$BUILD_DIR/arch/arm64/boot/Image" "$BUILD_DIR/Image"
else
    echo "ERROR: kernel Image not built" >&2
    exit 1
fi

# Copy DTB to build dir for packaging
if [ -f "$BUILD_DIR/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dtb" ]; then
    cp "$BUILD_DIR/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dtb" "$BUILD_DIR/rtd1295-wd-mycloud-home.dtb"
    echo "DTB copied to build dir"
else
    echo "ERROR: WDMCH DTB not built" >&2
    exit 1
fi

echo "Kernel build complete."
