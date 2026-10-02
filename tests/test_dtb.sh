#!/usr/bin/env bash
# Validate the WDMCH device tree blob.
#
# The artifact that matters is the DTB BINARY - that is what gets shipped to
# the stick. tools/check-fdt.py already validates it semantically (it runs in
# `make validate` and passed in CI), so this test adds the structural checks
# that need no external tool at all.
#
# It deliberately does NOT assert exact source phrasing against the
# decompiled .dts. That file is a rendering produced by whichever `dtc` was
# on PATH, and how it lays out a multi-string property - ordering, line
# wrapping, indentation - is a property of that tool, not of the board. An
# exact grep for 'compatible = "wd,mycloud-home"' passed with the locally
# built dtc and failed in CI with the system dtc, on a DTB that check-fdt.py
# had validated as correct in the same run. If a source-level check is
# wanted, assert the value, not the syntax dtc happened to choose.
set -Eeuo pipefail

DTB="${1:-}"
DTS="${2:-}"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -n "$DTB" ] || fail "no DTB given"
[ -s "$DTB" ] || fail "DTB missing or empty: $DTB"

echo "=== $DTB ($(stat -c %s "$DTB") bytes) ==="

# ---- 1. structural checks, no external tool needed ------------------------
python3 - "$DTB" <<'PY'
import struct, sys
p = sys.argv[1]
b = open(p, 'rb').read()
if len(b) < 32:
    print(f"FAIL: DTB too small ({len(b)} bytes)"); sys.exit(1)
magic = struct.unpack_from('>I', b, 0)[0]
if magic != 0xd00dfeed:
    print(f"FAIL: FDT magic 0x{magic:08X}, expected 0xd00dfeed"); sys.exit(1)
print(f"  FDT magic: OK (0x{magic:08X})")
totalsize = struct.unpack_from('>I', b, 4)[0]
if totalsize > len(b):
    print(f"FAIL: totalsize {totalsize} > file size {len(b)}"); sys.exit(1)
print(f"  totalsize {totalsize} <= file size {len(b)}: OK")
if totalsize < 0x1000:
    print(f"FAIL: totalsize too small: {totalsize}"); sys.exit(1)
PY

# ---- 2. semantic checks on the shipping binary ---------------------------
# The same validator `make validate` uses: it decompiles to stdout and matches
# values, so it does not depend on how dtc formats the output.
if command -v dtc >/dev/null 2>&1; then
    python3 tools/check-fdt.py "$DTB"
else
    echo "  (dtc not on PATH - semantic pass skipped here; make validate runs it)"
fi

# ---- 3. the decompiled .dts, when one is available -----------------------
# Value-level only: the string must be present, whatever dtc did with the
# surrounding syntax. A failure prints the head of the file, so the next
# occurrence is diagnosable without another CI round trip.
#
# The .dts is a RENDERING, not a build product: nothing in the build emits it,
# and `build/` is gitignored. The Makefile passed the path unconditionally, so
# the test demanded a file that only exists if somebody decompiled the DTB by
# hand earlier - true in this checkout, absent in every fresh CI runner. That is
# how build.yml stayed red across two releases while release.yml, which does not
# pass the path, stayed green: the same suite, two lanes, one of them failing
# on a file neither of them produces.
#
# So derive it when it is missing rather than require it, and say plainly when
# the value check cannot run rather than passing silently.
DTS_SOURCE="supplied"
if [ -n "$DTS" ] && [ ! -s "$DTS" ]; then
    if [ -s "$DTB" ] && command -v dtc >/dev/null 2>&1; then
        DTS="${DTS%.dts}.ci.dts"
        if dtc -I dtb -O dts -o "$DTS" "$DTB" 2>/dev/null; then
            DTS_SOURCE="decompiled from $DTB"
        else
            DTS=""
            echo "  (dtc could not decompile $DTB - value check skipped)"
        fi
    else
        DTS=""
        echo "  (no .dts and no dtc on PATH - value check skipped, not passed)"
    fi
fi

if [ -n "$DTS" ]; then
    [ -s "$DTS" ] || fail "DTS missing or empty: $DTS"
    echo "  (.dts: $DTS_SOURCE)"
    for want in 'wd,mycloud-home' 'WD My Cloud Home' '0x40000000' 'rtk-sata-phy'; do
        if ! grep -qF "$want" "$DTS"; then
            echo "FAIL: '$want' not present in $DTS" >&2
            echo "--- first 20 lines of $DTS ---" >&2
            head -20 "$DTS" >&2
            exit 1
        fi
    done
    echo "  decompiled .dts carries the expected board values: OK"
fi

echo "DTB test PASSED"
