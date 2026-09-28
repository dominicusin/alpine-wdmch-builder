#!/usr/bin/env bash
# Release helper for the WDMCH rescue image.
#
# The GitHub Actions workflow (.github/workflows/release.yml) owns the actual
# build and publication: push a v* tag and it builds the image and creates the
# release. This script does NOT rebuild or publish anything itself - it
# validates, creates the tag, watches CI, and then verifies the release really
# appeared. Running a local build here would only duplicate what CI does, and
# publishing here would race the workflow.
#
# Usage:
#   ./scripts/release.sh              # validate, tag as v<VERSION>, push, watch
#   ./scripts/release.sh --dry-run    # validate only, change nothing
#   ./scripts/release.sh --tag v1.2.3 # override the tag (must match VERSION)
#
# The tag MUST be v<VERSION> exactly. release.yml names the release from the
# VERSION *file*, not from the triggering tag, so tagging "v3.21.8-3-46"
# would publish the new artifacts under a name that differs from the tag.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJ_DIR"

REPO=dominicusin/alpine-wdmch-builder
TAG=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --tag)     TAG="${2:-}"; shift 2 ;;
        --tag=*)   TAG="${1#--tag=}"; shift ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

say()  { printf '\n=== %s ===\n' "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

VERSION=$(cat VERSION 2>/dev/null || true)
[ -n "$VERSION" ] || die "VERSION file is empty or missing"
[ -n "$TAG" ] || TAG="v${VERSION}"

# ---- preconditions --------------------------------------------------------
say "Preconditions"

command -v gh >/dev/null 2>&1 || die "gh CLI not found"
gh auth status >/dev/null 2>&1 || die "gh CLI not authenticated (run: gh auth login)"

[ -z "$(git status --porcelain)" ] || { git status --short >&2; die "working tree is not clean"; }
echo "  working tree clean: OK"

git fetch --quiet origin || die "git fetch failed"
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main 2>/dev/null || echo "")
[ "$LOCAL" = "$REMOTE" ] || die "HEAD ($LOCAL) is not origin/main ($REMOTE) - push first"
echo "  HEAD matches origin/main: OK"

echo "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$' \
    || die "tag '$TAG' is not of the form v<major>.<minor>.<patch>[-<n>]"
[ "$TAG" = "v${VERSION}" ] || die "tag '$TAG' does not match VERSION ($VERSION); release.yml names the release from the VERSION file, so a mismatch publishes under a different name than the tag"
echo "  tag $TAG matches VERSION: OK"

# ---- local gates ----------------------------------------------------------
# Same gates CI runs. Catching a failure here costs seconds rather than a
# ~30 minute CI cycle.
say "Local gates"
make test || die "make test failed - not tagging"
bash tools/release-audit.sh || die "release-audit.sh failed - not tagging"
echo "  local gates: OK"

if [ "$DRY_RUN" -eq 1 ]; then
    say "Dry run"
    echo "Would create and push tag $TAG, then wait for the Release workflow."
    echo "Nothing was changed."
    exit 0
fi

# ---- tag ------------------------------------------------------------------
say "Tagging $TAG"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    TAG_SHA=$(git rev-list -n1 "$TAG")
    [ "$TAG_SHA" = "$LOCAL" ] \
        || die "tag $TAG already exists at a different commit ($TAG_SHA) - resolve it by hand"
    echo "  tag already points at HEAD, reusing it"
else
    git tag -a "$TAG" -m "WDMCH rescue image $TAG

Installs into p20 SYSTEM_B on the factory GPT and hands over with switch_root."
    git push origin "$TAG"
    echo "  tag pushed"
fi

# ---- watch CI -------------------------------------------------------------
say "Waiting for the Release workflow"
sleep 20
RUN_ID=""
for _ in $(seq 1 30); do
    RUN_ID=$(gh run list --workflow=Release --limit 20 --json headBranch,databaseId \
               --jq "[.[] | select(.headBranch==\"$TAG\")] | first | .databaseId // empty" 2>/dev/null || true)
    [ -n "$RUN_ID" ] && break
    sleep 10
done
[ -n "$RUN_ID" ] || die "could not find the Release workflow run for $TAG - see https://github.com/$REPO/actions"

echo "  run $RUN_ID - this cross-compiles the kernel, expect ~30 minutes"
gh run watch "$RUN_ID" --interval 60

# Do NOT swallow this. A failed build followed by a published release is
# exactly the class of bug this script exists to prevent.
CONCLUSION=$(gh run view "$RUN_ID" --json conclusion -q .conclusion)
[ "$CONCLUSION" = "success" ] || {
    gh run view "$RUN_ID" --log-failed || true
    die "Release workflow concluded '$CONCLUSION' - no release was created"
}

# ---- verify the release actually exists -----------------------------------
say "Verifying the published release"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
    || die "CI succeeded but no release $TAG exists - check the workflow's publish step"

for a in "alpine-wdmch-rescue-${VERSION}-flash.zip" SHA256SUMS manifest.json; do
    gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name==\"$a\") | .name" \
        | grep -q . || die "release is missing the asset $a"
    echo "  asset OK: $a"
done

printf '\nRelease %s published: https://github.com/%s/releases/tag/%s\n' "$TAG" "$REPO" "$TAG"
