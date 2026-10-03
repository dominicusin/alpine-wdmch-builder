#!/usr/bin/env bash
set -Eeuo pipefail

# Package WDMCH USB rescue artifacts + the full USB stick tree.
#
# Structure (FIXED): all boot files at root of USB stick, NO boot/ directory.
#   sata.uImage                      — patched RAW kernel Image + 512 KiB padding
#   rescue.sata.dtb                 — WDMCH device tree
#   rescue.root.sata.cpio.gz_pad.img — exactly 4194304 bytes (gzip'd cpio, padded)
#   SHA256SUMS                      — checksums of the 3 boot files
#   manifest.json                   — metadata
#   README.txt                      — instructions for the user
#   apks/main/                      — Alpine main repo packages (offline install)
#   apks/community/                 — Alpine community repo packages
#
# Contract (symops/monarch-6.18 README, "Building and booting"):
#   sata.uImage = RAW patched ARM64 Image (header patched by
#                 tools/monarch/patch-header.py: code0=0x91005A4D,
#                 text_offset=0x200000) + 512 KiB zeros.
#                 Never gzip the Image: this U-Boot's built-in gunzip is
#                 unreliable above a few MB.
#   rescue.sata.dtb                 = WDMCH device tree blob
#   rescue.root.sata.cpio.gz_pad.img = exactly 4194304 bytes (from
#                 rootfs/build-rootfs.sh; the loader reads that fixed size)

KERNEL_DIR="${KERNEL_DIR:-.work/monarch-6.18}"
BUILD_DIR="${BUILD_DIR:-build/kernel}"
RELEASE_DIR="${RELEASE_DIR:-build/release}"
USB_TREE="${USB_TREE:-build/usb-tree-root}"

KERNEL_RELEASE=$(cat "$BUILD_DIR/kernel-release.txt")

echo "=== Packaging WDMCH USB rescue artifacts ==="
echo "  Kernel release: $KERNEL_RELEASE"
echo "  USB tree: $USB_TREE (root-level files, NO boot/ subdir)"

mkdir -p "$RELEASE_DIR"

# ---- 1. patch the Image header (vendor U-Boot text_offset requirement) --------
# Keep the pristine unpatched Image so re-runs never double-patch.
if [ ! -s "$BUILD_DIR/Image.unpatched" ]; then
    cp "$BUILD_DIR/Image" "$BUILD_DIR/Image.unpatched"
fi
cp "$BUILD_DIR/Image.unpatched" "$BUILD_DIR/Image"
python3 "$KERNEL_DIR/tools/monarch/patch-header.py" "$BUILD_DIR/Image"

# ---- 2. sata.uImage = raw patched Image + 512 KiB zeros -------------------------
cp "$BUILD_DIR/Image" "$RELEASE_DIR/sata.uImage"
dd if=/dev/zero bs=524288 count=1 >> "$RELEASE_DIR/sata.uImage" 2>/dev/null

echo "Verifying uImage padding..."
FILE_SIZE=$(stat -c '%s' "$RELEASE_DIR/sata.uImage")
KERNEL_SIZE=$(stat -c '%s' "$BUILD_DIR/Image")
PADDING_SIZE=$((FILE_SIZE - KERNEL_SIZE))
echo "  Kernel size: $KERNEL_SIZE"
echo "  Padding: $PADDING_SIZE bytes"
ZERO_BYTES=$(tail -c 524288 "$RELEASE_DIR/sata.uImage" | tr -d '\0' | wc -c)
[ "$ZERO_BYTES" -eq 0 ] || { echo "FAIL: padding contains non-zero bytes" >&2; exit 1; }
echo "sata.uImage packaged (${FILE_SIZE} bytes)"

# ---- 3. DTB ----------------------------------------------------------------------
cp "$BUILD_DIR/rtd1295-wd-mycloud-home.dtb" "$RELEASE_DIR/rescue.sata.dtb"
# `cp` failing aborts the build, but a zero-byte or truncated DTB would have
# been announced as "packaged" all the same.
DTB_SIZE=$(stat -c '%s' "$RELEASE_DIR/rescue.sata.dtb" 2>/dev/null || echo 0)
[ "$DTB_SIZE" -gt 0 ] || { echo "FAIL: rescue.sata.dtb is empty" >&2; exit 1; }
echo "rescue.sata.dtb packaged (${DTB_SIZE} bytes)"

