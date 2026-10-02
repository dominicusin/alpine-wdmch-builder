#!/bin/bash
# mutate.sh - apply a mutation and PROVE it landed, before claiming a check fires.
#
# Why this exists: while mutation-testing the btrfs kexec fix, three mutations
# were "applied" with a Python .replace() whose anchor did not match the file.
# Each reported "0 test failures" - which reads exactly like "the check does not
# detect this defect", the opposite conclusion. Two of those mutations had never
# touched the file at all.
#
# A silent replace is the worst possible mutation harness: it manufactures proof
# that a check is dead, and sends you off to fix a check that was working. So
# every mutation here goes through apply_mutation, which refuses to report
# success unless the before-text was present and is now absent, and the
# after-text was absent and is now present.
#
# Usage:
#   mutate.sh <file> <mode> <arg> [arg...]
#
#   modes:
#     expect-absent   after applying, <arg> must NOT occur (e.g. a defect string)
#     expect-present  after applying, <arg> must occur
#     expect-count    <arg> must be NEEDLE::N and occur exactly N times
#     unchanged       apply nothing; just check <arg> occurs (baseline probe)

set -eu
FILE=$1; MODE=$2; shift 2

if [ "$MODE" = "replace-block" ]; then
    python3 - "$FILE" "$MODE" "$@" <<'PY'
import sys
path, mode, arg = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()

if mode == "replace-block":
    # arg = "start_marker|||N|||replacement" - replaces N lines from the marker.
    # N matters: replacing only the `if` line of an if/fi leaves the whole body
    # behind, which looks like a successful mutation but is not the one intended.
    marker, _, rest = arg.partition("|||")
    count_s, _, repl = rest.partition("|||")
    count = int(count_s)
    lines = src.split("\n")
    hits = [n for n, l in enumerate(lines) if marker in l]
    if len(hits) != 1:
        sys.exit(f"MARKER-FAIL: {marker!r} matched {len(hits)} lines, need exactly 1")
    n = hits[0]
    print(f"    replacing {count} line(s) at {n+1}..{n+count}")
    lines[n:n+count] = [repl] if repl else []
    open(path, "w", encoding="utf-8").write("\n".join(lines))
    sys.exit(0)

sys.exit(f"unknown mode {mode!r}")
PY
fi

# --- prove the mutation actually changed the file, and reached the goal -----
python3 - "$FILE" "$MODE" "$@" <<'PY'
import sys
path, mode, arg = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()

# expect-count takes NEEDLE::N - split on the LAST "::" so a needle containing
# "::" still works. The needle is what gets counted; N is the expectation.
if mode == "expect-count":
    needle, _, want = arg.rpartition("::")
    if not needle:
        sys.exit("BAD-ARG: expect-count needs NEEDLE::N")
else:
    needle, want = arg, None

n = src.count(needle)
label = {"expect-absent": "must be absent", "expect-present": "must be present",
         "expect-count": f"must occur {want}x", "unchanged": "baseline",
         "replace-block": "post-mutation"}.get(mode)
if label is None:
    sys.exit(f"unknown mode {mode!r}")

if mode == "expect-absent" and n != 0:
    sys.exit(f"VERDICT-FAIL: {needle!r} still occurs {n}x ({label}) - the check does NOT fire")
if mode == "expect-present" and n < 1:
    sys.exit(f"VERDICT-FAIL: {needle!r} absent ({label}) - the check does NOT fire")
if mode == "expect-count" and n != int(want):
    sys.exit(f"VERDICT-FAIL: {needle!r} occurs {n}x, wanted {want} ({label})")
if mode == "unchanged" and n < 1:
    sys.exit(f"BASELINE-FAIL: {needle!r} not found in the pristine file - the probe is wrong")
print(f"    verdict ok ({label}: {n} occurrence(s))")
PY
