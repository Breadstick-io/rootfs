#!/usr/bin/env bash
# Bakes a VM image of Breadstick-RPM (Fedora) or Breadstick-Pac (x86-64 only) for Android's virtualization framework
# (plan Android/docs/4.0/multi-distro.md 5.14 V4). bake-vm.sh runs it for DISTRO=fedora|archlinux; Debian's bake stays
# bake-vm.sh's own, unchanged. LOCAL ONLY: nothing here uploads anything, and the manifest goes to OUT_DIR, never to a
# place the CDN or a released app reads.
#
#   DISTRO=fedora    ARCH=arm64|amd64 FROM=<fedora-45-<arch>[-desktop][-staged]-<stamp>.tar.zst> vm/bake-vm.sh
#   DISTRO=archlinux ARCH=amd64       FROM=<archlinux-rolling-amd64[-desktop][-staged]-<stamp>.tar.zst> vm/bake-vm.sh
#
# FROM is the system image bootstrap-fedora.sh or bootstrap-arch.sh made (the proot image: the Remix swap, Breadstick's
# repository and key, documentation and languages as those scripts set them, the desktop when it is a -desktop- image).
# The VM image is that system with what a real kernel needs and the proot workarounds taken out:
#   Fedora: kernel-core (on arm64 the raw Image unpacked from its EFI zboot file, bsl-unzboot), dracut with
#     hostonly=no and the virtio and vsock drivers, kernel-install's layout=other with a plugin that keeps
#     /boot/vmlinuz-<release> and /boot/initramfs-<release>.img for the app's boot-pair probe (V7), systemd and udev,
#     D-Bus and pam_systemd (systemd-logind and every user's systemd need them; Fedora's container image has
#     neither), iproute, nftables, fuse-sshfs,
#     zram-generator, systemd-networkd (DHCP for the TAP option, as Debian's image). sudo and /root back to Fedora's
#     modes (4111, 0550: the proot image's 4755 and 0700 are for fake root), so rpm -V sudo filesystem is clean. SELinux: off (selinux=0 on the
#     kernel line, no policy installed), as under proot: an AVF guest is the app's own sandbox, a policy would need the
#     disk labelled at bake time and relabelled after every user change made outside it, and the Standard engine has
#     none either.
#   Arch: linux with mkinitcpio (no autodetect, the agent's, network's and fuse's modules in MODULES, the default image
#     only), the keep-modules pacman hooks (the running kernel keeps its modules through an update, V7), sshfs,
#     nftables, zram-generator. The proot stubs in /usr/local/bin (systemctl, systemd-tmpfiles, setpriv), the two masked
#     systemd hooks and pacman.conf's DisableSandbox go: a real kernel needs none of them. Arch's own modes stay.
#   Both: the VM guest (vm/guest/install.sh: the static agent 2, its units, fstab, zram, the sudoers rule for wheel),
#     the getty and wait-online units masked, the root account locked, hostname breadstick-vm, no machine-id.
# Breadstick's repository is NOT used by the bake (rpm.breadstick.io and pacman.breadstick.io are empty until the 4.0
# publish): only the distribution's own mirrors, the repository left in the image as FROM has it.
#
# Output in OUT_DIR (default rootfs/dist/vm): <name>/{vmlinuz, initrd.img, root.img.zst, image.json} and
# <distro>/manifest-vm-<arch>.json, the path the 4.0 app reads (VmManifest.manifestName: cdn.breadstick.io/rootfs/
# <distro>/manifest-vm-<arch>.json; base "vm/<name>/" as Debian's). Named <distro>-<release>-<arch>-vm[-staged]-<stamp>
# (fedora-45-arm64-vm-..., archlinux-rolling-amd64-vm-...): -staged- whenever FROM is, and such an image is never
# published. image.json carries "distro" (the app's Distro wire id) and the kernel line.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
DISTRO="${DISTRO:?DISTRO=fedora|archlinux}"
ARCH="${ARCH:-arm64}"
FROM="${FROM:?FROM=<the image bootstrap-$DISTRO.sh made>}"
STAMP="${STAMP:-$(date -u +%Y%m%d%H%M)}"
OUT_DIR="${OUT_DIR:-$here/../dist/vm}"
case "$STAMP" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) echo "STAMP must be YYYYMMDDHHMM" >&2; exit 2 ;; esac
[ -f "$FROM" ] || { echo "FROM: no file $FROM" >&2; exit 2; }
base=$(basename "$FROM")
case "$DISTRO:$ARCH" in
  fedora:arm64|fedora:amd64)
    case "$base" in fedora-[0-9][0-9]-"$ARCH"-*.tar.zst) ;; *) echo "FROM must be a fedora-<release>-$ARCH-... image from bootstrap-fedora.sh" >&2; exit 2 ;; esac
    RELEASE=$(echo "$base" | cut -d- -f2) ;;
  archlinux:amd64)
    case "$base" in archlinux-rolling-amd64-*.tar.zst) ;; *) echo "FROM must be an archlinux-rolling-amd64-... image from bootstrap-arch.sh" >&2; exit 2 ;; esac
    RELEASE=rolling ;;
  archlinux:*) echo "Breadstick-Pac is x86-64 only: ARCH=amd64" >&2; exit 2 ;;
  *) echo "DISTRO must be fedora or archlinux (debian is bake-vm.sh's own)" >&2; exit 2 ;;
