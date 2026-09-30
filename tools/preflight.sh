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
if command -v lsblk >/dev/null 2>&1; then
    lsblk -b -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null \
        | awk 'NR==1 || /sda/ {printf "  %-10s %14s  %-8s %-10s %-12s %s\n", $1,$2,$3,$4,$5,$6}'
else
    echo "  lsblk unavailable; raw partition sizes:"
    cat /proc/partitions 2>/dev/null | sed 's/^/  /'
fi
echo
echo "  NOTE: partx is read-only and does not need root, so it is the"
echo "        most reliable way to see p20 when lsblk is unavailable."
if command -v partx >/dev/null 2>&1 && [ -r /dev/sda ]; then
    partx --show --bytes /dev/sda 2>/dev/null | grep -E ':(19|20|21):' | sed 's/^/  /'
fi

sec "3. Factory partition table: is it intact?"
# The installer's safety property is that it never rewrites this table.
# Capturing it now gives an exact before/after comparison.
if command -v sgdisk >/dev/null 2>&1 && [ -r /dev/sda ]; then
    sgdisk -p /dev/sda 2>/dev/null | sed 's/^/  /'
elif command -v parted >/dev/null 2>&1 && [ -r /dev/sda ]; then
    parted -s /dev/sda print free 2>/dev/null | sed 's/^/  /'
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
