# Source Classification

This document classifies all upstream sources used in the alpine-wdmch-builder project.

## Primary Sources

### `symops/monarch-6.18` — Primary WDMCH 6.18 kernel/boot-chain source

This is the authoritative kernel source for the WDMCH USB rescue build. It provides:

- The WDMCH board DTS and device-tree bindings
- The rescue USB filename conventions (`sata.uImage`, `rescue.sata.dtb`, etc.)
- The ARM64 Image header patch values (`code0=0x91005A4D`, `text_offset=0x200000`, `pe_offset=0x40`)
- DTB FDT headroom requirements (`dtc -p 16384`)
- Rescue initramfs staging reservation (`0x02200000` region)
- The current raw-image/padding boot contract

**Status**: Primary implementation source. All kernel code must come from this repository.

### `Fireblossom/wd-mch-kernel` — WDMCH port/config/rescue provenance

Community-maintained 4.9→6.18 WDMCH port providing:

- Board-specific DTS provenance
- Embedded initramfs packaging reference
- B-slot packaging details
- Validated hardware features

**Status**: Configuration and rescue provenance reference. Not a code source for this project.

### `sgissi/wdmch-tools` — WDMCH firmware-table tooling reference

Provides `fwtablectl` for WDMCH firmware-table manipulation.

**Status**: Firmware-table tooling reference only. Flashing operations are outside the USB-builder scope.

## Historical References (NOT implementation sources)

### `ealain/alpine-nas` — Historical Alpine-on-WD reference

Demonstrates the general Alpine-on-WD workflow but targets a **different Marvell WD platform**.

**Status**: Historical reference only. Cannot be copied blindly. Different SoC, different kernel, different board DTS.

### `Johns-Q/wdmc-gen2` — Historical USB initramfs approach

Demonstrates a historical WD Gen2 Alpine/USB initramfs boot flow, but targets **Armada 375** (Marvell, not Realtek).

**Status**: Historical reference only. Not the RTD1295 implementation. MBR/FAT instructions from this project are not assumed for WDMCH.

### `symops/MCG1-6.18` — Methodology only

Demonstrates a different WD generation targeting **LS1024A** hardware (NXP, not Realtek).

**Status**: Methodology reference only. No MCG1 kernel code belongs in WDMCH build output.

## Community Reference

### 4PDA post — Community hardware/boot reference

Community post containing hardware details and boot observations.

**Status**: Requires cross-check with source code before acting on any information. Community observations may be inaccurate.

## Source Hierarchy

```
symops/monarch-6.18    PRIMARY    All kernel code, DTB, boot contract
Fireblossom/wd-mch-kernel SECONDARY  Port provenance, config reference
sgissi/wdmch-tools      REFERENCE  Firmware-table tooling only
ealain/alpine-nas       HISTORICAL Different platform, not for copying
Johns-Q/wdmc-gen2       HISTORICAL Different SoC (Armada 375)
symops/MCG1-6.18        METHODOLOGY Different hardware (LS1024A)
4PDA post               COMMUNITY  Cross-check required
```

## Verification Policy

All source claims must be verified against the pinned `symops/monarch-6.18` repository before implementation. Historical references are not authoritative for WDMCH (RTD1295) hardware.