# ---- 4. rescue initramfs (must be exactly 4 MiB; built by build-rootfs.sh) --------
RESCUE_SRC="$BUILD_DIR/rescue.root.sata.cpio.gz_pad.img"
RESCUE_DST="$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img"
RESCUE_SIZE=4194304
if [ ! -f "$RESCUE_SRC" ] || [ "$(stat -c '%s' "$RESCUE_SRC" 2>/dev/null || echo 0)" -eq 0 ]; then
    echo "Building rescue rootfs..."
    bash rootfs/build-rootfs.sh build/rootfs "$KERNEL_RELEASE"
fi
cp "$RESCUE_SRC" "$RESCUE_DST"
CURRENT_SIZE=$(stat -c '%s' "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img")
if [ "$CURRENT_SIZE" -gt "$RESCUE_SIZE" ]; then
    echo "ERROR: rescue rootfs is $CURRENT_SIZE bytes (> 4 MiB fixed budget)" >&2
    exit 1
fi
PAD=$((RESCUE_SIZE - CURRENT_SIZE))
if [ "$PAD" -gt 0 ]; then
    dd if=/dev/zero bs=1 count="$PAD" >> "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img" 2>/dev/null
fi
FINAL_SIZE=$(stat -c '%s' "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img")
[ "$FINAL_SIZE" -eq "$RESCUE_SIZE" ] || { echo "FAIL: rescue rootfs size $FINAL_SIZE != $RESCUE_SIZE" >&2; exit 1; }
echo "rescue.root.sata.cpio.gz_pad.img packaged (${FINAL_SIZE} bytes)"

# ---- 5. checksums + manifest --------------------------------------------------------
( cd "$RELEASE_DIR" && sha256sum sata.uImage rescue.sata.dtb rescue.root.sata.cpio.gz_pad.img > SHA256SUMS )
echo "SHA256SUMS generated"

cat > "$RELEASE_DIR/manifest.json" <<MANIFEST
{
  "device": "WD My Cloud Home single-bay",
  "soc": "Realtek RTD1295",
  "arch": "aarch64",
  "kernel": "Linux $KERNEL_RELEASE",
  "kernel_commit": "$(git -C "$KERNEL_DIR" rev-parse HEAD)",
  "kernel_release": "$KERNEL_RELEASE",
  "dtb": "rtd1295-wd-mycloud-home.dtb",
  "boot_artifacts": [
    "sata.uImage",
    "rescue.sata.dtb",
    "rescue.root.sata.cpio.gz_pad.img"
  ]
}
MANIFEST
echo "manifest.json generated"

# ---- 6. the full USB stick tree: ALL files at root + apks/ (offline Alpine install) ---
echo ""
# ALPINE_ARCH is needed by the repository layout below. Sourced HERE rather than
# at step 7: the layout that needs it is built first, and under `set -u` an
# unsourced $ALPINE_ARCH aborts the build rather than producing a flat repo.
set -a
# shellcheck disable=SC1091
source config/alpine.env
set +a

echo "=== Building USB stick tree ($USB_TREE) ==="
echo "  Structure: ALL boot files at root (NO boot/ directory)"
rm -rf "$USB_TREE"
mkdir -p "$USB_TREE/apks/main" "$USB_TREE/apks/community"

# Boot files at root (NOT in boot/)
cp "$RELEASE_DIR/sata.uImage" "$USB_TREE/"
cp "$RELEASE_DIR/rescue.sata.dtb" "$USB_TREE/"
cp "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img" "$USB_TREE/"
cp "$RELEASE_DIR/SHA256SUMS" "$USB_TREE/"
cp "$RELEASE_DIR/manifest.json" "$USB_TREE/"

# README (UPDATED for root-level structure)
cat > "$USB_TREE/README.txt" <<'READMEEOF'
WDMCH Rescue USB - WD My Cloud Home (RTD1295)
==============================================

IMPORTANT: All files must be copied to the ROOT of a FAT32 USB stick.
NO subdirectories except apks/ (which has apks/main/ and apks/community/).

COPY THESE FILES TO USB STICK ROOT:
  sata.uImage                      patched kernel Image + 512 KiB padding
  rescue.sata.dtb                  device tree
  rescue.root.sata.cpio.gz_pad.img 4 MiB rescue initramfs (SSH inside)
  SHA256SUMS                       checksums
  manifest.json                    metadata
  README.txt                       this file
  apks/                            Alpine package repository (offline install)

VERIFY: after copying, run: sha256sum -c SHA256SUMS

