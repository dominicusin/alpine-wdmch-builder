#!/usr/bin/env bash
# Read-only inventory of the WDMCH, answering exactly the questions the
# strategic decision table needs.
#
# Safe to run on a live, working machine: it only reads. No writes, no
# mounts, no service changes. It is meant to be pasted or run over SSH
# BEFORE any maintenance window, so the "does it fit" and "is the migration
# worth it" questions are answered with measurements rather than impressions.
#
#   ssh dietpi@192.168.1.2 'bash -s' < tools/preflight.sh
set -Eeuo pipefail

hr() { printf '%s\n' "------------------------------------------------------------------"; }
sec() { hr; echo "  $*"; hr; }

# Which whole disk is the rescue stick?
#
# This must not be assumed. In the rescue environment the USB stick claims
# /dev/sda, so anything that hardcodes sda - the old version of this script
# included - inventories the boot medium and then answers "how big is p20?" with
# the stick's own partition table. On a machine reached over SSH the internal
# disk is usually sda, which is exactly why the bug would survive casual use.
stick_disk() {
    local mp src mf
    # MOUNTS_FILE exists so tests/test_preflight.sh can drive this with a
    # synthetic mount table. The default is the only value used in production,
    # and the script stays a single file because it is piped over SSH.
    mf=${MOUNTS_FILE:-/proc/mounts}
    for mp in /media/usb /mnt/usb /media/stick; do
        src=$(awk -v m="$mp" '$2 == m {print $1; exit}' "$mf" 2>/dev/null) || true
        if [ -n "${src:-}" ]; then
            printf '%s\n' "${src%%[0-9]}"     # /dev/sdb1 -> /dev/sdb
            return 0
        fi
    done
    printf '\n'                              # empty: no stick mounted
}

# Which whole disk is the internal SATA disk? The first disk that is not the
# stick. lsblk -d lists whole disks only, so partitions cannot be picked up.
# The exclusion compares whole disks, so both sides must be full paths:
# stick_disk yields /dev/sda (from the mount table) and lsblk -dno PATH yields
# /dev/sda too. Using -o NAME here returns bare "sda", which never compares
# equal, so the stick would be selected AS the internal disk - the exact
# failure this function exists to prevent.
internal_disk() {
    local want d
    want=$(stick_disk)
    if command -v lsblk >/dev/null 2>&1; then
        while read -r d; do
            [ -n "$d" ] || continue
            [ "$d" = "$want" ] && continue
            printf '%s\n' "$d"
            return 0
        done < <(lsblk -dno PATH 2>/dev/null || true)
    fi
    for d in /dev/sda /dev/sdb /dev/sdc /dev/sdd; do
        [ -b "$d" ] || continue
        [ "$d" = "$want" ] && continue
        printf '%s\n' "$d"
        return 0
    done
    printf '\n'
}

STICK_DISK=$(stick_disk)
INTERNAL_DISK=$(internal_disk)

echo
echo "==================================="
echo "  WDMCH pre-flight inventory"
echo "  $(date -Is 2>/dev/null || date)"
echo "==================================="

sec "1. Identity"
echo "  hostname : $(hostname 2>/dev/null || echo '?')"
echo "  kernel   : $(uname -r 2>/dev/null || echo '?')"
echo "  arch     : $(uname -m 2>/dev/null || echo '?')"
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release; echo "  os       : ${PRETTY_NAME:-?}"
fi
echo "  uptime   : $(uptime -p 2>/dev/null || echo '?')"

