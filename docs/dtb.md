# docs/dtb.md

# WDMCH Device Tree Build

## Overview

The WDMCH device tree describes the Realtek RTD1295 SoC and all board-specific peripherals. It is compiled from the WDMCH board DTS and must pass semantic validation.

## Source

The DTS source comes from `symops/monarch-6.18`. The node name may vary in the source tree but the published artifact is always `rtd1295-wd-mycloud-home.dtb`.

## Build Command

```bash
dtc -@ -p 16384 -I dts -O dtb \
  -o build/kernel/rtd1295-wd-mycloud-home.dtb \
  path/to/rtd1295-wd-mycloud-home.dts
```

Alternatively, use the kernel build system:
```bash
make -C "$KERNEL" O="$BUILD" ARCH=arm64 dtbs
```

## Critical Board Semantics

The DTB must contain the following:

- `compatible = "wd,mycloud-home", "realtek,rtd1295"`
- `model = "WD My Cloud Home"`
- `memory@0` with `size = 0x40000000` (1 GiB)
- `/chosen linux,initrd-start = 0x02200000` (when rescue initramfs is used)
- RTD1295 IRQ mux node
- `Realtek,rtk-sata-phy` SATA PHY node
- `r8169soc` Ethernet MAC node
- USB/DWC3 node
- Thermal and watchdog nodes
- Board SATA calibration tables

## FDT Totalsize Validation

The FDT header field at offset 4 (`totalsize`) must be larger than the semantic minimum and consistent with the padded artifact. Use `dtc -I dtb -O dts` to round-trip and verify.

**Common mistake**: Padding the DTB file without updating `totalsize` leaves the FDT header inconsistent. The `dtc` tool handles this correctly; manual padding is never required.