PREPARE THE STICK
  1. Format a USB stick as FAT32 (MBR, single partition)
  2. Copy EVERYTHING from this directory onto the stick ROOT:
     cp -r * /media/<stick>/
  3. Verify: cd /media/<stick> && sha256sum -c SHA256SUMS

BOOT THE BOX
  1. Power off the WD My Cloud Home
  2. Insert the stick into the front USB port
  3. Hold the reset button, power on, keep holding ~10 seconds
  4. The rescue kernel boots; it prints its IP on the serial console
     and announces itself on the network (DHCP)
  5. ssh root@<ip>   (public-key only - the key baked into the image;
     no password login)

INSTALL ALPINE TO THE INTERNAL DISK (offline, no network needed)
  ssh root@<ip>
  install-alpine <disk>        # <disk> is printed in the rescue banner
                               # as "Disk:" - do NOT guess it
  # packages come from apks/ on this stick - no network needed

WHAT install-alpine WRITES
  Exactly two partitions: p20 (SYSTEM_B) + p21 (DATA), formatted as ONE
  btrfs spanning both, label "@ROOT_LABEL@", data profile @BTRFS_DATA_PROFILE@, no md RAID.
  Both are destroyed. Back up p21 first if it holds anything.
  It does NOT create partitions and does NOT modify the partition table.
  Left untouched: p1 (firmware table), the A/B/GOLD firmware slots
  (p2-p17), p18 (CONFIG), p19, and your data in p22/p24.
  A copy of the firmware table is saved to /root/wdmch-fw-table-backup.bin
  on the installed system.

BOOTING THE INSTALLED SYSTEM
  The vendor U-Boot cannot boot from the internal disk - it only reads
  boot files from this stick. So leave the stick plugged in: the rescue
  kernel boots and hands over to the system on p20 automatically.

  To get the RESCUE SHELL instead of the installed system:
      touch norescue         # create this file in the ROOT of the stick

  Optional - boot without the stick after a first successful boot:
      /usr/local/sbin/boot-full-alpine --exec

SAFETY
  - The vendor flash (A/B/GOLD slots) is never touched
  - install-alpine reformats ONE partition (p20) - anything on it is lost
  - Your data partitions (p22 DATA, p24 DISKVOLUME1) are NOT touched
  - To return to stock firmware: remove the USB stick, power cycle
READMEEOF

# The README above states the label and profile the installer will really use.
# Those values were written out by hand, which is how this repository ends up
# documenting a filesystem it does not create. They are substituted from
# install-alpine - the single place they are defined - using explicit markers, so
# the quoted heredoc stays quoted and nothing else in the text is expanded.
_root_label=$(sed -n 's/^ROOT_LABEL="\(.*\)"/\1/p' rootfs/install-alpine | head -1)
_data_profile=$(sed -n 's/^BTRFS_DATA_PROFILE=\(.*\)/\1/p' rootfs/install-alpine | head -1)
if [ -z "$_root_label" ] || [ -z "$_data_profile" ]; then
    echo "ERROR: could not read ROOT_LABEL/BTRFS_DATA_PROFILE from rootfs/install-alpine" >&2
    exit 1
fi
sed -i "s|@ROOT_LABEL@|$_root_label|; s|@BTRFS_DATA_PROFILE@|$_data_profile|" \
    "$USB_TREE/README.txt"
unset _root_label _data_profile
echo "README.txt written"

# ---- 7. Alpine packages (use dl-packages.sh) ----------------------------------------
set -a
# shellcheck disable=SC1091
source config/alpine.env
set +a

echo ""
echo "=== Downloading Alpine packages (via dl-packages.sh) ==="
if bash image/dl-packages.sh; then
    echo "Package download complete"
else
    echo "ERROR: package download failed — log follows:" >&2
    cat build/dl-packages.log >&2 || true
    exit 1
fi

# ---- lay the offline repository out the way apk.static requires -------------
# apk opens <repo>/<arch>/APKINDEX.tar.gz and has NO fallback to
# <repo>/APKINDEX.tar.gz. Proven by strace on the shipped apk.static under qemu:
#
#     openat(AT_FDCWD, "<repo>/aarch64/APKINDEX.tar.gz") = -1 ENOENT
#
# The download stages these FLAT (apks/main/*.apk), which is what a human would
# guess. On the stick, that layout means apk finds nothing and every install
# dies with "e2fsprogs (no such package)" - after the image was reported
# complete and after every artifact check passed.
#
# The flat tree stays as the staging area; the stick gets apk's layout.
# No copy step: image/dl-packages.sh already lays both repositories out at
# apks/<repo>/<arch>/, which is exactly what apk.static opens. An earlier attempt
# copied a flat tree into the arch level here, but USB_TREE *is* the staging
# tree, so `cp` was copying a directory into itself and failing the build.
mkdir -p "$USB_TREE/apks/main/$ALPINE_ARCH" "$USB_TREE/apks/community/$ALPINE_ARCH"

