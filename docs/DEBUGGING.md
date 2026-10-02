# Troubleshooting

Symptom-by-symptom diagnosis for the WDMCH USB rescue image. For the recovery
workflow itself see [RECOVERY.md](RECOVERY.md); for the build and layout
contract see [usb-rescue.md](usb-rescue.md) and [architecture.md](architecture.md).

## Triage order

Work top to bottom. Each step assumes the previous one passed.

1. Verify the stick contents and checksums from a Linux host.
2. Watch the serial console through the U-Boot stage.
3. From a rescue shell, read `/proc/partitions` and `dmesg`.

---

## No boot from USB

**Symptoms:** the box powers on and starts its normal boot, or U-Boot reports a
missing file, or nothing happens at all.

**Cause 1 — files in the wrong place (most common).** The loader reads fixed
filenames from the **root** of the FAT32 stick. A `boot/` subdirectory is wrong:

```bash
ls /mnt/stick/
# sata.uImage  rescue.sata.dtb  rescue.root.sata.cpio.gz_pad.img
# SHA256SUMS  manifest.json  README.txt  apks/
```

**Cause 2 — corrupt copy.** Always check:

```bash
cd /mnt/stick && sha256sum -c SHA256SUMS
```

Every listed file must report `OK`. A single `FAILED` means re-copy the file.

**Cause 3 — wrong initramfs size.** The loader reads exactly 4194304 bytes:

```bash
stat -c '%s' /mnt/stick/rescue.root.sata.cpio.gz_pad.img
# must print exactly: 4194304
```

Too short reads garbage; too large gets truncated and the tail of the cpio
archive is lost.

**Cause 4 — wrong filesystem or partition table.** The stick must be FAT32 with
an MBR and a single partition. exFAT and NTFS are not supported here. (An ext4
stick is sometimes listed in older notes; treat that as **unverified** unless
you have tested it on your own unit.)

**Cause 5 — reset button not held.** Hold reset while applying power, not after.
Alternatively, if the box has no factory partition, U-Boot takes the USB path on
its own.

**Cause 6 — `sata.uImage` was gzipped or wrapped.** It must be a raw ARM64
`Image` plus zero padding, not an `mkimage`/FIT container and not compressed.

---

## Kernel panic or early hang

**Symptoms:** U-Boot loads the files fine, then nothing, or a panic on serial.

**Check the header patch first.** The first bytes of `sata.uImage` must decode as:

```text
code0       = 0x91005A4D   (offset 0)
text_offset = 0x200000     (offset 8)
pe_offset   = 0x40         (offset 60)
```

Verify on a host. The repo ships the real check, so prefer it:

```bash
python3 tools/check-image-header.py build/release/sata.uImage
```

Against a bare stick (no repo checkout) this standalone version prints each
field and states whether it matches, instead of only showing the numbers:

```bash
python3 - <<'EOF'
import struct, sys
d = open('sata.uImage', 'rb').read(64)
if len(d) < 64:
    sys.exit("FAIL: sata.uImage is shorter than 64 bytes")
got = {
    'code0':       struct.unpack_from('<I', d, 0)[0],
    'text_offset': struct.unpack_from('<Q', d, 8)[0],
    'pe_offset':   struct.unpack_from('<I', d, 60)[0],   # u32, not u64
}
want = {'code0': 0x91005A4D, 'text_offset': 0x200000, 'pe_offset': 0x40}
bad = 0
for k in ('code0', 'text_offset', 'pe_offset'):
    ok = got[k] == want[k]
    bad += not ok
    print(f"{k:<12} = 0x{got[k]:08X}   expected 0x{want[k]:08X}   {'OK' if ok else 'MISMATCH'}")
sys.exit(1 if bad else 0)
EOF
```

Note the widths: `code0` and `pe_offset` are **32-bit**, only `text_offset` is
64-bit. Reading `pe_offset` as 8 bytes at offset 60 runs off the end of the
64-byte header and raises `struct.error` instead of printing the value.

All three must match the values above. A `text_offset` of 0 means the header
was never patched, or was patched twice from an already-patched copy.

**Check the padding.** The trailing 512 KiB must be all zero:

```bash
tail -c 524288 /mnt/stick/sata.uImage | tr -d '\0' | wc -c
# must print 0
```

