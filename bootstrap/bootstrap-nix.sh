#!/usr/bin/env bash
# Breadstick-Nix's images (4.0, plan Android docs/4.0/multi-distro.md 5.9 and section 11). LOCAL ONLY: nothing here
# uploads anything or signs anything, no binary cache is made or served (nix.breadstick.io waits for its signing key,
# plan 10 decision 8), and no manifest is written anywhere a released app or the CDN reads.
#
#   [ARCH=arm64|amd64] [VERSION=1.0.44~test1] [PKGROOT=/abs/packages] [MANIFEST_DIR=/abs/dir] \
#     rootfs/bootstrap/bootstrap-nix.sh [desktop|base|both|vm]
#
# vm (plan 5.14 V4): the same configuration with "engine": "vm" as a virtual machine image, through nixpkgs'
# make-disk-image (vm/nixos/vm-image.nix; the build boots a helper VM, so /dev/kvm is passed in: arm64 on this host,
# amd64 would run its helper under TCG for hours): OUT_DIR/vm/nixos-26.05-<arch>-vm-<stamp>/{vmlinuz, initrd.img,
# root.img.zst, image.json} as bake-vm.sh writes Debian's, the kernel line's init=/sbin/init (the module's
# boot.loader.initScript), "distro": "nix", and with MANIFEST_DIR a local manifest-vm-nix-<arch>.json (the app reads
# only Debian's manifest-vm-<arch>.json from the CDN today; a per-distribution name is V4's, plan 5.14). Test it with
# vm/test/qemu-test-nix.sh.
#
# From the official nixos/nix container image (this host's architecture: an x86-64 system is built by the arm64 Nix,
# its packages fetched from cache.nixos.org and the few built here run under qemu-user 10 through binfmt, so
# AutoBuild/tools/qemu-x86_64-setup.sh must have run), in a container that has the network and never the gpg-agent
# socket:
#   1. nixpkgs pinned (NIXPKGS_URL, the release nixos-26.05 pointed at when this was written; its sha256 checked).
#   2. /etc/breadstick/nix assembled exactly as a device has it (bootstrap/nix's system.nix, breadstick.nix and
#      configuration.nix, packages' breadstick-nix/nix as module/, the parts of the packages tree the overlay builds
#      as src/ with VERSION, rootfs' vm/guest as vm-guest/, local.json with no account yet, packages.json empty), so
#      the store paths built here are the ones a device's first `bsl-nix apply` evaluates to: nothing rebuilds.
#   3. The NixOS system (breadstick.engine = "proot"; boot.isContainer) built for the architecture, copied with
#      nixpkgs' source into a root tree with its own Nix database (`nix copy --to local?root=`, Phase 0's route, so
#      no --load-db at first start), the system profile set, the build's gcroot removed (it names this container's
#      path) and nixpkgs' kept (gcroots/breadstick-nixpkgs).
#   4. The first activation in a chroot (users, groups, /etc, the paths module.nix makes: /bin/sh, /bin/bash,
#      /usr/local/bin, /usr/lib/breadstick), so the image is a system the app can run commands in before its first
#      `bsl-nix boot`; in a privileged container with no network that sees only the root tree (activation needs /proc
#      and /dev, which only a privileged container may mount). /etc/machine-id is left EMPTY (every device makes its
#      own at its first boot), /run emptied.
#   5. The image: the root tree as tar (numeric owner 0), zstd level 19, nixos-<release>-<arch>[-desktop]-<stamp>.tar.zst
#      in dist/ (git-ignored), written .unchecked and renamed only when its checks pass (nix-image-checks.sh: under
#      Cloudflare's 512,000,000-byte cache limit, no hard link, the store verified against its database).
#
# DOCS_LANGS (the owner's rule for any desktop image over the cache limit, 2026-11-14; plan 5.4): all, trimmed or auto
# (the default). trimmed builds the image's generation with documentation off and English only
# (breadstick.imageTrim), while the configuration it ships has neither setting (local.json "trimmed": true only marks
# the image), so the first apply on the device brings documentation and the user's language back (bsl-nix boot adds
# the device's locale to local.json's "locales"). auto builds it with both first and, when that image is at or over
# the limit, builds the trimmed one and keeps only it.
#
# MANIFEST_DIR (optional): manifest-nix-<arch>[-desktop].json for each image (RootfsDownloader.manifestName for
# Distro.NIX), for a LOCAL check. Refused under AutoBuild/dist or a mirror.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
case "$(uname -m)" in aarch64|arm64) HOST=arm64 ;; x86_64) HOST=amd64 ;; *) echo "ERROR: unknown host" >&2; exit 1 ;; esac
ARCH="${ARCH:-$HOST}"
case "$ARCH" in arm64) NIXSYS=aarch64-linux ;; amd64) NIXSYS=x86_64-linux ;; *) echo "ERROR: ARCH must be arm64 or amd64" >&2; exit 1 ;; esac
WHAT="${1:-desktop}"
case "$WHAT" in base|desktop|both|vm) ;; *) echo "usage: $0 [desktop|base|both|vm]" >&2; exit 1 ;; esac
VERSION="${VERSION:-1.0.44~test1}"
case "$VERSION" in *[!0-9A-Za-z.~+-]*|'') echo "ERROR: VERSION is a Debian version" >&2; exit 1 ;; esac
PKGROOT="${PKGROOT:-$ROOT/../packages}"
[ -f "$PKGROOT/breadstick-nix/nix/module.nix" ] || { echo "ERROR: $PKGROOT is not a packages tree with breadstick-nix (set PKGROOT=)" >&2; exit 1; }
PKGROOT="$(cd "$PKGROOT" && pwd)"
# nixos-26.05 on 2026-11-15 (channels.nixos.org/nixos-26.05 -> releases.nixos.org); NIXPKGS_SHA256 is
# nix-prefetch-url --unpack's (sha256, base32) of that tarball. Change both together.
RELEASE="${NIXPKGS_RELEASE:-nixos-26.05.14234.f1e5c356f35d}"
NIXPKGS_URL="${NIXPKGS_URL:-https://releases.nixos.org/nixos/26.05/$RELEASE/nixexprs.tar.xz}"
NIXPKGS_SHA256="${NIXPKGS_SHA256:-}"
STATE_VERSION="26.05"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
STAMP="${STAMP:-$(date -u +%Y%m%d%H%M)}"
case "$STAMP" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) echo "ERROR: STAMP must be YYYYMMDDHHMM" >&2; exit 1 ;; esac
LEVEL="${BAKE_ZSTD_LEVEL:-19}"
DOCS_LANGS="${DOCS_LANGS:-auto}"
case "$DOCS_LANGS" in all|trimmed|auto) ;; *) echo "ERROR: DOCS_LANGS is all, trimmed or auto" >&2; exit 1 ;; esac
case "${OVER_CACHE_LIMIT:-}" in ''|keep) ;; *) echo "ERROR: OVER_CACHE_LIMIT is keep or unset" >&2; exit 1 ;; esac
NIX_IMAGE="${NIX_IMAGE:-nixos/nix:latest}"
# The first activation's container: mount and chroot (the nixos/nix image has no mount).
ACT_IMAGE="${ACT_IMAGE:-debian:trixie}"
# shellcheck source=nix-image-checks.sh
. "$HERE/nix-image-checks.sh"
log() { printf '\033[1;34m[bake-nix]\033[0m %s\n' "$*"; }
if [ -n "${MANIFEST_DIR:-}" ]; then
  case "$MANIFEST_DIR" in /*) ;; *) echo "ERROR: MANIFEST_DIR must be an absolute path" >&2; exit 1 ;; esac
  case "$(realpath -m "$MANIFEST_DIR")/" in
    */AutoBuild/dist/*|*/mirror/*) echo "ERROR: MANIFEST_DIR may not be under AutoBuild/dist or a mirror" >&2; exit 1 ;;
  esac
fi
if [ "$ARCH" != "$HOST" ]; then
  [ -e /proc/sys/fs/binfmt_misc/qemu-x86_64-10 ] || { echo "ERROR: an amd64 system needs qemu-user 10 (AutoBuild/tools/qemu-x86_64-setup.sh)" >&2; exit 1; }
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

WORK="$(mktemp -d)"
C="bsl-r9-nix-bake-$ARCH-$$"
cleanup() {
  docker rm -f "$C" "$C-act" >/dev/null 2>&1 || true
  # A root tree a failed step left is the container's root's (its store folders are 0555): removed in a container.
  if [ -d "$WORK/out/root" ]; then
    docker run --rm --platform "linux/$HOST" -v "$WORK/out:/out" "$NIX_IMAGE" sh -c 'chmod -R u+w /out/root 2>/dev/null; rm -rf /out/root' >/dev/null 2>&1 || true
  fi
  [ -d "$WORK/out" ] && docker run --rm --platform "linux/$HOST" -v "$WORK/out:/out" "$NIX_IMAGE" sh -c 'rm -f /out/system-path /out/nixpkgs-path' >/dev/null 2>&1 || true
  # The work folder holds the assembled /etc/breadstick/nix (files, folders, relative links; rm never follows one).
  rm -rf --one-file-system "$WORK"
}
trap cleanup EXIT

# --- /etc/breadstick/nix, as a device has it --------------------------------------------------------------------
E="$WORK/etc-nix"
mkdir -p "$E/module" "$E/src" "$E/vm-guest"
cp "$HERE/nix/system.nix" "$HERE/nix/breadstick.nix" "$E/"
cp "$PKGROOT"/breadstick-nix/nix/*.nix "$E/module/"
for d in breadstick-session/src breadstick-theme/src breadstick-tools/src breadstick-nix/src; do
  mkdir -p "$E/src/$d"
  cp -r "$PKGROOT/$d/." "$E/src/$d/"
done
mkdir -p "$E/src/breadstick-systemd"
cp -r "$PKGROOT/breadstick-systemd/src" "$E/src/breadstick-systemd/src"
cp "$PKGROOT/breadstick-systemd/DESIGN.md" "$E/src/breadstick-systemd/"
printf '%s\n' "$VERSION" > "$E/src/VERSION"
cp -r "$ROOT/vm/guest/." "$E/vm-guest/"
find "$E" \( -name __pycache__ -o -name '*.pyc' -o -name '*.o' \) -prune -exec rm -rf {} +
# The VM guest's built programs, if a local build left them, never go in (the module builds its own).
rm -f "$E/vm-guest/bsl-vmagent" "$E/vm-guest/bsl-vmnet" "$E/vm-guest/bsl-x11-relay"
printf '{\n  "packages": [],\n  "version": 1\n}\n' > "$E/packages.json"
cp "$HERE/nix/configuration.nix" "$WORK/configuration.nix"
# The theme's own relative links (gtk-dark.css, the fontconfig link) come along; an absolute one would name this host.
find "$E" -type l -lname '/*' -print -quit | grep -q . && { echo "ERROR: the assembled /etc/breadstick/nix holds an absolute link" >&2; exit 1; }

cp "$ROOT/vm/nixos/vm-image.nix" "$WORK/vm-image.nix"
cat > "$WORK/vmstep.sh" <<'BSL_NIX_VMSTEP_END'
#!/bin/sh
# Runs in the nixos/nix container with /dev/kvm: the VM image's files into /out/vm.
set -eu
export NIX_CONFIG="sandbox = false
filter-syscalls = false
experimental-features = nix-command
system-features = kvm nixos-test big-parallel benchmark
extra-platforms = $NIXSYS
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
NP=$(nix-prefetch-url --unpack --print-path --name "nixpkgs-$RELEASE" "$NIXPKGS_URL" | tail -n 2)
NP_SHA=$(echo "$NP" | head -n 1); NP_PATH=$(echo "$NP" | tail -n 1)
mkdir -p /etc/breadstick /etc/nixos
rm -rf /etc/breadstick/nix
cp -r /cfg/etc-nix /etc/breadstick/nix
cp /cfg/configuration.nix /etc/nixos/configuration.nix
ln -sfn "$NP_PATH" /etc/breadstick/nix/nixpkgs
cat > /etc/breadstick/nix/local.json <<EOF
{
  "channel": "stable",
  "desktop": true,
  "engine": "vm",
  "imageTrim": false,
  "stateVersion": "$STATE_VERSION",
  "user": ""
}
EOF
printf '{\n  "channel": "stable",\n  "path": "%s",\n  "release": "%s",\n  "sha256": "%s",\n  "url": "%s"\n}\n' \
  "$NP_PATH" "$RELEASE" "$NP_SHA" "$NIXPKGS_URL" > /etc/breadstick/nix/nixpkgs.json
export NIX_PATH="nixpkgs=/etc/breadstick/nix/nixpkgs:nixos-config=/etc/nixos/configuration.nix"
echo "[vmstep] building the VM image for $NIXSYS"
V=$(nix-build /cfg/vm-image.nix --arg nixpkgs "$NP_PATH" --argstr system "$NIXSYS" --no-out-link)
mkdir -p /out/vm
for f in vmlinuz initrd.img; do cp -L "$V/$f" /out/vm/$f; done
cp -L "$V/root.img" /out/vm/root.img
chmod 0644 /out/vm/*
for f in toplevel kernel-version nixpkgs; do cp "$V/$f" /out/vm/$f; done
echo "[vmstep] done"
BSL_NIX_VMSTEP_END

cat > "$WORK/step.sh" <<'BSL_NIX_STEP_END'
#!/bin/sh
# Runs in the nixos/nix container. $1 = base|desktop, $2 = 1 for a trimmed generation.
set -eu
FLAVOUR=$1 TRIM=${2:-}
export NIX_CONFIG="sandbox = false
filter-syscalls = false
experimental-features = nix-command
extra-platforms = $NIXSYS
max-jobs = auto
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
echo "[step] nixpkgs $RELEASE"
NP=$(nix-prefetch-url --unpack --print-path --name "nixpkgs-$RELEASE" "$NIXPKGS_URL" | tail -n 2)
NP_SHA=$(echo "$NP" | head -n 1)
NP_PATH=$(echo "$NP" | tail -n 1)
if [ -n "$NIXPKGS_SHA256" ] && [ "$NP_SHA" != "$NIXPKGS_SHA256" ]; then
  echo "ERROR: nixpkgs is $NP_SHA, not the pinned $NIXPKGS_SHA256" >&2; exit 1
fi
mkdir -p /etc/breadstick /etc/nixos
rm -rf /etc/breadstick/nix
cp -r /cfg/etc-nix /etc/breadstick/nix
cp /cfg/configuration.nix /etc/nixos/configuration.nix
ln -sfn "$NP_PATH" /etc/breadstick/nix/nixpkgs
DESK=true; [ "$FLAVOUR" = base ] && DESK=false
TRIMMED=false; [ -n "$TRIM" ] && TRIMMED=true
cat > /etc/breadstick/nix/local.json <<EOF
{
  "channel": "stable",
  "desktop": $DESK,
  "engine": "proot",
  "imageTrim": $TRIMMED,
  "stateVersion": "$STATE_VERSION",
  "user": ""
}
EOF
printf '{\n  "channel": "stable",\n  "path": "%s",\n  "release": "%s",\n  "sha256": "%s",\n  "url": "%s"\n}\n' \
  "$NP_PATH" "$RELEASE" "$NP_SHA" "$NIXPKGS_URL" > /etc/breadstick/nix/nixpkgs.json
export NIX_PATH="nixpkgs=/etc/breadstick/nix/nixpkgs:nixos-config=/etc/nixos/configuration.nix"
echo "[step] building the $FLAVOUR system for $NIXSYS${TRIM:+ (trimmed)}"
SYS=$(nix-build '<nixpkgs/nixos>' -A system --argstr system "$NIXSYS" --no-out-link)
echo "[step] system $SYS"
R=/out/root
rm -rf "$R"; mkdir -p "$R"
nix copy --no-check-sigs --to "local?root=$R" "$SYS" "$NP_PATH"
# The profile's links are made in the root tree (-p names a real path); they point at the store as a device sees it.
nix-env --store "local?root=$R" -p "$R/nix/var/nix/profiles/system" --set "$SYS"
[ -L "$R/nix/var/nix/profiles/system" ] || { echo "ERROR: no system profile in the root tree" >&2; exit 1; }
# The build's own roots name this container's paths; nixpkgs' is kept by name.
rm -f "$R"/nix/var/nix/gcroots/auto/*
ln -sfn "$NP_PATH" "$R/nix/var/nix/gcroots/breadstick-nixpkgs"
mkdir -p "$R/etc/breadstick" "$R/etc/nixos" "$R/tmp" "$R/root" "$R/proc" "$R/dev" "$R/sys" "$R/run" "$R/var" \
  "$R/home" "$R/mnt" "$R/bin" "$R/usr/bin" "$R/var/lib/breadstick"
chmod 1777 "$R/tmp"; chmod 0700 "$R/root"
cp -r /etc/breadstick/nix "$R/etc/breadstick/nix"
cp /etc/nixos/configuration.nix "$R/etc/nixos/configuration.nix"
: > "$R/etc/NIXOS"
# What the app runs commands with before the first activation, and what activation keeps.
ln -sfn /nix/var/nix/profiles/system/sw/bin/sh "$R/bin/sh"
ln -sfn /nix/var/nix/profiles/system/sw/bin/bash "$R/bin/bash"
ln -sfn /nix/var/nix/profiles/system/sw/bin/env "$R/usr/bin/env"
echo "$SYS" > /out/system-path
echo "$NP_PATH" > /out/nixpkgs-path
echo "[step] done"
BSL_NIX_STEP_END

# The first activation, in a chroot of the root tree with /proc, /dev and /sys mounted (activation's scripts read
# /proc/self and /dev/fd), in a privileged container with no network that sees only the root tree. Then what the
# chroot left that is this container's, never a device's: /run's contents (a device's first boot makes its own), the
# machine id (empty: each device makes its own), and the build's gcroots.
cat > "$WORK/activate.sh" <<'BSL_NIX_ACT_END'
#!/bin/sh
set -eu
R=/out/root
mount -t proc proc "$R/proc"
mount --rbind /dev "$R/dev"
mount -t sysfs sys "$R/sys"
rc=0
chroot "$R" /nix/var/nix/profiles/system/activate || rc=$?
umount -l "$R/sys" "$R/dev" "$R/proc" || true
[ "$rc" = 0 ] || { echo "ERROR: the first activation failed ($rc)" >&2; exit 1; }
: > "$R/etc/machine-id"
find "$R/run" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
rm -f "$R/nix/var/nix/gcroots/auto/"* "$R/etc/breadstick/nix/local.json.tmp"
echo "[activate] done"
BSL_NIX_ACT_END

name_of() {  # $1 = base|desktop
  local n
  n="nixos-$(echo "$RELEASE" | sed -E 's/^nixos-([0-9]+\.[0-9]+).*/\1/')-$ARCH"
  [ "$1" = desktop ] && n="$n-desktop"
  echo "$OUT_DIR/$n-$STAMP.tar.zst"
}

