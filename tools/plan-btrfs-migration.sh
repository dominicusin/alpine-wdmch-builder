#!/usr/bin/env bash
# plan-btrfs-migration.sh - plan the move to one btrfs spanning p20 + p21.
#
# READ-ONLY. It inspects the target and prints the plan; it never writes.
# The destructive steps are emitted for the operator to run, because a wrong
# profile or a missing precondition here destroys the root filesystem of a
# machine that cannot boot without a USB stick.
#
# WHY THIS IS NEEDED
#   The WDMCH was measured on 2026-10-02 (docs/measurements/2026-10-02-wdmch.md):
#     /dev/md1 = ext4, LABEL=SYSTEM, mounted at /  -> a member of sda20
#     /dev/sda21 = btrfs, LABEL=DATA, 12 mount points
#     md1 is a degraded RAID1 ([2/1]) with sda20 as its only member
#   The md array is a liability, not a safeguard: it will never be repaired,
#   and the "mirror" has exactly one disk. The request is to replace it with a
#   single btrfs spanning sda20 and sda21 and boot from that.
#
# THE CONSTRAINT THAT DECIDES THE PROFILE
#     sda20 = 20 GB        sda21 = 7.3 TB
#     data to place: root ~6.3 GB + subvolumes ~11.5 GB = ~17.7 GB
#
#   Any REDUNDANT profile is limited by the SMALLEST device: raid1 or dup both
#   yield 20 GB usable, which is 88% full before the system is even usable. That
#   is tighter than today AND wastes 7.3 TB.
#
#   So: data profile single, metadata profile dup.
#     - ~7.3 TB usable, which is the point of combining them
#     - metadata kept in two copies across both devices
#     - if a device is lost the filesystem degrades (its own chunks go) rather
#       than disappearing entirely, which is what raid0 would do
#
# THE STEP THAT CANNOT BE DONE FROM A RUNNING SYSTEM
#   / is md1 on sda20. You cannot add sda20 to a filesystem while the root
#   filesystem is still mounted from it. That step needs the rescue image
#   booted from USB - the vendor U-Boot cannot read the internal disk, so this
#   is the only way in. It is ROADMAP stage 1, which has never been executed.

set -u

DISK_A=${DISK_A:-/dev/sda20}     # 20 GB, currently the md1 member / root
DISK_B=${DISK_B:-/dev/sda21}     # 7.3 TB, currently the DATA btrfs
DATA_MOUNT=${DATA_MOUNT:-/data}
# The label the CURRENT installer creates. An earlier version defaulted to
# SYSTEM, the pre-btrfs name, and then planned against that stale value.
ROOT_LABEL=${ROOT_LABEL:-wdmch-root}
NEW_ROOT_LABEL=$ROOT_LABEL
NEW_LABEL=${NEW_LABEL:-WDMCROOT}

pass() { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; BAD=$((BAD+1)); }
info() { echo "  --    $*"; }
BAD=0

echo
echo "==============================================================="
echo "  btrfs migration plan (read-only)"
echo "  $(date -Is 2>/dev/null || date)"
echo "==============================================================="

# --- 1. do both devices exist, and is the layout what we think? --------------
echo
echo "1. Devices"
for d in "$DISK_A" "$DISK_B"; do
    if [ -b "$d" ]; then
        sz=$(lsblk -bndo SIZE "$d" 2>/dev/null || echo 0)
        pass "$(printf '%-14s %14s bytes  %s' "$d" "$sz" "$(numfmt --to=iec --suffix=B "$sz" 2>/dev/null)")"
    else
        bad "$d does not exist"
    fi
done

SA=$(lsblk -bndo SIZE "$DISK_A" 2>/dev/null || echo 0)
SB=$(lsblk -bndo SIZE "$DISK_B" 2>/dev/null || echo 0)

if [ "$SA" -gt 0 ] && [ "$SB" -gt 0 ] && [ "$SA" -lt "$SB" ]; then
    info "asymmetric by $(numfmt --to=iec "$((SB/SA))")x - this is what rules out raid1"
