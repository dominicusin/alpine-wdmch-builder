#!/usr/bin/env python3
"""Patch ARM64 Image header with WDMCH-rescue values.

Reads the kernel Image, validates the ARM64 magic, and patches:
  - code0  = 0x91005A4D  (at offset 0)
  - text_offset = 0x200000 (at offset 8)
  - pe_offset = 0x40 (at offset 60)
"""
import struct
import sys

PATCH_CODE0 = 0x91005A4D
PATCH_TEXT_OFFSET = 0x200000
PATCH_PE_OFFSET = 0x40
ARM64_MAGIC = 0x644D5241  # 'ARM\6' little-endian at offset 56

def patch_image(path):
    with open(path, "r+b") as f:
        k = bytearray(f.read())

        # Validate ARM64 magic
        magic = struct.unpack_from("<I", k, 56)[0]
        if magic != ARM64_MAGIC:
            raise ValueError(
                f"Bad ARM64 magic: 0x{magic:08X}, expected 0x{ARM64_MAGIC:08X}"
            )

        # Patch header
        struct.pack_into("<I", k, 0, PATCH_CODE0)
        struct.pack_into("<Q", k, 8, PATCH_TEXT_OFFSET)
        struct.pack_into("<I", k, 60, PATCH_PE_OFFSET)

        # Write back
        f.seek(0)
        f.write(k)
        f.truncate()

        print(f"Patched {path}:")
        print(f"  code0 = 0x{PATCH_CODE0:08X}")
        print(f"  text_offset = 0x{PATCH_TEXT_OFFSET:08X}")
        print(f"  pe_offset = 0x{PATCH_PE_OFFSET:08X}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <Image-path>", file=sys.stderr)
        sys.exit(1)
    patch_image(sys.argv[1])
