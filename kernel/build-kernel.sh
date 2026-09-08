#!/usr/bin/env bash
set -Eeuo pipefail

# Load source locks
set -a
source config/source-lock.env
set +a

KERNEL_DIR="${KERNEL_DIR:-.work/monarch-6.18}"
BUILD_DIR="${BUILD_DIR:-build/kernel}"
MODULE_STAGE="${MODULE_STAGE:-build/kernel/modules}"
JOBS="${JOBS:-$(nproc)}"

CLANG_TARGET="${CLANG_TARGET:-aarch64-linux-gnu}"
CC="${CCACHE:-ccache} aarch64-linux-gnu-gcc"

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

# Cross-compilation with GCC
# GCC uses aarch64-linux-gnu-ld (GNU ld) by default
# Uses GNU ld via aarch64-linux-gnu-gcc
export ARCH=arm64
export CROSS_COMPILE="${CLANG_TARGET}-"

# Configure kernel using defconfig with config from file
# Write config directly to output dir to avoid dirty source tree
# Use O= for out-of-tree build - Kbuild will check source tree cleanliness
# But we must ensure the output dir is clean before this
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Copy kernel config to output dir as .config
# This avoids putting .config in the source tree
cp config/kernel.config "$BUILD_DIR/.config"

# Configure kernel using defconfig - reads from output dir .config
echo "Configuring kernel with defconfig..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" CC="$CC" defconfig 2>&1

# Force CMA config symbols immediately
echo "Ensuring CMA config symbols..."
for sym in CONFIG_CMA CONFIG_CMA_MIGRATION CONFIG_CMA_DEBUGFS; do
    if ! grep -q "^${sym}=y" "$BUILD_DIR/.config" 2>/dev/null; then
        echo "${sym}=y" >> "$BUILD_DIR/.config"
        echo "Added ${sym}=y to .config"
    fi
done

# Verify .config exists
if [ ! -f "$BUILD_DIR/.config" ]; then
    echo "ERROR: .config not found in output dir" >&2
    exit 1
fi

# Verify CMA is enabled
echo "Verifying CMA config..."
if ! grep -q "^CONFIG_CMA=y" "$BUILD_DIR/.config" 2>/dev/null; then
    echo "ERROR: CONFIG_CMA not enabled in .config" >&2
    exit 1
fi
echo "CONFIG_CMA=y confirmed"

# Verify required config symbols
echo "Verifying required kernel config symbols..."
for sym in \
    CONFIG_ARCH_REALTEK CONFIG_ARCH_RTD129x CONFIG_OF CONFIG_OF_FLATTREE \
    CONFIG_DEVTMPFS CONFIG_DEVTMPFS_MOUNT CONFIG_AHCI_RTD1295 \
    CONFIG_SATA_HOST CONFIG_SATA_AHCI_PLATFORM CONFIG_R8169SOC \
    CONFIG_PHY_RTK_RTD_SATAPHY CONFIG_KEXEC_CORE CONFIG_KEXEC \
    CONFIG_BLK_DEV_INITRD CONFIG_SCSI CONFIG_MMC CONFIG_MMC_BLOCK \
    CONFIG_USB CONFIG_USB_DWC3 CONFIG_PHYLIB CONFIG_PSI \
    CONFIG_PREEMPT_BUILD CONFIG_PREEMPT CONFIG_PREEMPT_RCU \
    CONFIG_RCU_EXPERT CONFIG_RCU_BOOST CONFIG_RCU_NOCB_CPU CONFIG_CMA; do
    if ! grep -q "^${sym}=y" "$BUILD_DIR/.config" 2>/dev/null; then
        echo "WARNING: $sym not enabled in config" >&2
    fi
done

# Diagnose cma_diag_race_shift_calls symbol
echo "=== Diagnosing cma_diag_race_shift_calls ==="
echo "References in source:"
grep -Rnw --exclude-dir=.git --exclude='*.o' --exclude='*.a' 'cma_diag_race_shift_calls' "$KERNEL_DIR" 2>/dev/null | head -20 || true
echo "Config references:"
grep -Rnw --exclude-dir=.git 'CONFIG_CMA' "$KERNEL_DIR/Kconfig" "$KERNEL_DIR/fs/cma" "$KERNEL_DIR/kernel/sched" 2>/dev/null | head -10 || true
echo "Source status:"
git -C "$KERNEL_DIR" status --short 2>/dev/null | head -10 || true

# Build host tools needed for prepare
echo "Building host tools..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" CC="$CC" scripts 2>&1

# Prepare modules (creates modules.builtin)
echo "Preparing modules..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" CC="$CC" modules_prepare 2>&1

# Build kernel Image and DTBs
echo "Building kernel Image and DTBs..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" CC="$CC" -j"$JOBS" Image dtbs 2>&1

# Build modules
echo "Building modules..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" CC="$CC" -j"$JOBS" modules 2>&1

# Install modules
echo "Installing modules..."
mkdir -p "$MODULE_STAGE"
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" CC="$CC" INSTALL_MOD_PATH="$MODULE_STAGE" modules_install 2>&1

# Copy modules.builtin to source tree for modules_install
if [ -f "$BUILD_DIR/modules.builtin" ]; then
    cp "$BUILD_DIR/modules.builtin" "$KERNEL_DIR/modules.builtin" 2>/dev/null || true
fi

# Copy kernel release to build dir
echo "Saving kernel release..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" CC="$CC" kernelrelease > "$BUILD_DIR/kernel-release.txt" 2>/dev/null || true

# Copy Image to build dir for packaging
if [ -f "$BUILD_DIR/arch/arm64/boot/Image" ]; then
    cp "$BUILD_DIR/arch/arm64/boot/Image" "$BUILD_DIR/Image" 2>/dev/null || true
fi

# Copy DTB to build dir for packaging
if [ -f "$BUILD_DIR/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dtb" ]; then
    cp "$BUILD_DIR/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dtb" "$BUILD_DIR/rtd1295-wd-mycloud-home.dtb" 2>/dev/null || true
    echo "DTB copied to build dir"
elif [ -f "$BUILD_DIR/arch/arm64/boot/dts/realtek/rtd1295-wd-mycloud-home.dts" ]; then
    echo "WARNING: DTB .dts found but not .dtb"
fi

echo "Kernel build complete."
