# docs/INSTALL.md

# Installation Guide

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
bash dtb/verify-dtb.sh
```

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
