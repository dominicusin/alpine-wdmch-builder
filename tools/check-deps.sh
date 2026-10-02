#!/usr/bin/env bash
set -Eeuo pipefail

check_deps() {
    local missing=0
    # Every tool here is invoked UNGUARDED somewhere in the build. If a command
    # is only reached through `command -v X` it degrades gracefully and does
    # not belong on this list - parted and sgdisk are the two that qualify, and
    # they are deliberately absent.
    #
    # curl and unzip were missing, and both are load-bearing:
    #   image/dl-packages.sh  curl fetches APKINDEX; without it the offline
    #                         repository cannot be built at all
    #   image/package-rescue.sh  unzip reads back the archive it just built
    #   image/dl-packages.sh     tar xzOf reads the cached APKINDEX
    #
    # tar was found by tests/test_verifiers.sh, which derives the list from
    # the build scripts instead of trusting this one.
    #
    # This list is a claim about the build, so it has a test: a tool that
    # appears unguarded in a build script and not here fails tests/test_tools.sh.
    for tool in git make aarch64-linux-gnu-gcc ccache python3 dtc cpio gzip xz \
                zip unzip curl sha256sum tar; do
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
    echo "  Arch Linux:    sudo pacman -S git make gcc aarch64-linux-gnu-gcc binutils dtc python cpio gzip xz zip unzip curl tar ccache"
    echo "  Debian/Ubuntu: sudo apt install git make gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu device-tree-compiler python3 cpio gzip xz-utils zip unzip curl tar ccache"
    echo "  Alpine:        apk add git make gcc gcc-aarch64-linux-gnu binutils dtc python3 cpio gzip xz zip unzip curl tar ccache"
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