sec "2. THE decisive question: how big is p20 SYSTEM_B?"
# The installer writes only here. If the target system does not fit, no
# later step matters and the whole approach has to be reconsidered.
echo "  rescue stick    : ${STICK_DISK:-none detected}"
echo "  internal disk   : ${INTERNAL_DISK:-NONE FOUND - nothing below is reliable}"
echo
# lsblk draws partitions with a tree prefix ("├─sda1", "└─sda24"), so the
# device name is NOT the first field. Matching on $1 found nothing and the
# entire partition table was suppressed - which is exactly the table this
# section exists to print. Measured on the WDMCH: the only line shown was the
# whole disk, and the operator was left to guess.
if command -v lsblk >/dev/null 2>&1; then
    lsblk -b -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null \
        | awk -v d="${INTERNAL_DISK#/dev/}" '
            # Strip the tree prefix. lsblk draws "├─sda1" with U+251C U+2500,
            # which is three bytes each in UTF-8, so matching specific bytes is
            # fragile; removing every leading non-alphanumeric works whatever
            # the encoding and whatever the terminal emits.
            function name(f) { gsub(/^[^A-Za-z0-9]+/, "", f); return f }
            NR == 1 { printf "  %-10s %14s  %-8s %-10s %-12s %s\n", $1,$2,$3,$4,$5,$6; next }
            { n = name($1)
              if (n == d || (index(n, d) == 1 && substr(n, length(d)+1) ~ /^[0-9]+$/))
                  printf "  %-10s %14s  %-8s %-10s %-12s %s\n", n,$2,$3,$4,$5,$6 }'
else
    echo "  lsblk unavailable; raw partition sizes:"
    cat /proc/partitions 2>/dev/null | sed 's/^/  /'
fi
echo
echo "  NOTE: partx is read-only and does not need root, so it is the"
echo "        most reliable way to see p20 when lsblk is unavailable."
# -b, not -r. /dev/sda is root:disk 0660, so for the unprivileged user this
# inventory is meant for, `[ -r /dev/sda ]` is FALSE even though the disk is
# right there - and section 3 then reported "no readable internal disk" on a
# machine with a perfectly intact factory GPT. Measured, not reasoned.
if command -v partx >/dev/null 2>&1 && [ -n "${INTERNAL_DISK:-}" ] && [ -b "$INTERNAL_DISK" ]; then
    # `|| true` is load-bearing. The script runs under `set -Eeuo pipefail`, and
    # on a disk that has no partitions 19-21 grep exits 1 - which killed the
    # whole inventory. It was invisible before because the old `-r` test was
    # false for an unprivileged user, so this block never ran at all. A
    # read-only inventory must not abort because a filter matched nothing.
    partx --show --bytes "$INTERNAL_DISK" 2>/dev/null | grep -E ':(19|20|21):' | sed 's/^/  /' || true
fi
echo
# The verdict, stated rather than left for the operator to spot in a table of
# 24 partitions. Silence here reads as "I did not look", and on this machine
# a missing p20 changes the decision completely.
P20_BYTES=$(lsblk -bndo SIZE "${INTERNAL_DISK}20" 2>/dev/null | head -1 || true)
if [ -n "${P20_BYTES:-}" ] && [ "$P20_BYTES" -gt 0 ] 2>/dev/null; then
    echo "  VERDICT: p20 SYSTEM_B = $((P20_BYTES / 1024 / 1024)) MiB on ${INTERNAL_DISK}20"
    if [ ! -r "$INTERNAL_DISK" ]; then
        echo "           (the disk is present but not readable without root;"
        echo "            the sizes above come from the kernel, which is enough.)"
    fi
else
    echo "  VERDICT: NO p20 (${INTERNAL_DISK:-no disk}20) FOUND."
    echo "           If this machine is not a WDMCH, stop here. If it is, the"
    echo "           factory table is gone and the installer will refuse it."
fi

sec "3. Factory partition table: is it intact?"
# The installer's safety property is that it never rewrites this table.
# Capturing it now gives an exact before/after comparison.
if [ -z "${INTERNAL_DISK:-}" ] || [ ! -b "$INTERNAL_DISK" ]; then
    echo "  (no internal disk found; ${STICK_DISK:-no rescue stick} is not it)"
