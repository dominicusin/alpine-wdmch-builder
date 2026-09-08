#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_DIR="$1"

test -s "$RELEASE_DIR/sata.uImage" || { echo "FAIL: sata.uImage missing or empty"; exit 1; }
test -s "$RELEASE_DIR/rescue.sata.dtb" || { echo "FAIL: rescue.sata.dtb missing or empty"; exit 1; }
test -s "$RELEASE_DIR/rescue.root.sata.cpio.gz_pad.img" || { echo "FAIL: rescue.root.sata.cpio.gz_pad.img missing or empty"; exit 1; }
test -s "$RELEASE_DIR/SHA256SUMS" || { echo "FAIL: SHA256SUMS missing"; exit 1; }
test -s "$RELEASE_DIR/manifest.json" || { echo "FAIL: manifest.json missing"; exit 1; }

# Check for zero-length files
for f in sata.uImage rescue.sata.dtb rescue.root.sata.cpio.gz_pad.img; do
    size=$(stat -c '%s' "$RELEASE_DIR/$f")
    test "$size" -gt 0 || { echo "FAIL: $f is zero-length"; exit 1; }
done

echo "Image test PASSED"
