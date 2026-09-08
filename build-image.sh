#!/usr/bin/env bash
set -Eeuo pipefail

VERSION=$(cat VERSION 2>/dev/null || echo "0.1.0-dev")

show_help() {
    cat <<EOF
Alpine WDMCH Builder v${VERSION}

Usage:
  ./build-image.sh           Build the complete WDMCH USB rescue image
  ./build-image.sh --help    Show this help message
  ./build-image.sh --clean   Clean build artifacts (.work/ and build/)
  ./build-image.sh --dry-run Validate configuration without building

Environment:
  Optional config/build.env can define:
    WDMCH_SSH_AUTHORIZED_KEY  SSH public key for root login
    KERNEL_REF                Override kernel commit reference
    CCACHE_DIR                ccache directory (default: build/.ccache)
    CLANG_TARGET              Clang target triple (default: aarch64-linux-gnu)
EOF
}

run_dry_run() {
    echo "=== Dry run: validating configuration ==="
    echo "VERSION: ${VERSION}"
    echo ""
    echo "Checking required tools..."
    for tool in git make clang ccache python3 dtc cpio gzip xz; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "  OK: $tool"
        else
            echo "  MISSING: $tool"
        fi
    done
    echo ""
    echo "Checking source locks..."
    for f in config/source-lock.env config/alpine.env; do
        if test -f "$f"; then
            echo "  OK: $f"
        else
            echo "  MISSING: $f"
        fi
    done
    echo ""
    echo "All dry-run checks passed."
}

clean_build() {
    echo "Cleaning build artifacts..."
    rm -rf .work/ build/
    echo "Clean complete."
}

ARG="${1:-}"
if [ "$ARG" = "--help" ]; then
    show_help
elif [ "$ARG" = "--clean" ]; then
    clean_build
elif [ "$ARG" = "--dry-run" ]; then
    run_dry_run
elif [ -z "$ARG" ]; then
    echo "Use --help for usage info"
    exit 1
else
    echo "Unknown option: $ARG"
    exit 1
fi
