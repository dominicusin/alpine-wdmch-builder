#!/usr/bin/env bash
set -Eeuo pipefail

# Build the WDMCH rescue initramfs.
#
# Contract (symops/monarch-6.18 README, "Building and booting"):
#   rescue.root.sata.cpio.gz_pad.img = gzip'd newc cpio, zero-padded to
#   EXACTLY 4194304 bytes. The vendor U-Boot rescue path reads that fixed
#   block size unconditionally.
#
# Contents: minimal static-aarch64 userspace assembled from pinned Alpine
#   APKs (busybox-static, dropbear, apk-tools-static, utmps, musl, zlib) -
#   no kernel modules needed: all rescue drivers are built into the kernel.
#
# SSH: root login with the public key from config/build.env
#   (WDMCH_SSH_AUTHORIZED_KEY) or ~/.ssh/id_ed25519.pub fallback. Password
#   authentication is disabled (dropbear -s). No private key material ships.

ROOT="${1:-build/rootfs}"
RELEASE="${2:-$(cat build/kernel/kernel-release.txt 2>/dev/null || echo none)}"

echo "=== Building Alpine rescue initramfs ==="

# Load Alpine pin (version/arch)
set -a
source config/alpine.env
set +a

ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
MAIN_REPO="$ALPINE_MIRROR/v$ALPINE_VERSION/main/$ALPINE_ARCH"
COMMUNITY_REPO="$ALPINE_MIRROR/v$ALPINE_VERSION/community/$ALPINE_ARCH"

# ---- resolve the SSH public key --------------------------------------------
AUTH_KEY=""
if [ -f config/build.env ]; then
    # shellcheck disable=SC1091
    . config/build.env
fi
if [ -n "${WDMCH_SSH_AUTHORIZED_KEY:-}" ]; then
    AUTH_KEY="$WDMCH_SSH_AUTHORIZED_KEY"
elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    AUTH_KEY="$(head -1 "$HOME/.ssh/id_ed25519.pub")"
    echo "NOTE: WDMCH_SSH_AUTHORIZED_KEY not set; using $HOME/.ssh/id_ed25519.pub"
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    AUTH_KEY="$(head -1 "$HOME/.ssh/id_rsa.pub")"
    echo "NOTE: WDMCH_SSH_AUTHORIZED_KEY not set; using $HOME/.ssh/id_rsa.pub"
fi
if [ -z "$AUTH_KEY" ]; then
    echo "ERROR: no SSH public key found (config/build.env WDMCH_SSH_AUTHORIZED_KEY or ~/.ssh/*.pub)" >&2
    exit 1
fi
case "$AUTH_KEY" in
    ssh-ed25519*|ssh-rsa*) : ;;
    *) echo "ERROR: WDMCH_SSH_AUTHORIZED_KEY does not look like a public key: ${AUTH_KEY:0:20}..." >&2; exit 1 ;;
esac

# ---- download pinned APKs ---------------------------------------------------
APK_CACHE=".work/apk-cache"
mkdir -p "$APK_CACHE"

# name|repo|filename  (pinned versions, resolvable against config/alpine.env)
APKS=(
    "musl|main|musl-1.2.5-r11.apk"
    "busybox-static|main|busybox-static-1.37.0-r14.apk"
    "zlib|main|zlib-1.3.2-r0.apk"
    "utmps-libs|main|utmps-libs-0.1.2.3-r2.apk"
    "dropbear|main|dropbear-2024.86-r0.apk"
    "apk-tools-static|main|apk-tools-static-2.14.6-r3.apk"
    "alpine-keys|main|alpine-keys-2.5-r0.apk"
    "kexec-tools|community|kexec-tools-2.0.30-r0.apk"
)

fetch_apk() {
    local repo="$1" file="$2" url
    [ -s "$APK_CACHE/$file" ] && return 0
    if [ "$repo" = main ]; then url="$MAIN_REPO/$file"; else url="$COMMUNITY_REPO/$file"; fi
    echo "Downloading $file"
    curl -fsSL "$url" -o "$APK_CACHE/$file"
}

for entry in "${APKS[@]}"; do
    IFS='|' read -r _name repo file <<< "$entry"
    fetch_apk "$repo" "$file"
done

# ---- assemble the initramfs tree --------------------------------------------
rm -rf "$ROOT"
mkdir -p "$ROOT"

for entry in "${APKS[@]}"; do
    IFS='|' read -r _name repo file <<< "$entry"
    tar xzf "$APK_CACHE/$file" -C "$ROOT" --exclude='.SIGN.RSA*' 2>/dev/null
done

