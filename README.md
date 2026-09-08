# Alpine WDMCH Builder

[![CI](https://github.com/dominicusin/alpine-wdmch-builder/actions/workflows/build.yml/badge.svg)](https://github.com/dominicusin/alpine-wdmch-builder/actions/workflows/build.yml)

A reproducible build system for creating a **USB Rescue Boot image** for the **single-bay WD My Cloud Home** (Realtek RTD1295, 4× Cortex-A53, 1 GiB RAM).

## Overview

This project builds a complete USB rescue environment:

- **Kernel**: `symops/monarch-6.18` (Linux 6.18.x, ARM64)
- **Rootfs**: Alpine aarch64 minirootfs with Dropbear SSH + DHCP
- **Boot**: Raw patched ARM64 `Image` + WDMCH DTB
- **Rescue**: Standalone initramfs with optional `kexec` handoff

## Architecture

```
vendor ROM/BL31/U-Boot
    -> WDMCH rescue kernel
    -> Alpine rescue userspace
       -> shell / DHCP / SSH
       -> optional kexec full Alpine kernel
```

## Quick Start

```bash
# Clone and build
git clone https://github.com/dominicusin/alpine-wdmch-builder.git
cd alpine-wdmch-builder
./build-image.sh

# Or dry-run to validate setup
./build-image.sh --dry-run
```

## Project Structure

```
config/          - Source locks and build configuration
kernel/          - Kernel fetch, build, and patch scripts
dtb/             - Device tree build and validation
rootfs/          - Alpine rescue rootfs build scripts
image/           - USB rescue artifact packaging
tools/           - Host-side validation tools
tests/           - Repository validation tests
docs/            - Documentation
.github/workflows/ - CI/CD pipelines
```

## Key Files

| File | Description |
|------|-------------|
| `sata.uImage` | Patched raw ARM64 kernel Image + padding |
| `rescue.sata.dtb` | WDMCH device tree blob |
| `rescue.root.sata.cpio.gz_pad.img` | Alpine rescue initramfs |
| `SHA256SUMS` | Checksums for all release artifacts |
| `manifest.json` | Build metadata and artifact manifest |

## Source References

See [docs/SOURCES.md](docs/SOURCES.md) for full source classification.

## License

MIT License — see [LICENSE](LICENSE).

## Warnings

- **DO NOT** boot GOLD partition — it is a factory-reset appliance, not a safe fallback
- **DO NOT** write A/B/GOLD slots as part of this project
- **DO** back up any existing WDMCH firmware table before future flashing work
- This is a **rescue boot** tool; it does not overwrite NAS firmware
- No private SSH key is stored anywhere in this repository or its artifacts
