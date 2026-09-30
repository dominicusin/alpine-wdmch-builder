#!/usr/bin/env bash
# Prepare and VERIFY a rescue USB stick.
#
# The documentation used to say "cp -r build/usb-tree-root/* /mnt/stick/"
# and stop there. Nothing checked the copy, so a truncated image or a wrong
# layout would only be discovered on the WDMCH, at the serial console, with
# the box open - and a failed hardware session costs a great deal more than a
# five minute local check.
#
# This script performs the copy and then proves the stick is bootable, using
# the SHA256SUMS the image itself ships.
#
#   tools/prepare-usb.sh --device /dev/sdX
#   tools/prepare-usb.sh --image /mnt/stick     # verify a stick in place
#
# It REQUIRES an explicit --device. It refuses a device that looks like a
# fixed internal disk unless --force-internal is also given, because this
# script is destructive and the rescue stick is a different animal from the
# unit it rescues.
set -Eeuo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$PROJ/build/usb-tree-root"

DEVICE=""
IMAGE=""
FORCE_INTERNAL=0
ASSUME_YES=0

die() { echo "ERROR: $*" >&2; exit 1; }
hr()  { printf '%s\n' "--------------------------------------------------------------"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --device)          DEVICE="${2:-}"; shift 2 ;;
        --image)           IMAGE="${2:-}"; shift 2 ;;
        --force-internal)  FORCE_INTERNAL=1; shift ;;
        --yes)             ASSUME_YES=1; shift ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# ---------------------------------------------------------------- verify mode
if [ -n "$IMAGE" ]; then
    echo "=== Verifying rescue stick contents at $IMAGE ==="
    [ -d "$IMAGE" ] || die "not a directory: $IMAGE"

    fail=0
    for f in sata.uImage rescue.sata.dtb rescue.root.sata.cpio.gz_pad.img \
             SHA256SUMS manifest.json README.txt; do
        if [ -f "$IMAGE/$f" ] && [ -s "$IMAGE/$f" ]; then
            printf '  ok        %s\n' "$f"
        else
            printf '  MISSING   %s\n' "$f"; fail=1
        fi
    done
    if [ -d "$IMAGE/boot" ]; then
        echo "  UNEXPECTED boot/ directory - the vendor loader reads the"
        echo "             stick root; a boot/ subdirectory cannot boot."; fail=1
    fi

    echo
    echo "  initramfs size: $(stat -c %s "$IMAGE/rescue.root.sata.cpio.gz_pad.img" 2>/dev/null || echo '?') (must be 4194304)"
    sz=$(stat -c %s "$IMAGE/rescue.root.sata.cpio.gz_pad.img" 2>/dev/null || echo 0)
    [ "$sz" = "4194304" ] || { echo "  WRONG SIZE"; fail=1; }

    echo
    echo "  kernel header (the vendor U-Boot refuses an unpatched Image):"
    if command -v python3 >/dev/null 2>&1 && [ -f "$PROJ/tools/check-image-header.py" ]; then
        python3 "$PROJ/tools/check-image-header.py" "$IMAGE/sata.uImage" | sed 's/^/    /' \
            || { echo "    FAILED: sata.uImage is not a valid patched ARM64 Image"; fail=1; }
    else
        echo "    (check-image-header.py unavailable - skipped)"
    fi

    echo
    echo "  checksums:"
    ( cd "$IMAGE" && sha256sum -c SHA256SUMS ) || fail=1

    echo
    echo "  offline repository: $(find "$IMAGE/apks" -name '*.apk' 2>/dev/null | wc -l) packages"
    n=$(find "$IMAGE/apks" -name '*.apk' 2>/dev/null | wc -l)
    [ "$n" -ge 20 ] || { echo "  repository looks incomplete (<20 packages)"; fail=1; }

    hr
    if [ "$fail" -eq 0 ]; then
        echo "  STICK IS GOOD. Safe to boot the WDMCH from it."
        exit 0
    fi
    echo "  STICK IS NOT USABLE. Re-copy before touching the WDMCH."
    exit 1
fi

# ------------------------------------------------------------------ copy mode
[ -n "$DEVICE" ] || die "give --device /dev/sdX (destructive) or --image /mnt/stick (read-only verify)"
[ -b "$DEVICE" ] || die "$DEVICE is not a block device"
[ -d "$TREE" ] || die "rescue tree not built: $TREE (run 'make package')"
[ "$(id -u)" = "0" ] || die "must run as root (it repartitions the stick)"

# --- refuse to touch an internal disk unless told explicitly
removable=0
if [ -r "/sys/class/block/$(basename "$DEVICE")/removable" ]; then
    [ "$(cat "/sys/class/block/$(basename "$DEVICE")/removable")" = "1" ] && removable=1
fi
if [ "$removable" -eq 0 ] && [ "$FORCE_INTERNAL" -eq 0 ]; then
    hr
    echo "  $DEVICE is NOT flagged removable."
    hr
    echo "  This script ERASES the device. Pointing it at the wrong disk"
    echo "  destroys a working system."
    echo
    echo "  Check the candidate list with:  lsblk -o NAME,SIZE,TYPE,MODEL,TRAN"
    echo
    die "refusing. Re-run with --force-internal only if you are certain."
fi

hr
echo "  DEVICE : $DEVICE"
echo "  MODEL  : $(cat "/sys/class/block/$(basename "$DEVICE")/model" 2>/dev/null | sed 's/ *$//' || echo '?')"
echo "  SIZE   : $(cat "/sys/class/block/$(basename "$DEVICE")/size" 2>/dev/null | awk '{printf "%.1f GiB", $1*512/1073741824}' || echo '?') bytes"
echo "  REMOVABLE: $removable"
hr
echo "  THIS WILL ERASE $DEVICE COMPLETELY."
echo
if [ "$ASSUME_YES" -ne 1 ]; then
    printf '  Type the device path to confirm: '
    read -r answer
    [ "$answer" = "$DEVICE" ] || die "confirmation did not match; nothing was changed"
fi

# --- partition FAT32 spanning the stick
echo
echo "==> Repartitioning as a single FAT32 partition"
umount "$DEVICE" 2>/dev/null || true
umount "${DEVICE}"* 2>/dev/null || true
wipefs -a "$DEVICE" >/dev/null 2>&1 || true
if command -v sfdisk >/dev/null 2>&1; then
    sfdisk "$DEVICE" <<'PART' >/dev/null
label: dos
unit: sectors

start=2048, type=c, bootable
PART
else
    parted -s "$DEVICE" mklabel msdos >/dev/null
    parted -s "$DEVICE" mkpart primary fat32 1MiB 100% >/dev/null
fi
partprobe "$DEVICE" 2>/dev/null || true
udevadm settle 2>/dev/null || sleep 2

PART=""
for cand in "${DEVICE}1" "${DEVICE}p1"; do
    [ -b "$cand" ] && { PART="$cand"; break; }
done
[ -n "$PART" ] || die "no partition device appeared after repartitioning"

echo "==> Formatting $PART as FAT32"
mkfs.vfat -F 32 -n WDMCHRESC "$PART" >/dev/null

MOUNT=$(mktemp -d)
trap 'umount "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
mount "$PART" "$MOUNT"
echo "==> Mounted at $MOUNT"

echo "==> Copying the rescue tree (root level, no boot/ subdirectory)"
( cd "$TREE" && cp -a . "$MOUNT" )
sync

echo
bash "$0" --image "$MOUNT"
