# docs/RECOVERY.md

# Recovery Procedures

## Booting the Rescue Image

### Physical USB Rescue Boot

1. **Prepare USB storage**: Copy the three artifacts from `build/release/` to a USB storage device:
   ```
   /boot/
     sata.uImage
     rescue.sata.dtb
     rescue.root.sata.cpio.gz_pad.img
   ```

2. **Power off** the WD My Cloud Home

3. **Insert USB** storage device into the front USB port

4. **Press and hold** the reset button while powering on

5. **Boot sequence**:
   - Vendor ROM initializes
   - U-Boot detects USB storage
   - Loads `sata.uImage` (patched kernel) and `rescue.sata.dtb` (DTB)
   - Kernel boots and executes `/init` as PID 1
   - Filesystems are mounted
   - Ethernet comes up via DHCP
   - Dropbear SSH starts
   - Root shell is available

## SSH Access

After boot:
1. Find the IP address via serial console or router DHCP lease
2. Connect via SSH: `ssh root@<ip>`
3. **Public-key authentication only** — no password is configured
4. Dropbear SSH server is running on port 22

## Optional: Full Alpine Boot via kexec

If a full Alpine kernel and DTB are present on the rescue filesystem:

```bash
/usr/local/sbin/boot-full-alpine
```

This loads the full Alpine kernel via `kexec` and boots it, replacing the rescue environment.

## Recovery Boundary

### DO NOT DO:

- **DO NOT boot the GOLD partition** — GOLD is a factory-reset appliance, not a safe fallback
- **DO NOT write A/B/GOLD firmware slots** — this project is read-only with respect to NAS firmware
- **DO NOT flash any firmware** without first backing up existing WDMCH firmware tables

### DO:

- **DO back up existing WDMCH firmware tables** before any future flashing work
- **DO use `sgissi/wdmch-tools`** (`fwtablectl`) for firmware table manipulation if needed
- **DO test on non-production hardware** first

## Serial Console

Expected boot output (examples based on observed WDMCH boot logs):

```
U-Boot > sf probe
U-Boot > fatload usb 0:1 0x48000000 /boot/sata.uImage
## Loading File from usb0 ... OK
U-Boot > fatload usb 0:1 0x49000000 /boot/rescue.sata.dtb
## Loading File from usb0 ... OK
U-Boot > booti 0x48000000 - 0x49000000
## Starting kernel ...

[    0.000000] Booting Linux on physical CPU 0x0
[    0.000000] Linux version 6.18.x (builder@host)
[    0.000000] Machine model: WD My Cloud Home
[    0.000000] Memory: 1024MB
[    0.000000] Console: ttyS0
...
=== WDMCH Rescue Init ===
Mounting filesystems...
Bringing up eth0...
Starting Dropbear SSH...
=== Rescue shell ===
```

**Note**: Serial output may vary based on kernel configuration and hardware revision. These are examples, not guaranteed byte-for-byte output.

## Troubleshooting

- **No boot from USB**: Verify USB storage is formatted correctly and files are in `/boot/`
- **Kernel panic**: Check `sata.uImage` header values (code0=0x91005A4D, text_offset=0x200000, pe_offset=0x40)
- **No network**: Verify `r8169soc` driver is loaded and DHCP server is available
- **SSH not accessible**: Check Dropbear configuration and authorized_keys permissions
- **kexec fails**: Ensure full Alpine kernel and DTB are present at `/boot/alpine/`
