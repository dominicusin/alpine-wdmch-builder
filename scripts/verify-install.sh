#!/usr/bin/env sh
# Verify an installed WDMCH Alpine system.
#
# Run this on the box after the rescue handover - over SSH, or from the serial
# console. It checks the things that can silently go wrong and that the build
# cannot test without real hardware: that the handover landed on a real root,
# that an init exists, that the network came up, and that SSH is reachable.
#
# Usage:
#   verify-install              # check the live system
#   verify-install /mnt/target  # check a mounted target root (no network checks)
#
# Exits 0 if every check passed, 1 otherwise.
set -u

TARGET="${1:-/}"
LIVE=0
[ "$TARGET" = "/" ] && LIVE=1

fails=0
pass() { echo "  OK    $*"; }
fail() { echo "  FAIL  $*"; fails=$((fails + 1)); }
warn() { echo "  WARN  $*"; }

echo "=== WDMCH install verification (target: $TARGET) ==="
if [ "$LIVE" -eq 0 ]; then
    echo "    offline mode: network checks are skipped"
fi
echo

# ---- 1. we are actually looking at an installed system --------------------
echo "[init]"
init=""
for i in sbin/init init usr/sbin/init bin/init; do
    if [ -x "$TARGET/$i" ]; then init="$i"; break; fi
done
if [ -n "$init" ]; then
    pass "/$init is executable"
else
    fail "no init found - the system cannot boot unattended"
    echo "        install-alpine should have created /sbin/init; re-run the install"
fi

if [ "$LIVE" -eq 1 ] && [ -r /proc/1/cmdline ]; then
    pid1=$(tr '\0' ' ' < /proc/1/cmdline)
    case "$pid1" in
        *init*) pass "PID 1 is: $pid1" ;;
        *)      warn "PID 1 is '$pid1' - expected an init" ;;
    esac
fi

# ---- 2. the root filesystem is the one the installer created --------------
# These describe the RUNNING system, so they only make sense against a live
# root. Pointed at a mounted target they would read the host's /proc and
# report nonsense about whatever disk the host happens to boot from.
if [ "$LIVE" -eq 1 ]; then
    echo
    echo "[root filesystem]"
    if command -v blkid >/dev/null 2>&1; then
        rootdev=$(findmnt -n -o SOURCE / 2>/dev/null || awk '$2=="/"{print $1; exit}' /proc/mounts)
        if [ -n "${rootdev:-}" ]; then
            lbl=$(blkid -s LABEL -o value "$rootdev" 2>/dev/null || true)
            typ=$(blkid -s TYPE  -o value "$rootdev" 2>/dev/null || true)
            [ "$lbl" = "wdmch-root" ] && pass "root is $rootdev, $typ, label wdmch-root" \
                                     || fail "root is $rootdev (label '$lbl', type '$typ') - expected label wdmch-root"
        else
            warn "could not determine the root device"
        fi
    else
        warn "no blkid available; skipping the label check"
    fi

    if grep -q ' / ' /proc/mounts 2>/dev/null; then
        rw=$(awk '$2=="/"{print $4}' /proc/mounts)
        case "$rw" in
            rw,*) pass "root is mounted rw" ;;
            *)   fail "root is mounted read-only ($rw)" ;;
        esac
    fi

    # ---- 3. the factory partition table survived --------------------------
    echo
    echo "[partition table]"
    n=$(awk '$4 ~ /^sda/ {c++} END{print c+0}' /proc/partitions 2>/dev/null || echo 0)
    if [ "$n" -ge 20 ]; then
        pass "internal disk exposes $n partitions (factory GPT preserved)"
    elif [ "$n" -eq 0 ]; then
        warn "no sda device in /proc/partitions"
    else
        fail "internal disk exposes only $n partitions - the factory GPT was rewritten"
    fi
else
    echo
    echo "[root filesystem] skipped (live-only check)"
    echo
    echo "[partition table]  skipped (live-only check)"
fi

if [ -f "$TARGET/boot/Image" ]; then
    echo
    echo "[kernel on disk]"
    pass "/boot/Image present ($(wc -c < "$TARGET/boot/Image") bytes)"
else
    echo
    echo "[kernel on disk]"
    warn "/boot/Image missing - the kexec handoff will not work"
fi

# ---- 4. the offline install is complete -----------------------------------
echo
echo "[installed packages]"
if [ -d "$TARGET/usr/lib/apk/db/installed" ]; then
    for p in busybox openrc openrc-init dropbear ifupdown-ng mdev-conf; do
        if [ -d "$TARGET/usr/lib/apk/db/installed/$p" ]; then
            pass "$p installed"
        else
            fail "$p missing from the installed database"
        fi
    done
else
    fail "no apk installed database - the offline install did not complete"
fi

# ---- 5. networking (live only) -------------------------------------------
if [ "$LIVE" -eq 1 ]; then
    echo
    echo "[network]"
    if [ -f /etc/network/interfaces ]; then
        pass "/etc/network/interfaces present"
    else
        fail "/etc/network/interfaces missing - the install step did not run"
    fi
    if ip -o link show eth0 >/dev/null 2>&1; then
        pass "eth0 exists"
        if ip -o addr show eth0 2>/dev/null | grep -q 'inet '; then
            addr=$(ip -o -4 addr show eth0 2>/dev/null | awk '{print $4; exit}')
            pass "eth0 has an address: $addr"
        else
            fail "eth0 has no IPv4 address - DHCP did not complete"
        fi
    else
        fail "eth0 is missing"
    fi
    if pgrep -x dropbear >/dev/null 2>&1; then
        pass "dropbear is running"
    else
        fail "dropbear is not running - SSH will be refused"
    fi
fi

# ---- verdict --------------------------------------------------------------
echo
if [ "$fails" -eq 0 ]; then
    echo "RESULT: PASS - the installed system is healthy"
    exit 0
fi
echo "RESULT: FAIL - $fails check(s) failed"
exit 1
