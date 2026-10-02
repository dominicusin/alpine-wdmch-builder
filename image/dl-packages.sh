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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJ_DIR"
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

# The cached index can outlive the packages it names. Alpine supersedes a
# package and prunes the old file from the CDN mirror, but this cache is only
# refreshed when absent - so a checkout that last built weeks ago resolves
# libssl3-3.3.7-r1 from its own index and then gets a 404 for it from the live
# mirror, and the build fails on a package that exists in neither place at once.
# Hit while rebuilding locally: the cached index was from 2026-09-22 and libssl3
# had moved on.
#
# `make clean-cache` drops it. A long-lived checkout should do the same before a
# release build, because CI always fetches fresh and would not reproduce it.
if [ ! -f "$MAIN_INDEX" ]; then
    log "APKINDEX (main) not cached — downloading..."
    mkdir -p "$(dirname "$MAIN_INDEX")"
    curl -fsSL "$MAIN_URL/APKINDEX.tar.gz" -o "$MAIN_INDEX" || { log "ERROR: cannot download main APKINDEX"; exit 1; }
fi
if [ ! -f "$COMM_INDEX" ]; then
    log "APKINDEX (community) not cached — downloading..."
    mkdir -p "$(dirname "$COMM_INDEX")"
    curl -fsSL "$COMMUNITY_URL/APKINDEX.tar.gz" -o "$COMM_INDEX" || { log "ERROR: cannot download community APKINDEX"; exit 1; }
fi

OK=0
FAIL=0
NEVER=0

# Seed packages. Everything else on the stick is derived from these by
# image/resolve-deps.py - there is deliberately NO hand-maintained package
# list. A hardcoded list is what let e2fsprogs reach the stick without
# e2fsprogs-libs, libblkid, libuuid and libcom_err, so mke2fs could not run
# and install-alpine died at the first filesystem command.
#
# openrc-init and ifupdown-ng are NOT optional extras - a full offline install
# of alpine-base alone yields NO /sbin/init (nothing can be booted or handed
# over to) and NO /sbin/ifup (the `networking` service has nothing to call).
# busybox-ifupdown, which the resolver reaches through the ifupdown-any
# virtual, is a 1.2 KB placeholder package that ships no binaries at all.
# btrfs-progs is required now: install-alpine creates ONE btrfs across p20
# and p21, and mkfs.btrfs is not in busybox. It is unpacked from this offline
# repo at install time, exactly as e2fsprogs is. Omitting it here would
# have produced a stick that cannot create the filesystem it exists for.
SEEDS=(alpine-base openrc-init ifupdown-ng dropbear e2fsprogs kexec-tools btrfs-progs)

log "=== Resolving dependency closure for: ${SEEDS[*]} ==="
CLOSURE=$(python3 image/resolve-deps.py --tsv \
              --main "$MAIN_INDEX" \
              --community "$COMM_INDEX" \
              "${SEEDS[@]}" 2>"$LOG.resolve-err" | sort)
RC=$?
if [ $RC -ne 0 ] || [ -z "$CLOSURE" ]; then
    log "ERROR: dependency resolution failed (rc=$RC)"
    cat "$LOG.resolve-err" >&2 2>/dev/null || true
    exit 1
fi
if [ -s "$LOG.resolve-err" ]; then
    # The resolver exits non-zero for every failure it knows about, so any
    # stderr with rc=0 is a diagnostic nobody anticipated. It is fatal rather
    # than a warning: the previous version downgraded unresolved packages to
    # a warning, which is how a stick got built with a missing library and
    # apk add failed on the WDMCH after the disk was already being written.
    # Silence from the resolver is the contract; anything on stderr breaks it.
    log "ERROR: resolver wrote to stderr but exited 0 - treating as failure:"
    sed 's/^/    /' "$LOG.resolve-err"
    log "    the offline repo would be INCOMPLETE - the install would fail."
    exit 1
fi
rm -f "$LOG.resolve-err"

n_closure=$(echo "$CLOSURE" | wc -l)
log "Closure resolved: $n_closure packages"
log ""

# Prune anything left over from a previous run BEFORE downloading.
#
# The USB tree is a persistent directory, so changing the seed set used to
# leave the old packages sitting next to the new ones. A local build then
# carried packages that are not in the closure - and therefore not in any CI
# release - so the stick stopped matching the published artifact and nothing
# reported it. CI starts from a clean checkout, which is why the releases
# looked right while local builds silently drifted.
log "Pruning packages not in the closure ..."
KEEP=$(mktemp)
trap 'rm -f "$KEEP"' EXIT
echo "$CLOSURE" | cut -f4 | sed 's|.*/||' | sort -u > "$KEEP"
stale=0
for d in "$MAIN_DIR" "$COMM_DIR"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.apk; do
        [ -e "$f" ] || continue
        b=$(basename "$f")
        grep -qxF "$b" "$KEEP" || { rm -f "$f"; stale=$((stale + 1)); }
    done
done
if [ "$stale" -gt 0 ]; then
    log "  removed $stale stale package(s) from a previous run"
else
    log "  nothing stale"
fi
log ""

# TSV: repo <TAB> name <TAB> version <TAB> filename. The repo comes from the
# resolver, so no name has to be recovered from a filename here.
while IFS=$'\t' read -r repo pkg ver file; do
    [ -n "$file" ] || continue
    if [ "$repo" = "community" ]; then
        url="$COMMUNITY_URL"; dir="$COMM_DIR"
    else
        url="$MAIN_URL"; dir="$MAIN_DIR"
    fi
    if download_pkg "$pkg" "$ver" "$url" "$dir"; then
        OK=$((OK + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done <<< "$CLOSURE"

if [ "$FAIL" -ne 0 ]; then
    log ""
    log "ERROR: $FAIL package(s) failed to download - the offline repo is incomplete."
    log "       Refusing to produce a stick that cannot complete an install."
    exit 1
fi

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
