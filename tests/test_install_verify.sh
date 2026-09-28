#!/usr/bin/env bash
# Test install-alpine's post-install verification block.
#
# The block decides whether the installed system is usable, and it contains a
# self-heal: if apk did not create /sbin/init (which is normally a symlink to
# busybox, made by busybox's .post-install), it recreates the link so an
# install cannot end up with a rootfs that cannot boot. That path cannot be
# exercised on real hardware here, so it is driven directly against synthetic
# target roots.
#
# The block is extracted from the real script, so this test cannot drift from
# what ships.
set -Eeuo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJ_DIR/rootfs/install-alpine"

test -f "$SRC" || { echo "FAIL: $SRC not found"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Extract the exact verification block from the shipping script.
python3 - "$SRC" > "$WORK/verify.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
start = s.index('echo "[install] verifying the installed system ..."')
end = s.index('die "the installed system is not usable', start)
end = s.index('\n', s.index('fi', end)) + 1
sys.stdout.write("verify_failed=0\n" + s[start:end])
PY
test -s "$WORK/verify.sh" || { echo "FAIL: could not extract the verification block"; exit 1; }

{ echo 'die() { echo "DIE: $*"; exit 9; }'
  cat "$WORK/verify.sh"
  echo 'echo "RESULT verify_failed=$verify_failed"'
} > "$WORK/harness.sh"

FAILED=0

# Seed a target root with everything the block checks EXCEPT init.
seed() {
    mkdir -p "$1/bin" "$1/sbin" "$1/usr/sbin"
    cp /bin/busybox "$1/bin/busybox"
    printf '#!/bin/sh\n' > "$1/sbin/ifup";         chmod +x "$1/sbin/ifup"
    printf '#!/bin/sh\n' > "$1/usr/sbin/dropbear"; chmod +x "$1/usr/sbin/dropbear"
}

check() {
    local name="$1" root="$2" expect="$3" out got
    out=$(MNT="$root" bash "$WORK/harness.sh" 2>&1) || true
    echo "--- $name (expect: $expect) ---"
    echo "$out" | sed 's/^/    /'
    if echo "$out" | grep -q 'RESULT verify_failed=0'; then got=ok; else got=fail; fi
    if [ "$got" = "$expect" ]; then
        echo "    => PASS"
    else
        echo "    => FAIL (got $got, wanted $expect)"
        FAILED=1
    fi
}

# A: apk already produced /sbin/init - used as found, nothing invented.
seed "$WORK/a"
ln -sf /bin/busybox "$WORK/a/sbin/init"
check "init already present" "$WORK/a" ok

# B: the case this self-heal exists for. No init, busybox present.
seed "$WORK/b"
check "no init, busybox present -> self-heal" "$WORK/b" ok
if [ -L "$WORK/b/sbin/init" ]; then
    echo "    symlink: sbin/init -> $(readlink "$WORK/b/sbin/init")"
else
    echo "    => FAIL: self-heal did not create the symlink"
    FAILED=1
fi

# C: nothing can be salvaged - must fail loudly, not claim success.
seed "$WORK/c"
rm -f "$WORK/c/bin/busybox"
check "no init, no busybox -> hard failure" "$WORK/c" fail

# The busybox in the rescue image must actually have the init applet, or the
# self-heal would point /sbin/init at something that cannot boot.
BB="$PROJ_DIR/build/rootfs/bin/busybox"
if [ -x "$BB" ] && command -v qemu-aarch64 >/dev/null 2>&1; then
    # grep -c, not grep -x: `grep -x` exits on the first match and closes the
    # pipe, so qemu dies of SIGPIPE (141). Under `set -o pipefail` that turns
    # a successful check into a spurious failure. grep -c consumes all input.
    if [ "$(qemu-aarch64 "$BB" --list 2>/dev/null | grep -c '^init$')" -ge 1 ]; then
        echo "busybox provides the init applet: OK"
    else
        echo "=> FAIL: busybox has no init applet; the self-heal would create a broken link"
        FAILED=1
    fi
else
    echo "busybox/qemu unavailable - skipped the busybox applet check"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "Install verification SELF-HEAL: all cases PASSED"
else
    echo "Install verification SELF-HEAL: FAILURES PRESENT"
fi
exit "$FAILED"
