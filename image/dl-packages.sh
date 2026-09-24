#!/usr/bin/env bash
# Robust Alpine APK download for USB rescue stick
# Log: build/dl-packages.log  |  stdout: progress + result
# Idempotent, --dry-run supported, trap cleanup on exit/err/int
set -euo pipefail

LOG="build/dl-packages.log"

# --- helpers ---
log() { echo "$@" | tee -a "$LOG"; }
log_stderr() { echo "$@" >&2 | tee -a "$LOG" >&2; }

cleanup() {
    local rc=$?
    if [ -f /tmp/dl-packages.lock ]; then rm -f /tmp/dl-packages.lock; fi
    exit $rc
}
trap cleanup EXIT ERR INT

# --- parse args ---
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        --help|-h)
            echo "Usage: $0 [--dry-run]"
            echo "  --dry-run  print what would be done without downloading"
            exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

cd /home/dominicusin/src/alpine-wdmch-builder
# shellcheck disable=SC1091
source config/alpine.env

MAIN_URL="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}/v${ALPINE_VERSION}/main/${ALPINE_ARCH}"
COMMUNITY_URL="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}/v${ALPINE_VERSION}/community/${ALPINE_ARCH}"
MAIN_INDEX=".work/apk-cache-offline/main-APKINDEX.tar.gz"
COMM_INDEX=".work/apk-cache-offline/community-APKINDEX.tar.gz"
MAIN_DIR="build/usb-tree-root/apks/main"
COMM_DIR="build/usb-tree-root/apks/community"

[ -d "$MAIN_DIR" ] || mkdir -p "$MAIN_DIR"
[ -d "$COMM_DIR" ] || mkdir -p "$COMM_DIR"

# --- version resolver ---
get_version() {
    local pkg="$1" idx="$2"
    tar xzOf "$idx" APKINDEX 2>/dev/null | awk -v p="$pkg" '
        $0=="P:"p { f=1 }
        f && /^V:/ { print substr($0,3); exit }
    '
}

# --- download one package ---
download_pkg() {
    local pkg="$1" ver="$2" url="$3" dest="$4"
    local file="$pkg-$ver.apk"
    if [ -s "$dest/$file" ]; then
        log "[SKIP] $file (already present, $(stat -c%s "$dest/$file") B)"
        return 0
    fi
    log -n "DL $file ... "
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[DRY-RUN] would download $url/$file"
        return 0
    fi
    if curl -fsSL "$url/$file" -o "$dest/$file" 2>/dev/null; then
        log "OK ($(stat -c%s "$dest/$file") B)"
        return 0
    else
        log "FAIL"
        return 1
    fi
}

# --- main ---
log "=== dl-packages.sh started at $(date) ==="
log "MAIN_URL=$MAIN_URL"
log "COMMUNITY_URL=$COMMUNITY_URL"
log "MAIN_INDEX=$MAIN_INDEX"
log "COMM_INDEX=$COMM_INDEX"
log "MAIN_DIR=$MAIN_DIR"
log "COMM_DIR=$COMM_DIR"
log "DRY_RUN=$DRY_RUN"
log ""

if [ ! -f "$MAIN_INDEX" ]; then
    log "ERROR: $MAIN_INDEX not found. Run resolve-deps.py first."
    exit 1
fi
if [ ! -f "$COMM_INDEX" ]; then
    log "ERROR: $COMM_INDEX not found. Run resolve-deps.py first."
    exit 1
fi

OK=0
FAIL=0
NEVER=0

PKGS_MAIN=(
    alpine-base alpine-baselayout alpine-baselayout-data alpine-conf
    alpine-keys alpine-release apk-tools busybox busybox-mdev-openrc
    busybox-openrc busybox-suid ca-certificates-bundle chrony dhcpcd-openrc
    dropbear e2fsprogs musl musl-utils openrc openssl scanelf tzdata util-linux
)
PKGS_COMM=(kexec-tools)

log "=== Downloading ${#PKGS_MAIN[@]} main + ${#PKGS_COMM[@]} community packages ==="
log ""

for pkg in "${PKGS_MAIN[@]}"; do
    ver=$(get_version "$pkg" "$MAIN_INDEX" || true)
    if [ -z "$ver" ]; then
        log "[NOVER] $pkg — no version in APKINDEX"
        NEVER=$((NEVER+1))
        continue
    fi
    if download_pkg "$pkg" "$ver" "$MAIN_URL" "$MAIN_DIR"; then
        OK=$((OK+1))
    else
        FAIL=$((FAIL+1))
    fi
done

log ""
log "=== Community packages ==="
for pkg in "${PKGS_COMM[@]}"; do
    ver=$(get_version "$pkg" "$COMM_INDEX" || get_version "$pkg" "$MAIN_INDEX" || true)
    if [ -z "$ver" ]; then
        log "[NOVER] $pkg — no version in APKINDEX"
        NEVER=$((NEVER+1))
        continue
    fi
    if [ -n "$(get_version "$pkg" "$COMM_INDEX" 2>/dev/null || true)" ]; then
        url="$COMMUNITY_URL"; dir="$COMM_DIR"
    else
        url="$MAIN_URL"; dir="$MAIN_DIR"
    fi
    if download_pkg "$pkg" "$ver" "$url" "$dir"; then
        OK=$((OK+1))
    else
        FAIL=$((FAIL+1))
    fi
done

log ""
log "=== Copying APKINDEX files ==="
cp "$MAIN_INDEX" "$MAIN_DIR/APKINDEX.tar.gz"
cp "$COMM_INDEX" "$COMM_DIR/APKINDEX.tar.gz"
log "Copied main and community APKINDEX to USB tree."

log ""
log "=== FINAL RESULT ==="
log "OK=$OK  FAIL=$FAIL  NOVER=$NEVER"
log ""

log "=== APK files on USB tree ==="
find "$MAIN_DIR" "$COMM_DIR" -name '*.apk' -exec basename {} \; | sort
log ""

log "=== Full USB tree ==="
find build/usb-tree-root -type f | sort
log ""

apk_size=$(du -sh build/usb-tree-root/apks/ 2>/dev/null | cut -f1 || echo "N/A")
log "APK repo size: $apk_size"
log ""
log "=== dl-packages.sh finished at $(date) ==="
