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

# Cross-compilation toolchain setup
# Use Clang with ccache for reproducible builds
CLANG_TARGET="${CLANG_TARGET:-aarch64-linux-gnu}"
CC="${CCACHE:-ccache} clang"

# Check for clang
if ! command -v clang >/dev/null 2>&1; then
    echo "ERROR: clang not found. Install clang for cross-compilation." >&2
    exit 1
fi

# Check for ccache
if command -v ccache >/dev/null 2>&1; then
    CCACHE_DIR="${CCACHE_DIR:-build/.ccache}"
    mkdir -p "$CCACHE_DIR"
    echo "Using ccache with CCACHE_DIR=$CCACHE_DIR"
fi

echo "=== Building WDMCH kernel with Clang ==="
echo "Source: $KERNEL_DIR"
echo "Build:  $BUILD_DIR"
echo "Compiler: $CC"
echo "Target: $CLANG_TARGET"
echo "Jobs: $JOBS"

# Verify kernel source exists
if [ ! -f "$KERNEL_DIR/Makefile" ]; then
    echo "ERROR: Kernel source not found at $KERNEL_DIR" >&2
    exit 1
fi

# Configure with WDMCH kernel config
echo "Configuring kernel..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" LLVM=1 LLVM_IAS=1 CC="${CC}" olddefconfig < config/kernel.config 2>/dev/null || \
    make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" LLVM=1 LLVM_IAS=1 CC="${CC}" olddefconfig

# Verify required config symbols
echo "Verifying required kernel config symbols..."
for sym in \
    CONFIG_ARCH_REALTEK \
    CONFIG_ARCH_RTD129x \
    CONFIG_OF \
    CONFIG_OF_FLATTREE \
    CONFIG_DEVTMPFS \
    CONFIG_DEVTMPFS_MOUNT \
    CONFIG_AHCI_RTD1295 \
    CONFIG_SATA_HOST \
    CONFIG_SATA_AHCI_PLATFORM \
    CONFIG_R8169SOC \
    CONFIG_PHY_RTK_RTD_SATAPHY \
    CONFIG_KEXEC_CORE \
    CONFIG_KEXEC \
    CONFIG_BLK_DEV_INITRD \
    CONFIG_SCSI \
    CONFIG_MMC \
    CONFIG_MMC_BLOCK \
    CONFIG_USB \
    CONFIG_USB_DWC3 \
    CONFIG_PHYLIB \
    CONFIG_PSI \
    CONFIG_PREEMPT_BUILD \
    CONFIG_PREEMPT \
    CONFIG_PREEMPT_RCU \
    CONFIG_RCU_EXPERT \
    CONFIG_RCU_BOOST \
    CONFIG_RCU_NOCB_CPU; do
    if ! grep -q "^${sym}=y" "$BUILD_DIR/.config" 2>/dev/null; then
        echo "WARNING: $sym not enabled in config" >&2
    fi
done

# Build kernel image, DTBs, and modules using Clang
echo "Building kernel with Clang (this may take a while)..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" LLVM=1 LLVM_IAS=1 CC="${CC}" -j"$JOBS" Image dtbs modules

# Install modules
echo "Installing modules..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" LLVM=1 LLVM_IAS=1 CC="${CC}" INSTALL_MOD_PATH="$MODULE_STAGE" modules_install

# Get kernel release
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="${CLANG_TARGET}-" LLVM=1 LLVM_IAS=1 CC="${CC}" kernelrelease > "$BUILD_DIR/kernel-release.txt"
release=$(cat "$BUILD_DIR/kernel-release.txt")
echo "Kernel release: $release"

echo "Kernel build complete."