docker pull -q --platform "linux/$HOST" "$NIX_IMAGE" >/dev/null
docker pull -q --platform "linux/$HOST" "$ACT_IMAGE" >/dev/null
OUTV="$WORK/out"
mkdir -p "$OUTV"
build_one() {  # $1 = base|desktop, $2 = 1 trimmed; writes $3 (.unchecked)
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker run --name "$C" --platform "linux/$HOST" \
    -e NIXSYS="$NIXSYS" -e RELEASE="$RELEASE" -e NIXPKGS_URL="$NIXPKGS_URL" -e NIXPKGS_SHA256="$NIXPKGS_SHA256" \
    -e STATE_VERSION="$STATE_VERSION" \
    -v "$WORK/etc-nix:/cfg/etc-nix:ro" -v "$WORK/configuration.nix:/cfg/configuration.nix:ro" \
    -v "$WORK/step.sh:/step.sh:ro" -v "$OUTV:/out" -v "bsl-r9-nix-store-$HOST:/nix" \
    "$NIX_IMAGE" sh /step.sh "$1" "${2:-}"
  docker rm -f "$C" >/dev/null
  log "first activation"
  docker run --rm --name "$C-act" --platform "linux/$HOST" --privileged --network none \
    -v "$WORK/activate.sh:/activate.sh:ro" -v "$OUTV:/out" "$ACT_IMAGE" sh /activate.sh
  log "writing $(basename "$3")"
  # As root (the tree's files are the container's root's): numeric owner 0, the store's modes kept.
  docker run --rm --platform "linux/$HOST" -v "$OUTV:/out" -v "bsl-r9-nix-store-$HOST:/nix" "$NIX_IMAGE" \
    sh -c 'cd /out/root && tar --numeric-owner --owner=0 --group=0 -cf - .' | zstd -q -"$LEVEL" -T0 -o "$3.unchecked"
  zstd -q -t "$3.unchecked"
}
check_one() {  # $1 = base|desktop, $2 = tarball
  local t="$2.unchecked" why
  if why="$(bsl_nix_size_check "$t")"; then
    log "$why"
  elif [ "${OVER_CACHE_LIMIT:-}" = keep ]; then
    log "WARNING: $why (kept: OVER_CACHE_LIMIT=keep)"
  else
    mv -f "$t" "$2.rejected"; echo "ERROR: $why" >&2; return 1
  fi
  zstd -dc "$t" | tar tvf - > "$WORK/list"
  if ! why="$(bsl_nix_listing_check "$WORK/list")"; then
    mv -f "$t" "$2.rejected"; echo "ERROR: $(basename "$2"): $why" >&2; return 1
  fi
  # The store against its own database, in a container with no network (nothing fetched or signed here).
  docker run --rm --platform "linux/$HOST" --network none -v "$OUTV:/out" -v "bsl-r9-nix-store-$HOST:/nix" "$NIX_IMAGE" \
    sh -c 'nix-store --store "local?root=/out/root" --verify --check-contents' \
    || { mv -f "$t" "$2.rejected"; echo "ERROR: $(basename "$2"): the store does not verify" >&2; return 1; }
  mv -f "$t" "$2"
}
write_manifest() {  # $1 = base|desktop, $2 = tarball
  [ -n "${MANIFEST_DIR:-}" ] || return 0
  mkdir -p "$MANIFEST_DIR"
  local m="manifest-nix-$ARCH.json"
  [ "$1" = desktop ] && m="manifest-nix-$ARCH-desktop.json"
  printf '{\n  "version": "%s",\n  "file": "%s",\n  "size": %s,\n  "sha256": "%s",\n  "arch": "%s",\n  "distro": "nix"\n}\n' \
    "$STAMP" "$(basename "$2")" "$(stat -c %s "$2")" "$(sha256sum "$2" | cut -d' ' -f1)" "$ARCH" > "$MANIFEST_DIR/$m"
  log "local manifest $MANIFEST_DIR/$m"
}

