#!/bin/bash
# test_property_seeds.sh - property tests must not be seed-specific.
#
# tests/test_resolver_properties.py generates random indexes from a seeded PRNG
# so a failure is reproducible. The cost of that design is a property test that
# passes on ONE seed and fails on another: the seed you happened to run is the
# seed you know, and nothing forces you to try another.
#
# So the spread is a test. Eight seeds - 0, 1 and a large odd number included,
# because those are the ones that behave differently - must all pass. Each round
# count is lower than the default so the sweep stays cheap; the default run in
# `make test` covers depth, this covers breadth.
#
# It also fails on a traceback even when the exit code is 0. A property helper
# that raises on the first failure would otherwise look like a clean run.
set -u
cd "$(dirname "$0")/.." || exit 1
T=tests/test_resolver_properties.py
FAILED=0

[ -f "$T" ] || { echo "FAIL: $T missing" >&2; exit 1; }

echo "=== the property tests hold across seeds, not just the documented one ==="

for s in 0 1 2 42 1337 20261002 999983 7; do
    out=$(RESOLVER_TEST_SEED="$s" RESOLVER_TEST_ROUNDS=60 python3 "$T" 2>&1)
    rc=$?
    case "$out" in
        *Traceback*) printf '  FAIL  seed %-9s raised instead of reporting\n' "$s"; FAILED=$((FAILED+1)) ;;
        *)
            if [ "$rc" -eq 0 ]; then
                printf '  ok    seed %-9s\n' "$s"
            else
                printf '  FAIL  seed %-9s -> %s\n' "$s" \
                    "$(printf '%s' "$out" | grep -m1 FAIL | cut -c1-60)"
                FAILED=$((FAILED+1))
            fi
            ;;
    esac
done

echo
if [ "$FAILED" -eq 0 ]; then
    echo "property seeds: PASSED"
else
    echo "property seeds: FAILED ($FAILED)" >&2
    exit 1
fi