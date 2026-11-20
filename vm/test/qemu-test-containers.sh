#!/bin/sh
# Docker and Podman in a Breadstick VM image (4.0, r14): boots the image under QEMU in Docker with vhost-vsock, as
# qemu-test.sh does, and runs qemu-test-containers.py against it: the app's own installs (containers-<kind>-<distro>.sh,
# Android's linux/Containers.kt, copied here byte for byte), then real containers with the network through the relay.
# It pulls from Docker Hub (hello-world, alpine, nginx:alpine): the host needs the internet.
#   vm/test/qemu-test-containers.sh <image folder> [arm64|amd64]
#   KINDS="docker podman" (default both)   CID=81 (one per test running at once)   DISK=16G (the app's disk size today)
#   RULES=app|image: where the network rules come from. "app" (default): the image as it is (one baked before 4.0 has
#     none, and the app's install writes them); "image": today's vm/guest/files (vmnet-setup, vmnet.nft,
#     vmnet-containers.nft) written into the test's copy of the disk first, as a 4.0 bake installs them.
# arm64 under KVM on an arm64 host; amd64 under TCG (slow: allow an hour or more). Needs bsl-vmtest:3 (Dockerfile here).
set -eu
IMG=$(cd "${1:?image folder}" && pwd)
ARCH=${2:-arm64}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/bsl-vmtest-containers.XXXXXX")
trap 'cp "$work/console.log" "${KEEP_CONSOLE:-/dev/null}" 2>/dev/null; rm -rf "$work"' EXIT
zstd -q -dc "$IMG/root.img.zst" > "$work/root.img"
truncate -s "${DISK:-16G}" "$work/root.img"
cp "$IMG/vmlinuz" "$IMG/initrd.img" "$IMG/image.json" "$work/"
if [ "${RULES:-app}" = image ]; then
  cmds="$work/debugfs.cmds"
  : > "$cmds"
  for f in vmnet-setup:0100755 vmnet.nft:0100644 vmnet-containers.nft:0100644; do
    n=${f%%:*}; t="/usr/lib/breadstick-vm/$n"
    printf 'rm %s\nwrite %s %s\nsif %s mode %s\nsif %s uid 0\nsif %s gid 0\n' "$t" "$here/../guest/files/$n" "$t" "$t" "${f##*:}" "$t" "$t" >> "$cmds"
  done
  /sbin/debugfs -w -f "$cmds" "$work/root.img" >/dev/null 2>"$work/debugfs.err" || { cat "$work/debugfs.err" >&2; exit 1; }
  /sbin/e2fsck -fn "$work/root.img" >/dev/null 2>&1 || { echo "the disk does not check clean after debugfs" >&2; exit 1; }
fi
docker run --rm --platform "linux/$(dpkg --print-architecture)" --name "${CNAME:-bsl-vmtest-containers-$ARCH-$$}" \
  -e CID="${CID:-81}" -e KINDS="${KINDS:-docker podman}" -e RULES="${RULES:-app}" --device /dev/kvm --device /dev/vhost-vsock \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined -e ARCH="$ARCH" \
  -v "$work:/w" -v "$here:/t:ro" bsl-vmtest:3 python3 /t/qemu-test-containers.py
