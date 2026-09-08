#!/usr/bin/env bash
set -Eeuo pipefail

# Load source locks
set -a
source config/source-lock.env
set +a

KERNEL_DIR="${KERNEL_DIR:-.work/monarch-6.18}"
GIT_REPO="${GIT_REPO:-https://github.com/symops/monarch-6.18.git}"
BRANCH="${BRANCH:-main}"

if [ ! -d "$KERNEL_DIR/.git" ]; then
    echo "=== Cloning kernel source ==="
    git clone "$GIT_REPO" "$KERNEL_DIR" --branch "$BRANCH" --depth 1
else
    echo "=== Kernel source already exists, checking status ==="
    git -C "$KERNEL_DIR" status --short || true
    echo "=== Fetching updates ==="
    git -C "$KERNEL_DIR" fetch origin "$BRANCH" --depth 1 || true
    echo "=== Merging instead of resetting ==="
    git -C "$KERNEL_DIR" merge --ff-only "origin/$BRANCH" 2>&1 || echo "Merge not possible (local changes), keeping current tree"
fi

# Clean the source tree to ensure Kbuild out-of-tree build checks pass
echo "Cleaning source tree for out-of-tree build..."
git -C "$KERNEL_DIR" clean -fdx 2>&1 || true
git -C "$KERNEL_DIR" checkout -- . 2>&1 || true

echo "Kernel source ready at $KERNEL_DIR"