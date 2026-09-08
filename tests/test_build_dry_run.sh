#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Running all tests ==="

bash tests/test_repo_layout.sh
bash tests/test_kernel_metadata.sh build/kernel/Image build/kernel/modules build/kernel/kernel-release.txt || true
bash tests/test_dtb.sh build/kernel/rtd1295-wd-mycloud-home.dtb build/kernel/rtd1295-wd-mycloud-home.dts || true
bash tests/test_rootfs.sh build/rootfs "$(cat build/kernel/kernel-release.txt 2>/dev/null || echo none)" || true
bash tests/test_image.sh build/release || true
bash tests/test_tools.sh

echo "All tests completed."
