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

mkdir -p "$BUILD_DIR" "$MODULE_STAGE"

echo "=== Building WDMCH kernel ==="
echo "Source: $KERNEL_DIR"
echo "Build:  $BUILD_DIR"

# Verify kernel source exists
if [ ! -f "$KERNEL_DIR/Makefile" ]; then
    echo "ERROR: Kernel source not found at $KERNEL_DIR" >&2
    exit 1
fi

# Configure with WDMCH kernel config
echo "Configuring kernel..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 olddefconfig < config/kernel.config 2>/dev/null || \
    make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 olddefconfig

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
    CONFIG_PHYLIB; do
    if ! grep -q "^${sym}=y" "$BUILD_DIR/.config" 2>/dev/null; then
        echo "WARNING: $sym not enabled in config" >&2
    fi
done

# Build kernel image, DTBs, and modules
echo "Building kernel (this may take a while)..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 -j"$JOBS" Image dtbs modules

# Install modules
echo "Installing modules..."
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 INSTALL_MOD_PATH="$MODULE_STAGE" modules_install

# Get kernel release
make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH=arm64 kernelrelease > "$BUILD_DIR/kernel-release.txt"
release=$(cat "$BUILD_DIR/kernel-release.txt")
echo "Kernel release: $release"

echo "Kernel build complete."
