#!/bin/bash
# test_apk_layout.sh - the offline repo must have the layout apk.static opens.
#
# Found by running the installer's own apk command against the real stick tree
# under qemu. It failed on every package:
#
#     WARNING: opening file:///.../apks/main: No such file or directory
#     ERROR: unable to select packages: e2fsprogs (no such package)
#
# which reads like a missing package and is not. strace showed why:
#
#     openat(AT_FDCWD, "<repo>/aarch64/APKINDEX.tar.gz") = -1 ENOENT
#
# apk requires <repo>/<arch>/APKINDEX.tar.gz and has NO fallback to
# <repo>/APKINDEX.tar.gz. The stick shipped a FLAT apks/main/ - the shape a
# human would guess, and the shape most offline-repo examples use. Every install
# would have failed on the WDMCH, after the image reported itself complete and
# after every artifact check passed.
#
# Nothing could have caught this: the flash.zip contents were correct, the
# closure was correct, the checksums were correct. The packages were simply in a
# directory apk does not look in.
#
# This test has two halves. The first is static and cheap - the layout, which
# runs everywhere. The second EXECUTES the shipped apk.static under qemu against
# the real tree, which is what actually proves it, and skips loudly when the
# host cannot do it rather than passing quietly.
set -u
cd "$(dirname "$0")/.." || exit 1
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }

echo "=== the offline repo has the layout apk.static actually opens ==="

ARCH=$(sed -n 's/^ALPINE_ARCH=//p' config/alpine.env | head -1)
[ -n "$ARCH" ] || { echo "FAIL: ALPINE_ARCH not set in config/alpine.env" >&2; exit 1; }
echo "  (architecture: $ARCH)"

