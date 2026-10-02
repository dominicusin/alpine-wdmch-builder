#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$1"
RELEASE="$2"
PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"

test -x "$ROOT/init" || { echo "FAIL: init not executable"; exit 1; }
test -x "$ROOT/bin/busybox" || { echo "FAIL: busybox not found"; exit 1; }
test -x "$ROOT/usr/sbin/dropbear" || { echo "FAIL: dropbear not found"; exit 1; }
test -f "$ROOT/etc/network/interfaces" || { echo "FAIL: network/interfaces missing"; exit 1; }
test -f "$ROOT/root/.ssh/authorized_keys" || { echo "FAIL: authorized_keys missing"; exit 1; }
test -x "$ROOT/etc/init.d/99-disk-root" || { echo "FAIL: 99-disk-root handoff script not executable"; exit 1; }
test -x "$ROOT/usr/local/sbin/verify-install" || {
    echo "FAIL: verify-install not shipped in the rescue image"
    echo "      install-alpine copies it onto the target so the operator can"
    echo "      health-check the box after the first boot"
    exit 1
}
sh -n "$ROOT/usr/local/sbin/verify-install" || {
    echo "FAIL: verify-install is not valid POSIX sh"; exit 1; }

# flash.zip must contain exactly the packages the resolver says are in the
# closure - no more, no fewer. `zip -r` against an existing archive only adds
# and updates entries, so a package removed from the stick tree used to
# survive in the artifact indefinitely and never appear in any review.
if [ -f "$PROJ_DIR/build/flash.zip" ]; then
    echo "Checking flash.zip package set matches the resolver closure"
    python3 - "$PROJ_DIR" <<'PY'
import re, subprocess, sys, zipfile, os
repo = sys.argv[1]
idx = os.path.join(repo, "build/usb-tree-root/apks")
main_i = os.path.join(idx, "main/APKINDEX.tar.gz")
comm_i = os.path.join(idx, "community/APKINDEX.tar.gz")
# Both of these are hard failures, not skips. This guard exists to catch a
# package that reached flash.zip without being in the closure; if the
# resolver is broken or the offline repo was never built, the check cannot
# run and reporting success would hide exactly the bug it was written for.
if not (os.path.exists(main_i) and os.path.exists(comm_i)):
    print(f"  FAIL: offline APKINDEX missing under {idx}")
    print("        the closure check cannot run; run `make package` first")
    sys.exit(1)
# The seeds are READ FROM image/dl-packages.sh, not restated here.
#
# This list used to be a second, hand-maintained copy of the one in
# dl-packages.sh. Adding btrfs-progs there - required now, because mkfs.btrfs is
# not in busybox and the installer cannot create its filesystem without it - left
# this copy untouched, so the check recomputed a 35-package closure and reported
# btrfs-progs, eudev-libs, lzo and zstd-libs as being in flash.zip "but not in
# the closure". CI caught it; this checkout could not, because build/flash.zip
# predated the seed.
#
# Two copies of a fact drift. Reading the declaration means the next seed added
# cannot break this check, which is the point of the check.
seed_src = os.path.join(repo, "image/dl-packages.sh")
m = re.search(r"^SEEDS=\(([^)]*)\)", open(seed_src, encoding="utf-8").read(), re.M)
if not m:
    print(f"  FAIL: no SEEDS=(...) declaration in {seed_src}")
    print("        the closure check cannot run; reporting success would hide")
    print("        exactly the drift this check exists to catch")
    sys.exit(1)
seeds = m.group(1).split()
out = subprocess.run([sys.executable, os.path.join(repo, "image/resolve-deps.py"),
                      "--tsv", "--main", main_i, "--community", comm_i] + seeds,
                     capture_output=True, text=True, cwd=repo)
if out.returncode != 0:
    print(f"  FAIL: image/resolve-deps.py exited {out.returncode}")
    sys.stderr.write(out.stderr)
    sys.exit(1)
want = {l.split("\t")[3].split("/")[-1] for l in out.stdout.splitlines() if l.count("\t") >= 3}
with zipfile.ZipFile(os.path.join(repo, "build/flash.zip")) as z:
    have = {n.split("/")[-1] for n in z.namelist() if n.endswith(".apk")}
extra, missing = have - want, want - have
if extra or missing:
    for n in sorted(extra):
        print(f"  FAIL: {n} is in flash.zip but not in the closure")
    for n in sorted(missing):
        print(f"  FAIL: {n} is in the closure but missing from flash.zip")
    sys.exit(1)
print(f"  {len(have)} packages, exactly the closure: OK")
PY
    [ $? -eq 0 ] || exit 1
fi

# The installed system gets /sbin/init from busybox's .post-install
# (`busybox --install -s`) plus its /sbin trigger. apk skips BOTH under
# --no-scripts, so passing that flag on the target install silently yields a
# rootfs with no init: 99-disk-root refuses to hand over and the box never
# boots. Only the throwaway e2fsprogs pull may use --no-scripts.
echo "Checking the target install keeps package scripts enabled"
if python3 - "$PROJ_DIR/rootfs/install-alpine" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
for m in re.finditer(r'"\$APK" add(?:(?!^\S).)*?(?=^\S)', src, re.S | re.M):
    blk = m.group(0)
    if '--root "$MNT"' in blk and '--no-scripts' in blk:
        sys.exit(1)
sys.exit(0)
PY
then
    echo "  target install runs package scripts: OK"
else
    echo "  FAIL: --no-scripts on the target apk add (/sbin/init would never be created)"
    exit 1
fi

# This image deliberately ships ZERO kernel modules: every driver the rescue
# needs is built into the kernel, so $ROOT/lib/modules/$RELEASE does not exist
# and must not be required. Assert the built-in contract instead -- if a
# required driver drops to =m the rescue kernel cannot mount the internal SATA
# disk, read the USB stick, or bring up Ethernet.
echo "Checking built-in kernel drivers (kernel release: ${RELEASE})"
KERNEL_CONFIG="$PROJ_DIR/config/kernel.config"
if [ ! -f "$KERNEL_CONFIG" ]; then
    echo "FAIL: kernel config not found: $KERNEL_CONFIG"
    exit 1
fi

BUILTIN_REQUIRED="
CONFIG_SCSI
CONFIG_BLK_DEV_SD
CONFIG_SATA_HOST
CONFIG_SATA_AHCI
CONFIG_AHCI_RTD1295
CONFIG_PHY_RTK_RTD_SATAPHY
CONFIG_R8169SOC
CONFIG_REALTEK_PHY
CONFIG_USB_STORAGE
CONFIG_EXT4_FS
CONFIG_VFAT_FS
"

missing=0
for opt in $BUILTIN_REQUIRED; do
    if grep -q "^${opt}=y" "$KERNEL_CONFIG"; then
        echo "  $opt: built-in"
    else
        echo "  FAIL: $opt is not built into the kernel (no modules are shipped)"
        missing=1
    fi
done
[ "$missing" -eq 0 ] || { echo "FAIL: required drivers must be =y, not =m"; exit 1; }

# Check no password auth in sshd_config if it exists
if [ -f "$ROOT/etc/ssh/sshd_config" ]; then
    if grep -RqsE '^(PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords)' "$ROOT/etc/ssh" 2>/dev/null; then
        # Allow if commented out, fail if active settings enable password
        grep -E '^(PermitRootLogin yes|PasswordAuthentication yes|PermitEmptyPasswords yes)' "$ROOT/etc/ssh/sshd_config" 2>/dev/null && { echo "FAIL: password auth enabled"; exit 1; }
    fi
fi

echo "Rootfs validation PASSED"
