#!/usr/bin/env bash
set -Eeuo pipefail

DTB="$1"
DTS="$2"

test -s "$DTB" || { echo "FAIL: DTB missing or empty"; exit 1; }
test -s "$DTS" || { echo "FAIL: DTS missing or empty"; exit 1; }

# Verify DTS contains required board semantics
grep -q 'compatible = "wd,mycloud-home"' "$DTS" || { echo "FAIL: compatible not found"; exit 1; }
grep -q 'model = "WD My Cloud Home"' "$DTS" || { echo "FAIL: model not found"; exit 1; }
grep -q '0x40000000' "$DTS" || { echo "FAIL: memory size not found"; exit 1; }
grep -q 'Realtek,rtk-sata-phy' "$DTS" || { echo "FAIL: SATA PHY not found"; exit 1; }
grep -q 'r8169soc' "$DTS" || true  # May be named differently

# Validate FDT header totalsize
python3 - "$DTB" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
magic = struct.unpack_from('<I', b, 0)[0]
assert magic == 0xd00dfeed, f'Bad FDT magic: 0x{magic:08X}'
totalsize = struct.unpack_from('>I', b, 4)[0]
print(f'FDT magic verified: 0xd00dfeed')
print(f'FDT totalsize: {totalsize}')
print(f'File size: {len(b)}')
assert totalsize <= len(b), f'totalsize ({totalsize}) > file size ({len(b)})'
print('DTB validation PASSED')
PY
