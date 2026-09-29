# Installation Guide

## Disk layout and what gets written

The WD My Cloud Home disk ships with a **factory GPT containing 24 fixed
partitions**. This project **preserves that table** — it never repartitions the
disk and never writes the A/B/GOLD firmware slots. The full table is documented
in [architecture.md](architecture.md).

The installer writes exactly one partition:

| Target | Action |
|---|---|
| **p20 (`SYSTEM_B`)** | Formatted ext4, filesystem label `wdmch-root`; the Alpine root filesystem is installed here |
| p1 (`FW_TABLE`) and all other partitions | **Untouched** |

Nothing is created and nothing is deleted. This is deliberate: it preserves the
firmware table, the A/B/GOLD firmware slots, your data (p22) and your storage
volume (p24). p20 is also one of the partitions the upstream rescue init already
scans for a root filesystem, so the handoff works without extra configuration.

The bootConfig file in p18 (`CONFIG`) has the form `2:B:2;` — boot state, A-or-B
side, boot attempts. Side **B** is the "Rescue" side and is the correct one for
anything permanent.

## Back up the firmware table first

Before any flashing work, back up p1 (`FW_TABLE`):

```bash
dd if=/dev/sda1 of=fw-table-backup.bin bs=512
```

## Installing Alpine

From the rescue shell (SSH on port 22, public-key auth only):

```bash
install-alpine /dev/sda          # interactive; requires typing YES
install-alpine /dev/sda --yes    # non-interactive
```

Packages come from `apks/` on the USB stick, so no network is needed. The
installer requires explicit confirmation before it writes.

On the next rescue boot the init finds the filesystem labelled `wdmch-root` and
`switch_root`s into the installed system. To get the rescue shell instead,
create an empty file named `norescue` in the **root** of the USB stick.

## Building the Rescue Image

### Prerequisites

- x86_64 Linux host with aarch64 cross-toolchain
- Required tools: `git`, `make`, `gcc`, `dtc`, `python3`, `cpio`, `gzip`, `xz`
- `qemu-user-static` for rootfs testing

### Quick Build

```bash
# Clone the repository
git clone https://github.com/dominicusin/alpine-wdmch-builder.git
cd alpine-wdmch-builder

# Configure build environment (optional)
cp config/build.env.example config/build.env
# Edit config/build.env to add your SSH public key

# Build everything
./build-image.sh
```

### Dry Run

```bash
./build-image.sh --dry-run
```

### Clean Build

```bash
./build-image.sh --clean
./build-image.sh
```

## CI/CD

The repository includes GitHub Actions workflows:

- `build.yml`: Full build on push/PR to main
- `validate.yml`: Validation checks on push/PR
- `release.yml`: Creates GitHub Release on version tags

## Building Locally

### Kernel Build

```bash
bash kernel/fetch-kernel.sh
bash kernel/build-kernel.sh
bash kernel/verify-kernel.sh
```

### DTB Build

```bash
bash dtb/build-dtb.sh
bash tests/test_dtb.sh build/kernel/rtd1295-wd-mycloud-home.dtb \
                        build/kernel/rtd1295-wd-mycloud-home.dts
```

`tests/test_dtb.sh` is the single DTB check — it validates the shipping
binary through `tools/check-fdt.py` and only inspects the decompiled `.dts`
at value level. An earlier `dtb/verify-dtb.sh` duplicated it with an exact
`grep -q 'compatible = "wd,mycloud-home"'`, which passed with one `dtc` build
and failed with another on a byte-identical, correct blob.

### Rootfs Build

```bash
bash rootfs/build-rootfs.sh
```

### Package Artifacts

```bash
bash image/package-rescue.sh
bash image/verify-image.sh
```

## Configuration

Copy `config/build.env.example` to `config/build.env` and set:

```bash
WDMCH_SSH_AUTHORIZED_KEY=ssh-rsa AAAAB3NzaC1yc2E...
```

## Troubleshooting

See [docs/DEBUGGING.md](DEBUGGING.md) for common issues.
