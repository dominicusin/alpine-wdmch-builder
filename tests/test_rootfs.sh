#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$1"
RELEASE="$2"

test -x "$ROOT/init" || { echo "FAIL: init not executable"; exit 1; }
test -x "$ROOT/bin/busybox" || { echo "FAIL: busybox not found"; exit 1; }
test -x "$ROOT/usr/sbin/dropbear" || { echo "FAIL: dropbear not found"; exit 1; }
test -d "$ROOT/lib/modules/$RELEASE" || { echo "FAIL: modules not found for $RELEASE"; exit 1; }
test -f "$ROOT/etc/network/interfaces" || { echo "FAIL: network/interfaces missing"; exit 1; }
test -f "$ROOT/root/.ssh/authorized_keys" || { echo "FAIL: authorized_keys missing"; exit 1; }

# Check no password auth in sshd_config if it exists
if [ -f "$ROOT/etc/ssh/sshd_config" ]; then
    if grep -RqsE '^(PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords)' "$ROOT/etc/ssh" 2>/dev/null; then
        # Allow if commented out, fail if active settings enable password
        grep -E '^(PermitRootLogin yes|PasswordAuthentication yes|PermitEmptyPasswords yes)' "$ROOT/etc/ssh/sshd_config" 2>/dev/null && { echo "FAIL: password auth enabled"; exit 1; }
    fi
fi

echo "Rootfs validation PASSED"
