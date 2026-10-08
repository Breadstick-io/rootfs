#!/bin/sh
# Bakes the Breadstick VM image (docs/2.0/vm.md "Image and kernel"; Android branch vm-2.0):
# a Debian 13 system that boots under Android's virtualization framework, with systemd, Debian's
# own kernel, the agent (vsock 5000), networking through the app (vsock 5100) and the display relay
# (vsock 6000). No provision.sh: nothing here is a proot workaround.
#
#   ARCH=amd64 vm/bake-vm.sh          # the Intel Googlebook (bakes under qemu-user 10 on arm64)
#   ARCH=arm64 vm/bake-vm.sh          # phones, tablets, the ARM Googlebook
#   DESKTOP=0 ARCH=arm64 vm/bake-vm.sh   # no XFCE (a quick test image)
#
# Output, in $OUT_DIR (default rootfs/dist/vm), named by stamp so a published copy never changes:
#   debian-trixie-<arch>-vm-<stamp>/{vmlinuz, initrd.img, root.img.zst, image.json}
#   manifest-vm-<arch>.json   the shape the app reads from cdn.breadstick.io/rootfs/ (NOT published
#                             by this script; AutoBuild/deploy/rootfs-image.sh does not know it yet)
# The app writes root.img sparse, extends it, and systemd grows the file system at first boot.
set -eu

ARCH="${ARCH:-arm64}"
SUITE="${SUITE:-trixie}"
DESKTOP="${DESKTOP:-1}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
here=$(cd "$(dirname "$0")" && pwd)
OUT_DIR="${OUT_DIR:-$here/../dist/vm}"
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
STAMP="${STAMP:-$(date -u +%Y%m%d%H%M)}"
NAME="debian-$SUITE-$ARCH-vm-$STAMP"
OUT="$OUT_DIR/$NAME"
mkdir -p "$OUT"

case "$ARCH" in
  arm64) KPKG=linux-image-arm64 ;;
  amd64) KPKG=linux-image-amd64 ;;
  *) echo "ARCH must be arm64 or amd64" >&2; exit 2 ;;
esac

# Debian's archive keyring: the host's, or the copy bootstrap-debian.sh caches in dist/.keyring.
if [ -z "${KEYRING:-}" ]; then
  for k in /usr/share/keyrings/debian-archive-keyring.gpg \
           "$here/../dist/.keyring/usr/share/keyrings/debian-archive-keyring.gpg" \
           "$here/../dist/.keyring/usr/share/keyrings/debian-archive-keyring.pgp"; do
    [ -s "$k" ] && { KEYRING="$k"; break; }
  done
fi
[ -s "${KEYRING:-}" ] || { echo "No Debian keyring: run bootstrap/bootstrap-debian.sh once, or set KEYRING" >&2; exit 2; }
# The guest's window-close helper, from the packages checkout beside this one (optional).
PACKAGES="${PACKAGES:-$here/../../packages}"

log() { printf '\033[1;34m[bake-vm]\033[0m %s\n' "$*"; }

