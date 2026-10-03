#!/bin/sh
# QEMU smoke test for Alpine rescue rootfs
# This runs inside a qemu-aarch64 userspace environment
# It does NOT test WDMCH board kernel boot

set -Eeuo pipefail

ROOTFS="$1"
KERNEL_RELEASE="$2"

# Either qemu binary does for this test. qemu-aarch64-static exists so the
# emulator can be COPIED INTO a foreign rootfs to make chroot work; this test
# never chroots - it execs the target binary directly - so the static build is
# not needed here. Requiring it made the one test that actually EXECUTES aarch64
# code unrunnable on any host that has only the ordinary package, which is most
# of them. It still fails closed if neither is present.
QEMU=""
for candidate in qemu-aarch64-static qemu-aarch64; do
    if command -v "$candidate" >/dev/null 2>&1; then QEMU="$candidate"; break; fi
done
[ -n "$QEMU" ] || {
    echo "FAIL: no qemu-aarch64 found - the smoke test cannot run" >&2
    echo "      Install qemu-user-static (provides qemu-aarch64-static) or" >&2
    echo "      qemu-user (provides qemu-aarch64)." >&2
    exit 1
}

echo "=== QEMU aarch64 rescue rootfs smoke test (via $QEMU) ==="

# The whole point of this test is to execute aarch64 code under emulation.
# If the emulator is missing, the test has not passed - it has not run. CI
# installs qemu-user-static, so a missing emulator there is a broken
# environment, not a reason to report green.

# Prepare a test directory with the rootfs
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cp -a "$ROOTFS" "$TEST_DIR/rootfs"

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
if ! "$QEMU" "$TEST_DIR/rootfs/bin/busybox" --help >/dev/null 2>&1; then
    echo "FAIL: the aarch64 BusyBox did not run under QEMU" >&2
    "$QEMU" "$TEST_DIR/rootfs/bin/busybox" --help 2>&1 | head -3 >&2 || true
    exit 1
fi
echo "OK: BusyBox runs in QEMU"

echo "QEMU smoke test PASSED"