# --- 1. the layout, statically ------------------------------------------------
for repo in main community; do
    base="build/usb-tree-root/apks/$repo"
    if [ ! -d "$base" ]; then
        echo "  (offline repo not built - run 'make package' for the dynamic check)"
        break
    fi
    check "apks/$repo/$ARCH/ exists" "$([ -d "$base/$ARCH" ] && echo 0 || echo 1)"
    check "  ...and holds APKINDEX.tar.gz" \
          "$([ -s "$base/$ARCH/APKINDEX.tar.gz" ] && echo 0 || echo 1)"
    check "  ...and holds packages" \
          "$([ -n "$(ls "$base/$ARCH"/*.apk 2>/dev/null | head -1)" ] && echo 0 || echo 1)"

    # The flat layout is the defect. If a top-level APKINDEX reappears, apk will
    # ignore it and the install will fail exactly as it did.
    check "  ...and NO flat APKINDEX (the shape that broke every install)" \
          "$([ ! -e "$base/APKINDEX.tar.gz" ] && echo 0 || echo 1)"
done

# The installer points apk at the REPO ROOT; apk appends <arch>/ itself. If the
# installer ever changed to pass a deeper path, this would double the level.
check "the installer passes the repository root, not the arch level" \
      "$(grep -q 'repository "file://\$APKS_DIR/main"' rootfs/install-alpine && echo 0 || echo 1)"
check "  ...for both repositories" \
      "$(grep -q 'repository "file://\$APKS_DIR/community"' rootfs/install-alpine && echo 0 || echo 1)"

# The layout is defined once, in the download step. A second definition in
# package-rescue.sh is a second thing to drift - and the first attempt at this
# fix was exactly that, which failed by copying a directory into itself because
# USB_TREE *is* the staging tree.
check "the layout is defined in dl-packages.sh, not duplicated in package-rescue.sh" \
      "$(grep -q 'apks/main/\${ALPINE_ARCH}' image/dl-packages.sh && echo 0 || echo 1)"
check "  ...and package-rescue.sh does not copy the repo into itself" \
      "$(grep -q 'cp -a .*usb-tree-root/apks' image/package-rescue.sh && echo 1 || echo 0)"

# --- 2. apk.static actually opening it ---------------------------------------
APK=build/rootfs/sbin/apk.static
if [ ! -x "$APK" ]; then
    echo "  (apk.static not built - skipping the dynamic check)"
elif ! command -v qemu-aarch64 >/dev/null 2>&1; then
    echo "  (qemu-aarch64 not present - skipping the dynamic check)"
else
    W=$(mktemp -d); mkdir -p "$W/t"
    R="$PWD/build/usb-tree-root/apks"
    if [ ! -d "$R/main/$ARCH" ]; then
        echo "  (offline repo not built - skipping the dynamic check)"
    else
        out=$(qemu-aarch64 -L "$PWD/build/rootfs" "$APK" \
                add --root "$W/t" --initdb \
                --repository "file://$R/main" \
                --repository "file://$R/community" \
                --keys-dir "$PWD/build/rootfs/etc/apk/keys" \
                --no-cache --no-scripts e2fsprogs 2>&1)
        # The property: the packages RESOLVE. Permission and chroot errors are
        # an artefact of running as an unprivileged user and say nothing about
        # the layout, so they are not what this checks.
        got=$(printf '%s' "$out" | grep -cE 'Installing e2fsprogs ')
        check "apk.static resolves packages from the shipped tree" \
              "$([ "${got:-0}" -ge 1 ] && echo 0 || echo 1)"
        check "  ...and does not report 'no such package'" \
              "$(printf '%s' "$out" | grep -q 'no such package' && echo 1 || echo 0)"
        check "  ...and mke2fs actually landed" \
              "$([ -e "$W/t/sbin/mke2fs" ] && echo 0 || echo 1)"
        rm -rf "$W"
    fi
fi

# --- 3. the TREE is complete, not merely present --------------------------------
# `[ -d build/usb-tree-root ]` cannot tell "never built" from "half destroyed".
# During this work an `rm -rf build/usb-tree-root` followed by a bare
# dl-packages.sh left a tree that EXISTED and had the repositories but none of
# the boot files, and three tests reported it as damaged rather than as the thing
# they needed. The set below is the one tools/prepare-usb.sh itself requires, so
# the check and the consumer cannot drift.
TREE=build/usb-tree-root
if [ -d "$TREE" ]; then
    missing=""
    for f in sata.uImage rescue.sata.dtb rescue.root.sata.cpio.gz_pad.img \
             SHA256SUMS manifest.json README.txt; do
        [ -s "$TREE/$f" ] || missing="$missing $f"
    done
    check "the build tree carries every boot file prepare-usb.sh requires" \
          "$([ -z "$missing" ] && echo 0 || echo 1)"
    if [ -n "$missing" ]; then
        echo "      missing:$missing"
        echo "      the tree is PARTLY built - 'make package' completes it."
        echo "      A test that only asks whether the directory exists cannot tell"
        echo "      this apart from a tree that was never built."
    fi
fi

# --- 4. the SHIPPED artifact, which is what the operator actually gets -------
# The build tree and flash.zip are different things. A layout correct in build/
# and flattened in the archive would pass everything above and still break every
# install. So this reads the zip itself, the way an operator does.
ZIP=build/flash.zip
if [ ! -s "$ZIP" ]; then
    echo "  (flash.zip not built - skipping the artifact check)"
else
    check "flash.zip exists" "0"
    n_arch=$(unzip -l "$ZIP" 2>/dev/null | grep -cE 'apks/(main|community)/[a-z0-9_]+/.*\.apk$')
    check "  ...its packages sit under apks/<repo>/<arch>/" \
          "$([ "${n_arch:-0}" -gt 0 ] && echo 0 || echo 1)"
    n_flat=$(unzip -l "$ZIP" 2>/dev/null | grep -cE 'apks/(main|community)/[^/]+\.apk$')
    check "  ...and NO packages are flat (the shape that broke every install)" \
          "$([ "${n_flat:-0}" -eq 0 ] && echo 0 || echo 1)"
    n_idx=$(unzip -l "$ZIP" 2>/dev/null | grep -cE 'apks/(main|community)/[a-z0-9_]+/APKINDEX')
    check "  ...both APKINDEX files are under the arch level too" \
          "$([ "${n_idx:-0}" -eq 2 ] && echo 0 || echo 1)"
    echo "  ($n_arch packages under the arch level, $n_idx indexes, $n_flat flat)"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "apk layout: PASSED"
else
    echo "apk layout: FAILED ($FAILED)" >&2
    exit 1
fi