# Release Checklist

## Pre-Release Verification

### Source Integrity

- [ ] `symops/monarch-6.18` is pinned to a known commit
- [ ] `KERNEL_REF` in `config/source-lock.env` is not `HEAD` or empty
- [ ] All required source repositories are referenced
- [ ] Historical references (`ealain/alpine-nas`, `Johns-Q/wdmc-gen2`, `symops/MCG1-6.18`) are classified as such

### Kernel Validation

- [ ] Kernel builds from pinned source
- [ ] `rtd1295-wd-mycloud-home.dtb` is generated and validated
- [ ] Image header has `code0=0x91005A4D`, `text_offset=0x200000`, `pe_offset=0x40`
- [ ] Required capabilities are enabled (SATA, Ethernet, USB, DT, kexec)
- [ ] Kernel modules match the built kernel release

### Rootfs Validation

- [ ] Alpine aarch64 minirootfs is checksum-verified
- [ ] `/lib/modules/<kernel-release>` is present and matches
- [ ] `/init` is executable and runs as PID 1
- [ ] DHCP on `eth0` is configured
- [ ] Dropbear SSH is configured with public-key only
- [ ] No root password is set
- [ ] `/usr/local/sbin/boot-full-alpine` exists (optional kexec)

### Artifact Validation

- [ ] `sata.uImage` exists with correct size (kernel + 512 KiB padding)
- [ ] `rescue.sata.dtb` exists and passes FDT validation
- [ ] `rescue.root.sata.cpio.gz_pad.img` is exactly 4 MiB
- [ ] `SHA256SUMS` matches all artifacts
- [ ] `manifest.json` contains correct metadata
- [ ] No private key material in any artifact

### CI/CD Validation

- [ ] `build.yml` runs on `ubuntu-24.04`
- [ ] `checkout` uses explicit major version
- [ ] `release.yml` is gated on version tags
- [ ] Permissions are least-privilege
- [ ] `WDMCH_SSH_AUTHORIZED_KEY` is used only for rootfs creation
- [ ] `validate.yml` runs on push/PR

### Documentation

- [ ] `README.md` has accurate overview and warnings
- [ ] `docs/SOURCES.md` classifies all references correctly
- [ ] `docs/architecture.md` documents the boot chain
- [ ] `docs/usb-rescue.md` describes USB preparation and boot procedure
- [ ] `docs/INSTALL.md` has build instructions
- [ ] `docs/DEBUGGING.md` has troubleshooting steps
- [ ] `docs/RECOVERY.md` documents safety boundaries

### Safety Checks

- [ ] **DO NOT** boot GOLD partition — documented
- [ ] **DO NOT** write A/B/GOLD slots — documented
- [ ] Back up existing WDMCH firmware table before any flashing
- [ ] No build step writes to NAS block devices
- [ ] USB rescue creation is read-only with respect to NAS

### Final Steps

- [ ] Run `./tools/release-audit.sh` — all checks pass
- [ ] Tag with version: `v<version>`
- [ ] GitHub Release publishes correct artifacts
- [ ] `SHA256SUMS` and `manifest.json` are published
- [ ] No private SSH key is in the release

## Post-Release

- [ ] Verify artifacts on non-production WDMCH hardware
- [ ] Document any observed serial output for future reference
- [ ] Update version in `VERSION` file for next release
