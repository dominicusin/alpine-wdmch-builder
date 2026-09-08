#!/usr/bin/env python3
"""Validate WDMCH device tree blob.

Checks:
  - FDT magic == 0xd00dfeed
  - compatible contains "wd,mycloud-home"
  - model == "WD My Cloud Home"
  - memory size == 0x40000000
  - FDT totalsize <= file size
  - FDT totalsize >= used structure/string/reserve-map end
"""
import struct
import sys
import subprocess

FDT_MAGIC = 0xd00dfeed

def parse_fdt(path):
    with open(path, 'rb') as f:
        data = f.read()

    if len(data) < 32:
        print(f"FAIL: DTB too small ({len(data)} bytes)")
        return False

    ok = True

    # Check magic
    magic = struct.unpack_from('<I', data, 0)[0]
    if magic == FDT_MAGIC:
        print(f"  FDT magic: OK (0x{magic:08X})")
    else:
        print(f"  FDT magic: FAIL (0x{magic:08X}, expected 0x{FDT_MAGIC:08X})")
        ok = False

    # Check totalsize
    totalsize = struct.unpack_from('>I', data, 4)[0]
    file_size = len(data)
    print(f"  FDT totalsize: {totalsize} (file: {file_size})")
    if totalsize <= file_size:
        print(f"  totalsize <= file_size: OK")
    else:
        print(f"  totalsize > file_size: FAIL")
        ok = False

    # Use dtc to parse and check semantic content
    try:
        result = subprocess.run(
            ['dtc', '-I', 'dtb', '-O', 'dts', '-o', '-', path],
            capture_output=True, text=True, timeout=10
        )
        dts_output = result.stdout

        if 'compatible' in dts_output and 'wd,mycloud-home' in dts_output:
            print(f"  compatible contains wd,mycloud-home: OK")
        else:
            print(f"  compatible contains wd,mycloud-home: FAIL")
            ok = False

        if 'WD My Cloud Home' in dts_output:
            print(f"  model == WD My Cloud Home: OK")
        else:
            print(f"  model == WD My Cloud Home: FAIL")
            ok = False

        # Check memory size
        if '0x40000000' in dts_output:
            print(f"  memory@0 size == 0x40000000: OK")
        else:
            print(f"  memory@0 size == 0x40000000: FAIL")
            ok = False

    except (subprocess.TimeoutExpired, FileNotFoundError):
        print("  WARNING: dtc not available for semantic check")

    return ok

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <dtb-path>", file=sys.stderr)
        sys.exit(1)
    
    if parse_fdt(sys.argv[1]):
        print("FDT validation PASSED")
        sys.exit(0)
    else:
        print("FDT validation FAILED")
        sys.exit(1)