**Check memory in the boot log.** The DTB gives memory a base address of
`0x40000000` and **no size cell** — `reg = <0x00 0x40000000>` — so the size is
whatever the bootloader reports, not something the tree fixes. Read the actual
figure from the kernel's `Memory:` line rather than expecting a particular
total: a board with different DRAM prints a different number, and a `Memory:`
line that disagrees with the hardware means the DTB is wrong or not being
loaded. A mismatched DTB can also panic at a random later address rather than
failing early.

**Check the initramfs is intact**, not just present:

```bash
gzip -t /mnt/stick/rescue.root.sata.cpio.gz_pad.img && echo "gzip stream OK"
```

---

## No network / no DHCP lease

**Symptoms:** the rescue shell comes up but there is no address on `eth0`.

- **Ethernet driver:** the `r8169soc` GMAC driver is built into the kernel. This
  project builds no kernel modules, so there is nothing to `insmod` — if the
  interface is missing, it is a kernel/DTB problem, not a missing module.
- **Link state:**

  ```bash
  ifconfig eth0
  cat /sys/class/net/eth0/carrier        # 1 = link up
  dmesg | grep -i -E 'r8169|stmmac|link'
  ```

- **DHCP:** confirm the lease attempt and the address in use:

  ```bash
  dmesg | grep -i dhcp
  ifconfig eth0 | grep 'inet addr\|inet '
  ```

  If DHCP fails, the rescue init falls back to a static `192.168.1.222/24` and
  prints a warning. Connect on that subnet directly if your LAN uses a
  different range.
- **Cable and switch port:** a dead link will not get a lease. Check the LEDs.

---

## SSH refused or rejecting the key

**Symptoms:** connection refused, timeout, or `Permission denied (publickey)`.

```bash
ss -ltn 2>/dev/null | grep :22 || netstat -ltn | grep :22
ps | grep dropbear
```

- **Connection refused** — dropbear is not running. Check the rescue init output
  on serial, and confirm `/usr/sbin/dropbear` exists in the initramfs.
- **Permission denied (publickey)** — the key is baked in at build time from
  `WDMCH_SSH_AUTHORIZED_KEY`. Confirm the same public key you supplied is in
  `~/.ssh/authorized_keys` on your client machine (it must be the `.pub`).
- **Password auth will never work.** There is no root password by design; dropbear
  runs public-key only on port 22.
- **Timeout** — you have the wrong address. See the network section above.

---

## Reading the disk from a rescue shell

```bash
cat /proc/partitions
```

You should see the factory GPT's 24 partitions. Use it to confirm:

- p1 (`<disk>1`) is `FW_TABLE` — back it up before any flashing work:
  `tools/backup-fw-table.sh`
  `/dev/sda1` is the USB stick in a rescue shell, not the firmware table — use `tools/backup-fw-table.sh`, which picks the internal disk.
- p20 (`sda20`) is `SYSTEM_B` — this is the partition the installer writes, and
  it carries the ext4 label `wdmch-root` after installation.

```bash
dmesg | tail -50
```

`dmesg` is the fastest way to see whether the SATA link came up, whether the
disk was enumerated, and where a boot actually stopped. If the box stops before
`/proc/partitions` shows anything, the kernel or DTB is the problem, not the
initramfs.

---

## kexec failures

Relevant only when using the no-stick path from the installed system.

```bash
/usr/local/sbin/boot-full-alpine    # prepare the kexec entry
kexec -e                            # reboot into it
```

- **`kexec -e` reports no entry** — `boot-full-alpine` did not run, or it failed.
  Check that the kernel and DTB are present in the installed system's on-disk
  `/boot` directory.
- **Loops back into rescue / reboots into nothing** — the kexec entry points at
  a kernel the box cannot start. Re-run `boot-full-alpine` and re-check the
  paths it reports before executing `kexec -e`.
- **"kexec failed or need reboot"** — usually a kernel/initrd mismatch rather
  than a genuine failure; it succeeds on the reboot.
- The kexec path is **optional**. If it does not work, the stick-based rescue
  boot remains the reliable route.

---

## Getting back to a rescue shell

If the box boots into a broken installed system instead of the rescue
environment, you have not lost the device:

1. Power off.
2. Insert the known-good FAT32 stick.
3. Hold the reset button while powering on.
4. If the rescue init still switches into the installed system, add an empty
   file named `norescue` to the **root** of the stick and retry.
5. You now have a shell over SSH or serial, and can fix the installed system.

Nothing in the rescue path requires the box to be bootable from its own disk —
that is precisely why the stick path exists.
