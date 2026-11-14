#!/bin/sh
# Builds the three guest programs STATIC for one architecture, in Debian 13 (a container of that architecture; amd64
# runs under the host's qemu-user binfmt). They read /etc/passwd themselves and use no NSS, so one build serves the
# Debian, Fedora, Arch and NixOS images whatever their libc (plan 5.14 V5).
#
#   vm/guest/build.sh arm64|amd64 OUTDIR     # -> OUTDIR/{bsl-vmagent,bsl-vmnet,bsl-x11-relay}
# Used by bake-vm.sh, and by vm/test/qemu-test.sh (AGENT_DIR) to test today's sources on a published image.
set -eu
ARCH="${1:?arm64 or amd64}"
OUT="${2:?output folder}"
SUITE="${SUITE:-trixie}"
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
# A foreign architecture runs from its own tag (AutoBuild tools/qemu-x86_64-setup.sh, 2026-10-25):
# `docker run --platform linux/amd64 debian:trixie` on this arm64 host re-pulls debian:trixie AS
# amd64, and every later native user of that tag (bake-vm.sh's disk step, the gate, other
# builds) then runs under qemu, or fails once binfmt is gone. Seen again on the 2026-11-10 bake.
HOST_ARCH=$(dpkg --print-architecture)
GUEST_IMG="debian:$SUITE"
if [ "$ARCH" != "$HOST_ARCH" ]; then
  GUEST_IMG="bsl-debian-$SUITE:$ARCH"
  docker image inspect "$GUEST_IMG" >/dev/null 2>&1 || {
    docker pull -q --platform "linux/$ARCH" "debian:$SUITE" >/dev/null && docker tag "debian:$SUITE" "$GUEST_IMG" &&
      docker pull -q --platform "linux/$HOST_ARCH" "debian:$SUITE" >/dev/null; }
fi
docker run --rm --platform "linux/$ARCH" -e OWNER="$(id -u):$(id -g)" -v "$here:/src:ro" -v "$OUT:/out" "$GUEST_IMG" sh -ec '
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends gcc libc6-dev >/dev/null
  for p in bsl-vmagent bsl-vmnet bsl-x11-relay; do
    gcc -O2 -Wall -pthread -static -o /out/$p /src/$p.c
    strip /out/$p
  done
  chmod 755 /out/bsl-vmagent /out/bsl-vmnet /out/bsl-x11-relay
  chown "$OWNER" /out/bsl-vmagent /out/bsl-vmnet /out/bsl-x11-relay'
for p in bsl-vmagent bsl-vmnet bsl-x11-relay; do
  file "$OUT/$p" | sed 's/^/  /'
  file "$OUT/$p" | grep -q 'statically linked' || { echo "build.sh: $p is not static" >&2; exit 1; }
done