# 1. The guest programs, built against the guest's own libc (Debian 13 in a container of that
#    architecture; amd64 runs under the host's qemu-user binfmt).
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/bsl-vm-stage.XXXXXX")
chmod 1777 "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
log "building guest programs for $ARCH"
docker run --rm --platform "linux/$ARCH" -e OWNER="$(id -u):$(id -g)" -v "$here/guest:/src:ro" -v "$STAGE:/out" "debian:$SUITE" sh -ec '
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends gcc libc6-dev >/dev/null
  for p in bsl-vmagent bsl-vmnet bsl-x11-relay; do
    gcc -O2 -Wall -pthread -o /out/$p /src/$p.c
    strip /out/$p
  done
  chmod 755 /out/*
  chown "$OWNER" /out/*'
file "$STAGE/bsl-vmagent" | sed 's/^/  /'
cp "$here"/guest/files/* "$STAGE"/
cp "$here/../bootstrap/breadstick-archive-keyring.gpg" "$here/../bootstrap/breadstick.sources" "$STAGE"/
# unshare mode reads it as a mapped uid: it must be somewhere world-readable, not under $HOME.
cat "$KEYRING" > "$STAGE/debian-archive-keyring.gpg"
KEYRING="$STAGE/debian-archive-keyring.gpg"
chmod -R a+rX "$STAGE"

# 2. The system. No recommends; XFCE as the desktop, and with DESKTOP=1 Breadstick's own desktop
#    (breadstick-desktop from apt.breadstick.io: the look, the shell programs and the session
#    script the app runs, as on the Standard system; without it the VM showed stock XFCE).
INCLUDE="systemd-sysv,udev,dbus,dbus-user-session,libpam-systemd,$KPKG,initramfs-tools,kmod,iproute2,nftables,\
sudo,passwd,ca-certificates,locales,less,nano,procps,psmisc,curl,wget,tmux,openssh-client,bash-completion,python3,\
apt-utils,gnupg,file,xz-utils,zstd,e2fsprogs,systemd-zram-generator,\
xterm,x11-apps,x11-utils,x11-xserver-utils,xdotool,wmctrl,dbus-x11,fonts-dejavu-core,xauth"
if [ "$DESKTOP" = 1 ]; then
  INCLUDE="$INCLUDE,xfce4-session,xfwm4,xfce4-panel,xfdesktop4,xfce4-settings,xfconf,thunar,xfce4-terminal,\
mousepad,adwaita-icon-theme,librsvg2-common,at-spi2-core"
fi

log "mmdebstrap $SUITE/$ARCH (desktop=$DESKTOP) -> $OUT"
CLOSE_HOOK=true
if [ -f "$PACKAGES/breadstick-session/src/lib/bsl-close" ]; then
  cp "$PACKAGES/breadstick-session/src/lib/bsl-close" "$STAGE/bsl-close"
  chmod 755 "$STAGE/bsl-close"
  CLOSE_HOOK="mkdir -p \"\$1/usr/lib/breadstick\" && cp '$STAGE/bsl-close' \"\$1/usr/lib/breadstick/bsl-close\""
else
  log "no bsl-close at $PACKAGES (floating windows will close with xdotool)"
fi
mmdebstrap --mode=unshare --arch="$ARCH" --variant=minbase --components=main \
  --keyring="$KEYRING" \
  --aptopt='Apt::Install-Recommends "false"' \
  --include="$INCLUDE" \
  --customize-hook="mkdir -p \"\$1/usr/lib/breadstick-vm\"" \
  --customize-hook="copy-in '$STAGE/bsl-vmagent' '$STAGE/bsl-vmnet' '$STAGE/bsl-x11-relay' '$STAGE/vmnet-setup' '$STAGE/vmnet.nft' /usr/lib/breadstick-vm" \
  --customize-hook="copy-in '$STAGE/bsl-vmagent.service' '$STAGE/bsl-vmnet.service' '$STAGE/bsl-vmnet-setup.service' '$STAGE/bsl-x11-relay.service' /etc/systemd/system" \
  --customize-hook="copy-in '$STAGE/fstab' /etc" \
  --customize-hook="$CLOSE_HOOK" \
  --customize-hook="upload '$STAGE/modules.conf' /etc/modules-load.d/breadstick-vm.conf" \
  --customize-hook="mkdir -p \"\$1/etc/systemd/journald.conf.d\"" \
  --customize-hook="upload '$STAGE/journald.conf' /etc/systemd/journald.conf.d/breadstick-vm.conf" \
  --customize-hook="upload '$STAGE/sudoers' /etc/sudoers.d/breadstick-vm" \
  --customize-hook="upload '$STAGE/profile.sh' /etc/profile.d/breadstick-vm.sh" \
  --customize-hook="upload '$STAGE/zram-generator.conf' /etc/systemd/zram-generator.conf" \
  --customize-hook='chmod 440 "$1/etc/sudoers.d/breadstick-vm"; chmod 755 "$1"/usr/lib/breadstick-vm/bsl-* "$1/usr/lib/breadstick-vm/vmnet-setup"' \
  --customize-hook='chroot "$1" systemctl enable bsl-vmagent.service bsl-vmnet-setup.service bsl-vmnet.service bsl-x11-relay.service' \
  --customize-hook='chroot "$1" systemctl mask apt-daily.timer apt-daily-upgrade.timer serial-getty@ttyS0.service serial-getty@hvc0.service getty@tty1.service systemd-networkd-wait-online.service 2>/dev/null || true' \
  --customize-hook='if [ -e "$1/lib/systemd/system/systemd-networkd.service" ] || [ -e "$1/usr/lib/systemd/system/systemd-networkd.service" ]; then mkdir -p "$1/etc/systemd/network"; printf "[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n" > "$1/etc/systemd/network/80-breadstick-vm-tap.network"; chroot "$1" systemctl enable systemd-networkd.service; fi' \
  --customize-hook='echo breadstick-vm > "$1/etc/hostname"; printf "127.0.0.1 localhost\n127.0.1.1 breadstick-vm\n::1 localhost ip6-localhost ip6-loopback\n" > "$1/etc/hosts"' \
  --customize-hook='sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" "$1/etc/locale.gen"; chroot "$1" locale-gen >/dev/null' \
  --customize-hook='chroot "$1" passwd -l root >/dev/null' \
  --customize-hook="upload '$STAGE/breadstick-archive-keyring.gpg' /usr/share/keyrings/breadstick-archive-keyring.gpg" \
  --customize-hook="upload '$STAGE/breadstick.sources' /etc/apt/sources.list.d/breadstick.sources" \
  --customize-hook="if [ $DESKTOP = 1 ]; then chroot \"\$1\" apt-get update -q && DEBIAN_FRONTEND=noninteractive chroot \"\$1\" apt-get install -y -q breadstick-desktop; fi" \
  --customize-hook='printf "virtio_pci\nvirtio_blk\nvirtio_console\nvirtio_balloon\nvmw_vsock_virtio_transport\next4\n" >> "$1/etc/initramfs-tools/modules"; chroot "$1" update-initramfs -u -k all' \
  "$SUITE" "$STAGE/root.tar" "$MIRROR"

# 3. The disk. mke2fs -d keeps ownership only when it runs as root, so the tree is unpacked and
#    turned into ext4 in a container (Debian 13's e2fsprogs); the kernel and initramfs come out of
#    the same tree. Native container: this step only moves data.
log "making the ext4 disk"
docker run --rm --platform "linux/$(dpkg --print-architecture)" -e OWNER="$(id -u):$(id -g)" -v "$STAGE:/s" -v "$OUT:/o" "debian:$SUITE" sh -ec '
  command -v mke2fs >/dev/null || { apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq e2fsprogs >/dev/null; }
  mkdir /r
  tar -C /r --numeric-owner -xpf /s/root.tar
  cp -L /r/boot/vmlinuz-* /o/vmlinuz
  cp -L /r/boot/initrd.img-* /o/initrd.img
  ls /r/boot/vmlinuz-* | sed "s|.*/vmlinuz-||" > /o/kernel-version
  rm -rf /r/dev/* /r/proc/* /r/sys/* /r/tmp/* /r/var/cache/apt/archives/*.deb /r/var/lib/apt/lists/*_Packages* /r/var/lib/apt/lists/*_InRelease
  mb=$(du -sm /r | cut -f1)
  mke2fs -q -t ext4 -L bslroot -d /r /o/root.img $((mb * 13 / 10 + 256))M
  chown "$OWNER" /o/vmlinuz /o/initrd.img /o/kernel-version /o/root.img'
rm -f "$STAGE/root.tar"

log "compressing root.img ($(du -h --apparent-size "$OUT/root.img" | cut -f1) apparent)"
zstd -q -T0 -15 --rm "$OUT/root.img" -o "$OUT/root.img.zst"

KVER=$(cat "$OUT/kernel-version")
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { stat -c %s "$1"; }
cat > "$OUT/image.json" <<EOF
{
  "format": 1,
  "name": "$NAME",
  "arch": "$ARCH",
  "suite": "$SUITE",
  "kernel_version": "$KVER",
  "agent": 1,
  "desktop": $([ "$DESKTOP" = 1 ] && echo true || echo false),
  "cmdline": "console=ttyS0 8250.nr_uarts=4 root=/dev/vda rw panic=-1 quiet",
  "files": {
    "kernel": { "name": "vmlinuz", "sha256": "$(sha "$OUT/vmlinuz")", "size": $(size "$OUT/vmlinuz") },
    "initrd": { "name": "initrd.img", "sha256": "$(sha "$OUT/initrd.img")", "size": $(size "$OUT/initrd.img") },
    "root": { "name": "root.img.zst", "sha256": "$(sha "$OUT/root.img.zst")", "size": $(size "$OUT/root.img.zst") }
  }
}
EOF
# The CDN manifest names the versioned folder; the app resolves file names against it.
sed "s|\"name\": \"$NAME\",|\"name\": \"$NAME\",\n  \"base\": \"vm/$NAME/\",|" "$OUT/image.json" > "$OUT_DIR/manifest-vm-$ARCH.json"
log "done: $OUT"
ls -la "$OUT"
