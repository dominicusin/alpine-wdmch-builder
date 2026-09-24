#!/usr/bin/env bash
set -euo pipefail

cd /home/dominicusin/src/alpine-wdmch-builder
source config/alpine.env

ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
MAIN_URL="$ALPINE_MIRROR/v$ALPINE_VERSION/main/$ALPINE_ARCH"
COMMUNITY_URL="$ALPINE_MIRROR/v$ALPINE_VERSION/community/$ALPINE_ARCH"
APK_DIR="build/usb-tree/apks"
MAIN_DIR="$APK_DIR/main"
COMMUNITY_DIR="$APK_DIR/community"
mkdir -p "$MAIN_DIR" "$COMMUNITY_DIR"

MAIN_INDEX=".work/apk-cache-offline/main-APKINDEX.tar.gz"
COMMUNITY_INDEX=".work/apk-cache-offline/community-APKINDEX.tar.gz"

get_version() {
    local pkg="$1" index="$2"
    tar xzOf "$index" APKINDEX 2>/dev/null | awk -v p="$pkg" '
        $0 == "P:"p { found=1 }
        found && /^V:/ { print substr($0,3); exit }
    '
}

download_pkg() {
    local pkg="$1" ver="$2" url="$3" dest_dir="$4"
    local file="$pkg-$ver.apk"
    if [ -s "$dest_dir/$file" ]; then
        echo "  [cached] $file"
        return 0
    fi
    echo -n "  downloading $file ... "
    if curl -fsSL "$url/$file" -o "$dest_dir/$file" 2>/dev/null; then
        echo "OK ($(stat -c%s "$dest_dir/$file") bytes)"
        return 0
    else
        echo "FAIL"
        return 1
    fi
}

PACKAGES_MAIN=(
    alpine-base alpine-baselayout alpine-baselayout-data alpine-conf
    alpine-keys alpine-release apk-tools busybox busybox-mdev-openrc
    busybox-openrc busybox-suid ca-certificates-bundle chrony dhcpcd-openrc
    dropbear e2fsprogs musl musl-utils openrc openssl scanelf tzdata util-linux
)

PACKAGES_COMMUNITY=(
    kexec-tools
)

echo "=== Downloading Alpine packages (v$ALPINE_VERSION $ALPINE_ARCH) ==="
TOTAL=0
OK=0
FAIL=0

for pkg in "${PACKAGES_MAIN[@]}"; do
    TOTAL=$((TOTAL + 1))
    ver=$(get_version "$pkg" "$MAIN_INDEX")
    if [ -z "$ver" ]; then
        echo "  [WARN] no version for $pkg in main"
        FAIL=$((FAIL + 1))
        continue
    fi
    if download_pkg "$pkg" "$ver" "$MAIN_URL" "$MAIN_DIR"; then
        OK=$((OK + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

for pkg in "${PACKAGES_COMMUNITY[@]}"; do
    TOTAL=$((TOTAL + 1))
    ver=$(get_version "$pkg" "$COMMUNITY_INDEX")
    if [ -z "$ver" ]; then
        # try main as fallback
        ver=$(get_version "$pkg" "$MAIN_INDEX")
        url="$MAIN_URL"
        dest_dir="$MAIN_DIR"
    else
        url="$COMMUNITY_URL"
        dest_dir="$COMMUNITY_DIR"
    fi
    if [ -z "$ver" ]; then
        echo "  [WARN] no version for $pkg anywhere"
        FAIL=$((FAIL + 1))
        continue
    fi
    if download_pkg "$pkg" "$ver" "$url" "$dest_dir"; then
        OK=$((OK + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "=== Result: $OK OK, $FAIL failed (из $TOTAL) ==="
echo "=== APK count: main=$(find "$MAIN_DIR" -name '*.apk' | wc -l) community=$(find "$COMMUNITY_DIR" -name '*.apk' | wc -l) ==="
echo ""
echo "=== package list ==="
find "$MAIN_DIR" "$COMMUNITY_DIR" -name '*.apk' -exec basename {} \; | sort
echo ""
echo "=== copying APKINDEX files ==="
cp "$MAIN_INDEX" "$MAIN_DIR/APKINDEX.tar.gz"
cp "$COMMUNITY_INDEX" "$COMMUNITY_DIR/APKINDEX.tar.gz"
echo ""
echo "=== final USB tree ==="
find "$APK_DIR" -type f | sort