# Keep only what the rescue uses; drop docs/dev/engines and the shared
# libcrypto/libssl (Alpine's dropbear is statically linked against
# libcrypto - its only NEEDED libs are libz, libutmps and musl).
rm -rf "$ROOT/usr/share" "$ROOT/usr/include" "$ROOT/etc/ssl" \
       "$ROOT/usr/lib/engines-3" "$ROOT/usr/lib/ossl-modules" \
       "$ROOT/usr/lib/libcrypto.so.3" "$ROOT/usr/lib/libssl.so.3" \
       "$ROOT/usr/lib/libutmps.a" "$ROOT/etc/logrotate.d" \
       "$ROOT/sbin/apk.static.SIGN.RSA*" "$ROOT/.SIGN.RSA*" "$ROOT/.PKGINFO"

# busybox: single static binary + applet symlinks
install -m 755 "$ROOT/bin/busybox.static" "$ROOT/bin/busybox"
rm -f "$ROOT/bin/busybox.static"
for applet in sh ash ls cat echo mkdir mknod mount umount switch_root reboot \
              poweroff halt sleep ps grep sed awk cut head tail wc tr vi \
              ifconfig route udhcpc ping \
              blkid findfs fdisk sfdisk mkfs.vfat mkfs.ext2 mke2fs \
              mkswap swapon losetup chroot tar gzip gunzip xz xzcat \
              insmod rmmod lsmod dmesg uname hostname date df du free \
              cp mv rm ln touch chmod chown dd sync which env \
              mdev sysctl wget telnet tftp nc clear reset; do
    ln -sf busybox "$ROOT/bin/$applet"
done

# udhcpc needs its hook script
mkdir -p "$ROOT/usr/share/udhcpc"
cat > "$ROOT/usr/share/udhcpc/default.script" <<'EOF'
#!/bin/sh
# minimal udhcpc hook: apply the lease to the interface
case "$1" in
  bound|renew)
    ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}"
    if [ -n "$router" ]; then
      route del default 2>/dev/null
      for r in $router; do route add default gw "$r" dev "$interface"; done
    fi
    if [ -n "$dns" ]; then
      : > /etc/resolv.conf
      for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
    fi
    ;;
  deconfig)
    ifconfig "$interface" 0.0.0.0
    ;;
esac
exit 0
EOF
chmod 755 "$ROOT/usr/share/udhcpc/default.script"

# ---- SSH: dropbear, public-key-only root -----------------------------------
mkdir -p "$ROOT/root/.ssh" "$ROOT/etc/dropbear"
echo "$AUTH_KEY" > "$ROOT/root/.ssh/authorized_keys"
chmod 700 "$ROOT/root/.ssh"
chmod 600 "$ROOT/root/.ssh/authorized_keys"

# root account with empty password field (dropbear -s forbids password
# auth anyway; this keeps /etc/passwd parsing happy for login shells)
echo "root::0:0:root:/:/bin/sh" > "$ROOT/etc/passwd"
echo "root:x:0:" > "$ROOT/etc/group"

# dropbear host keys are generated on first boot by /init (dropbear -R)

# ---- /init (PID 1) ---------------------------------------------------------
cp rootfs/init "$ROOT/init"
chmod 755 "$ROOT/init"

# ---- install-alpine helper (runs entirely from the USB stick) --------------
mkdir -p "$ROOT/usr/local/sbin"
cp rootfs/install-alpine "$ROOT/usr/local/sbin/install-alpine"
chmod 755 "$ROOT/usr/local/sbin/install-alpine"

# ---- standard dirs ----------------------------------------------------------
mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/tmp" "$ROOT/run" \
         "$ROOT/mnt" "$ROOT/media" "$ROOT/var/log" "$ROOT/etc/network" \
         "$ROOT/newroot"

# ---- build the padded cpio (FIXED: write to ABSOLUTE path) -----------------
OUT="build/kernel/rescue.root.sata.cpio.gz_pad.img"
mkdir -p build/kernel
TMP="$(pwd)/build/kernel-rescue-tmp.cpio.gz"

echo "Packing rescue initramfs (newc cpio, gzip -9)..."
( cd "$ROOT" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$TMP" )

SIZE=$(stat -c '%s' "$TMP")
echo "gzip'd cpio size: $SIZE bytes"
if [ "$SIZE" -gt 4194304 ]; then
    rm -f "$TMP"
    echo "ERROR: initramfs ($SIZE bytes) exceeds the fixed 4 MiB rescue budget (4194304)." >&2
    echo "       The vendor loader reads exactly 4194304 bytes; it cannot be trimmed." >&2
    exit 1
fi

mv "$TMP" "$OUT"
PAD=$((4194304 - SIZE))
if [ "$PAD" -gt 0 ]; then
    dd if=/dev/zero bs=1 count="$PAD" >> "$OUT" 2>/dev/null
fi
FINAL=$(stat -c '%s' "$OUT")
echo "rescue.root.sata.cpio.gz_pad.img: $FINAL bytes (target 4194304)"
[ "$FINAL" -eq 4194304 ] || { echo "ERROR: final size $FINAL != 4194304" >&2; exit 1; }

echo "Rescue initramfs build complete."
