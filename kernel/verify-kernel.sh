#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_DIR="${BUILD_DIR:-build/kernel}"
RELEASE_FILE="${BUILD_DIR}/kernel-release.txt"
IMAGE="${BUILD_DIR}/Image"
MODULES="${BUILD_DIR}/modules"

echo "=== Verifying kernel build ==="

# Check kernel release
if [ ! -f "$RELEASE_FILE" ]; then
    echo "ERROR: kernel-release.txt not found" >&2
    exit 1
fi
release=$(cat "$RELEASE_FILE")
echo "Kernel release: $release"

# Check Image exists
if [ ! -s "$IMAGE" ]; then
    echo "ERROR: Image not found or empty" >&2
    exit 1
fi

# Check modules
if [ ! -d "$MODULES/lib/modules/$release" ]; then
    echo "ERROR: Modules directory not found for release $release" >&2
    exit 1
fi

# Validate ARM64 magic before patch
python3 -c "
import struct, sys
b = open('$IMAGE', 'rb').read(64)
assert len(b) == 64, f'Expected 64 bytes, got {len(b)}'
magic = struct.unpack_from('<I', b, 56)[0]
assert magic == 0x644D5241, f'Bad ARM64 magic before patch: 0x{magic:08X}'
print('ARM64 Image magic verified: 0x644D5241')
"

echo "Kernel verification passed."
