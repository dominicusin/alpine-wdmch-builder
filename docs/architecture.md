# Architecture

## Boot Chain

```
vendor ROM/BL31/U-Boot
        -> WDMCH rescue kernel
        -> Alpine rescue userspace
           -> shell / DHCP / SSH
           -> optional kexec full Alpine kernel
```

## Components

### 1. Vendor Boot ROM / U-Boot

The WD My Cloud Home boots from its internal NOR flash containing:
- Vendor ROM (immutable)
- BL31 (Trusted Firmware)
- U-Boot (second-stage bootloader)

The U-Boot environment configures the boot path. USB rescue is triggered by inserting a USB storage device and pressing the reset button.

### 2. Rescue Kernel (`symops/monarch-6.18`)

- **Source**: `symops/monarch-6.18` (pinned to reviewed commit)
- **Architecture**: ARM64 (aarch64)
- **SoC**: Realtek RTD1295 (4× Cortex-A53, 1 GiB DRAM)
- **Key features**: RTD129x IRQ mux, r8169soc GMAC, RTD1295 AHCI, SATA PHY, DWC3/USB, thermal, watchdog, cpufreq
- **Boot format**: Raw patched ARM64 `Image` with `code0=0x91005A4D`, `text_offset=0x200000`, `pe_offset=0x40`
- **DTB**: `rtd1295-wd-mycloud-home.dtb` compiled from WDMCH board DTS

The kernel is packaged as `sata.uImage` — a raw `Image` plus 512 KiB zero padding per the WDMCH rescue loader contract.

### 3. Alpine Rescue Userspace

- **Base**: Alpine aarch64 minirootfs (pinned version)
- **Package manager**: `apk` (statically linked for rescue)
- **Networking**: DHCP via `udhcpc` on `eth0` (integrated GMAC driver: `r8169soc`, PHY: RTL8211E)
- **SSH**: Dropbear with root public-key authentication only (no password)
- **Init**: Custom PID 1 init that mounts filesystems, loads modules, brings up networking, starts Dropbear, and drops to shell
- **Optional kexec**: `/usr/local/sbin/boot-full-alpine` for handoff to full Alpine kernel

### 4. Rescue Initramfs

The rescue rootfs is packaged as `rescue.root.sata.cpio.gz_pad.img`:
- Fixed size: 4 MiB (4,194,304 bytes)
- Gzip compressed CPIO archive
- Contains `/init` as PID 1
- Includes matching kernel modules in `/lib/modules/<release>`

### 5. Device Tree

- **Source**: WDMCH board DTS from `symops/monarch-6.18`
- **Compile**: `dtc -@ -p 16384 -I dts -O dtb`
- **Artifact**: `rtd1295-wd-mycloud-home.dtb`
- **Key nodes**: memory@0 (0x40000000), chosen linux,initrd-start=0x02200000, RTD1295 IRQ mux, r8169soc, RTD1295 AHCI, SATA PHY, DWC3, thermal, watchdog

## Storage Layout (USB Rescue)

```
USB Storage
├── /boot/
│   ├── sata.uImage              # Patched raw ARM64 Image + 512 KiB padding
│   ├── rescue.sata.dtb          # WDMCH device tree blob
│   └── rescue.root.sata.cpio.gz_pad.img  # 4 MiB padded rescue rootfs
└── (possibly other rescue files)
```

## Safety Boundaries

- **NO** write access to NAS block devices
- **NO** modification of A/B/GOLD firmware slots
- **NO** private key material in repository or artifacts
- USB rescue creation is **read-only** with respect to the NAS
- `kexec` from rescue is optional, not mandatory

## Build Environment

- **Host**: x86_64 Linux with aarch64 cross-toolchain
- **QEMU**: User-mode only for rootfs post-processing and tests
- **CI**: GitHub Actions on `ubuntu-24.04`
- **Toolchain**: ARM64 GCC/binutils cross-compiler
