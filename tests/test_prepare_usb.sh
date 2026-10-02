#!/bin/bash
# test_prepare_usb.sh - tools/prepare-usb.sh, which had NO tests at all.
#
# ROADMAP.md claimed this script was "проверенный на заведомо плохих входных
# данных" - verified against deliberately bad inputs. It had never been executed
# by anything: not the Makefile, not a workflow, not a test. Only the
# documentation mentioned it. That is the drift this repository keeps finding -
# a claim about the repo, true when written, false when read - and it was on the
# one tool whose job is to repartition a USB stick.
#
# Only the read-only half is tested. --device writes, and this must never do that.
# The --image path is the script's actual purpose: "prove the stick is bootable",
# using the SHA256SUMS the image ships, so a truncated copy or a wrong layout is
# caught here rather than at the serial console with the WDMCH open.
#
# Every destructive path is asserted to be REACHED AND REFUSED without running it.

set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT=tools/prepare-usb.sh
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT has a syntax error" >&2; exit 1; }

echo "=== prepare-usb.sh ==="

# --- refusals: must happen before anything is written -----------------------
# rc is captured IMMEDIATELY. Inside a command substitution `$?` is whatever the
# previous command in THAT subshell left, not the script's status - so all four
# of these read 0 and report "not refused" for a script that plainly refuses.
# The same trap has now been fixed in five harnesses in this repository, which is
# why it is written out here rather than left to be rediscovered.
bash "$SCRIPT" --bogus >"$W/o" 2>&1; rc=$?
check "an unknown argument is refused" \
      "$(cond "[ $rc -ne 0 ] && grep -q 'unknown argument' '$W/o'"; echo $?)"
bash "$SCRIPT" >"$W/o" 2>&1; rc=$?
check "no --device and no --image is refused" \
      "$(cond "[ $rc -ne 0 ] && grep -q 'give --device' '$W/o'"; echo $?)"
bash "$SCRIPT" --device "$W/not-a-block-device" >"$W/o" 2>&1; rc=$?
check "a non-block --device is refused before it is touched" \
      "$(cond "[ $rc -ne 0 ] && grep -q 'is not a block device' '$W/o'"; echo $?)"
bash "$SCRIPT" --image "$W/no-such-dir" >"$W/o" 2>&1; rc=$?
check "a --image that is not a directory is refused" \
      "$(cond "[ $rc -ne 0 ] && grep -q 'not a directory' '$W/o'"; echo $?)"

# The destructive device path must demand an EXPLICIT device and root. This is
# the check that stops "prepare-usb.sh" with no arguments from picking a disk.
check "the device path cannot run unconfirmed" \
      "$(cond 'grep -q "ASSUME_YES" "$SCRIPT"'; echo $?)"
check "  ...and an internal-looking disk needs --force-internal" \
      "$(cond 'grep -q -- "--force-internal" "$SCRIPT"'; echo $?)"
check "  ...and the confirmation must match the device name" \
      "$(cond 'grep -q "confirmation did not match" "$SCRIPT"'; echo $?)"

# --- the verification path, against a real copy of the built tree ------------
if [ ! -d build/usb-tree-root ]; then
    echo "  SKIP: build/usb-tree-root not built (run 'make package')"
    echo "        the refusal checks above still ran"
    exit $([ "$FAILED" -eq 0 ] && echo 0 || echo 1)
fi

mkdir -p "$W/good"
cp -a build/usb-tree-root/. "$W/good/"

bash "$SCRIPT" --image "$W/good" >"$W/good.log" 2>&1
check "a correct copy of the image PASSES" "$?"
check "  ...and says so" \
      "$(cond 'grep -q "STICK IS GOOD" "$W/good.log"'; echo $?)"

# --- a corrupted file must be caught -----------------------------------------
cp -a "$W/good" "$W/corrupt"
printf 'X' | dd of="$W/corrupt/sata.uImage" bs=1 seek=100 conv=notrunc status=none
bash "$SCRIPT" --image "$W/corrupt" >"$W/corrupt.log" 2>&1
rc=$?
check "a single flipped byte in the kernel is CAUGHT" \
      "$([ $rc -ne 0 ] && echo 0 || echo 1)"
check "  ...and the failing file is named" \
      "$(cond 'grep -q "sata.uImage" "$W/corrupt.log"'; echo $?)"

# --- a missing file must be caught -------------------------------------------
cp -a "$W/good" "$W/missing"
rm -f "$W/missing/rescue.sata.dtb"
bash "$SCRIPT" --image "$W/missing" >"$W/missing.log" 2>&1
check "a missing DTB is CAUGHT" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# --- an empty stick must be caught -------------------------------------------
mkdir -p "$W/empty"
bash "$SCRIPT" --image "$W/empty" >"$W/empty.log" 2>&1
check "an empty stick is CAUGHT" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "  ...and it does not claim the stick is good" \
      "$(cond '! grep -q "STICK IS GOOD" "$W/empty.log"'; echo $?)"

# --- it must never write to the thing it is verifying -------------------------
before=$(find "$W/good" -type f | wc -l)
bash "$SCRIPT" --image "$W/good" >/dev/null 2>&1
after=$(find "$W/good" -type f | wc -l)
check "verifying does not modify the stick" \
      "$([ "$before" = "$after" ] && echo 0 || echo 1)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "prepare-usb: PASSED"
else
    echo "prepare-usb: FAILED ($FAILED)" >&2
    exit 1
fi