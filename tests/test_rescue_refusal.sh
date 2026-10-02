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
sed -e 's/\[ -b "\$part" \]/is_block "$part"/g' \
    -e 's/\[ -b "\$dev" \]/is_block "$dev"/g' "$WORK/guards.raw" > "$WORK/guards.sh"
grep -q 'is_block' "$WORK/guards.sh" \
    || { echo "FAIL: could not install the is_block seam"; exit 1; }

# The factory-table allowlist lives further down, next to the GPT detection.
python3 - "$SRC" > "$WORK/allow.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
start = s.index('# On the factory table, only SYSTEM_A and SYSTEM_B may be written.')
end = s.index('ROOT_DEV="${DISK}${ROOT_PART}"', start)
sys.stdout.write(s[start:end])
PY

test -s "$WORK/allow.sh" || { echo "FAIL: could not extract the partition allowlist"; exit 1; }
grep -q '19|20' "$WORK/allow.sh" \
    || { echo "FAIL: extraction lost the 19/20 allowlist"; exit 1; }

FAILED=0

run_case() {
    # $1 label  $2 root part  $3 existing nodes (one per line)  $4 mount table  $5 want
    local label="$1" rootpart="$2" nodes="$3" mounts="$4" want="$5" out got

    printf '%s\n' "$nodes" > "$WORK/nodes"
    printf '%s\n' "$mounts" > "$WORK/mounts"

    set +e
    out=$(
        export DISK=/dev/sda ROOT_PART="$rootpart" DATA_PART=21 ROOT_LABEL=wdmch-root SINGLE_DEV=0 \
           PROC_MOUNTS="$WORK/mounts" MDSTAT_PATH="$WORK/no-mdstat"
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
echo "--- the factory-table allowlist (only p19/p20 may be written) ---"
echo "    The partition number is checked where the partition table is known,"
echo "    not behind a filesystem probe. Previously the only 19|20 allowlist"
echo "    sat behind 'has ext4', so a GOLD slot without ext4 was writable."

allow_case() {
    # $1 label  $2 root part  $3 has_gpt  $4 blank  $5 want
    local label="$1" rootpart="$2" has_gpt="$3" blank="$4" want="$5" out got

    set +e
    out=$(
        export DISK=/dev/sda ROOT_PART="$rootpart" DATA_PART=21 \
               has_gpt="$has_gpt" BLANK_DISK="$blank" ROOT_LABEL=wdmch-root SINGLE_DEV=0
        # shellcheck disable=SC1090
        . "$WORK/allow.sh" >/dev/null 2>&1
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

allow_case "p20 SYSTEM_B on a factory disk"            20 1 0 proceed
allow_case "p19 SYSTEM_A on a factory disk"            19 1 0 proceed
allow_case "p9 ROOTFS_GOLD on a factory disk"           9 1 0 refuse
allow_case "p2 KERNEL_A on a factory disk"              2 1 0 refuse
allow_case "p18 CONFIG on a factory disk"              18 1 0 refuse
allow_case "p22 DATA on a factory disk"                22 1 0 refuse
allow_case "p24 DISKVOLUME1 on a factory disk"         24 1 0 refuse
allow_case "p1 FW_TABLE on a factory disk"              1 1 0 refuse
# On a blank disk the number is irrelevant: ROOT_DEV is forced to $DISK1.
allow_case "p9 on --blank (ROOT_DEV forced to sda1)"    9 0 1 proceed

echo
echo "--- the factory-GPT detection: a THIRD independent guard ---"
echo "    Even with no rescue mount at all, a stick cannot pass this: it has"
echo "    one FAT32 partition, so p18 and p20 do not exist and has_gpt stays 0."

python3 - "$SRC" > "$WORK/gpt.raw" <<'PY'
import sys
s = open(sys.argv[1]).read()
start = s.index('has_gpt=0\nif [ -b "${DISK}1" ]')
end = s.index('# On the factory table, only SYSTEM_A and SYSTEM_B may be written.', start)
sys.stdout.write(s[start:end])
PY

test -s "$WORK/gpt.raw" || { echo "FAIL: could not extract the GPT detection"; exit 1; }
# The same block-device seam as the rescue guard; without it has_gpt would
# always be 0 and every case here would refuse for the wrong reason.
sed 's/\[ -b "\${DISK}\([0-9]\+\)" \]/is_block "\${DISK}\1"/g' \
    "$WORK/gpt.raw" > "$WORK/gpt.sh"
grep -q 'is_block' "$WORK/gpt.sh" \
    || { echo "FAIL: could not install the is_block seam on the GPT block"; exit 1; }

gpt_case() {
    # $1 label  $2 existing nodes  $3 blank  $4 want
    local label="$1" nodes="$2" blank="$3" want="$4" out got
    printf '%s\n' "$nodes" > "$WORK/nodes"

    set +e
    out=$(
        export DISK=/dev/sda BLANK_DISK="$blank" ROOT_PART=20
        is_block() { grep -qxF "$1" "$WORK/nodes"; }
        log() { :; }
        # shellcheck disable=SC1090
        . "$WORK/gpt.sh" >/dev/null 2>&1
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

# A real rescue stick: one FAT32 partition, nothing else.
gpt_case "rescue stick (only sda1 exists)" \
    "/dev/sda1" 0 refuse

# The factory disk, as it must look.
gpt_case "factory disk (p1, p18, p20 present)" \
    "/dev/sda1
/dev/sda18
/dev/sda20" 0 proceed

# A factory disk missing only p18 must NOT be silently accepted.
gpt_case "factory disk with p18 missing" \
    "/dev/sda1
/dev/sda20" 0 refuse

# An unrelated disk with three partitions that are not the right ones.
gpt_case "unrelated 3-partition disk" \
    "/dev/sda1
/dev/sda2
/dev/sda3" 0 refuse

# The escape hatch, when the operator is certain.
gpt_case "rescue stick shape with --blank" \
    "/dev/sda1" 1 proceed

echo
if [ "$FAILED" -eq 0 ]; then
    echo "install-alpine refusal guards: PASSED"
else
    echo "install-alpine refusal guards: FAILED" >&2
    exit 1
fi
