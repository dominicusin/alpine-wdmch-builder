#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$1"
RELEASE="$2"
PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"

test -x "$ROOT/init" || { echo "FAIL: init not executable"; exit 1; }
test -x "$ROOT/bin/busybox" || { echo "FAIL: busybox not found"; exit 1; }
test -x "$ROOT/usr/sbin/dropbear" || { echo "FAIL: dropbear not found"; exit 1; }
test -f "$ROOT/etc/network/interfaces" || { echo "FAIL: network/interfaces missing"; exit 1; }
test -f "$ROOT/root/.ssh/authorized_keys" || { echo "FAIL: authorized_keys missing"; exit 1; }
test -x "$ROOT/etc/init.d/99-disk-root" || { echo "FAIL: 99-disk-root handoff script not executable"; exit 1; }
test -x "$ROOT/usr/local/sbin/verify-install" || {
    echo "FAIL: verify-install not shipped in the rescue image"
    echo "      install-alpine copies it onto the target so the operator can"
    echo "      health-check the box after the first boot"
    exit 1
}
sh -n "$ROOT/usr/local/sbin/verify-install" || {
    echo "FAIL: verify-install is not valid POSIX sh"; exit 1; }

# The installed system gets /sbin/init from busybox's .post-install
# (`busybox --install -s`) plus its /sbin trigger. apk skips BOTH under
# --no-scripts, so passing that flag on the target install silently yields a
# rootfs with no init: 99-disk-root refuses to hand over and the box never
# boots. Only the throwaway e2fsprogs pull may use --no-scripts.
echo "Checking the target install keeps package scripts enabled"
if python3 - "$PROJ_DIR/rootfs/install-alpine" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
for m in re.finditer(r'"\$APK" add(?:(?!^\S).)*?(?=^\S)', src, re.S | re.M):
    blk = m.group(0)
    if '--root "$MNT"' in blk and '--no-scripts' in blk:
        sys.exit(1)
sys.exit(0)
PY
then
    echo "  target install runs package scripts: OK"
else
    echo "  FAIL: --no-scripts on the target apk add (/sbin/init would never be created)"
    exit 1
fi

# This image deliberately ships ZERO kernel modules: every driver the rescue
# needs is built into the kernel, so $ROOT/lib/modules/$RELEASE does not exist
# and must not be required. Assert the built-in contract instead -- if a
# required driver drops to =m the rescue kernel cannot mount the internal SATA
# disk, read the USB stick, or bring up Ethernet.
echo "Checking built-in kernel drivers (kernel release: ${RELEASE})"
KERNEL_CONFIG="$PROJ_DIR/config/kernel.config"
if [ ! -f "$KERNEL_CONFIG" ]; then
    echo "FAIL: kernel config not found: $KERNEL_CONFIG"
    exit 1
fi

BUILTIN_REQUIRED="
CONFIG_SCSI
CONFIG_BLK_DEV_SD
CONFIG_SATA_HOST
CONFIG_SATA_AHCI
CONFIG_AHCI_RTD1295
CONFIG_PHY_RTK_RTD_SATAPHY
CONFIG_R8169SOC
CONFIG_REALTEK_PHY
CONFIG_USB_STORAGE
CONFIG_EXT4_FS
CONFIG_VFAT_FS
"

missing=0
for opt in $BUILTIN_REQUIRED; do
    if grep -q "^${opt}=y" "$KERNEL_CONFIG"; then
        echo "  $opt: built-in"
    else
        echo "  FAIL: $opt is not built into the kernel (no modules are shipped)"
        missing=1
    fi
done
[ "$missing" -eq 0 ] || { echo "FAIL: required drivers must be =y, not =m"; exit 1; }

# Check no password auth in sshd_config if it exists
if [ -f "$ROOT/etc/ssh/sshd_config" ]; then
    if grep -RqsE '^(PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords)' "$ROOT/etc/ssh" 2>/dev/null; then
        # Allow if commented out, fail if active settings enable password
        grep -E '^(PermitRootLogin yes|PasswordAuthentication yes|PermitEmptyPasswords yes)' "$ROOT/etc/ssh/sshd_config" 2>/dev/null && { echo "FAIL: password auth enabled"; exit 1; }
    fi
fi

echo "Rootfs validation PASSED"
