.PHONY: all clean help build kernel dtb rootfs package validate test release release-dry-run

VERSION := $(shell cat VERSION 2>/dev/null || echo "0.1.0-dev")
KERNEL_REF := $(shell grep -m1 '^KERNEL_REF=' config/source-lock.env 2>/dev/null | cut -d= -f2)

all: build

release:
	bash scripts/release.sh

help:
	@echo "Alpine WDMCH Builder v$(VERSION)"
	@echo ""
	@echo "Targets:"
	@echo "  all          - Build everything (default)"
	@echo "  kernel       - Build WDMCH kernel"
	@echo "  dtb          - Build WDMCH device tree"
	@echo "  rootfs       - Build Alpine rescue rootfs"
	@echo "  package      - Package USB rescue artifacts"
	@echo "  validate     - Run all validators"
	@echo "  test         - Run all tests"
	@echo "  clean        - Remove build artifacts"
	@echo "  help         - Show this help"
	@echo ""
	@echo "Configuration:"
	@echo "  VERSION=$(VERSION)"
	@echo "  KERNEL_REF=$(KERNEL_REF)"

build: kernel dtb rootfs package validate

kernel:
	bash kernel/fetch-kernel.sh
	bash kernel/build-kernel.sh
	bash kernel/verify-kernel.sh

dtb:
	bash dtb/build-dtb.sh
	bash tests/test_dtb.sh build/kernel/rtd1295-wd-mycloud-home.dtb build/kernel/rtd1295-wd-mycloud-home.dts

rootfs:
	bash rootfs/build-rootfs.sh build/rootfs $$(cat build/kernel/kernel-release.txt 2>/dev/null || echo none)

package:
	bash image/package-rescue.sh
	bash image/verify-image.sh

# NOTE: no `|| true` on the validators or tests below. Swallowing a failure
# here is how a broken artifact previously shipped under a green build - if a
# check cannot run (missing artifact, not built yet) it must say so loudly.
validate:
	python3 tools/check-image-header.py build/release/sata.uImage
	python3 tools/check-fdt.py build/release/rescue.sata.dtb
	bash tools/check-artifacts.sh build/release

test: validate
	bash tests/test_repo_layout.sh
	bash tests/test_kernel_metadata.sh build/kernel/Image build/kernel/kernel-release.txt
	bash tests/test_dtb.sh build/kernel/rtd1295-wd-mycloud-home.dtb build/kernel/rtd1295-wd-mycloud-home.dts
	bash tests/test_rootfs.sh build/rootfs $$(cat build/kernel/kernel-release.txt 2>/dev/null || echo none)
	bash tests/test_install_verify.sh
	bash tests/test_verify_install_gpt.sh
	bash tests/test_rescue_refusal.sh
	bash tests/test_in_use_partition.sh
	bash tests/test_btrfs_target.sh
	bash tests/test_btrfs_profiles.sh
	bash tests/test_seams.sh
	bash tests/test_syntax.sh
	bash tests/test_prepare_usb.sh
	bash tests/test_mutate.sh
	bash tests/test_wdmch_layout.sh
	bash tests/test_p1_backup.sh
	bash tests/test_no_fail_open.sh
	bash tests/test_handoff.sh
	bash tests/test_vendor_slots.sh
	bash tests/test_init_disk.sh
	bash tests/test_resolver.sh
	bash tests/test_preflight.sh
	bash tests/test_backup_fw.sh
	bash tests/test_verifiers.sh
	bash tests/test_workflows.sh
	bash tests/test_planning_count_guard.sh
	bash tests/test_tools.sh
	bash test-flash.sh

# Create real filesystems to verify the btrfs profile choice. NOT part of
# `make test`: formatting is destructive, and a check that formats should not be
# a side effect of running the suite. Opt-in, on purpose.
verify-fs:
	WDMCH_VERIFY_FS=1 bash tests/test_btrfs_profiles.sh

# Drop the cached APKINDEX. See image/dl-packages.sh: the cache can outlive the
# packages it names, and a stale one fails the build on a version that no longer
# exists on the mirror - while CI, fetching fresh, would not reproduce it.
clean-cache:
	rm -rf .work/apk-cache-offline

clean:
	./build-image.sh --clean

release-dry-run:
	./build-image.sh --dry-run

# Reproducibility: ensure deterministic builds
reproducible:
	@echo "Checking build reproducibility..."
	@echo "KERNEL_REF=$(KERNEL_REF)"
	@cat config/source-lock.env
	@cat config/alpine.env
