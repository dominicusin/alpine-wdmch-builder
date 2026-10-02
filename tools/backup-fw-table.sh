#!/usr/bin/env bash
# backup-fw-table.sh - back up the WDMCH firmware table (p1) from a rescue shell.
#
# Why this exists as a script: the command used to live in four documents as
#
#     dd if=/dev/sda1 of=fw-table-backup.bin bs=512
#
# and in a rescue environment /dev/sda is the USB STICK, not the internal disk.
# So that command backs up the stick's FAT32 partition, writes it somewhere
# obvious, and leaves the operator convinced they have a firmware-table backup
# before flashing anything. The internal disk is usually /dev/sdb here, and
# nothing in the command said so.
#
# This picks the internal disk the same way the installer does - never the disk
# the rescue stick is mounted from - refuses to proceed if it cannot identify
# one, and refuses to report success on an empty file, because dd can exit 0
# having written nothing.
#
# Read-only against the disk: it reads p1 and writes a file in the current
# directory. It never writes to any block device.
#
# Usage:
#   backup-fw-table.sh [-o OUTPUT]        # default: ./fw-table-backup.bin
#   backup-fw-table.sh --device /dev/sdb  # override the disk, if autodetect
#                                           # cannot see the mount table
set -Eeuo pipefail

OUT=./fw-table-backup.bin
DISK=""
AUTODETECT=1

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) [ $# -ge 2 ] || die "$1 needs a path"; OUT=$2; shift 2 ;;
        --device)    [ $# -ge 2 ] || die "$1 needs a device"; DISK=$2; shift 2 ;;
        -h|--help)   sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

# --- which whole disk is the rescue stick? ------------------------------------
# The stick is mounted at /media/usb by rootfs/init. Its whole-disk name is that
# device with the partition digits removed, so sda1 becomes sda.
stick_disk() {
    local mp src
    for mp in /media/usb /mnt/usb /media/stick; do
        [ -r /proc/mounts ] || return 0
        src=$(awk -v m="$mp" '$2 == m {print $1; exit}' /proc/mounts 2>/dev/null) || true
        if [ -n "${src:-}" ]; then
            printf '%s\n' "${src%%[0-9]}"
            return 0
        fi
    done
    printf '\n'
}

if [ -z "$DISK" ]; then
    STICK=$(stick_disk)
    echo "  rescue stick : ${STICK:-none detected}"
    for d in /dev/sda /dev/sdb /dev/sdc /dev/sdd; do
        [ -b "$d" ] || continue
        [ -n "$STICK" ] && [ "$d" = "$STICK" ] && continue
        DISK=$d
        break
    done
    [ -n "$DISK" ] || die "could not identify the internal disk.
       The rescue stick may be occupying /dev/sda with no mount entry to prove
       it. Pass the disk explicitly:  $0 --device /dev/sdb
       Refusing to guess: a wrong guess here means backing up the wrong
       partition and believing you have a firmware-table backup."
    echo "  internal disk: $DISK"
elif [ ! -b "$DISK" ]; then
    die "$DISK is not a block device"
else
    STICK=$(stick_disk)
    [ -n "$STICK" ] && [ "$DISK" = "$STICK" ] && \
        die "$DISK is the rescue stick, not the internal disk.
       Backing it up would produce a copy of the USB stick that looks like a
       firmware table."
    echo "  internal disk: $DISK (given)"
fi

FW="${DISK}1"
[ -b "$FW" ] || die "$FW does not exist - is $DISK really a WDMCH disk?
       The factory table has p1 as the first partition."

echo "  reading       : $FW"
echo "  writing       : $OUT"

# dd can exit 0 having written nothing, so the size check is the actual
# success test, not the exit status.
if ! dd if="$FW" of="$OUT" bs=512 status=none 2>/dev/null; then
    die "dd failed reading $FW"
fi
[ -s "$OUT" ] || die "$OUT is empty - $FW read as zero bytes.
       Treating this as a success is the failure mode this script exists to
       prevent, so it is refused."

BYTES=$(stat -c%s "$OUT" 2>/dev/null || echo '?')
echo
echo "  SAVED: $OUT ($BYTES bytes)"
if [ "$BYTES" -lt 4096 ] 2>/dev/null; then
    echo "  WARNING: $BYTES bytes is small for a firmware table. It is not"
    echo "           obviously empty, but do not rely on this copy alone."
fi
echo
echo "  Keep it off the WDMCH. It is the only copy of this table you have."
