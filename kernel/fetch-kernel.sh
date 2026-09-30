#!/usr/bin/env bash
set -Eeuo pipefail

# Fetch the kernel source at exactly the commit pinned in
# config/source-lock.env. A floating reference (HEAD, a branch name) makes
# every build unreproducible, so it is rejected outright rather than
# silently resolved to whatever the remote tip happens to be today.
#
# The previous version ignored KERNEL_REF completely: it cloned
# `--branch main --depth 1` and merged origin/main, so the "pinned" value in
# config/source-lock.env had no effect on the build at all.

# Load source locks
set -a
# shellcheck disable=SC1091
source config/source-lock.env
set +a

KERNEL_DIR="${KERNEL_DIR:-.work/monarch-6.18}"
GIT_REPO="${GIT_REPO:-${KERNEL_REPO:-https://github.com/symops/monarch-6.18.git}}"
PINNED_REF="${KERNEL_REF:-}"

# ---- refuse to float ------------------------------------------------------------
if [ -z "$PINNED_REF" ]; then
    echo "ERROR: KERNEL_REF is empty in config/source-lock.env." >&2
    echo "       Pin it to a reviewed commit (see the manifest's kernel_commit)." >&2
    exit 1
fi
case "$PINNED_REF" in
    HEAD|main|master)
        echo "ERROR: KERNEL_REF='$PINNED_REF' is a floating reference." >&2
        echo "       A build must be tied to one reviewed commit. Pin the full" >&2
        echo "       40-character SHA in config/source-lock.env." >&2
        exit 1 ;;
esac
if ! echo "$PINNED_REF" | grep -Eq '^[0-9a-f]{7,40}$'; then
    echo "ERROR: KERNEL_REF='$PINNED_REF' is not a git commit SHA." >&2
    exit 1
fi
# Require the full 40. The regex above and the post-checkout comparison below
# (a prefix match) both tolerate an abbreviated SHA, which would quietly make
# this "immutable" lock weaker than it looks. The fetch would usually fail on
# a short SHA, but that is luck, not enforcement.
if [ "${#PINNED_REF}" -ne 40 ]; then
    echo "ERROR: KERNEL_REF='$PINNED_REF' is ${#PINNED_REF} characters." >&2
    echo "       Pin the full 40-character SHA: a prefix is ambiguous in a" >&2
    echo "       file that exists to be immutable." >&2
    exit 1
fi

echo "=== Kernel source: $GIT_REPO @ $PINNED_REF ==="

# ---- fetch exactly that commit --------------------------------------------------
# git fetch <remote> <sha> works on GitHub and keeps the clone shallow, which
# matters: a full clone of this tree is several gigabytes.
if [ ! -d "$KERNEL_DIR/.git" ]; then
    echo "--- initialising $KERNEL_DIR"
    mkdir -p "$KERNEL_DIR"
    git -C "$KERNEL_DIR" init -q
    if git -C "$KERNEL_DIR" remote get-url origin >/dev/null 2>&1; then
        git -C "$KERNEL_DIR" remote set-url origin "$GIT_REPO"
    else
        git -C "$KERNEL_DIR" remote add origin "$GIT_REPO"
    fi
fi

echo "--- fetching $PINNED_REF"
if ! git -C "$KERNEL_DIR" fetch --depth 1 origin "$PINNED_REF"; then
    echo "ERROR: could not fetch $PINNED_REF from $GIT_REPO" >&2
    echo "       If the commit was rewritten or the repo was force-pushed," >&2
    echo "       pick a reachable commit and update KERNEL_REF." >&2
    exit 1
fi

git -C "$KERNEL_DIR" checkout -q --detach FETCH_HEAD

# ---- verify we really are on the pin --------------------------------------------
ACTUAL=$(git -C "$KERNEL_DIR" rev-parse HEAD)
case "$ACTUAL" in
    "$PINNED_REF"*) : ;;
    *)
        echo "ERROR: checked out $ACTUAL but KERNEL_REF is $PINNED_REF" >&2
        exit 1 ;;
esac
echo "--- HEAD is $ACTUAL (matches the pin)"

# Clean the source tree so Kbuild's out-of-tree build checks pass.
git -C "$KERNEL_DIR" clean -fdx >/dev/null 2>&1 || true
git -C "$KERNEL_DIR" checkout -- . >/dev/null 2>&1 || true

echo "Kernel source ready at $KERNEL_DIR"
