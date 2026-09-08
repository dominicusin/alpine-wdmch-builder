#!/usr/bin/env bash
set -Eeuo pipefail

check_deps() {
    local missing=0
    for tool in git make gcc-aarch64-linux-gnu ccache python3 dtc cpio gzip xz zip sha256sum; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "MISSING: $tool"
            missing=1
        else
            echo "OK: $tool"
        fi
    done
    return $missing
}

show_install_hints() {
    echo ""
    echo "Installation hints:"
    echo "  Arch Linux:    sudo pacman -S git make gcc-aarch64-linux-gnu ccache binutils dtc python cpio gzip xz zip"
    echo "  Debian/Ubuntu: sudo apt install git make gcc-aarch64-linux-gnu ccache binutils-aarch64-linux-gnu dtc python3 cpio gzip xz zip"
    echo "  Alpine:        apk add git make gcc-aarch64-linux-gnu ccache binutils dtc python3 cpio gzip xz zip"
}

# Main
echo "=== Dependency Check ==="
if ! check_deps; then
    show_install_hints
    echo ""
    echo "Some dependencies are missing. Install them before building."
    exit 1
fi
echo ""
echo "All dependencies satisfied."
