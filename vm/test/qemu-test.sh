#!/bin/sh
# Boots a bake-vm.sh image under QEMU in Docker with vhost-vsock and runs qemu-test.py against it:
# the agent (ping, info, time, file, run as root and as the user, a pty), the user's systemd session,
# networking through a host relay (DNS, apt-get update, an HTTPS fetch), the display relay, the
# Breadstick session in Floating and Desktop mode, the bridges, shared folders, disk growth and a
# clean power-off. Debian, Fedora and Arch images alike (image.json's "distro", plan 5.14 V4).
#   vm/test/qemu-test.sh <image folder from bake-vm.sh> [arm64|amd64]
#   STAGED_REPO=<stage> vm/test/qemu-test.sh ...   # first upgrade breadstick-desktop from a staged repo
#   AGENT_DIR=<dir> vm/test/qemu-test.sh ...       # today's guest programs (vm/guest/build.sh) in the test's disk
#   KERNEL=0 vm/test/qemu-test.sh ...              # skip the disk's-own-kernel test (it installs a kernel: 4 boots)
#   GROW=0 FILEBACKUP=0 vm/test/qemu-test.sh ...   # skip the disk growth (a boot) and the file backup round trip (a boot)
#   PROOT_IMAGE=<proot image .tar.zst> vm/test/qemu-test.sh ...   # also restore a proot system into the VM, last
#   CID=78 vm/test/qemu-test.sh ...                # the guest's vsock CID (default 77): one per test running at once
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
# The image's own description: its distribution and kernel line (plan 5.14 V4; Debian's images before 4.0 say neither).
[ -f "$IMG/image.json" ] && cp "$IMG/image.json" "$work/"
# AGENT_DIR=<vm/guest/build.sh output>: today's guest programs (and vmnet-setup) in place of the image's, written into
# the test's copy of the disk with debugfs, to test the sources on a published image (plan 5.14 V5). The published
# image is never touched.
AGENT_ENV=
if [ -n "${AGENT_DIR:-}" ]; then
  A_DIR=$(cd "$AGENT_DIR" && pwd)
  cmds="$work/debugfs.cmds"
  : > "$cmds"
  for f in "$A_DIR/bsl-vmagent" "$A_DIR/bsl-vmnet" "$A_DIR/bsl-x11-relay" "$here/../guest/files/vmnet-setup"; do
    case "$f" in *" "*) echo "AGENT_DIR: no spaces in paths, please ($f)" >&2; exit 2 ;; esac
    [ -f "$f" ] || { echo "AGENT_DIR: no $f" >&2; exit 2; }
    t="/usr/lib/breadstick-vm/$(basename "$f")"
    printf 'rm %s\nwrite %s %s\nsif %s mode 0100755\nsif %s uid 0\nsif %s gid 0\n' "$t" "$f" "$t" "$t" "$t" "$t" >> "$cmds"
  done
  /sbin/debugfs -w -f "$cmds" "$work/root.img" >/dev/null 2>"$work/debugfs.err" || { cat "$work/debugfs.err" >&2; exit 1; }
  /sbin/e2fsck -fn "$work/root.img" >/dev/null 2>&1 || { echo "the disk does not check clean after debugfs" >&2; exit 1; }
  AGENT_ENV="-e AGENT=2"
fi
# PROOT_IMAGE=<a proot system image or backup tar.zst of the same distribution> (plan 5.14 V20): restored into the VM
# the way the app restores a proot system's backup there (file-unpack-proot.sh, then file-restore.sh), last.
if [ -n "${PROOT_IMAGE:-}" ]; then
  zstd -q -dc "$PROOT_IMAGE" > "$work/proot.tar"
fi
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
docker run --rm --platform "linux/$(dpkg --print-architecture)" --name "${CNAME:-bsl-vmtest-$ARCH-$$}" $A $R $AGENT_ENV -e KERNEL="${KERNEL:-1}" -e GROW="${GROW:-1}" -e FILEBACKUP="${FILEBACKUP:-1}" -e CID="${CID:-77}" --device /dev/kvm --device /dev/vhost-vsock --security-opt seccomp=unconfined --security-opt apparmor=unconfined -e ARCH="$ARCH" \
  -v "$work:/w" -v "$here:/t:ro" bsl-vmtest:3 python3 /t/qemu-test.py
