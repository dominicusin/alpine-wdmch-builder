# Alpine WDMCH Builder

[![CI](https://github.com/dominicusin/alpine-wdmch-builder/actions/workflows/build.yml/badge.svg)](https://github.com/dominicusin/alpine-wdmch-builder/actions/workflows/build.yml)

A reproducible build system for creating a **USB Rescue Boot image** for the **single-bay WD My Cloud Home** (Realtek RTD1295, 4× Cortex-A53, 1 GiB RAM).

## Overview

This project builds a complete USB rescue environment:

- **Kernel**: `symops/monarch-6.18` (Linux 6.18.x, ARM64), all required drivers built in — no kernel modules are built
- **Rootfs**: Alpine aarch64 minirootfs with Dropbear SSH + DHCP
- **Boot**: raw patched ARM64 `Image` + WDMCH DTB
- **Rescue**: standalone 4 MiB initramfs that can hand off to an installed Alpine root filesystem

## Architecture

```text
vendor ROM/BL31/U-Boot
    -> boot_rescue_from_usb (reads fixed filenames from the USB stick ROOT)
    -> WDMCH rescue kernel + rescue initramfs
       -> shell / DHCP / SSH
       -> switch_root into installed Alpine (filesystem label wdmch-root)
       -> optional kexec path, no stick needed
```

The vendor U-Boot **cannot boot from the internal SATA disk**. Every boot goes
through the FAT32 USB stick — either by holding the reset button at power-on, or
automatically when no factory partition is found.

## Quick Start

```bash
# Clone and build
git clone https://github.com/dominicusin/alpine-wdmch-builder.git
cd alpine-wdmch-builder
./build-image.sh

# Or dry-run to validate setup
./build-image.sh --dry-run
```

## Using the rescue stick

Copy the build tree to the **root** of a FAT32 stick (MBR, single partition) —
there is no `boot/` subdirectory, the loader reads fixed filenames from the root:

```bash
mount /dev/sdX1 /mnt/stick
cp -r build/usb-tree-root/* /mnt/stick/
sync
cd /mnt/stick && sha256sum -c SHA256SUMS
```

Then power off the box, insert the stick, and hold the reset button while
powering on. See [docs/usb-rescue.md](docs/usb-rescue.md).

## Installing Alpine to the internal disk

From the rescue shell:

```bash
install-alpine /dev/sda          # interactive
install-alpine /dev/sda --yes    # non-interactive
```

The installer writes **only the existing p20 (`SYSTEM_B`)**, formatted ext4 with
the label `wdmch-root`. The factory 24-partition GPT is preserved; p1
(`FW_TABLE`), the A/B/GOLD firmware slots, your data (p22) and your storage
volume (p24) are untouched. It requires explicit confirmation.

On the next rescue boot the init finds `wdmch-root` and `switch_root`s into the
installed system. Add an empty file named `norescue` to the stick root to get
the rescue shell instead.

## Project Structure

```text
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
| `sata.uImage` | Raw patched ARM64 kernel `Image` + 512 KiB zero padding (not an mkimage/FIT wrapper) |
| `rescue.sata.dtb` | WDMCH device tree blob |
| `rescue.root.sata.cpio.gz_pad.img` | Alpine rescue initramfs, exactly 4194304 bytes |
| `SHA256SUMS` | Checksums for the release artifacts |
| `manifest.json` | Build metadata and artifact manifest |

## Documentation

- [docs/usb-rescue.md](docs/usb-rescue.md) — stick layout and boot procedure
- [docs/architecture.md](docs/architecture.md) — boot chain and storage layout
- [docs/INSTALL.md](docs/INSTALL.md) — build and install
- [docs/RECOVERY.md](docs/RECOVERY.md) — recovery procedures
- [docs/DEBUGGING.md](docs/DEBUGGING.md) — troubleshooting
- [docs/SOURCES.md](docs/SOURCES.md) — source classification

## Source References

See [docs/SOURCES.md](docs/SOURCES.md) for full source classification.

## License

MIT License — see [LICENSE](LICENSE).

## Warnings

- **DO NOT** boot GOLD partition — it is a factory-reset appliance, not a safe fallback
- **DO NOT** write A/B/GOLD slots as part of this project
- **DO** back up any existing WDMCH firmware table before future flashing work
  (`dd if=/dev/sda1 of=fw-table-backup.bin bs=512`)
- This is a **rescue boot** tool; it does not overwrite NAS firmware
- The factory GPT is preserved — never repartition the internal disk
- No private SSH key is stored anywhere in this repository or its artifacts
