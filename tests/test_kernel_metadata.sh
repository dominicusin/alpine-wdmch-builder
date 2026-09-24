#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-build/kernel/Image}"
RELEASE_FILE="${2:-build/kernel/kernel-release.txt}"

test -s "$IMAGE" || { echo "FAIL: Image missing or empty"; exit 1; }
test -s "$RELEASE_FILE" || { echo "FAIL: kernel-release.txt missing"; exit 1; }

release="$(cat "$RELEASE_FILE")"
test -n "$release" || { echo "FAIL: empty kernel release"; exit 1; }

# On unpatched Image: ARM64 magic at offset 56
python3 - "$IMAGE" <<'PY'
import struct, sys
p = sys.argv[1]
b = open(p, 'rb').read(64)
assert len(b) == 64, f'Expected 64 bytes, got {len(b)}'
assert struct.unpack_from('<I', b, 56)[0] == 0x644D5241, 'bad ARM64 magic'
print('ARM64 Image magic OK')
PY

# If an unpatched pristine copy exists, cross-check it separately
if [ -s "build/kernel/Image.unpatched" ]; then
    python3 - "build/kernel/Image.unpatched" <<'PY'
import struct, sys
p = sys.argv[1]
b = open(p, 'rb').read(64)
assert struct.unpack_from('<I', b, 56)[0] == 0x644D5241, 'bad ARM64 magic on unpatched copy'
PY
    echo "Unpatched Image copy OK"
fi

echo "Kernel metadata validation PASSED"
