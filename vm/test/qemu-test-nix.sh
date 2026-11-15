#!/bin/sh
# Boots a Breadstick-Nix VM image (bootstrap-nix.sh vm) under QEMU in Docker with vhost-vsock and runs
# qemu-test-nix.py against it (round 9, plan 5.14 V4). As qemu-test.sh for Debian's, with NixOS's checks.
#   vm/test/qemu-test-nix.sh <image folder> [arm64|amd64]
# arm64 under KVM on this host; amd64 under TCG (slow). Needs bsl-vmtest:3 (Dockerfile beside this script).
set -eu
IMG=$(cd "${1:?image folder}" && pwd)
ARCH=${2:-arm64}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/bsl-vmtest-nix.XXXXXX")
trap 'cp "$work/console.log" "${KEEP_CONSOLE:-/dev/null}" 2>/dev/null; rm -rf "$work"' EXIT
zstd -q -dc "$IMG/root.img.zst" > "$work/root.img"
truncate -s 12G "$work/root.img"
cp "$IMG/vmlinuz" "$IMG/initrd.img" "$IMG/image.json" "$work/"
docker run --rm --platform "linux/$(dpkg --print-architecture)" --name "${CNAME:-bsl-r9-nix-vmtest-$ARCH-$$}" \
  -e CID="${CID:-79}" --device /dev/kvm --device /dev/vhost-vsock --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined -e ARCH="$ARCH" -v "$work:/w" -v "$here:/t:ro" bsl-vmtest:3 python3 /t/qemu-test-nix.py
