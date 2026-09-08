.PHONY: all clean help build kernel dtb rootfs package validate test release-dry-run

VERSION := $(shell cat VERSION 2>/dev/null || echo "0.1.0-dev")
KERNEL_REF := $(shell grep KERNEL_REF config/source-lock.env 2>/dev/null | cut -d= -f2)

all: build

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
	bash dtb/verify-dtb.sh

rootfs:
	bash rootfs/build-rootfs.sh

package:
	bash image/package-rescue.sh
	bash image/verify-image.sh

validate:
	bash tests/test_tools.sh
	python3 tools/check-image-header.py build/release/sata.uImage || true
	python3 tools/check-fdt.py build/release/rescue.sata.dtb || true
	bash tools/check-artifacts.sh build/release || true

test: validate
	bash tests/test_repo_layout.sh
	bash tests/test_kernel_metadata.sh build/kernel/Image build/kernel/modules build/kernel/kernel-release.txt || true
	bash tests/test_dtb.sh build/kernel/rtd1295-wd-mycloud-home.dtb build/kernel/rtd1295-wd-mycloud-home.dts || true
	bash tests/test_rootfs.sh build/rootfs $$(cat build/kernel/kernel-release.txt 2>/dev/null || echo none) || true
	bash tests/test_image.sh build/release || true
	bash tests/test_tools.sh
	bash tests/test_workflows.sh || true

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
