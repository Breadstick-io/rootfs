#!/bin/sh
# Boots a bake-vm.sh image under QEMU in Docker with vhost-vsock and runs qemu-test.py against it:
# the agent (ping, info, time, file, run as root and as the user, a pty), the user's systemd session,
# networking through a host relay (DNS, apt-get update, an HTTPS fetch) and a clean power-off.
#   vm/test/qemu-test.sh <image folder from bake-vm.sh> [arm64|amd64]
# arm64 runs under KVM on an arm64 host; amd64 under TCG (slow). Needs the bsl-vmtest:2 image
# (Debian 13 + qemu-system-arm/x86 + python3; Dockerfile beside this script).
set -eu
IMG=$(cd "${1:?image folder}" && pwd)
ARCH=${2:-arm64}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/bsl-vmtest.XXXXXX")
trap 'cp "$work/console.log" "${KEEP_CONSOLE:-/dev/null}" 2>/dev/null; rm -rf "$work"' EXIT
zstd -q -dc "$IMG/root.img.zst" > "$work/root.img"
truncate -s 8G "$work/root.img"
cp "$IMG/vmlinuz" "$IMG/initrd.img" "$work/"
# The app's VM helpers (Android app/src/main/assets/vm), for the bridges test; skipped without them.
ASSETS=${ANDROID_ASSETS:-$here/../../../Android/app/src/main/assets/vm}
[ -d "$ASSETS" ] && A="-v $(cd "$ASSETS" && pwd):/a:ro" || A=
docker run --rm $A --device /dev/kvm --device /dev/vhost-vsock --security-opt seccomp=unconfined --security-opt apparmor=unconfined -e ARCH="$ARCH" \
  -v "$work:/w" -v "$here:/t:ro" bsl-vmtest:2 python3 /t/qemu-test.py