else
    bad "expected $DISK_A to be much smaller than $DISK_B; re-check the layout"
fi

# --- 2. what is on them right now -------------------------------------------
echo
echo "2. Current state"
ta=$(lsblk -bno TYPE,FSTYPE,PARTLABEL,MOUNTPOINT "$DISK_A" 2>/dev/null | tr -s ' ')
tb=$(lsblk -bno TYPE,FSTYPE,PARTLABEL,MOUNTPOINT "$DISK_B" 2>/dev/null | tr -s ' ')
info "$DISK_A : $ta"
info "$DISK_B : $tb"

ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null || echo '?')
info "root is currently: $ROOT_SRC"
if [ "$ROOT_SRC" = "/dev/md1" ]; then
    info "  -> md1 spans $DISK_A; this is the RAID being removed"
elif echo "$ROOT_SRC" | grep -q md; then
    info "  -> root is an md array; the plan below assumes $DISK_A is its only member"
fi

MDLINE=$(grep -E '^md[0-9]+ *:' /proc/mdstat 2>/dev/null | head -1)
[ -n "$MDLINE" ] && info "mdstat: $MDLINE"

# --- 3. how much data has to move -------------------------------------------
echo
echo "3. Data to place"
ROOT_USED=$(du -sx --block-size=1 / 2>/dev/null | awk '{print $1}' || echo 0)
DATA_USED=$(btrfs filesystem usage -b "$DATA_MOUNT" 2>/dev/null | awk '/Used:/ {print $2}' | head -1)
DATA_USED=${DATA_USED:-$(du -sx --block-size=1 "$DATA_MOUNT" 2>/dev/null | awk '{print $1}')}
NEED=$(( ${ROOT_USED:-0} + ${DATA_USED:-0} ))
info "root (all of /)        ~$(numfmt --to=iec "${ROOT_USED:-0}")"
info "existing btrfs on $DISK_B ~$(numfmt --to=iec "${DATA_USED:-0}")"
info "total to place          ~$(numfmt --to=iec "$NEED")"

echo
echo "  Capacity under each candidate profile:"
printf "    %-28s %s\n" "single data + dup metadata" "$(numfmt --to=iec "$SB")   <- chosen"
printf "    %-28s %s\n" "raid1 / dup (redundant)" "$(numfmt --to=iec "$SA")    <- would be $(awk -v n=$NEED -v s=$SA 'BEGIN{printf "%.0f%% full", n*100/s}') before use"
printf "    %-28s %s\n" "raid0" "$(numfmt --to=iec $((SA+SB)))   <- any device loss is total loss"

# --- 4. prerequisites --------------------------------------------------------
echo
echo "4. Prerequisites"
command -v btrfs >/dev/null 2>&1 && pass "btrfs-progs present ($(btrfs --version 2>/dev/null | head -1))" \
                                 || bad "btrfs-progs missing"
command -v rsync >/dev/null 2>&1 && pass "rsync present" || bad "rsync missing (needed to place the root)"
if command -v mdadm >/dev/null 2>&1; then
    pass "mdadm present"
else
    bad "mdadm is NOT installed - the md1 array cannot be stopped or reassembled"
    info "this is a real blocker: installing it is a package change on a live host"
fi
if sudo -n true 2>/dev/null; then pass "passwordless sudo"; else bad "no passwordless sudo"; fi

AVAIL=$(df -B1 --output=avail "$DATA_MOUNT" 2>/dev/null | tail -1 | tr -d ' ')
if [ -n "${AVAIL:-}" ] && [ "$AVAIL" -gt "$NEED" ]; then
    pass "staging space on $DISK_MOUNT available: $(numfmt --to=iec "$AVAIL")"
else
    bad "not enough room on $DATA_MOUNT to stage the root before the switch"
fi

