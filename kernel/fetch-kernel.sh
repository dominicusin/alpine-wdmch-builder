#!/usr/bin/env bash
set -Eeuo pipefail

# Load source locks
set -a
source config/source-lock.env
set +a

KERNEL_DIR="${KERNEL_DIR:-.work/monarch-6.18}"
BUILD_DIR="${BUILD_DIR:-build/kernel}"

# Cross-compilation setup
CLANG_TARGET="${CLANG_TARGET:-aarch64-linux-gnu}"
CC="${CCACHE:-ccache} clang"

echo "=== Fetching WDMCH kernel ==="
echo "Repository: $KERNEL_REPO"
echo "Reference:  $KERNEL_REF"

if [ ! -d "$KERNEL_DIR/.git" ]; then
    echo "Cloning $KERNEL_REPO into $KERNEL_DIR..."
    git clone "$KERNEL_REPO" "$KERNEL_DIR"
else
    echo "$KERNEL_DIR already exists, fetching..."
    git -C "$KERNEL_DIR" fetch --all --depth=1
fi

# Reset to pinned ref
echo "Resetting to $KERNEL_REF..."
git -C "$KERNEL_DIR" reset --hard "$KERNEL_REF"

# Verify commit
actual_sha=$(git -C "$KERNEL_DIR" rev-parse HEAD)
echo "Actual commit: $actual_sha"
if [ "$actual_sha" != "$KERNEL_REF" ] && [ "$KERNEL_REF" != "HEAD" ]; then
    echo "ERROR: Commit SHA mismatch! Expected $KERNEL_REF, got $actual_sha" >&2
    exit 1
fi

# Check for dirty tree
if git -C "$KERNEL_DIR" diff-index --quiet HEAD --; then
    echo "Tree is clean."
else
    echo "ERROR: Tree is dirty! Refusing to continue." >&2
    exit 1
fi

echo "Kernel fetch complete."
