# Recovery Procedures

How to get a rescue shell on a WD My Cloud Home, and the boundaries you must not
cross while doing it.

## First: always have a working rescue stick

Keep a known-good stick prepared at all times. It is the only way back into the
box, because **the vendor U-Boot cannot boot from the internal SATA disk** —
every boot goes through the USB stick.

## Booting the rescue image

### 1. Prepare the stick

Copy the build tree to the **root** of a FAT32 stick. The loader reads fixed
filenames from the root; there is **no `boot/` subdirectory**.

```bash
mount /dev/sdX1 /mnt/stick
cp -r build/usb-tree-root/* /mnt/stick/
sync
cd /mnt/stick && sha256sum -c SHA256SUMS
```

The stick root holds `sata.uImage`, `rescue.sata.dtb`,
`rescue.root.sata.cpio.gz_pad.img`, `SHA256SUMS`, `manifest.json`, `README.txt`
and `apks/`. `apks/` is the only subdirectory. See [usb-rescue.md](usb-rescue.md).

### 2. Boot

1. Power off the WD My Cloud Home.
2. Insert the stick into the front USB port.
3. Press and **hold the reset button** while powering on.
4. U-Boot runs `boot_rescue_from_usb`, loads the three artifacts from the stick
   root into RAM (initramfs staged at physical `0x02200000`, 4 MiB).
5. The rescue kernel boots and runs `/init` as PID 1.

If the box has no factory partition, U-Boot enters the same path
automatically without the reset button.

## Getting the rescue shell instead of the installed system

Normally the rescue init looks for a filesystem labelled `wdmch-root` on the
internal disk and, if it holds a valid system, `switch_root`s into it. To skip
that handoff and get the rescue environment itself, create an empty file named
`norescue` in the **root** of the stick:

```bash
touch /mnt/stick/norescue
```

Remove the file to restore normal handoff.

## SSH access

1. Find the IP from the serial console or the router's DHCP lease.
2. `ssh root@<ip>` — dropbear listens on **port 22**.
3. **Public-key authentication only.** No root password is configured and
   password auth is refused. The key is baked in at build time from
   `WDMCH_SSH_AUTHORIZED_KEY`.

## Booting the installed system

Normally automatic: the rescue init finds `wdmch-root`, mounts it and switches
root, so the box continues into the installed Alpine with the stick still
plugged in.

To boot without the stick, on the installed system:

```bash
/usr/local/sbin/boot-full-alpine   # prepares kexec from the on-disk /boot
kexec -e                           # reboots into it
```

## Recovery boundary

### DO NOT

- **DO NOT boot the GOLD partition.** GOLD is a factory-reset appliance, not a
  safe fallback.
- **DO NOT write the A/B/GOLD firmware slots.**
- **DO NOT repartition the internal disk.** The factory GPT has 24 fixed
  partitions; destroying it can leave the box unbootable.
- **DO NOT flash any firmware** without a firmware-table backup first.

### DO

- **DO back up the firmware table** (p1) before any flashing work:

  ```bash
  dd if=/dev/sda1 of=fw-table-backup.bin bs=512
  ```

- **DO** keep a second known-good stick if the box has user data on it.
- **DO** use `sgissi/wdmch-tools` (`fwtablectl`) for firmware-table work, if
  ever needed.
- **DO** test on non-production hardware first.

## Serial console

Indicative output. Exact text varies with kernel configuration and hardware
revision — this is not byte-for-byte guaranteed.

```text
U-Boot > boot_rescue_from_usb
Loading file from usb0 ... OK

[    0.000000] Booting Linux on physical CPU 0x0
[    0.000000] Linux version 6.18.x
[    0.000000] Machine model: WD My Cloud Home
[    0.000000] Memory: 1024MB
[    0.000000] Console: ttyS0
...
=== WDMCH Rescue Init ===
```

## When a boot fails

Go to [DEBUGGING.md](DEBUGGING.md) for symptom-by-symptom diagnosis: no boot
from USB, kernel panic, header values, no network, SSH refused, kexec
failures, and how to read `/proc/partitions` and `dmesg` from a live rescue
shell.
