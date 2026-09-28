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
- [ ] Every WDMCH-critical driver is `=y`, not `=m` — this image ships **zero
      kernel modules**, so anything built modular is unavailable before `/init`
      runs. Asserted by `tests/test_rootfs.sh` against `config/kernel.config`.

### Rootfs Validation

- [ ] Alpine aarch64 minirootfs is checksum-verified
- [ ] `/init` is executable and runs as PID 1
- [ ] `etc/init.d/99-disk-root` is executable (the `switch_root` handoff)
- [ ] DHCP on `eth0` is configured
- [ ] Dropbear SSH is configured with public-key only
- [ ] No root password is set
- [ ] The target `apk add` runs package scripts — `--no-scripts` skips
      busybox's `.post-install`, so `/sbin/init` would never be created and the
      installed system could not boot. Asserted by `tests/test_rootfs.sh`.

> `boot-full-alpine` is **not** a build artifact. It is written onto the target
> filesystem by `install-alpine` at install time, so there is nothing to check
> in `build/`; the requirement is that the installer creates it, not that it
> ships.

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
- [ ] The factory 24-partition GPT is preserved — only `p20 SYSTEM_B` is
      written. Creating `sda1`/`sda2` is not a valid layout: the vendor
      initramfs probes `sda9`, `sda18` and `sda19..sda24`, so a rootfs outside
      that range is unreachable and the unit will not boot.
- [ ] `p1 FW_TABLE` is backed up before any write, and is never overwritten
- [ ] The installer refuses to run against the USB stick, which can claim
      `/dev/sda` — formatting it would destroy the boot medium
- [ ] No build step writes to NAS block devices
- [ ] USB rescue creation is read-only with respect to NAS

### Final Steps

- [ ] Run `./tools/release-audit.sh` — all checks pass
- [ ] `VERSION` matches the tag being pushed — `release.yml` derives the
      release name from the `VERSION` **file**, not from the triggering tag,
      so a mismatch publishes new artifacts under the old tag
- [ ] Tag with version: `v<version>`
- [ ] GitHub Release publishes correct artifacts
- [ ] `SHA256SUMS` and `manifest.json` are published
- [ ] No private SSH key is in the release

## Post-Release

- [ ] Verify artifacts on non-production WDMCH hardware
- [ ] ~~Confirm `/sbin/init` exists on the installed system~~ — no longer a hard
      blocker. `install-alpine` recreates `/sbin/init` as a symlink to the
      installed busybox if the package install did not create it, so an install
      cannot end up with a rootfs that cannot boot. Covered by
      `tests/test_install_verify.sh`; still worth confirming on first hardware
      run that the handover actually happens.
- [ ] Document any observed serial output for future reference
- [ ] Update version in `VERSION` file for next release
