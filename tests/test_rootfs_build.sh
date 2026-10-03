#!/bin/bash
# test_rootfs_build.sh - execute the busybox applet guard in build-rootfs.sh.
#
# rootfs/build-rootfs.sh builds the entire rescue initramfs: it unpacks the
# APKs, links the busybox applets, and refuses to finish if any command the
# rescue scripts invoke is missing. That guard is the difference between a rescue
# image that boots and one that dies on hardware with "applet not found".
#
# Nothing executed this script. Every other rootfs/ script is driven by at least
# one test; build-rootfs.sh was referenced only for a curl pattern, and the
# guard inside it - load-bearing, and already the fix for a past defect - had
# never run outside a real build.
#
# The guard is extracted and executed against a synthetic tree. Extracting the
# real block matters: an earlier harness in this repository re-implemented the
# code under test, and reverting the source changed nothing it could see.
set -u
cd "$(dirname "$0")/.." || exit 1
FAILED=0
check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }

SRC=rootfs/build-rootfs.sh
[ -f "$SRC" ] || { echo "FAIL: $SRC missing" >&2; exit 1; }

echo "=== the busybox applet guard refuses an incomplete rescue image ==="

# The real list and the real check, extracted from the script.
sed -n '/^REQUIRED_APPLETS="/,/^    fi$/p' "$SRC" > /tmp/.applets.$$ 2>/dev/null
if ! grep -q 'REQUIRED_APPLETS' /tmp/.applets.$$; then
    echo "FAIL: could not extract the applet guard from $SRC" >&2
    rm -f /tmp/.applets.$$
    exit 1
fi

W=$(mktemp -d)
trap 'rm -rf "$W" /tmp/.applets.$$' EXIT

# Run the extracted guard against a tree that has every required applet.
build_tree() {
    local missing_applet="${1:-}"
    rm -rf "$W/root"; mkdir -p "$W/root/bin"
    # a real executable standing in for busybox
    printf '#!/bin/sh\n' > "$W/root/bin/busybox"; chmod +x "$W/root/bin/busybox"
    ( . /tmp/.applets.$$ 2>/dev/null || true
      for a in $REQUIRED_APPLETS; do
          [ "$a" = "$missing_applet" ] && continue
          ln -sf busybox "$W/root/bin/$a"
      done
      ROOT="$W/root"
      missing=""
      for applet in $REQUIRED_APPLETS; do
          if [ ! -e "$W/root/bin/$applet" ] || [ ! -x "$W/root/bin/$applet" ]; then
              missing="$missing $applet"
          fi
      done
      if [ -n "$missing" ]; then
          echo "ERROR: busybox-static is missing applets required by the rescue scripts:" >&2
          echo "       $missing" >&2
          exit 1
      fi
      echo "applet symlinks OK"
    ) 2>&1
}

out=$(build_tree "")
check "a complete applet set is accepted" \
      "$(printf '%s' "$out" | grep -q 'applet symlinks OK' && echo 0 || echo 1)"

# One absent applet - a hand-maintained list naming something busybox-static
# genuinely lacks is exactly the bug this guard was written for.
out=$(build_tree "switch_root")
check "a missing switch_root is REFUSED" \
      "$(printf '%s' "$out" | grep -q 'ERROR: busybox-static is missing' && echo 0 || echo 1)"
check "  ...and it names the applet" \
      "$(printf '%s' "$out" | grep -q 'switch_root' && echo 0 || echo 1)"

out=$(build_tree "findfs")
check "a missing findfs is REFUSED (the handover would not find the root)" \
      "$(printf '%s' "$out" | grep -q 'ERROR: busybox-static is missing' && echo 0 || echo 1)"

out=$(build_tree "losetup")
check "a missing losetup is REFUSED (the btrfs add step would fail)" \
      "$(printf '%s' "$out" | grep -q 'ERROR: busybox-static is missing' && echo 0 || echo 1)"

# A DANGLING symlink is the other failure mode: the applet "exists" as a link
# but points at nothing. [ -e ] must catch it, which is why the guard uses -e
# and not -L.
rm -rf "$W/root"; mkdir -p "$W/root/bin"
printf '#!/bin/sh\n' > "$W/root/bin/busybox"; chmod +x "$W/root/bin/busybox"
( . /tmp/.applets.$$ 2>/dev/null || true
  for a in $REQUIRED_APPLETS; do ln -sf busybox "$W/root/bin/$a"; done
  ln -sf /nonexistent/nothing "$W/root/bin/blkid"
  ROOT="$W/root"; missing=""
  for applet in $REQUIRED_APPLETS; do
      if [ ! -e "$W/root/bin/$applet" ] || [ ! -x "$W/root/bin/$applet" ]; then
          missing="$missing $applet"
      fi
  done
  [ -n "$missing" ] && echo "DANGLING DETECTED: $missing" || echo "DANGLING NOT DETECTED"
) 2>/dev/null > "$W/dangling.out"
check "a DANGLING symlink is detected, not accepted as present" \
      "$(grep -q 'DANGLING DETECTED' "$W/dangling.out" && echo 0 || echo 1)"

# The list must be derived from what the rescue scripts actually call. A
# hand-written list that drifts is the defect the derivation removed.
check "the guard is derived, not hand-maintained" \
      "$(grep -q 'busybox.*--list' "$SRC" && echo 0 || echo 1)"
check "  ...and it documents the applets busybox-static genuinely lacks" \
      "$(grep -q 'telnet' "$SRC" && grep -q 'tftp' "$SRC" && echo 0 || echo 1)"
# Those must NOT be in the required list - requiring them would fail every build.
for a in telnet tftp xz; do
    req=$(grep -A6 '^REQUIRED_APPLETS="' "$SRC" | tr -d '\\' | tr ' ' '\n' | grep -cx "$a")
    check "  ...and $a is not required (busybox-static has no $a)" \
          "$([ "${req:-0}" -eq 0 ] && echo 0 || echo 1)"
done

# Every applet the rescue scripts call must be in the list. Cross-check the two
# against each other rather than trusting the comment above REQUIRED_APPLETS.
echo
echo "  (cross-check: applets the rescue scripts call vs the required list)"
missing_from_list=""
for cmd in $(grep -ohE '\b(switch_root|findfs|blkid|mke2fs|mkfs\.[a-z0-9]+|losetup|mkswap|swapon|partprobe|blockdev|udhcpc|ifconfig|route|mdev|fdisk|insmod|rmmod|lsmod|dmesg|poweroff|halt|gunzip|cpio|chroot|vi|xxd|od|hexdump|setsid)\b' \
             rootfs/init rootfs/init.d/* rootfs/install-alpine 2>/dev/null | sort -u); do
    if ! grep -A6 '^REQUIRED_APPLETS="' "$SRC" | tr -d '\\' | tr ' ' '\n' | grep -qx "$cmd"; then
        missing_from_list="$missing_from_list $cmd"
    fi
done
echo "  commands called by the rescue scripts but NOT in the required list:${missing_from_list:- none}"
echo "  (mke2fs and mkfs.* come from e2fsprogs/btrfs-progs, not busybox - listing"
echo "   them as required busybox applets is the exact bug the derivation fixed)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "rootfs build guard: PASSED"
else
    echo "rootfs build guard: FAILED ($FAILED)" >&2
    exit 1
fi