# APKINDEX fallback, now into the arch directory apk actually reads
if [ ! -f "$USB_TREE/apks/main/$ALPINE_ARCH/APKINDEX.tar.gz" ]; then
    cp ".work/apk-cache-offline/main-APKINDEX.tar.gz" \
       "$USB_TREE/apks/main/$ALPINE_ARCH/APKINDEX.tar.gz" 2>/dev/null || true
fi
if [ ! -f "$USB_TREE/apks/community/$ALPINE_ARCH/APKINDEX.tar.gz" ]; then
    cp ".work/apk-cache-offline/community-APKINDEX.tar.gz" \
       "$USB_TREE/apks/community/$ALPINE_ARCH/APKINDEX.tar.gz" 2>/dev/null || true
fi

# Fail here rather than ship a stick whose offline repo cannot be opened. This
# is the defect above, guarded: the layout is now asserted, so a future change
# that flattens it again fails the build instead of every install.
for repo in main community; do
    idx="$USB_TREE/apks/$repo/$ALPINE_ARCH/APKINDEX.tar.gz"
    if [ ! -s "$idx" ]; then
        echo "ERROR: $idx missing - apk.static cannot open this repository." >&2
        echo "       It requires <repo>/<arch>/APKINDEX.tar.gz; the flat layout" >&2
        echo "       it used to ship silently yields 'no such package' on the" >&2
        echo "       WDMCH, after this image reported itself complete." >&2
        exit 1
    fi
done

echo ""
echo "=== USB tree ready: $USB_TREE ==="
echo ""
echo "Files at USB stick root (copy these to FAT32 stick):"
find "$USB_TREE" -maxdepth 2 -type f | sort | while read -r f; do echo "  $f ($(du -h "$f" | cut -f1))"; done
echo ""
echo "To copy to USB stick:"
echo "  mount /dev/sdX1 /mnt && cp -r $USB_TREE/* /mnt/ && sync"
echo ""
echo "Artifact packaging complete."

# ---- 8. flash.zip at build/flash.zip (for test-flash.sh) --------------------------
PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Rebuild the archive from scratch. `zip -r` against an existing flash.zip
# only ADDS and updates entries - it never removes one, so anything deleted
# from the stick tree (a pruned stale apk, a renamed artifact) would survive
# in the published release indefinitely. CI starts from a clean checkout so
# the releases looked correct while a local flash.zip silently accumulated
# packages that were not in the closure.
rm -f "$PROJ_DIR/build/flash.zip"
( cd "$USB_TREE" && zip -r -q "$PROJ_DIR/build/flash.zip" . )
# flash.zip is the delivery vehicle, and "created" used to mean only that zip
# exited 0. An empty or near-empty archive would have been announced as a
# finished stick. Check it carries what the stick needs to boot.
ZIP_PATH="$PROJ_DIR/build/flash.zip"
ZIP_SIZE=$(stat -c '%s' "$ZIP_PATH" 2>/dev/null || echo 0)
[ "$ZIP_SIZE" -gt 0 ] || { echo "FAIL: flash.zip is empty" >&2; exit 1; }
# Capture the listing once. Piping it into `grep -q` is a trap here: grep
# exits on the first match, the upstream awk takes SIGPIPE, and under
# `set -o pipefail` the whole pipeline returns 141 even though the entry IS
# present - so a good archive would be reported as broken. Same bug class as
# the `grep -x` SIGPIPE fix earlier in this project.
ZIP_LISTING=$(unzip -l "$ZIP_PATH" 2>/dev/null | awk '{print $4}')
for required in sata.uImage rescue.sata.dtb rescue.root.sata.cpio.gz_pad.img \
                SHA256SUMS manifest.json README.txt; do
    # A here-string, not a pipe. `printf ... | grep -q` would still SIGPIPE:
    # grep exits on the first match, printf takes the signal, and pipefail
    # turns a present entry into exit 141 and a false "missing" report.
    if ! grep -qxF "$required" <<< "$ZIP_LISTING"; then
        echo "FAIL: flash.zip is missing $required" >&2
        exit 1
    fi
done
echo "flash.zip created at build/flash.zip (${ZIP_SIZE} bytes, 6 required entries present)"
