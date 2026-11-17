#!/bin/sh
# The Nix based instance moved between the engines, the VM half (4.0 round 12): qemu-test-nix-move.py in bsl-vmtest:3
# with a fresh copy of the Nix VM image's disk and a Standard instance's tree (bootstrap/test-nix-move-proot.sh make).
#   vm/test/qemu-test-nix-move.sh <vm image folder> <instance.tar> <out: vm-backup.tar> [arm64|amd64]
# arm64 under KVM on this host; amd64 under TCG (slow). The disk is 16 GiB (the stage and the copy at once).
set -eu
IMG=$(cd "${1:?image folder}" && pwd)
INST=$(cd "$(dirname "${2:?instance.tar}")" && pwd)/$(basename "$2")
OUT=${3:?out tar}
ARCH=${4:-arm64}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/bsl-vmtest-nixmove.XXXXXX")
trap 'for f in "$work"/console*.log; do [ -e "$f" ] && cp "$f" "${KEEP_CONSOLE:-/dev/null}.$(basename "$f")" 2>/dev/null; done; rm -rf "$work"' EXIT
zstd -q -dc "$IMG/root.img.zst" > "$work/root.img"
truncate -s 16G "$work/root.img"
cp "$IMG/vmlinuz" "$IMG/initrd.img" "$IMG/image.json" "$work/"
ln "$INST" "$work/instance.tar" 2>/dev/null || cp "$INST" "$work/instance.tar"
rc=0
docker run --rm --platform "linux/$(dpkg --print-architecture)" --name "${CNAME:-bsl-r12-nixfix-vmmove-$ARCH-$$}" \
  -e CID="${CID:-81}" --device /dev/kvm --device /dev/vhost-vsock --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined -e ARCH="$ARCH" -v "$work:/w" -v "$here:/t:ro" bsl-vmtest:3 python3 /t/qemu-test-nix-move.py || rc=$?
[ -f "$work/vm-backup.tar" ] && mv -f "$work/vm-backup.tar" "$OUT"
exit $rc
