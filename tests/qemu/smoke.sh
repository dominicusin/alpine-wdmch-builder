#!/bin/sh
# QEMU smoke test for Alpine rescue rootfs
# This runs inside a qemu-aarch64 userspace environment
# It does NOT test WDMCH board kernel boot

set -Eeuo pipefail

ROOTFS="$1"
KERNEL_RELEASE="$2"

echo "=== QEMU aarch64 rescue rootfs smoke test ==="

# The whole point of this test is to execute aarch64 code under emulation.
# If the emulator is missing, the test has not passed - it has not run. CI
# installs qemu-user-static, so a missing emulator there is a broken
# environment, not a reason to report green.
if ! command -v qemu-aarch64-static >/dev/null 2>&1; then
    echo "FAIL: qemu-aarch64-static not found - the smoke test cannot run" >&2
    exit 1
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
    echo "WARNING: No modules dir (rescue uses built-in drivers only)"
fi

# The one substantive assertion in this file. BusyBox is statically linked
# for aarch64 and must execute under emulation - that is what proves the
# rescue userspace is a working binary rather than a set of plausible files.
# It used to print a WARNING and let the test pass, so the test could not
# fail on the very thing it exists to check.
echo "Attempting QEMU userspace test..."
if ! qemu-aarch64-static "$TEST_DIR/rootfs/bin/busybox" --help >/dev/null 2>&1; then
    echo "FAIL: the aarch64 BusyBox did not run under QEMU" >&2
    qemu-aarch64-static "$TEST_DIR/rootfs/bin/busybox" --help 2>&1 | head -3 >&2 || true
    exit 1
fi
echo "OK: BusyBox runs in QEMU"

rm -rf "$TEST_DIR"
echo "QEMU smoke test PASSED"
