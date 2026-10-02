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
    WDMCH_SSH_AUTHORIZED_KEY  SSH public key for root login (required for release)
    KERNEL_REF                Override kernel commit reference
    CCACHE_DIR                ccache directory (default: build/.ccache)
    CROSS_TARGET              Cross-compilation target triple (default: aarch64-linux-gnu)
EOF
}

run_dry_run() {
    echo "=== Dry run: validating configuration ==="
    echo "VERSION: ${VERSION}"
    echo ""
    # tools/check-deps.sh is the single owner of the dependency list. This used
    # to be a second hand-written copy, and the two had already drifted: the
    # copy here omitted curl and unzip while the build calls both unguarded.
    # A list that exists twice is a list that is wrong once.
    #
    # check-deps.sh exits non-zero on a missing tool, so the dry run inherits
    # that verdict rather than printing MISSING and carrying on to a green
    # "All dry-run checks passed."
    if ! bash tools/check-deps.sh; then
        echo ""
        echo "Dry run FAILED: required build tools are missing (see above)."
        return 1
    fi
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
    echo "Checking SSH key..."
    if [ -n "${WDMCH_SSH_AUTHORIZED_KEY:-}" ]; then
        echo "  OK: WDMCH_SSH_AUTHORIZED_KEY is set"
    elif [ -f config/build.env ]; then
        if grep -q 'WDMCH_SSH_AUTHORIZED_KEY' config/build.env; then
            echo "  OK: WDMCH_SSH_AUTHORIZED_KEY in config/build.env"
        else
            echo "  WARNING: WDMCH_SSH_AUTHORIZED_KEY not set"
        fi
    else
        echo "  WARNING: WDMCH_SSH_AUTHORIZED_KEY not set"
    fi
    echo ""
    echo "All dry-run checks passed."
}

clean_build() {
    echo "Cleaning build artifacts..."
    rm -rf .work/ build/
    echo "Clean complete."
}

run_build() {
    echo "=== Building WDMCH rescue image ==="
    echo "VERSION: ${VERSION}"

    # Fail on a missing tool before spending 30 minutes on a kernel build.
    # check-deps.sh is the single owner of the list; run_dry_run calls the same
    # script, so a dry run that passes means a real build will not stop here.
    if ! bash tools/check-deps.sh; then
        echo ""
        echo "Build FAILED: required tools are missing (see above)." >&2
        exit 1
    fi
    echo ""
    # Load optional build env
    if [ -f config/build.env ]; then
        set -a
        # shellcheck disable=SC1091
        source config/build.env
        set +a
    fi

    # Set up cross-compilation with GCC
    export CROSS_TARGET="${CROSS_TARGET:-aarch64-linux-gnu}"
    export CC="${CCACHE:-ccache} aarch64-linux-gnu-gcc"
    export CROSS_COMPILE="${CROSS_TARGET}-"

    # Check for aarch64-linux-gnu-gcc (package: gcc-aarch64-linux-gnu)
    if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        echo "ERROR: aarch64-linux-gnu-gcc not found. Install gcc-aarch64-linux-gnu." >&2
        exit 1
    fi

    # Check for ccache
    if ! command -v ccache >/dev/null 2>&1; then
        echo "WARNING: ccache not found. Install ccache for faster rebuilds." >&2
    fi

    # Clone kernel if not already present
    if [ ! -d ".work/monarch-6.18" ]; then
        echo "Cloning WDMCH kernel tree..."
        bash kernel/fetch-kernel.sh
    fi

    # Build kernel
    echo "Building kernel..."
    bash kernel/build-kernel.sh

    # Build DTB
    echo "Building DTB..."
    bash dtb/build-dtb.sh

    # Build rootfs
    echo "Building rootfs..."
    bash rootfs/build-rootfs.sh

    # Package rescue artifacts
    echo "Packaging rescue artifacts..."
    bash image/package-rescue.sh

    # Verify before declaring success.
    #
    # This used to end at an `ls -la build/release/`, so "Build complete"
    # meant only that the scripts returned 0. A local build - which is what
    # README.md's Quick Start tells people to run - got no verification at
    # all, because the CI workflows run `make test` separately. The result
    # was a success message for a build whose artifacts might be malformed.
    # `make validate` is the same check CI relies on; calling it here means
    # the message is earned.
    echo ""
    echo "Verifying artifacts..."
    make validate

    echo "=== Build complete and verified ==="
    ls -la build/release/
}

ARG="${1:-}"
if [ "$ARG" = "--help" ]; then
    show_help
elif [ "$ARG" = "--clean" ]; then
    clean_build
elif [ "$ARG" = "--dry-run" ]; then
    run_dry_run
elif [ -z "$ARG" ]; then
    run_build
else
    echo "Unknown argument: $ARG" >&2
    show_help
    exit 1
fi
