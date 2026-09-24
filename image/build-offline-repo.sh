#!/usr/bin/env bash
# Build offline Alpine package repository for USB installation stick.
# Downloads APKINDEX and all packages needed for a minimal Alpine system
# that can be installed on the WD My Cloud Home without network access.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${1:-build/usb-tree/apks}"

source "$SCRIPT_DIR/../config/alpine.env"

ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
MAIN_URL="$ALPINE_MIRROR/v$ALPINE_VERSION/main/$ALPINE_ARCH"
COMMUNITY_URL="$ALPINE_MIRROR/v$ALPINE_VERSION/community/$ALPINE_ARCH"

APK_CACHE=".work/apk-cache-offline"
mkdir -p "$APK_CACHE" "$REPO_DIR/main" "$REPO_DIR/community"

echo "=== Building offline Alpine package repository ==="
echo "Alpine version: $ALPINE_VERSION-$ALPINE_ARCH"
echo "Repo dir: $REPO_DIR"

# ---- download APKINDEX --------------------------------------------------------
echo "Downloading APKINDEX files..."
curl -fsSL "$MAIN_URL/APKINDEX.tar.gz" -o "$APK_CACHE/main-APKINDEX.tar.gz"
curl -fsSL "$COMMUNITY_URL/APKINDEX.tar.gz" -o "$APK_CACHE/community-APKINDEX.tar.gz"
cp "$APK_CACHE/main-APKINDEX.tar.gz" "$REPO_DIR/main/APKINDEX.tar.gz"
cp "$APK_CACHE/community-APKINDEX.tar.gz" "$REPO_DIR/community/APKINDEX.tar.gz"

# ---- resolve dependency closure -----------------------------------------------
echo "Resolving dependency closure..."

python3 "$SCRIPT_DIR/resolve-deps.py" \
    --main "$APK_CACHE/main-APKINDEX.tar.gz" \
    --community "$APK_CACHE/community-APKINDEX.tar.gz" \
    alpine-base e2fsprogs dropbear dhcpcd-openrc chrony kexec-tools \
    util-linux openssl ca-certificates-bundle tzdata \
    > "$APK_CACHE/closure.txt" 2>&1

if [ -s "$APK_CACHE/closure-fail.txt" ]; then
    echo "WARNING: some packages not found:"
    cat "$APK_CACHE/closure-fail.txt"
fi

echo "Packages to download:"
TOTAL=0
while IFS= read -r pkgfile; do
    [[ "$pkgfile" == *.apk ]] && TOTAL=$((TOTAL + 1))
done < "$APK_CACHE/closure.txt"
echo "  $TOTAL packages"

# ---- download packages --------------------------------------------------------
echo "Downloading packages..."
while IFS= read -r pkgfile; do
    [ -z "$pkgfile" ] && continue
    # Determine repo by trying main first, then community
    if [ -s "$APK_CACHE/$pkgfile" ]; then
        cp "$APK_CACHE/$pkgfile" "$REPO_DIR/main/"
        echo "  main/$pkgfile (cached)"
        continue
    fi
    if curl -fsSL "$MAIN_URL/$pkgfile" -o "$APK_CACHE/$pkgfile" 2>/dev/null; then
        cp "$APK_CACHE/$pkgfile" "$REPO_DIR/main/"
        echo "  main/$pkgfile"
    elif curl -fsSL "$COMMUNITY_URL/$pkgfile" -o "$APK_CACHE/$pkgfile" 2>/dev/null; then
        cp "$APK_CACHE/$pkgfile" "$REPO_DIR/community/"
        echo "  community/$pkgfile"
    else
        echo "  WARN: could not download $pkgfile"
    fi
done < "$APK_CACHE/closure.txt"

# ---- summary -------------------------------------------------------------------
TOTAL_SIZE=$(du -sh "$REPO_DIR" | cut -f1)
echo ""
echo "=== Offline repository ready ==="
echo "Total size: $TOTAL_SIZE"
echo "Location: $REPO_DIR"
echo ""
echo "To use: copy the entire apks/ directory to the USB stick"
echo "        alongside boot/ (sata.uImage, rescue.sata.dtb, etc.)"