esac
DESKTOP=0
case "$base" in *-desktop-*) DESKTOP=1 ;; esac
STAGED=
case "$base" in *-staged-*) STAGED=-staged ;; esac
NAME="$DISTRO-$RELEASE-$ARCH-vm$STAGED-$STAMP"
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
case "$OUT_DIR/" in */AutoBuild/dist/*|*/mirror/*) echo "OUT_DIR may not be under AutoBuild/dist or a mirror" >&2; exit 2 ;; esac
OUT="$OUT_DIR/$NAME"
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 2; }
HOST_ARCH=$(dpkg --print-architecture)
P="${CONTAINER_PREFIX:-bsl-vm-bake}-$DISTRO-$ARCH-$$"
log() { printf '\033[1;34m[bake-vm %s]\033[0m %s\n' "$DISTRO" "$*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bsl-vm-distro.XXXXXX")
cleanup() {
  docker rm -f "$P-step" >/dev/null 2>&1 || true
  docker rmi -f "$P:from" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
chmod 0755 "$WORK"

log "guest programs for $ARCH (static)"
cp -r "$here/guest" "$WORK/guest"
sh "$here/guest/build.sh" "$ARCH" "$WORK/guest/bin"
chmod -R a+rX "$WORK/guest"

log "importing $base"
zstd -q -dc "$FROM" | docker import --platform "linux/$ARCH" - "$P:from" >/dev/null

# The step, run as root in the imported system. Its own file (no heredoc whose content could end it early).
cat > "$WORK/step.sh" <<'BSL_VM_DISTRO_STEP_51c8'
set -eu
DISTRO=$1 DESKTOP=$2
G=/bsl-guest
say() { echo "[vm-step] $*"; }
install -m 0755 "$G/files/bsl-unzboot" /usr/local/sbin/bsl-unzboot.bake
if [ "$DISTRO" = fedora ]; then
    D="dnf -y --setopt=install_weak_deps=False --disablerepo=breadstick"
    say "1. kernel-install and dracut settings, then the kernel and the VM's packages"
    mkdir -p /etc/kernel/install.d /etc/dracut.conf.d /usr/lib/breadstick-vm
    install -m 0644 "$G/files/fedora/install.conf" /etc/kernel/install.conf
    install -m 0755 "$G/files/fedora/95-breadstick-vm.install" /etc/kernel/install.d/95-breadstick-vm.install
    install -m 0644 "$G/files/fedora/dracut.conf" /etc/dracut.conf.d/90-breadstick-vm.conf
    install -m 0755 "$G/files/bsl-unzboot" /usr/lib/breadstick-vm/bsl-unzboot
    X="xterm xdpyinfo xwininfo xset xorg-x11-xauth xdotool wmctrl dbus-x11 dejavu-sans-mono-fonts"
    # shellcheck disable=SC2086
    $D install kernel-core dracut systemd systemd-udev systemd-pam dbus kmod e2fsprogs iproute nftables fuse-sshfs zram-generator \
        util-linux sudo shadow-utils passwd procps-ng python3 zstd gzip xz tmux curl systemd-networkd $X
    v=$(ls /usr/lib/modules | head -n 1)
    [ "$(ls /usr/lib/modules | wc -l)" = 1 ] || { echo "more than one kernel: $(ls /usr/lib/modules)" >&2; exit 1; }
    # kernel-core's own scriptlet ran kernel-install before this system's settings were all there (the settings went
    # first, but a container has no machine-id): run it again, as every kernel update in the VM will.
    rm -f "/boot/initramfs-$v.img" "/boot/vmlinuz-$v"
    kernel-install add "$v" "/usr/lib/modules/$v/vmlinuz"
    [ -s "/boot/vmlinuz-$v" ] && [ -s "/boot/initramfs-$v.img" ] || { echo "kernel-install left no pair in /boot" >&2; ls -la /boot >&2; exit 1; }
    if [ "$(uname -m)" = aarch64 ]; then
        [ "$(dd if="/boot/vmlinuz-$v" bs=1 skip=56 count=4 2>/dev/null)" = ARMd ] || { echo "/boot/vmlinuz-$v is not a raw arm64 Image" >&2; exit 1; }
    fi
    lsinitrd "/boot/initramfs-$v.img" > /tmp/lsinitrd
    for m in vmw_vsock_virtio_transport virtio_balloon; do
        grep -q "/$m\.ko" /tmp/lsinitrd || grep -q "/$m\.ko" "/usr/lib/modules/$v/modules.builtin" || { echo "the initramfs has no $m" >&2; exit 1; }
    done
    say "2. Fedora's own modes for sudo and /root (the proot image's 4755 and 0700 are fake root's)"
    rpm --setperms sudo filesystem >/dev/null
    rpm --setugids sudo filesystem >/dev/null 2>&1 || true
    [ "$(stat -c %a /usr/bin/sudo)" = 4111 ] || { echo "sudo is $(stat -c %a /usr/bin/sudo)" >&2; exit 1; }
    rpm -V sudo filesystem > /tmp/v || true
    ! grep -E '^.M' /tmp/v || { echo "modes still differ from Fedora's" >&2; exit 1; }
    systemctl mask dnf-makecache.timer >/dev/null 2>&1 || true
    # Each user's session bus (the app's user script waits for /run/user/<uid>/bus): dbus-broker's user socket, which
    # its package's preset leaves off when installed in a container.
    systemctl --global enable dbus.socket >/dev/null
    [ -e /etc/systemd/user/sockets.target.wants/dbus.socket ] || [ -e /usr/lib/systemd/user/sockets.target.wants/dbus.socket ] \
        || { echo "no user D-Bus socket enabled" >&2; exit 1; }
else
    say "1. pacman for the bake (Arch's mirrors only; the image's own pacman.conf, less its proot-only DisableSandbox)"
    PC=/etc/pacman.conf
    awk '/^# Breadstick Linux \(the image bake\): no download sandbox under proot\.$/ { getline; next } { print }' "$PC" > /tmp/pc.new
    ! grep -q '^DisableSandbox' /tmp/pc.new || { echo "pacman.conf: DisableSandbox not in the bake's own block" >&2; exit 1; }
    cat /tmp/pc.new > "$PC"
    rm -f /tmp/pc.new
    # The bake's own configuration: no [breadstick] (its server is empty until the 4.0 publish), and no sandbox, which
    # qemu-user (this bake on an arm64 host) cannot give pacman.
    awk 'BEGIN { s = 0 } /^\[/ { s = ($0 ~ /^\[breadstick/) } !s { print } /^\[options\]/ { print "DisableSandbox" }' "$PC" > /tmp/bake.conf
    say "2. the proot stubs and masks out"
    for t in systemctl systemd-tmpfiles setpriv; do
        f=/usr/local/bin/$t
        [ -e "$f" ] || continue
        grep -q 'Breadstick' "$f" || { echo "$f is not Breadstick's stub" >&2; exit 1; }
        rm -f "$f"
    done
    for h in /etc/pacman.d/hooks/*.hook; do
        [ -L "$h" ] && [ "$(readlink "$h")" = /dev/null ] && { say "   unmasking $(basename "$h")"; rm -f "$h"; }
    done
    say "3. mkinitcpio settings and the keep-modules hooks, then linux and the VM's packages"
    mkdir -p /etc/mkinitcpio.conf.d /etc/mkinitcpio.d /etc/pacman.d/hooks /usr/lib/breadstick-vm
    install -m 0644 "$G/files/archlinux/mkinitcpio.conf" /etc/mkinitcpio.conf.d/breadstick-vm.conf
    install -m 0644 "$G/files/archlinux/linux.preset" /etc/mkinitcpio.d/linux.preset
    install -m 0755 "$G/files/archlinux/keep-modules" /usr/lib/breadstick-vm/keep-modules
    install -m 0644 "$G/files/archlinux/10-breadstick-vm-keep-modules.hook" /etc/pacman.d/hooks/
    install -m 0644 "$G/files/archlinux/95-breadstick-vm-keep-modules.hook" /etc/pacman.d/hooks/
    install -m 0755 "$G/files/bsl-unzboot" /usr/lib/breadstick-vm/bsl-unzboot
    # The image's keyring has no master key (bootstrap-arch.sh takes its secret half out): a bake-only one for
    # anything this transaction signs (archlinux-keyring's populate), taken out again below, as bootstrap-arch.sh does.
    pacman-key --init >/dev/null 2>&1
    X="xterm xorg-xdpyinfo xorg-xwininfo xorg-xset xorg-xauth xdotool wmctrl ttf-dejavu"
    # shellcheck disable=SC2086
    pacman --config /tmp/bake.conf -Syu --noconfirm --needed linux mkinitcpio systemd kmod e2fsprogs iproute2 \
        nftables sshfs zram-generator util-linux sudo shadow procps-ng python zstd tmux curl $X
    [ -s /boot/vmlinuz-linux ] && [ -s /boot/initramfs-linux.img ] || { echo "no /boot/vmlinuz-linux and initramfs-linux.img" >&2; ls -la /boot >&2; exit 1; }
    [ ! -e /boot/initramfs-linux-fallback.img ] || { echo "a fallback initramfs was made" >&2; exit 1; }
    say "   largest packages: $(pacman -Qi | awk '/^Name/ { n = $3 } /^Installed Size/ { print $4 $5 "=" n }' | sort -h | tail -n 8 | tr '\n' ' ')"
    lsinitcpio /boot/initramfs-linux.img > /tmp/lsinit
    v=; for d in /usr/lib/modules/*; do [ "$(cat "$d/pkgbase" 2>/dev/null)" = linux ] && v=${d##*/}; done
    # In the initramfs, or built into the kernel (Arch builds fuse in).
    for m in vmw_vsock_virtio_transport nf_tables nft_redir fuse dummy; do
        grep -q "/$m\.ko" /tmp/lsinit || grep -q "/$m\.ko" "/usr/lib/modules/$v/modules.builtin" || { echo "the initramfs has no $m" >&2; exit 1; }
    done
    gpgconf --homedir /etc/pacman.d/gnupg --kill all 2>/dev/null || true
    find /etc/pacman.d/gnupg/private-keys-v1.d /etc/pacman.d/gnupg/openpgp-revocs.d -mindepth 1 -maxdepth 1 -type f -delete
    rm -f /etc/pacman.d/gnupg/S.* /etc/pacman.d/gnupg/pubring.gpg~
    [ -z "$(gpg --homedir /etc/pacman.d/gnupg --batch --with-colons --list-secret-keys 2>/dev/null)" ] \
        || { echo "pacman's keyring still has a secret key" >&2; exit 1; }
    gpgconf --homedir /etc/pacman.d/gnupg --kill all 2>/dev/null || true
    rm -f /etc/pacman.d/gnupg/S.* /tmp/bake.conf /var/lib/pacman/sync/*
    # pacman -Scc --noconfirm keeps the cache (its question defaults to no): the downloaded packages, files only.
    find /var/cache/pacman/pkg -mindepth 1 -maxdepth 1 -type f -delete
fi
say "4. the VM guest (agent 2, units, settings), and DHCP for the app's TAP option (bsl.net=tap), as on Debian's"
sh "$G/install.sh" / "$G/bin"
mkdir -p /etc/systemd/network
printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n' > /etc/systemd/network/80-breadstick-vm-tap.network
systemctl enable systemd-networkd.service >/dev/null 2>&1
systemctl mask serial-getty@ttyS0.service serial-getty@hvc0.service getty@tty1.service \
    systemd-networkd-wait-online.service NetworkManager-wait-online.service >/dev/null 2>&1 || true
# No first-boot questions on a console nobody sees (Arch's systemd-firstboot asked for a time zone and waited): the
# app sets the time and the region, and the root account stays locked.
systemctl mask systemd-firstboot.service >/dev/null
systemctl --global mask pulseaudio.service pulseaudio.socket >/dev/null 2>&1 || true
passwd -l root >/dev/null
say "5. cleaning"
rm -f /usr/local/sbin/bsl-unzboot.bake
rm -f /etc/machine-id /var/lib/systemd/random-seed
[ "$DISTRO" = fedora ] && { : > /etc/machine-id; dnf -q clean all; rm -rf /var/cache/dnf/* /var/cache/libdnf5/* /var/log/dnf*; }
rm -rf /tmp/* /tmp/.[!.]* /var/tmp/* /root/.cache
say "done"
BSL_VM_DISTRO_STEP_51c8

log "the VM step (desktop=$DESKTOP)"
docker create --name "$P-step" --platform "linux/$ARCH" -v "$WORK/guest:/bsl-guest:ro" -v "$WORK/step.sh:/bsl-step.sh:ro" \
  "$P:from" sh /bsl-step.sh "$DISTRO" "$DESKTOP" >/dev/null
docker start -a "$P-step"
[ "$(docker inspect -f '{{.State.ExitCode}}' "$P-step")" = 0 ] || { echo "the VM step failed" >&2; exit 1; }

log "the ext4 disk"
mkdir -p "$OUT"
docker export "$P-step" > "$WORK/root.tar"
docker rm -f "$P-step" >/dev/null
docker run --rm --platform "linux/$HOST_ARCH" -e OWNER="$(id -u):$(id -g)" -e DISTRO="$DISTRO" -v "$WORK:/s" -v "$OUT:/o" debian:trixie sh -ec '
  command -v mke2fs >/dev/null || { apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq e2fsprogs >/dev/null; }
  mkdir /r
  tar -C /r --numeric-owner --xattrs -xpf /s/root.tar
  rm -f /r/.dockerenv /r/bsl-step.sh
  rmdir /r/bsl-guest 2>/dev/null || true
  if [ "$DISTRO" = fedora ]; then
    v=$(ls /r/usr/lib/modules | head -n 1)
    cp -L "/r/boot/vmlinuz-$v" /o/vmlinuz; cp -L "/r/boot/initramfs-$v.img" /o/initrd.img
  else
    cp -L /r/boot/vmlinuz-linux /o/vmlinuz; cp -L /r/boot/initramfs-linux.img /o/initrd.img
    v=; for d in /r/usr/lib/modules/*; do [ "$(cat "$d/pkgbase" 2>/dev/null)" = linux ] && v=${d##*/}; done
  fi
  echo "$v" > /o/kernel-version
  # docker export wrote empty files here: the VM s own.
  echo breadstick-vm > /r/etc/hostname
  printf "127.0.0.1 localhost\n127.0.1.1 breadstick-vm\n::1 localhost ip6-localhost ip6-loopback\n" > /r/etc/hosts
  rm -f /r/etc/resolv.conf
  rm -rf /r/dev/* /r/proc/* /r/sys/* /r/tmp/* /r/run/*
  mb=$(du -sm /r | cut -f1)
  mke2fs -q -t ext4 -L bslroot -d /r /o/root.img $((mb * 13 / 10 + 256))M
  chown "$OWNER" /o/vmlinuz /o/initrd.img /o/kernel-version /o/root.img'
rm -f "$WORK/root.tar"

log "compressing root.img ($(du -h --apparent-size "$OUT/root.img" | cut -f1) apparent)"
zstd -q -T0 -15 --rm "$OUT/root.img" -o "$OUT/root.img.zst"
KVER=$(cat "$OUT/kernel-version")
[ -n "$KVER" ] || { echo "no kernel release found" >&2; exit 1; }
CMDLINE="console=ttyS0 8250.nr_uarts=4 root=/dev/vda rw panic=-1 quiet"
[ "$DISTRO" = fedora ] && CMDLINE="$CMDLINE selinux=0"
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { stat -c %s "$1"; }
cat > "$OUT/image.json" <<BSL_VM_DISTRO_JSON_51c8
{
  "format": 1,
  "name": "$NAME",
  "arch": "$ARCH",
  "distro": "$DISTRO",
  "suite": "$RELEASE",
  "kernel_version": "$KVER",
  "agent": 2,
  "desktop": $([ "$DESKTOP" = 1 ] && echo true || echo false),
  "cmdline": "$CMDLINE",
  "files": {
    "kernel": { "name": "vmlinuz", "sha256": "$(sha "$OUT/vmlinuz")", "size": $(size "$OUT/vmlinuz") },
    "initrd": { "name": "initrd.img", "sha256": "$(sha "$OUT/initrd.img")", "size": $(size "$OUT/initrd.img") },
    "root": { "name": "root.img.zst", "sha256": "$(sha "$OUT/root.img.zst")", "size": $(size "$OUT/root.img.zst") }
  }
}
BSL_VM_DISTRO_JSON_51c8
mkdir -p "$OUT_DIR/$DISTRO"
sed "s|\"name\": \"$NAME\",|\"name\": \"$NAME\",\n  \"base\": \"vm/$NAME/\",|" "$OUT/image.json" > "$OUT_DIR/$DISTRO/manifest-vm-$ARCH.json"
log "done: $OUT (manifest $OUT_DIR/$DISTRO/manifest-vm-$ARCH.json)"
ls -la "$OUT"
