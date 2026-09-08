# docs/usb-rescue.md

# WDMCH USB Rescue Boot Guide

## Source-grounded Artifact Names

The current WDMCH rescue loader (from `symops/monarch-6.18`) expects these files:

```text
/boot/
  sata.uImage                    # Raw patched ARM64 Image + 512 KiB zero padding
  rescue.sata.dtb                # WDMCH device tree blob
  rescue.root.sata.cpio.gz_pad.img  # 4 MiB padded rescue rootfs
```

**Important**: `sata.uImage` is NOT a U-Boot `mkimage` wrapped image. It is a raw patched ARM64 `Image` with padding, as documented by the pinned `symops/monarch-6.18` source.

## USB Preparation

1. Format USB storage as a single FAT32 partition (or ext4, depending on U-Boot support)
2. Create `/boot/` directory on the USB storage
3. Copy the three artifacts from `build/release/` to `/boot/`
4. Verify all three files are present and non-empty

## Rescue Boot Procedure

1. Power off the WD My Cloud Home
2. Insert the USB storage device
3. Press and hold the reset button while powering on
4. The board should boot from USB and execute the rescue kernel

## Expected Boot Behavior

The rescue kernel boots, loads the DTB, and executes `/init` as PID 1:
- Filesystems are mounted (proc, sys, devtmpfs)
- Required kernel modules are loaded
- Ethernet (`eth0`) comes up via DHCP
- Dropbear SSH server starts
- A root shell is provided

## SSH Access

- Connect via `ssh root@<ip>` after DHCP assigns an address
- Authentication is **public-key only**
- No root password is configured
- No password authentication is allowed

## Optional: Full Alpine Boot via kexec

If a full Alpine kernel and DTB are present on the rescue filesystem:
```bash
/usr/local/sbin/boot-full-alpine
```
This loads the full Alpine kernel via `kexec` and boots it.

## Safety

- **DO NOT** boot the GOLD partition
- **DO NOT** write A/B/GOLD firmware slots
- **DO** back up existing firmware tables before any future flashing
- USB rescue creation is read-only with respect to the NAS

## Troubleshooting

See [docs/DEBUGGING.md](DEBUGGING.md) for serial output examples and recovery procedures.
