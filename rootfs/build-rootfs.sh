#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$1"
RELEASE="$2"

echo "=== Building Alpine rescue rootfs ==="

mkdir -p "$ROOT"

# Run the full build
bash rootfs/build-rootfs.sh

# Copy init as PID 1
cp rootfs/init "$ROOT/init"
chmod +x "$ROOT/init"

# Copy overlay files
if [ -d rootfs/overlay ]; then
    cp -a rootfs/overlay/* "$ROOT/" 2>/dev/null || true
fi

# Ensure network interfaces
mkdir -p "$ROOT/etc/network"
if [ ! -f "$ROOT/etc/network/interfaces" ]; then
    cp rootfs/overlay/etc/network/interfaces "$ROOT/etc/network/interfaces"
fi

# Ensure authorized_keys exists (even if empty example)
mkdir -p "$ROOT/root/.ssh"
if [ ! -f "$ROOT/root/.ssh/authorized_keys" ]; then
    cp rootfs/overlay/root/.ssh/authorized_keys.example "$ROOT/root/.ssh/authorized_keys"
fi
chmod 700 "$ROOT/root/.ssh"
chmod 600 "$ROOT/root/.ssh/authorized_keys"

# Ensure init is executable
chmod +x "$ROOT/init"

# Create dropbear config
mkdir -p "$ROOT/etc/dropbear"
cp rootfs/overlay/etc/dropbear/README "$ROOT/etc/dropbear/README"

# Create dropbear init
cp rootfs/overlay/etc/init.d/dropbear "$ROOT/etc/init.d/dropbear"
chmod +x "$ROOT/etc/init.d/dropbear"

# Create boot-full-alpine
mkdir -p "$ROOT/usr/local/sbin"
cp rootfs/overlay/usr/local/sbin/boot-full-alpine "$ROOT/usr/local/sbin/boot-full-alpine"
chmod +x "$ROOT/usr/local/sbin/boot-full-alpine"

# Set up basic directory structure
for d in proc sys dev tmp var/log bin sbin; do
    mkdir -p "$ROOT/$d"
done

# Build rescue cpio if modules are available
KERNEL_RELEASE=$(cat build/kernel/kernel-release.txt 2>/dev/null || echo "")
if [ -n "$KERNEL_RELEASE" ] && [ -d "$ROOT/lib/modules/$KERNEL_RELEASE" ]; then
    echo "Building rescue CPIO..."
    cd "$ROOT"
    find . | cpio -o -H newc | gzip -9 > "../build/rescue.root.sata.cpio.gz_pad.img"
    cd -
fi

# Pad rescue rootfs to 4 MiB
PAD_SIZE=4194304
IMG="build/rescue.root.sata.cpio.gz_pad.img"
if [ -f "$IMG" ]; then
    ACTUAL_SIZE=$(stat -c '%s' "$IMG")
    if [ "$ACTUAL_SIZE" -lt "$PAD_SIZE" ]; then
        dd if=/dev/zero bs=1 count=$((PAD_SIZE - ACTUAL_SIZE)) >> "$IMG" 2>/dev/null
        echo "Padded rescue rootfs to $PAD_SIZE bytes"
    elif [ "$ACTUAL_SIZE" -gt "$PAD_SIZE" ]; then
        echo "WARNING: Rescue rootfs exceeds 4 MiB ($ACTUAL_SIZE bytes)" >&2
    fi
fi

echo "Rescue rootfs build complete."