# --- 5. can this even be done from a running system? -------------------------
echo
echo "5. Sequencing - the part that decides when it can run"
if echo "$ROOT_SRC" | grep -q md; then
    info "root is mounted from an md array on $DISK_A."
    info "  => $DISK_A CANNOT be added to a filesystem while / is mounted from it."
    info "  => the machine must be running something else: the rescue image from USB."
    info "  => that is ROADMAP stage 1, and it has never been executed on this box."
    bad "cannot complete while booted from the current root"
fi

# --- 6. the plan -------------------------------------------------------------
cat <<WDECH_PLAN_END

PLAN
  0. VERIFY FIRST, from a rescue boot, before anything is written:
       lsblk -f; cat /proc/mdstat; blkid /dev/sda20 /dev/sda21
       Confirm the only md member is $DISK_A and nothing else is on it.

  1. BACK UP, while the system is still up. There is no usable backup today
     (/var/backups is 15 MB). Roughly $(numfmt --to=iec "$NEED") to stage:
       restic -r /data/backup init          # or a plain rsync to $DATA_MOUNT
     Do not skip this. The vendor loader cannot boot the internal disk; if the
     migration goes wrong the only way back in is the rescue stick.

   2. Format BOTH partitions as ONE new filesystem. This is what
      rootfs/install-alpine does; do not hand-roll it.

        mkfs.btrfs -f -d single -m raid1 -L $NEW_ROOT_LABEL \
            $DISK_A $DATA_MOUNT_DEV

      $DATA_MOUNT_DEV is /dev/sda21, NOT the /data mountpoint. Read it from
      findmnt, never guess:
        DATA_MOUNT_DEV=$(findmnt -no SOURCE /data | sed 's/\[.*\]//')

      -d single on data: a RAID1 data profile across a 20 GiB device and a
      7.3 TiB device caps usable space at the smaller member.
      -m raid1 on metadata: mirrored across both members, so losing either one
      leaves the filesystem mountable and scrubbable.

   3. RUN THE INSTALLER, which formats, populates and writes the fstab:
        /media/usb/rootfs/install-alpine

      It refuses to run while either partition is in use, if the factory GPT is
      absent, or if the rescue stick is missing. All three are true right now,
      because md1 is still live. That refusal is correct, and it is why this
      plan cannot be executed from the running system at all.

   4. Only after the installer reports success: remove md1.
        mdadm --stop /dev/md1
      Do NOT assemble it again. Nothing new on this machine uses md; the array
      belonged to the system being replaced.

   5. VERIFY BEFORE REBOOTING:
        btrfs filesystem show /mnt/install   # must list TWO devices
        btrfs filesystem usage /mnt/install
        blkid $DISK_A $DATA_MOUNT_DEV       # same UUID on both, label $NEW_ROOT_LABEL

   WHAT THIS PLAN DESTROYS
      Everything currently on $DISK_A and $DATA_MOUNT_DEV - /nix, /guix, /home,
      /var and whatever /data holds. Step 1 is not optional.

   WHAT THIS PLAN DOES NOT DO
      It does not reuse the existing filesystem on /data, does not rsync a live
      system onto it, and does not make / a subvolume of it. An earlier version
      of this file proposed all three and was wrong: it preserved the old layout
      at the cost of the one this project actually ships.


ROLLBACK
  Steps 2-3 are additive and reversible (btrfs device delete).
  Step 4 is additive and reversible (btrfs subvolume delete).
  Steps 5-7 are the irreversible ones; before them, the step-1 backup is the
  only way back.

WHAT I CANNOT DO
  Formatting is blocked for me. Every destructive command above is yours to
  run, which is the correct division: I can plan and verify, and I will not
  create the filesystem that a failed boot would leave unrecoverable.

WDECH_PLAN_END
echo
echo "==============================================================="
if [ "$BAD" -eq 0 ]; then
    echo "  Plan is coherent; the blockers above are sequencing, not design."
else
    echo "  $BAD problem(s) above must be resolved before starting."
fi
echo "==============================================================="
exit 0