if [ "$WHAT" = vm ]; then
  [ -e /dev/kvm ] || { echo "ERROR: the VM image's build needs /dev/kvm" >&2; exit 1; }
  NAME="nixos-$(echo "$RELEASE" | sed -E 's/^nixos-([0-9]+\.[0-9]+).*/\1/')-$ARCH-vm-$STAMP"
  VOUT="$OUT_DIR/vm/$NAME"
  mkdir -p "$VOUT"
  log "building $NAME"
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker run --name "$C" --platform "linux/$HOST" --device /dev/kvm \
    -e NIXSYS="$NIXSYS" -e RELEASE="$RELEASE" -e NIXPKGS_URL="$NIXPKGS_URL" -e STATE_VERSION="$STATE_VERSION" \
    -v "$WORK/etc-nix:/cfg/etc-nix:ro" -v "$WORK/configuration.nix:/cfg/configuration.nix:ro" \
    -v "$WORK/vm-image.nix:/cfg/vm-image.nix:ro" -v "$WORK/vmstep.sh:/vmstep.sh:ro" -v "$OUTV:/out" \
    -v "bsl-r9-nix-store-$HOST:/nix" "$NIX_IMAGE" sh /vmstep.sh
  docker rm -f "$C" >/dev/null
  docker run --rm --platform "linux/$HOST" -v "$OUTV:/out" "$NIX_IMAGE" sh -c 'chown -R '"$(id -u):$(id -g)"' /out/vm'
  cp "$OUTV/vm/vmlinuz" "$OUTV/vm/initrd.img" "$VOUT/"
  log "compressing root.img ($(du -h --apparent-size "$OUTV/vm/root.img" | cut -f1) apparent)"
  zstd -q -T0 -15 "$OUTV/vm/root.img" -o "$VOUT/root.img.zst"
  KVER="$(cat "$OUTV/vm/kernel-version")"
  TOP="$(cat "$OUTV/vm/toplevel")"
  rm -f "$OUTV/vm/"*; rmdir "$OUTV/vm"
  sha() { sha256sum "$1" | cut -d' ' -f1; }
  size() { stat -c %s "$1"; }
  cat > "$VOUT/image.json" <<EOF
{
  "format": 1,
  "name": "$NAME",
  "arch": "$ARCH",
  "distro": "nix",
  "suite": "$RELEASE",
  "kernel_version": "$KVER",
  "agent": 2,
  "desktop": true,
  "cmdline": "console=ttyS0 8250.nr_uarts=4 root=/dev/vda rw panic=-1 quiet init=/sbin/init",
  "files": {
    "kernel": { "name": "vmlinuz", "sha256": "$(sha "$VOUT/vmlinuz")", "size": $(size "$VOUT/vmlinuz") },
    "initrd": { "name": "initrd.img", "sha256": "$(sha "$VOUT/initrd.img")", "size": $(size "$VOUT/initrd.img") },
    "root": { "name": "root.img.zst", "sha256": "$(sha "$VOUT/root.img.zst")", "size": $(size "$VOUT/root.img.zst") }
  }
}
EOF
  if [ -n "${MANIFEST_DIR:-}" ]; then
    mkdir -p "$MANIFEST_DIR"
    sed "s|\"name\": \"$NAME\",|\"name\": \"$NAME\",\n  \"base\": \"vm/$NAME/\",|" "$VOUT/image.json" > "$MANIFEST_DIR/manifest-vm-nix-$ARCH.json"
    log "local manifest $MANIFEST_DIR/manifest-vm-nix-$ARCH.json"
  fi
  log "Artifact: $VOUT (system $TOP)"
  log "Nothing was uploaded."
  exit 0
