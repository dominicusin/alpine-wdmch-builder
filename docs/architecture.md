# Architecture

## Boot chain

```text
vendor ROM -> BL31 -> vendor U-Boot
        |
        |  boot_rescue_from_usb
        |  reads FIXED FILENAMES from the ROOT of the FAT32 USB stick
        v
  sata.uImage (raw patched Image) + rescue.sata.dtb + rescue.root.sata.cpio.gz_pad.img
        |
        v
  rescue initramfs (staged at physical 0x02200000, 4 MiB)
        |
        +-- mounts the stick, DHCP on eth0, dropbear :22 (public-key only)
        |
        +-- looks for a filesystem labelled wdmch-root on the internal disk
        |       found + valid  -> mount, switch_root into the installed Alpine
        |       /norescue present -> skip handoff, drop to rescue shell
        v
  installed Alpine (optional: kexec -e, no stick needed)
```

The vendor U-Boot **cannot boot from the internal SATA disk**. Every boot goes
through the USB stick, either because the reset button is held at power-on or
because no factory partition is found.

## Storage layout — USB rescue stick

FAT32, MBR, single partition. The loader reads fixed filenames from the root.
**There is no `boot/` subdirectory.**

```text
USB stick root
├── sata.uImage                      raw patched ARM64 Image + 512 KiB zero pad
├── rescue.sata.dtb                  WDMCH device tree blob
├── rescue.root.sata.cpio.gz_pad.img exactly 4194304 bytes
├── SHA256SUMS
├── manifest.json
├── README.txt
└── apks/
    ├── main/
    └── community/
```

## Storage layout — internal disk (factory GPT, preserved)

The WDMCH disk ships with a factory GPT containing 24 fixed partitions. This
project **never repartitions it** and **never writes the firmware slots**.

| # | Name | Size (sectors) | Type |
|---|---|---|---|
| 1 | FW_TABLE | 2014 | firmware table |
| 2 | KERNEL_A | 65536 | kernel |
| 3 | ROOTFS_A | 65536 | rootfs |
| 4 | ROOTFS_B | 65536 | rootfs |
| 5 | FDT_A | 2048 | device tree |
| 6 | FDT_B | 2048 | device tree |
| 7 | AFW_A | 8192 | firmware |
| 8 | KERNEL_B | 65536 | kernel |
| 9 | ROOTFS_GOLD | 65536 | rootfs |
| 10 | FDT_GOLD | 2048 | device tree |
| 11 | AFW_B | 8192 | firmware |
| 12 | BOOTCODE32 | 2048 | bootcode |
| 13 | BOOTCODE64 | 2048 | bootcode |
| 14 | BL31 | 2048 | trusted firmware |
| 15 | BL32 | 2048 | trusted firmware |
| 16 | KERNEL_GOLD | 65536 | kernel |
| 17 | AFW_GOLD | 8192 | firmware |
| 18 | CONFIG | 65536 | fat32 |
| 19 | SYSTEM_A | 1638400 | ext4 |
| 20 | SYSTEM_B | 1638400 | ext4 |
| 21 | CACHE | 1638400 | ext4 |
| 22 | DATA | 4194304 | ext4 |
| 23 | SWAP | 4194304 | linux-swap |
| 24 | DISKVOLUME1 | remainder (typically TBs) | ext4 |

Partition 18 (`CONFIG`) holds a file `bootConfig` whose content looks like:

```text
2:B:2;
```

That is `BOOT_STATE : A-or-B side : boot attempts`. Column 2 selects which
partition set is used. **B** is the side referred to as "Rescue", and is the
correct side for anything permanent.

## Where Alpine is installed

The installer writes the Alpine root filesystem into the **existing p20
(`SYSTEM_B`)** together with p21 (`DATA`), formatted as ONE btrfs filesystem
spanning both, with filesystem label `wdmch-root` and no md RAID. It does not
create any partition. p1 (`FW_TABLE`) and every other partition are left
untouched.

This is deliberate: it preserves the firmware table, the A/B/GOLD firmware
slots, the user's data (p22) and their storage volume (p24). p20 is also one of
the partitions the upstream rescue init already scans for a root filesystem —
it probes `sda9`, `sda18`, `sda19`..`sda24` and md arrays.

## Components

### Vendor ROM / BL31 / U-Boot

Immutable vendor boot chain on the internal flash. Its environment drives
`boot_rescue_from_usb`, which reads the fixed filenames from the stick root.

### Rescue kernel (`symops/monarch-6.18`)

- **Architecture**: ARM64 (aarch64)
- **SoC**: Realtek RTD1295 (4× Cortex-A53, 1 GiB DRAM)
- **Drivers**: all built **into** the kernel. This project builds **no kernel
  modules**, so the rescue initramfs has nothing to `insmod`.
- **Header patch**: `code0=0x91005A4D`, `text_offset=0x200000`,
  `pe_offset=0x40`
- **Packaging**: `sata.uImage` = raw patched `Image` + 512 KiB zero padding. Not
  an `mkimage`/FIT wrapper; never gzipped.

### Rescue initramfs

`rescue.root.sata.cpio.gz_pad.img` — a gzip'd `newc` cpio padded to exactly
4194304 bytes, because the loader reads that fixed size unconditionally. It
contains `/init` as PID 1, which mounts filesystems, waits for the SATA link,
mounts the stick, runs DHCP, starts dropbear, performs the `wdmch-root` handoff
and then respawns a console shell.

### Device tree

- **Artifact**: `rtd1295-wd-mycloud-home.dtb`, shipped as `rescue.sata.dtb`
- **Compile**: `dtc -@ -p 16384 -I dts -O dtb`
- **Key nodes**: `memory@0` (0x40000000), `chosen linux,initrd-start=0x02200000`,
  RTD1295 IRQ mux, `r8169soc` GMAC, RTD1295 AHCI, SATA PHY, DWC3, thermal,
  watchdog

See [dtb.md](dtb.md) for the full board semantics and FDT validation rules.

## Safety boundaries

- The factory GPT is **preserved**; the project never repartitions the disk.
- **NO** writes to the A/B/GOLD firmware slots, and **DO NOT** boot GOLD.
- Building the rescue stick is **read-only** with respect to the NAS.
- `install-alpine` writes **only** the existing p20, and only with explicit
  confirmation.
- **NO** private key material in the repository or in any artifact.

## Build environment

- **Host**: x86_64 Linux with an aarch64 cross-toolchain
- **QEMU**: user-mode only, for rootfs post-processing and tests
- **CI**: GitHub Actions
- **Toolchain**: ARM64 GCC/binutils cross-compiler
