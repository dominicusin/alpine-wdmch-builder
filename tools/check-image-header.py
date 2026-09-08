#!/usr/bin/env python3
"""Validate ARM64 Image header for WDMCH rescue boot.

Checks:
  - code0 == 0x91005A4D
  - text_offset == 0x200000
  - pe_offset == 0x40
"""
import struct
import sys

EXPECTED_CODE0 = 0x91005A4D
EXPECTED_TEXT_OFFSET = 0x200000
EXPECTED_PE_OFFSET = 0x40
ARM64_MAGIC = 0x644D5241  # 'ARM\6' at offset 56

def validate_image(path):
    with open(path, 'rb') as f:
        data = f.read()

    if len(data) < 64:
        print(f"FAIL: Image too small ({len(data)} bytes)")
        return False

    ok = True

    # Check ARM64 magic
    magic = struct.unpack_from('<I', data, 56)[0]
    if magic == ARM64_MAGIC:
        print(f"  ARM64 magic: OK (0x{magic:08X})")
    else:
        print(f"  ARM64 magic: FAIL (0x{magic:08X}, expected 0x{ARM64_MAGIC:08X})")
        ok = False

    # Check code0
    code0 = struct.unpack_from('<I', data, 0)[0]
    if code0 == EXPECTED_CODE0:
        print(f"  code0: OK (0x{code0:08X})")
    else:
        print(f"  code0: FAIL (0x{code0:08X}, expected 0x{EXPECTED_CODE0:08X})")
        ok = False

    # Check text_offset
    text_offset = struct.unpack_from('<Q', data, 8)[0]
    if text_offset == EXPECTED_TEXT_OFFSET:
        print(f"  text_offset: OK (0x{text_offset:08X})")
    else:
        print(f"  text_offset: FAIL (0x{text_offset:08X}, expected 0x{EXPECTED_TEXT_OFFSET:08X})")
        ok = False

    # Check pe_offset
    pe_offset = struct.unpack_from('<I', data, 60)[0]
    if pe_offset == EXPECTED_PE_OFFSET:
        print(f"  pe_offset: OK (0x{pe_offset:08X})")
    else:
        print(f"  pe_offset: FAIL (0x{pe_offset:08X}, expected 0x{EXPECTED_PE_OFFSET:08X})")
        ok = False

    return ok

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <image-path>", file=sys.stderr)
        sys.exit(1)
    
    if validate_image(sys.argv[1]):
        print("Image header validation PASSED")
        sys.exit(0)
    else:
        print("Image header validation FAILED")
        sys.exit(1)