fi

for f in base desktop; do
  [ "$WHAT" = both ] || [ "$WHAT" = "$f" ] || continue
  T="$(name_of "$f")"
  if [ "$f" = desktop ] && [ "$DOCS_LANGS" = trimmed ]; then
    build_one "$f" 1 "$T"
  else
    build_one "$f" "" "$T"
    if [ "$f" = desktop ] && [ "$DOCS_LANGS" = auto ] && ! why="$(bsl_nix_size_check "$T.unchecked")"; then
      log "$why"
      log "DOCS_LANGS=auto: the desktop image again, without documentation and languages (plan 5.4)"
      rm -f "$T.unchecked"
      build_one "$f" 1 "$T"
    fi
  fi
  check_one "$f" "$T"
  write_manifest "$f" "$T"
  log "Artifact: $T ($(stat -c %s "$T") bytes; system $(cat "$OUTV/system-path"))"
done
# The root tree is the container's root's: removed in a container too.
docker run --rm --platform "linux/$HOST" -v "$OUTV:/out" "$NIX_IMAGE" sh -c 'chmod -R u+w /out/root 2>/dev/null; rm -rf /out/root' || true
log "The Nix store volume bsl-r9-nix-store-$HOST is kept for the next bake (docker volume rm it to start clean)."
log "Nothing was uploaded."
