#!/usr/bin/env bash
# Test the validators: they must ACCEPT good artifacts and REJECT corrupt ones,
# for the stated reason.
#
# The previous version of this test was negative-only: it fed a corrupt
# artifact to each validator and required a non-zero exit. Two problems.
#
# 1. It never checked that the validators accept anything. A validator that
#    rejected every input - broken by a missing dependency, say - passed.
# 2. "Non-zero exit" is not the same as "rejected for the right reason". The
#    test also swallowed stderr, so a crash counted as a correct rejection:
#    a 19-byte junk file produces "Image too small", exits 1, and the old
#    test reported "Corrupted image correctly rejected". Any crash would have
#    read as a pass.
#
# Both are the "a check that reports success without testing" class, in the
# one place that is supposed to be immune to it.
set -Eeuo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_DIR"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAILED=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }

echo "=== Validators: acceptance and rejection ==="

# --- helpers ---------------------------------------------------------------

# Require the validator to reject, naming the given reason. A crash and a
# correct rejection both exit non-zero; only the message tells them apart.
must_reject() {
    local tool="$1" file="$2" reason="$3" label="$4" out
    out=$(python3 "$tool" "$file" 2>&1 || true)
    if printf '%s' "$out" | grep -q 'validation PASSED'; then
        fail "$label - accepted a corrupt artifact"
    elif ! printf '%s' "$out" | grep -qi -- "$reason"; then
        fail "$label - rejected, but not for the expected reason ($reason)"
        printf '        said: %s\n' "$(printf '%s' "$out" | tail -1)"
    else
        pass "$label"
    fi
}

must_accept() {
    local tool="$1" file="$2" label="$3" out rc
    if [ ! -s "$2" ]; then
        fail "$label - no artifact to test with (build first)"
        return
    fi
    out=$(python3 "$tool" "$2" 2>&1) || rc=$?
    rc=${rc:-0}
    # Both conditions. Checking only for the "validation PASSED" string let a
    # tool that prints PASSED and then exits non-zero slip through, because
    # the exit code was swallowed - the same mistake this test exists to
    # catch, committed in its own replacement.
    if [ "$rc" -ne 0 ]; then
        fail "$label - exit $rc on a GOOD artifact"
        printf '        said: %s\n' "$(printf '%s' "$out" | tail -1)"
    elif printf '%s' "$out" | grep -q 'validation PASSED'; then
        pass "$label"
    else
        fail "$label - rejected a GOOD artifact"
        printf '        said: %s\n' "$(printf '%s' "$out" | tail -1)"
    fi
}

# --- 1. the validators must accept the real build artifacts ---------------
# Without this, a validator that rejects everything would pass the whole file.
echo
echo "-- acceptance: real, good artifacts --"
must_accept tools/check-image-header.py build/release/sata.uImage \
    "check-image-header accepts the real sata.uImage"
must_accept tools/check-fdt.py build/release/rescue.sata.dtb \
    "check-fdt accepts the real rescue.sata.dtb"

# --- 2. they must reject corrupt input, for the right reason -------------
echo
echo "-- rejection: corrupt artifacts --"

python3 - > "$TMPDIR/corrupt.img" <<'PY'
import struct, tempfile
f = tempfile.NamedTemporaryFile(suffix='.img', delete=False)
k = bytearray(1024 * 1024)
k[56:60] = struct.pack('<I', 0xDEADBEEF)   # bad ARM64 magic
k[0:4]   = struct.pack('<I', 0xDEADBEEF)   # bad code0
k[8:16]  = struct.pack('<Q', 0xDEADBEEF)   # bad text_offset
k[60:64] = struct.pack('<I', 0xDEADBEEF)   # bad pe_offset
f.write(k); f.close()
print(f.name)
PY
must_reject tools/check-image-header.py "$(cat "$TMPDIR/corrupt.img")" \
    'ARM64 magic' "check-image-header rejects a corrupt Image"

# A junk file is the case the old test could not tell from a real rejection.
printf 'not an image at all' > "$TMPDIR/junk.img"
must_reject tools/check-image-header.py "$TMPDIR/junk.img" \
    'too small' "check-image-header rejects junk, and says why"

python3 - > "$TMPDIR/corrupt.dtb" <<'PY'
import struct, tempfile
f = tempfile.NamedTemporaryFile(suffix='.dtb', delete=False)
d = bytearray(4096)
d[0:4] = struct.pack('>I', 0xDEADBEEF)     # bad FDT magic
f.write(d); f.close()
print(f.name)
PY
must_reject tools/check-fdt.py "$(cat "$TMPDIR/corrupt.dtb")" \
    'FDT magic' "check-fdt rejects a corrupt DTB"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "All tool tests PASSED"
else
    echo "Tool tests FAILED" >&2
    exit 1
fi
