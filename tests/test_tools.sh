#!/usr/bin/env bash
set -Eeuo pipefail

# Test that intentionally corrupted artifacts fail validation

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "=== Testing validators against corrupted artifacts ==="

# Test check-image-header.py with corrupted image
echo "Testing Image header validator with corrupted data..."
python3 -c "
import struct, os, tempfile
f = tempfile.NamedTemporaryFile(suffix='.img', delete=False)
k = bytearray(1024 * 1024)
k[56:60] = struct.pack('<I', 0xDEADBEEF)  # Bad magic
k[0:4] = struct.pack('<I', 0xDEADBEEF)
k[8:16] = struct.pack('<Q', 0xDEADBEEF)
k[60:64] = struct.pack('<I', 0xDEADBEEF)
f.write(k)
f.close()
print(f.name)
" > "$TMPDIR/corrupted.img"
CORRUPT_IMG=$(cat "$TMPDIR/corrupted.img")
if python3 tools/check-image-header.py "$CORRUPT_IMG" 2>/dev/null; then
    echo "FAIL: Corrupted image was accepted"
    exit 1
fi
echo "OK: Corrupted image correctly rejected"

# Test check-fdt.py with corrupted DTB
echo "Testing FDT validator with corrupted data..."
python3 -c "
import struct, tempfile
f = tempfile.NamedTemporaryFile(suffix='.dtb', delete=False)
d = bytearray(4096)
d[0:4] = struct.pack('<I', 0xDEADBEEF)  # Bad magic
f.write(d)
f.close()
print(f.name)
" > "$TMPDIR/corrupted.dtb"
CORRUPT_DTB=$(cat "$TMPDIR/corrupted.dtb")
if python3 tools/check-fdt.py "$CORRUPT_DTB" 2>/dev/null; then
    echo "FAIL: Corrupted DTB was accepted"
    exit 1
fi
echo "OK: Corrupted DTB correctly rejected"

echo "All tool tests PASSED"
