#!/bin/bash
# test_handoff.sh - does the rescue->installed-system handover make the right
# decision, and refuse the wrong ones?
#
# 99-disk-root is the script that decides whether the box boots into the
# installed system or stays in the rescue shell. It had no test at all: not
# one branch had ever been executed. The escape hatch, the label lookup, the
# fallback scan and the "has an init" check are the whole difference between a
# working machine and a rescue shell you have to drive by hand.
#
# These run the real script. Nothing is reimplemented here: the tools it calls
# (findfs, mount, umount, switch_root) are PATH stubs that record what they
# were asked to do, and the paths it uses are the environment overrides the
# script itself provides.
#
# What this cannot prove: that the real kernel hands over correctly, that
# switch_root behaves as BusyBox's does, or that the label is on the partition
# the installer wrote. That is stage 2 of the roadmap and needs the machine.

set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT=rootfs/init.d/99-disk-root
FAILED=0

check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILED=$((FAILED+1)); fi; }
# Accumulator is _cond_rc, not rc: cond always runs inside $( ), and a bare
# `rc=0` there would clobber a caller's rc before the assertion could read it.
cond()  { _cond_rc=0; for a in "$@"; do eval "$a" || _cond_rc=1; done; return $_cond_rc; }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }

# run <label> <setup-fn> ; the setup fn populates $W (workdir)
# Sets: $OUT (combined output), $RC (exit), $SWITCHED (1 if switch_root ran)
run() {
    W=$(mktemp -d)
    BIN=$W/bin; mkdir -p "$BIN"
    SWITCHED=0
    cat > "$BIN/switch_root" <<'EOS'
#!/bin/sh
echo "SWITCH_ROOT_CALLED $*"
EOS
    cat > "$BIN/findfs" <<EOS
#!/bin/sh
# Prints the device carrying the requested label, or nothing (exit 1) if the
# filesystem does not exist - which is what real findfs does.
[ -f "$W/findfs" ] || exit 1
cat "$W/findfs"
EOS
    cat > "$BIN/mount" <<EOS
#!/bin/sh
echo "mount \$*" >> "$W/mounts.log"
exit 0
EOS
    cat > "$BIN/umount" <<'EOS'
#!/bin/sh
echo "umount $*" >> "$W/mounts.log"
exit 0
EOS
    chmod +x "$BIN"/*
    : > "$W/mounts"          # MOUNTS override: pretend nothing is mounted yet
    setup_$2
    OUT=$(ROOT_LABEL=wdmch-root NEWROOT="$W/newroot" USB_ROOT="$W/usb" \
          MOUNTS="$W/mounts" RESCUE_SSH_KEY="$W/root/.ssh/authorized_keys" \
          PATH="$BIN:$PATH" sh "$SCRIPT" 2>&1)
    RC=$?
    case "$OUT" in *SWITCH_ROOT_CALLED*) SWITCHED=1 ;; *) SWITCHED=0 ;; esac
}

newroot_with_init() {   # $W set: a candidate root that looks installed
    mkdir -p "$W/newroot/sbin"
    printf '#!/bin/sh\n' > "$W/newroot/sbin/init"; chmod +x "$W/newroot/sbin/init"
}
usb_marker() { mkdir -p "$W/usb"; : > "$W/usb/norescue"; }

echo "=== 99-disk-root: the handover decision ==="

# --- 1. the escape hatch must win over everything -----------------------------
# A machine that is perfectly installable still must NOT hand over if the
# operator asked for the rescue shell. This is the stop-cran.
setup_marker_and_system() { usb_marker; newroot_with_init; : > "$W/findfs"; echo /dev/sda20 > "$W/findfs"; }
run "marker" marker_and_system
check "norescue marker on the stick keeps the rescue shell" \
      "$(cond '[ $SWITCHED -eq 0 ]'; echo $?)"
check "  ...and says how to undo it" \
      "$(cond 'case "$OUT" in *"delete $W/usb/norescue"*) true ;; *) false ;; esac'; echo $?)"

# --- 2. no marker, labelled system: hand over ---------------------------------
setup_labelled() { newroot_with_init; : > "$W/findfs"; echo /dev/sda20 > "$W/findfs"; }
run "labelled" labelled
check "a labelled filesystem with an init is handed over to" \
      "$(cond '[ $SWITCHED -eq 1 ]'; echo $?)"
check "  ...switch_root receives the new root and the init" \
      "$(cond 'case "$OUT" in *"SWITCH_ROOT_CALLED -c /dev/console $W/newroot /sbin/init"*) true ;; *) false ;; esac'; echo $?)"
check "  ...and it does not re-mount an already-mounted new root" \
      "$(cond '! grep -q " $W/newroot " "$W/mounts.log" 2>/dev/null'; echo $?)"

# --- 3. no marker, no filesystem at all: stay put -----------------------------
setup_none() { : > "$W/findfs"; }   # findfs finds nothing; no block devices exist
run "none" none
check "no installed system leaves the rescue shell intact" \
      "$(cond '[ $SWITCHED -eq 0 ]'; echo $?)"
check "  ...and names what it was looking for" \
      "$(cond 'case "$OUT" in *wdmch-root*) true ;; *) false ;; esac'; echo $?)"

# --- 4. a filesystem with no init is NOT an installed system ------------------
# This is the case that matters most: p20 can be a formatted-but-empty ext4 if
# an install died midway. Handing over to it would drop the operator into a
# system with no init and no shell.
setup_bare() { mkdir -p "$W/newroot/etc"; : > "$W/findfs"; echo /dev/sda20 > "$W/findfs"; }
run "bare" bare
check "a filesystem with no init is refused, not entered" \
      "$(cond '[ $SWITCHED -eq 0 ]'; echo $?)"
check "  ...and says why" \
      "$(cond 'case "$OUT" in *"no usable init"*) true ;; *) false ;; esac'; echo $?)"

# --- 5. an init somewhere other than /sbin still counts -----------------------
setup_alt_init() { mkdir -p "$W/newroot/usr/lib/systemd"; printf '#!/bin/sh\n' > "$W/newroot/usr/lib/systemd/systemd"; chmod +x "$W/newroot/usr/lib/systemd/systemd"; : > "$W/findfs"; echo /dev/sda20 > "$W/findfs"; }
run "altinit" alt_init
check "a systemd-style init path is recognised" \
      "$(cond '[ $SWITCHED -eq 1 ]'; echo $?)"

# --- 6. the key safety net ----------------------------------------------------
# install-alpine refuses to finish without a key, so a target without one
# means someone deleted it. Copying the rescue key back in is deliberate, but
# it persists a credential on the internal disk and MUST say so.
setup_nokey() { newroot_with_init; mkdir -p "$W/root/.ssh"; : > "$W/root/.ssh/authorized_keys"; chmod 600 "$W/root/.ssh/authorized_keys"; : > "$W/findfs"; echo /dev/sda20 > "$W/findfs"; }
run "nokey" nokey
check "a target with no SSH key is still handed over" \
      "$(cond '[ $SWITCHED -eq 1 ]'; echo $?)"
check "  ...and the credential copy is disclosed, not silent" \
      "$(cond 'case "$OUT" in *"NO SSH key"*) true ;; *) false ;; esac'; echo $?)"
check "  ...including how to undo it" \
      "$(cond 'case "$OUT" in *"remove $W/newroot/root/.ssh/authorized_keys"*) true ;; *) false ;; esac'; echo $?)"

# --- 7. a target that already has a key is left alone -------------------------
setup_haskey() {
    newroot_with_init; mkdir -p "$W/root/.ssh"
    : > "$W/root/.ssh/authorized_keys"; chmod 600 "$W/root/.ssh/authorized_keys"
    mkdir -p "$W/newroot/root/.ssh"; : > "$W/newroot/root/.ssh/authorized_keys"
    : > "$W/findfs"; echo /dev/sda20 > "$W/findfs"
}
run "haskey" haskey
check "an existing key produces no credential-copy warning" \
      "$(cond 'case "$OUT" in *"NO SSH key"*) false ;; *) true ;; esac'; echo $?)"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "99-disk-root handover decisions: PASSED"
else
    echo "99-disk-root handover decisions: FAILED ($FAILED)" >&2
    exit 1
fi
