#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="$1"
MODULES="$2"
RELEASE_FILE="$3"

test -s "$IMAGE" || { echo "FAIL: Image missing or empty"; exit 1; }
test -s "$RELEASE_FILE" || { echo "FAIL: kernel-release.txt missing"; exit 1; }

release="$(cat "$RELEASE_FILE")"
test -n "$release" || { echo "FAIL: empty kernel release"; exit 1; }
test -d "$MODULES/lib/modules/$release" || { echo "FAIL: modules not found for release $release"; exit 1; }

python3 - "$IMAGE" <<'PY'
import struct, sys
p=sys.argv[1]
b=open(p,'rb').read(64)
assert len(b)==64, f'Expected 64 bytes, got {len(b)}'
assert struct.unpack_from('<I',b,56)[0] == 0x644d5241, 'bad ARM64 magic before patch'
assert struct.unpack_from('<Q',b,8)[0] == 0x200000, 'bad text_offset'
assert struct.unpack_from('<I',b,60)[0] == 0x40, 'bad pe_offset'
print('Kernel metadata validation PASSED')
PY
