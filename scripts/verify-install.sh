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

# How many PARTITIONS does a whole disk expose?
#
# /proc/partitions carries a line for the whole disk as well as one per
# partition, so the suffix after the device name must be digits; counting the
# bare device would report 25 for a 24-partition disk. The threshold passes
# either way, but this number is shown to the operator and should be real.
#
# PARTS is overridable so the test can supply a partition table. The default is
# the only value used on a real machine.
count_partitions() {
    local dev=${1##*/} parts
    parts=${PARTS:-/proc/partitions}
    awk -v dev="$dev" \
        'index($4, dev) == 1 && substr($4, length(dev)+1) ~ /^[0-9]+$/ {n++} END{print n+0}' \
        "$parts" 2>/dev/null || echo 0
}

# The internal disk is whichever sd? device has the most partitions.
#
# It used to be assumed to be sda. That is wrong in exactly the configuration
# the project documents: 99-disk-root says the USB stick can stay plugged in,
# and in the rescue environment the stick is the device that claims sda
# (rootfs/init says so). With the stick present the internal disk enumerates as
# sdb, sda holds the stick's one FAT32 partition, and the check reported
# "the factory GPT was rewritten" on a perfectly correct installation - sending
# the operator to RECOVERY.md to recover a machine that never broke.
#
# "Most partitions" is independent of enumeration order, of whether the stick is
# plugged in, and of which letter the kernel assigned.
select_internal_disk() {
    local best="" bestn=0 d c
    for d in /dev/sd?; do
        c=$(count_partitions "$d")
        if [ "$c" -gt "$bestn" ]; then bestn=$c; best="$d"; fi
    done
    printf '%s\n' "$best"
}

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

          # The label alone does not prove this install is the one the project
          # makes. The target is ONE btrfs spanning p20 + p21; a filesystem that
          # somehow ended up on a single device carries the same label and would
          # pass every other check here, including the factory-GPT one. So the
          # device count is asserted, not assumed.
          if [ "$typ" = "btrfs" ] && command -v btrfs >/dev/null 2>&1; then
              ndev=$(btrfs filesystem show "$rootdev" 2>/dev/null | grep -cE '^[[:space:]]*devid')
              case "$ndev" in
                  ''|0) warn "could not count btrfs devices on $rootdev" ;;
                  1)    fail "the root filesystem has only ONE device - the install did not span p20 and p21" ;;
                  *)    pass "btrfs spans $ndev devices" ;;
              esac
              # A degraded filesystem mounts and boots, then fails on the first
              # write touching a lost device. Saying so is the value of the check.
              miss=$(btrfs filesystem show "$rootdev" 2>/dev/null | grep -ci 'missing')
              if [ "${miss:-0}" -gt 0 ]; then
                  fail "the btrfs is DEGRADED - a member device is missing; the system will
          boot and then fail on writes to the lost device"
              else
                  pass "btrfs is not degraded"
              fi
          elif [ "$typ" = "ext4" ]; then
              warn "root is ext4, not btrfs - looks like an install from before the
              btrfs change (single device, p20 only)"
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
    # Count the disk that actually holds the root filesystem, not "sda".
    #
    # This used to count sda* unconditionally, which is wrong in exactly the
    # configuration the project documents: 99-disk-root says "the USB stick can
    # stay plugged in", and in the rescue environment the stick is the device
    # that claims sda (rootfs/init says so explicitly). With the stick present,
    # the internal disk enumerates as sdb, sda holds the stick's single FAT32
    # partition, and this check reported
    #     "internal disk exposes only 1 partitions - the factory GPT was rewritten"
    # on a perfectly correct installation - sending the operator to RECOVERY.md
    # to recover a machine that never broke.
    #
    # The internal disk is whichever sd? device has the most partitions. That is
    # independent of enumeration order, of whether the stick is plugged in, and
    # of which letter the kernel picked. Naming the disk in the output matters:
    # the operator has to be able to see which device was inspected.
    # Count only PARTITION entries. /proc/partitions also has a line for the
    # whole disk ("  259 0 1953525168 sdb"), and counting that would report 25
    # partitions for a 24-partition disk. The threshold passes either way, but
    # the operator is shown this number and it should be the real one.
    # Which disk is internal is decided by select_internal_disk, which is a
    # function rather than inline code so tests/test_verify_install_gpt.sh can
    # extract and run it. Inlining it here meant the test had to cut a range out
    # of a half-open `if`, which is not a runnable shell fragment.
    gpt_disk=$(select_internal_disk)
    gpt_n=$(count_partitions "$gpt_disk")
    if [ "$gpt_n" -ge 20 ]; then
        pass "$gpt_disk exposes $gpt_n partitions (factory GPT preserved)"
    elif [ "$gpt_n" -eq 0 ]; then
        warn "no sd? device with partitions in /proc/partitions - cannot check the GPT"
    else
        fail "largest disk $gpt_disk exposes only $gpt_n partitions - the factory GPT was rewritten"
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
