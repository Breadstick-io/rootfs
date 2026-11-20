#!/bin/sh
# The desktop choice of a VM instance (4.0, desktop-v1): boots a bake-vm.sh image under QEMU in Docker and runs
# desktop-choice.py against it: the chosen desktop installed at its first start, its shell process and a panel window
# up, the bridges under it, a clean logout, then XFCE again as before.
#   vm/test/desktop-choice.sh <image folder from bake-vm.sh> [plasma|gnome]
#   SESSION_SRC=<packages>/breadstick-session/src vm/test/desktop-choice.sh ...  # today's session files in the VM first
#                                                    # (an image whose breadstick-session has no bsl-desktop needs it)
#   MEM=2560 vm/test/desktop-choice.sh ...          # the VM's memory in MiB (a phone's 2.5 GiB by default)
#   SHOTS=<folder> vm/test/desktop-choice.sh ...    # screenshots of the stand-in X server as .xwd (needs xwd in the image)
#   CID=79 vm/test/desktop-choice.sh ...            # the guest's vsock CID, one per test running at once
# 2026-11-20: plasma passes every check; gnome fails two (what a hard stop and the next XFCE start find), which is
# part of why the app does not offer it (Android docs/4.0/desktops.md).
# arm64 under KVM on an arm64 host. Needs the bsl-vmtest:3 image (Dockerfile beside this script); the disk is a copy,
# grown to the product's 16 GB (sparse), and the image is never touched. Debian images only: no other distribution's
# release has an X11 session for KDE Plasma or GNOME (bsl-desktop says why), and the test says so and stops there.
set -eu
IMG=$(cd "${1:?image folder}" && pwd)
KIND=${2:-plasma}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/bsl-vmdesk.XXXXXX")
trap 'cp "$work/console.log" "${KEEP_CONSOLE:-/dev/null}" 2>/dev/null; rm -f "$work"/root.img "$work"/vmlinuz "$work"/initrd.img "$work"/image.json "$work"/console.log "$work"/session.tar; rm -f "$work"/st/usr/lib/breadstick/* "$work"/st/usr/share/breadstick/* 2>/dev/null; rmdir "$work"/st/usr/lib/breadstick "$work"/st/usr/share/breadstick "$work"/st/usr/lib "$work"/st/usr/share "$work"/st/usr "$work"/st "$work" 2>/dev/null || true' EXIT
zstd -q -dc "$IMG/root.img.zst" > "$work/root.img"
truncate -s 16G "$work/root.img"
cp "$IMG/vmlinuz" "$IMG/initrd.img" "$IMG/image.json" "$work/"
chmod 644 "$work/initrd.img"
if [ -n "${SESSION_SRC:-}" ]; then
  # What Apt/publish.sh stages for breadstick-session, as one tar the test unpacks in the VM.
  P=$(cd "$SESSION_SRC" && pwd)
  mkdir -p "$work/st/usr/lib/breadstick" "$work/st/usr/share/breadstick"
  install -m 0755 "$P/desktop/start-desktop-x11.sh" "$P/desktop/list-apps.sh" "$work/st/usr/lib/breadstick/"
  for f in "$P"/lib/*; do [ -f "$f" ] && install -m 0755 "$f" "$work/st/usr/lib/breadstick/"; done
  for f in gpu-devices gpu-software-apps gpu-native gpu-software-apps-native pkgnames; do
    [ -f "$P/share/$f" ] && install -m 0644 "$P/share/$f" "$work/st/usr/share/breadstick/$f"
  done
  tar -C "$work/st" --owner=0 --group=0 -cf "$work/session.tar" usr
fi
S=
[ -n "${SHOTS:-}" ] && { mkdir -p "$SHOTS"; S="-v $(cd "$SHOTS" && pwd):/shots"; }
docker run --rm --platform "linux/$(dpkg --print-architecture)" --name "${CNAME:-bsl-vmdesk-$$}" $S -e KIND="$KIND" -e MEM="${MEM:-2560}" -e CID="${CID:-79}" \
  --device /dev/kvm --device /dev/vhost-vsock --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  -v "$work:/w" -v "$here:/t:ro" "${TEST_IMAGE:-bsl-vmtest:3}" python3 /t/desktop-choice.py
