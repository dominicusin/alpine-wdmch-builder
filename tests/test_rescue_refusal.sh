#!/usr/bin/env bash
# Test install-alpine's refusal to touch the boot medium.
#
# This is the most dangerous logic in the project. On this hardware the rescue
# USB stick claims /dev/sda, so a careless `install-alpine /dev/sda` would
# erase the very stick the system is running from, and the only recovery is a
# firmware-level reflash. ROADMAP.md stage 2 exists to confirm the refusal on
# the real box.
#
# It had no test at all, which is not good enough for a guard whose failure
# destroys the boot medium - and it does not need hardware to exercise: the
# decision is made from a mount table.
#
# The block is extracted from the shipping script, so this test cannot drift
# from what ships. Two substitutions make it runnable here:
#   [ -b "$part" ]  ->  is_block "$part"     (no real block devices in a test)
# and install-alpine reads ${PROC_MOUNTS:-/proc/mounts}, which is the real
# file when unset, so shipping behaviour is unchanged.
set -Eeuo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJ_DIR/rootfs/install-alpine"

test -f "$SRC" || { echo "FAIL: $SRC not found"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$SRC" > "$WORK/guards.raw" <<'PY'
import sys
s = open(sys.argv[1]).read()
start = s.index('[ "$ROOT_PART" = "1" ]')
end = s.index('# A rescue stick always carries our own boot files')
sys.stdout.write(s[start:end])
PY

test -s "$WORK/guards.raw" || { echo "FAIL: could not extract the refusal block"; exit 1; }
grep -q 'stick_whole' "$WORK/guards.raw" \
    || { echo "FAIL: extraction lost the rescue-stick guard"; exit 1; }

# Turn the block-device test into a seam we can drive.
sed 's/\[ -b "\$part" \]/is_block "$part"/g' "$WORK/guards.raw" > "$WORK/guards.sh"
grep -q 'is_block' "$WORK/guards.sh" \
    || { echo "FAIL: could not install the is_block seam"; exit 1; }

FAILED=0

run_case() {
    # $1 label  $2 root part  $3 existing nodes (one per line)  $4 mount table  $5 want
    local label="$1" rootpart="$2" nodes="$3" mounts="$4" want="$5" out got

    printf '%s\n' "$nodes" > "$WORK/nodes"
    printf '%s\n' "$mounts" > "$WORK/mounts"

    set +e
    out=$(
        export DISK=/dev/sda ROOT_PART="$rootpart" PROC_MOUNTS="$WORK/mounts"
        is_block() { grep -qxF "$1" "$WORK/nodes"; }
        # shellcheck disable=SC1090
        . "$WORK/guards.sh" >/dev/null 2>&1
        echo PROCEED
    )
    set -e

    if printf '%s' "$out" | grep -q '^PROCEED$'; then got=proceed; else got=refuse; fi

    if [ "$got" = "$want" ]; then
        printf '  ok    %-48s -> %s\n' "$label" "$got"
    else
        printf '  FAIL  %-48s -> %s (expected %s)\n' "$label" "$got" "$want"
        FAILED=1
    fi
}

echo "=== install-alpine refusal guards ==="
echo
echo "--- the rescue-stick guard, keyed on /media/usb ---"

# 1. The case the guard exists for: the stick is sda1 and we were told /dev/sda.
run_case "stick is sda1, told to install to /dev/sda" 20 \
    "/dev/sda1
/dev/sda2" \
    "/dev/sda1 /media/usb vfat rw,relatime 0 0" \
    refuse

# 2. Internal SATA is the target and the stick is a different disk.
run_case "sata is sda, stick is sdb1 -> safe to proceed" 20 \
    "/dev/sda1
/dev/sda20
/dev/sdb1" \
    "/dev/sdb1 /media/usb vfat rw,relatime 0 0" \
    proceed

# 3. The stick is the second partition of the target disk.
run_case "stick is sda2, told /dev/sda" 20 \
    "/dev/sda1
/dev/sda2" \
    "/dev/sda2 /media/usb vfat rw,relatime 0 0" \
    refuse

# 4. Nothing at /media/usb - a normal boot.
run_case "no /media/usb mount (normal boot)" 20 \
    "/dev/sda1
/dev/sda20" \
    "/dev/sda20 / ext4 rw,relatime 0 0" \
    proceed

# 5. sda1 is mounted somewhere that is not /media/usb. The mount-table guard
#    is specifically about the rescue mount point, so it must not fire; the
#    boot-file probe later in install-alpine is the backstop, and that needs
#    a real mount so it is not covered here.
run_case "sda1 mounted at /mnt/data, not /media/usb" 20 \
    "/dev/sda1
/dev/sda20" \
    "/dev/sda1 /mnt/data ext4 rw,relatime 0 0" \
    proceed

# 6. p20 is the real target; make sure the guard does not fire on it.
run_case "stick is sdb1 and target is p20 -> safe" 20 \
    "/dev/sda1
/dev/sda20
/dev/sdb1" \
    "/dev/sdb1 /media/usb vfat rw,relatime 0 0" \
    proceed

echo
echo "--- the p1 firmware-table guard, independent of the mount table ---"

run_case "p1 as --root-part (firmware table)" 1 \
    "/dev/sda1
/dev/sda20" \
    "/dev/sda1 /media/usb vfat rw,relatime 0 0" \
    refuse

run_case "p20 as --root-part, stick elsewhere" 20 \
    "/dev/sda1
/dev/sda20
/dev/sdb1" \
    "/dev/sdb1 /media/usb vfat rw,relatime 0 0" \
    proceed

echo
if [ "$FAILED" -eq 0 ]; then
    echo "install-alpine refusal guards: PASSED"
else
    echo "install-alpine refusal guards: FAILED" >&2
    exit 1
fi
