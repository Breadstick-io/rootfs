#!/bin/sh
# Flatpak updates in a Breadstick VM image (4.0, r14): boots the image under QEMU in Docker with vhost-vsock, as
# qemu-test-containers.sh does, and runs qemu-test-flatpak-updates.py: Get apps > Flatpak's own setup, then Breadstick
# Updates' and the app's Settings' Flatpak commands against a real update from Flathub (a small ref, a few MB).
#   PACKAGES=<packages checkout> vm/test/qemu-test-flatpak-updates.sh <image folder>
#   CID=82 (one per test running at once)   CNAME=<container name>
# PACKAGES: the tree whose breadstick-theme updater.py (and breadstick-session bsl-engine, for an image whose session
# has none yet) is tried. arm64 under KVM on an arm64 host. Needs bsl-vmtest:3 (Dockerfile here) and the internet.
set -eu
IMG=$(cd "${1:?image folder}" && pwd)
PKG=$(cd "${PACKAGES:?PACKAGES=<packages checkout>}" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/bsl-vmtest-flatpak.XXXXXX")
u=$(mktemp -d "${TMPDIR:-/tmp}/bsl-vmtest-flatpak-u.XXXXXX")
# Files by name, then the two empty folders: nothing here is deleted recursively.
trap 'cp "$work/console.log" "${KEEP_CONSOLE:-/dev/null}" 2>/dev/null; rm -f "$work"/* "$u"/*; rmdir "$work" "$u"' EXIT
zstd -q -dc "$IMG/root.img.zst" > "$work/root.img"
truncate -s "${DISK:-16G}" "$work/root.img"
cp "$IMG/vmlinuz" "$IMG/initrd.img" "$IMG/image.json" "$work/"
cp "$PKG/breadstick-theme/src/usr/lib/breadstick/updater.py" "$PKG/breadstick-session/src/lib/bsl-engine" "$u/"
docker run --rm --platform "linux/$(dpkg --print-architecture)" --name "${CNAME:-bsl-vmtest-flatpak-updates-$$}" \
  -e CID="${CID:-82}" --device /dev/kvm --device /dev/vhost-vsock \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  -v "$work:/w" -v "$here:/t:ro" -v "$u:/u:ro" bsl-vmtest:3 python3 /t/qemu-test-flatpak-updates.py
