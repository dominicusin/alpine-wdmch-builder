#!/usr/bin/env bash
# Automate WDMCH rescue image releases.
#
# Usage:
#   ./scripts/release.sh            # Create a new release from current commit
#   ./scripts/release.sh --dry-run  # Validate build + tests without publishing
#   ./scripts/release.sh --tag v1.0 # Use a specific tag
#
# Requirements:
#   - gh CLI authenticated (gh auth login)
#   - GITHUB_TOKEN or GH_TOKEN env var with repo write access
#   - Working tree must be clean
#   - WDMCH_SSH_AUTHORIZED_KEY must be set as a GitHub secret
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJ_DIR"

TAG=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --tag*)     TAG="${1#--tag}"; shift ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ---- validate preconditions --------------------------------------------
echo "=== Release preconditions ==="

if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh CLI not authenticated. Run 'gh auth login'." >&2
    exit 1
fi

if [ -z "$(git status --porcelain)" ]; then
    echo "Working tree clean: OK"
else
    echo "ERROR: Working tree not clean. Commit or stash changes first." >&2
    git status --short >&2
    exit 1
fi

if [ -z "$TAG" ]; then
    # Derive tag from VERSION file or commit count
    VERSION=$(cat VERSION 2>/dev/null || echo "0.1.0-dev")
    COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    TAG="v${VERSION}-${COMMITS}"
    echo "Derived tag: $TAG"
fi

# Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists. Using --force to overwrite."
fi

# ---- verify SSH key secret exists ----------------------------------------
echo ""
echo "=== Checking secrets ==="
if gh secret list 2>/dev/null | grep -q 'WDMCH_SSH_AUTHORIZED_KEY'; then
    echo "WDMCH_SSH_AUTHORIZED_KEY secret: found"
else
    echo "ERROR: WDMCH_SSH_AUTHORIZED_KEY secret not set." >&2
    echo "Run: gh secret set WDMCH_SSH_AUTHORIZED_KEY < ~/.ssh/id_ed25519.pub" >&2
    exit 1
fi

# ---- build the image -----------------------------------------------------
echo ""
echo "=== Building WDMCH rescue image ==="
echo "This will take ~30 minutes (kernel cross-compilation)."

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: skipping full build, validating configuration only."
    ./build-image.sh --help
    ./build-image.sh --dry-run
else
    ./build-image.sh --clean
    ./build-image.sh
fi

# ---- verify artifacts ----------------------------------------------------
echo ""
echo "=== Verifying artifacts ==="

# Check kernel header
python3 -c "
import struct
d = open('build/kernel/Image','rb').read(32)
code0 = struct.unpack('<I', d[0:4])[0]
text_off = struct.unpack('<I', d[8:12])[0]
assert code0 == 0x91005A4D, f'code0 mismatch: 0x{code0:08x}'
assert text_off == 0x200000, f'text_offset mismatch: 0x{text_off:08x}'
print(f'Kernel header OK: code0=0x{code0:08x} text_offset=0x{text_off:08x}')
"

# Check initramfs size
IMGSZ=$(stat -c%s build/kernel/rescue.root.sata.cpio.gz_pad.img)
[ "$IMGSZ" -eq 4194304 ] || { echo "ERROR: initramfs size $IMGSZ != 4194304"; exit 1; }
echo "Initramfs: 4 MiB OK ($IMGSZ bytes)"

# Check DTB
python3 -c "
d = open('build/kernel/rtd1295-wd-mycloud-home.dtb','rb').read(4)
magic = int.from_bytes(d,'big')
assert magic == 0xd00dfeed, f'FDT magic mismatch: 0x{magic:08x}'
print('DTB magic OK')
"

# Check flash.zip has packages
APK_COUNT=$(unzip -l build/flash.zip | grep -c '\.apk$' || true)
[ "$APK_COUNT" -ge 20 ] || { echo "ERROR: only $APK_COUNT APK packages in flash.zip (need >= 20)"; exit 1; }
echo "Flash.zip has $APK_COUNT APK packages: OK"

echo ""
echo "All artifact checks passed."

# ---- create the release --------------------------------------------------
echo ""
echo "=== Creating release $TAG ==="

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: would create release $TAG with:"
    echo "  - alpine-wdmch-rescue-*-flash.zip"
    echo "  - SHA256SUMS"
    echo "  - manifest.json"
    echo ""
    echo "Release created successfully (dry run)."
    exit 0
fi

# Create the tag on the remote
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
    git tag -a "$TAG" -m "WDMCH Rescue Image $TAG

Automated release created by scripts/release.sh"
    git push origin "$TAG"
    echo "Tag $TAG pushed to remote."
fi

# Wait for the CI workflow triggered by the tag to complete
echo "Waiting for CI build to complete..."
RUN_ID=$(gh api repos/dominicusin/alpine-wdmch-builder/actions/runs --jq ".workflow_runs[] | select(.head_ref==\"$TAG\" or .head_branch==\"$TAG\") | .id" 2>/dev/null | head -1)

if [ -z "$RUN_ID" ]; then
    # Fallback: find the most recent run on the tag
    sleep 10
    RUN_ID=$(gh api repos/dominicusin/alpine-wdmch-builder/actions/runs --jq ".workflow_runs[] | select(.head_ref==\"$TAG\") | .id" 2>/dev/null | head -1)
fi

if [ -n "$RUN_ID" ]; then
    gh run watch "$RUN_ID" --exit-status --interval 60 2>/dev/null || true
fi

# Create the release with gh CLI
VERSION=$(cat VERSION 2>/dev/null || echo "0.1.0-dev")
gh release create "$TAG" \
    --title "WDMCH Rescue Image $VERSION" \
    --repo dominicusin/alpine-wdmch-builder \
    --generate-notes \
    --force \
    "alpine-wdmch-rescue-${VERSION}-flash.zip" \
    "SHA256SUMS" \
    "manifest.json"

echo ""
echo "=== Release $TAG created successfully ==="
echo "Download: https://github.com/dominicusin/alpine-wdmch-builder/releases/tag/$TAG"
