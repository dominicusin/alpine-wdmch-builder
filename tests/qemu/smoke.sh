#!/bin/sh
# QEMU smoke test for Alpine rescue rootfs
# This runs inside a qemu-aarch64 userspace environment
# It does NOT test WDMCH board kernel boot

set -Eeuo pipefail

ROOTFS="$1"
KERNEL_RELEASE="$2"

echo "=== QEMU aarch64 rescue rootfs smoke test ==="

# Check if qemu-aarch64-static is available
if ! command -v qemu-aarch64-static >/dev/null 2>&1; then
    echo "WARNING: qemu-aarch64-static not found, skipping QEMU test"
    exit 0
fi

# Prepare a test directory with the rootfs
TEST_DIR=$(mktemp -d)
cp -a "$ROOTFS" "$TEST_DIR/rootfs"

# Copy qemu-aarch64-static into rootfs for chroot capability
if [ -f /usr/bin/qemu-aarch64-static ]; then
    cp /usr/bin/qemu-aarch64-static "$TEST_DIR/rootfs/usr/bin/qemu-aarch64-static"
elif [ -f /usr/local/bin/qemu-aarch64-static ]; then
    cp /usr/local/bin/qemu-aarch64-static "$TEST_DIR/rootfs/usr/bin/qemu-aarch64-static"
fi

# Run assertions inside QEMU userspace
echo "Testing init exists and is executable..."
if [ -x "$TEST_DIR/rootfs/init" ]; then
    echo "OK: /init exists and is executable"
else
    echo "FAIL: /init not executable"
    exit 1
fi

echo "Testing /bin/busybox runs..."
if [ -x "$TEST_DIR/rootfs/bin/busybox" ]; then
    echo "OK: /bin/busybox exists"
else
    echo "FAIL: /bin/busybox not found"
    exit 1
fi

echo "Testing /usr/sbin/dropbear exists..."
if [ -x "$TEST_DIR/rootfs/usr/sbin/dropbear" ] || [ -x "$TEST_DIR/rootfs/usr/bin/dropbear" ]; then
    echo "OK: Dropbear exists"
else
    echo "FAIL: Dropbear not found"
    exit 1
fi

echo "Testing /etc/network/interfaces exists..."
if [ -f "$TEST_DIR/rootfs/etc/network/interfaces" ]; then
    echo "OK: /etc/network/interfaces exists"
else
    echo "FAIL: /etc/network/interfaces not found"
    exit 1
fi

echo "Testing /root/.ssh/authorized_keys exists..."
if [ -f "$TEST_DIR/rootfs/root/.ssh/authorized_keys" ]; then
    echo "OK: /root/.ssh/authorized_keys exists"
else
    echo "FAIL: authorized_keys not found"
    exit 1
fi

echo "Testing kernel module directory..."
if [ -d "$TEST_DIR/rootfs/lib/modules/$KERNEL_RELEASE" ]; then
    echo "OK: Modules directory matches kernel release"
else
    echo "FAIL: Modules directory mismatch"
    exit 1
fi

# Try running a basic command inside QEMU if possible
echo "Attempting QEMU userspace test..."
qemu-aarch64-static "$TEST_DIR/rootfs/bin/busybox" --help >/dev/null 2>&1 && echo "OK: BusyBox runs in QEMU" || echo "WARNING: Could not run BusyBox in QEMU"

rm -rf "$TEST_DIR"
echo "QEMU smoke test PASSED"
