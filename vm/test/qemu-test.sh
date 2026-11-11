#!/bin/sh
# Boots a bake-vm.sh image under QEMU in Docker with vhost-vsock and runs qemu-test.py against it:
# the agent (ping, info, time, file, run as root and as the user, a pty), the user's systemd session,
# networking through a host relay (DNS, apt-get update, an HTTPS fetch), the display relay, the
# Breadstick session in Floating and Desktop mode, the bridges, shared folders, disk growth and a
# clean power-off.
#   vm/test/qemu-test.sh <image folder from bake-vm.sh> [arm64|amd64]
#   STAGED_REPO=<stage> vm/test/qemu-test.sh ...   # first upgrade breadstick-desktop from a staged repo
# arm64 runs under KVM on an arm64 host; amd64 under TCG (slow). Needs the bsl-vmtest:3 image
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
# STAGED_REPO=<Apt/publish.sh stage> (AutoBuild test/gate.sh's VM stage): the VM first upgrades
# breadstick-desktop from it, read-only through /mnt/host; STAGED_SUITE=breadstick-test for a TEST=1 stage.
R=
if [ -n "${STAGED_REPO:-}" ]; then
  [ -s "$STAGED_REPO/dists/${STAGED_SUITE:-breadstick}/InRelease" ] || { echo "STAGED_REPO $STAGED_REPO has no dists/${STAGED_SUITE:-breadstick}/InRelease" >&2; exit 2; }
  R="-v $(cd "$STAGED_REPO" && pwd):/repo:ro -e STAGED_SUITE=${STAGED_SUITE:-breadstick}"
fi
docker run --rm $A $R --device /dev/kvm --device /dev/vhost-vsock --security-opt seccomp=unconfined --security-opt apparmor=unconfined -e ARCH="$ARCH" \
  -v "$work:/w" -v "$here:/t:ro" bsl-vmtest:3 python3 /t/qemu-test.py
