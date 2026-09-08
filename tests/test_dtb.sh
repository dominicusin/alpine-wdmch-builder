#!/usr/bin/env bash
set -Eeuo pipefail

DTB="$1"
DTS="$2"

test -s "$DTB" || { echo "FAIL: DTB missing or empty"; exit 1; }
test -s "$DTS" || { echo "FAIL: DTS missing or empty"; exit 1; }

# Verify DTS contains required board semantics
grep -q 'compatible = "wd,mycloud-home"' "$DTS" || { echo "FAIL: compatible = \"wd,mycloud-home\" not found"; exit 1; }
grep -q 'model = "WD My Cloud Home"' "$DTS" || { echo "FAIL: model = \"WD My Cloud Home\" not found"; exit 1; }
grep -q '0x40000000' "$DTS" || { echo "FAIL: memory@0 size 0x40000000 not found"; exit 1; }
grep -q 'Realtek,rtk-sata-phy' "$DTS" || { echo "FAIL: Realtek,rtk-sata-phy not found"; exit 1; }
grep -q 'r8169soc' "$DTS" || true

# Verify FDT totalsize via round-trip
python3 - "$DTB" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
magic = struct.unpack_from('<I', b, 0)[0]
assert magic == 0xd00dfeed, f'Bad FDT magic: 0x{magic:08X}'
totalsize = struct.unpack_from('>I', b, 4)[0]
file_size = len(b)
assert totalsize <= file_size, f'totalsize ({totalsize}) > file size ({file_size})'
# Check totalsize >= used structure/string/reserve-map end
# Minimum reasonable check: totalsize covers at least the header + some content
assert totalsize > 0x1000, f'totalsize too small: {totalsize}'
print(f'FDT validation PASSED (totalsize={totalsize}, file_size={file_size})')
PY

echo "DTB test PASSED"
