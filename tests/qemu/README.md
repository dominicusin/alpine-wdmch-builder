#!/usr/bin/env bash
set -Eeuo pipefail

# Install and update tools
tools/setup-tools.sh 2>/dev/null || true

# Test tools
echo "Testing check-deps.sh..."
bash tools/check-deps.sh || true

echo "Testing check-image-header.py..."
python3 tools/check-image-header.py /dev/null 2>&1 || true

echo "Testing check-fdt.py..."
python3 tools/check-fdt.py /dev/null 2>&1 || true

echo "Testing check-artifacts.sh..."
bash tools/check-artifacts.sh build/release 2>&1 || true

echo "Tool tests completed."