elif [ ! -r "$INTERNAL_DISK" ]; then
    # Present, but this user cannot read it. Say exactly that - the previous
    # wording claimed no disk was found, which is false and alarming.
    echo "  ${INTERNAL_DISK} is present but not readable without root."
    echo "  Re-run under sudo to dump the table:"
    echo "      sudo sgdisk -p ${INTERNAL_DISK}"
    echo "  (the partition count in section 2 already comes from the kernel and"
    echo "   does not need root, so the factory table can be judged from there.)"
elif command -v sgdisk >/dev/null 2>&1; then
    sgdisk -p "$INTERNAL_DISK" 2>/dev/null | sed 's/^/  /'
elif command -v parted >/dev/null 2>&1; then
    parted -s "$INTERNAL_DISK" print free 2>/dev/null | sed 's/^/  /'
else
    echo "  (no sgdisk/parted; the rescue image reports this itself)"
fi

sec "4. Memory: the strongest argument FOR moving to Alpine"
if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:|^MemAvailable:|^SwapTotal:/ {
             printf "  %-16s %10.1f MiB\n", $1, $2/1024 }' /proc/meminfo
else
    free -m 2>/dev/null | sed 's/^/  /'
fi

sec "5. Disk usage under real load (the case for staying on Debian)"
if [ -r /proc/loadavg ]; then
    echo "  loadavg      : $(cut -d' ' -f1-3 /proc/loadavg)"
fi
if command -v df >/dev/null 2>&1; then
    echo
    echo "  --- root filesystem ---"
    df -h / 2>/dev/null | sed 's/^/  /'
    for m in /home /var /srv; do
        mountpoint -q "$m" 2>/dev/null || continue
        echo "  --- $m ---"; df -h "$m" 2>/dev/null | sed 's/^/  /'
    done
fi

sec "6. Services that would have to be reproduced on Alpine"
if command -v systemctl >/dev/null 2>&1; then
    systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
        | awk '{printf "  %-28s %s\n", $1, $4}' | head -30
    echo
    echo "  --- enabled at boot (the real restoration list) ---"
    systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend 2>/dev/null \
        | awk '{printf "  %-34s %s\n", $1, $2}' | head -30
else
    echo "  (not systemd; see /etc/init.d)"
    ls -1 /etc/init.d 2>/dev/null | sed 's/^/  /' | head -20
fi

sec "7. Does this machine already run a FidoNet / INN gateway?"
# Marked as unconfirmed inference in STRATEGY.md; this is what settles it.
if [ -d /etc/fido ]; then echo "  /etc/fido exists:"; ls -1 /etc/fido 2>/dev/null | sed 's/^/    /'; fi
if [ -d /var/spool/fido ]; then echo "  /var/spool/fido exists:"; du -sh /var/spool/fido 2>/dev/null | sed 's/^/    /'; fi
pgrep -a -f 'innd|innfeed|fidoserver|sshd.*fido' 2>/dev/null | sed 's/^/  proc: /' || echo "  no obvious innd/innfeed process"

sec "8. Printing and remote access (if present)"
if command -v lpstat >/dev/null 2>&1; then lpstat -e 2>/dev/null | sed 's/^/  printer: /'; fi
command -v mosh-server >/dev/null 2>&1 && echo "  mosh-server: present" || echo "  mosh-server: absent"
[ -r /etc/nftables.conf ] && echo "  /etc/nftables.conf: present" || echo "  /etc/nftables.conf: absent"

sec "9. Backups: the thing to have BEFORE the window, not during it"
for d in /backups /srv/backups /var/backups "$HOME"; do
    [ -d "$d" ] || continue
    echo "  $d: $(du -sh "$d" 2>/dev/null | cut -f1)"
done
echo
echo "  p1 (FW_TABLE) is the partition the installer backs up to"
echo "  /root/wdmch-fw-table-backup.bin. Verify it AFTER a successful"
echo "  install; do not rely on it as your only rollback."

hr
echo "  Record this output. It closes these decision-table rows:"
echo "    does it fit in p20      -> section 2"
echo "    is the migration worth  -> sections 4, 5, 6, 7"
echo "    what must be restored   -> sections 6, 8"
hr
echo
