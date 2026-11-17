#!/usr/bin/env bash
# Breadstick-Nix's images (4.0, plan Android docs/4.0/multi-distro.md 5.9 and section 11). LOCAL ONLY: nothing here
# uploads anything or signs anything, no binary cache is made or served (nix.breadstick.io waits for its signing key,
# plan 10 decision 8), and no manifest is written anywhere a released app or the CDN reads.
#
#   [ARCH=arm64|amd64] [VERSION=1.0.44~test1] [PKGROOT=/abs/packages] [MANIFEST_DIR=/abs/dir] \
#     rootfs/bootstrap/bootstrap-nix.sh [desktop|base|both|vm]
#
# vm (plan 5.14 V4): the same configuration with "engine": "vm" as a virtual machine image, through nixpkgs'
# make-disk-image (vm/nixos/vm-image.nix; the build boots a helper VM, so /dev/kvm is passed in: this host's
# architecture) or, with VM_ROUTE=tree (the default for amd64 on this arm64 host, round 12), with no helper VM: the
# system copied into a root tree with its own database as the proot image is, made into the ext4 disk by mkfs.ext4 -d:
# OUT_DIR/vm/nixos-26.05-<arch>-vm-<stamp>/{vmlinuz, initrd.img,
# root.img.zst, image.json} as bake-vm.sh writes Debian's, "distro": "nix", the kernel line's
# init=/nix/var/nix/profiles/system/init (NixOS 26.05's systemd stage 1 resolves it to the newest generation's closure;
# /sbin/init, a script, is no closure to it) and no root= (stage 1 mounts / from the configuration's fileSystems, and a
# root= beside it is a second sysroot.mount), and with MANIFEST_DIR a local nix/manifest-vm-<arch>.json: the one name
# the app reads (VmManifest.manifestName for Distro.NIX, plan 5.14 V4), the one AutoBuild deploy/vm-image.sh DISTRO=nix
# publishes and tools/serve-test-images.sh serves (round 10; it was manifest-vm-nix-<arch>.json). Test it with
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
#   5. The image: the root tree as tar (numeric owner 0), zstd --ultra -22 --long=27 (round 12; BAKE_ZSTD_LEVEL and
#      BAKE_ZSTD_LONG), nixos-<release>-<arch>[-desktop]-<stamp>.tar.zst
#      in dist/ (git-ignored), written .unchecked and renamed only when its checks pass (nix-image-checks.sh: under
#      Cloudflare's 512,000,000-byte cache limit, no hard link, the store verified against its database, and on a
#      desktop image the desktop marker and /usr/share's links, which the first activation makes).
#
# DOCS_LANGS (the owner's rule for any desktop image over the cache limit, 2026-11-14; plan 5.4): all, trimmed or auto
# (the default). No image carries a language but English (a NixOS system builds each locale it has, and the
# configuration's locales start empty), so the trim is documentation: trimmed builds the image's generation with
# documentation off (breadstick.imageTrim, which the user's first `bsl-nix apply` turns off, bringing documentation
# back), and the user's language is filled in at the first desktop start by `bsl-nix languages` (the app runs it; on
# Wi-Fi or Ethernet, as Fedora's fill). auto builds it with documentation first and, when that image is within
# HEADROOM (25,600,000 bytes, 5% of the limit; round 12) of the limit or over it, builds the trimmed one and keeps only it.
#
# MANIFEST_DIR (optional): manifest-nix-<arch>[-desktop].json for each image (RootfsDownloader.manifestName for
# Distro.NIX), for a LOCAL check. Refused under AutoBuild/dist or a mirror.
#
# RUN (default nixbake): the name every Docker object this run makes carries, bsl-<RUN>-*: the containers
# (bsl-<RUN>-bake-<arch>-<pid>, -act, -tar, -verify, -chown, -clean) and the Nix store volume (bsl-<RUN>-store-<host>).
# All of them are removed when the run ends, the volume included (a store of about 3 GB; KEEP_STORE=1 keeps the
# volume for the next bake with the same RUN, and says so). The two images it pulls (nixos/nix, debian:trixie) are
# Docker Hub's and stay.
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
# zstd --ultra -22 with a 128 MiB window (--long=27, round 12): the store's many copies of the same libraries lie far
# apart in the tar, and a long window finds them. Measured on round 11's trimmed arm64 desktop image: 497,583,098 bytes
# at level 19, 445,782,682 at -22 --long=27 (10% smaller). 27 is libzstd's default window limit for decoding
# (ZSTD_WINDOWLOG_LIMIT_DEFAULT), so the app's zstd-jni ZstdInputStream reads it with no setting changed; never more.
LEVEL="${BAKE_ZSTD_LEVEL:-22}"
LONG="${BAKE_ZSTD_LONG:-27}"
case "$LONG" in ''|0) ZSTD_LONG= ;; 1[0-9]|2[0-7]) ZSTD_LONG="--long=$LONG" ;; *) echo "ERROR: BAKE_ZSTD_LONG is 10 to 27 (the app decodes no larger window), or 0" >&2; exit 1 ;; esac
ZSTD_ULTRA=; [ "$LEVEL" -gt 19 ] && ZSTD_ULTRA=--ultra
RUN="${RUN:-nixbake}"
case "$RUN" in *[!a-z0-9-]*|''|-*) echo "ERROR: RUN is lowercase letters, digits and -" >&2; exit 1 ;; esac
case "${KEEP_STORE:-}" in ''|1) ;; *) echo "ERROR: KEEP_STORE is 1 or unset" >&2; exit 1 ;; esac
VOL="bsl-$RUN-store-$HOST"
DOCS_LANGS="${DOCS_LANGS:-auto}"
HEADROOM="${HEADROOM:-25600000}"
case "$HEADROOM" in *[!0-9]*|'') echo "ERROR: HEADROOM is a number of bytes" >&2; exit 1 ;; esac
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
C="bsl-$RUN-bake-$ARCH-$$"
cleanup() {
  docker rm -f "$C" "$C-act" "$C-tar" "$C-verify" "$C-chown" >/dev/null 2>&1 || true
  # A root tree a failed step left is the container's root's (its store folders are 0555): removed in a container.
  if [ -d "$WORK/out/root" ]; then
    docker run --rm --name "$C-clean" --platform "linux/$HOST" -v "$WORK/out:/out" "$NIX_IMAGE" sh -c 'chmod -R u+w /out/root 2>/dev/null; rm -rf /out/root' >/dev/null 2>&1 || true
  fi
  [ -d "$WORK/out" ] && docker run --rm --name "$C-clean" --platform "linux/$HOST" -v "$WORK/out:/out" "$NIX_IMAGE" sh -c 'chmod -R u+w /out/vmroot 2>/dev/null; rm -rf /out/system-path /out/nixpkgs-path /out/vm /out/vmroot' >/dev/null 2>&1 || true
  docker rm -f "$C-clean" >/dev/null 2>&1 || true
  if [ "${KEEP_STORE:-}" = 1 ]; then
    echo "[bake-nix] the Nix store volume $VOL is kept (KEEP_STORE=1; docker volume rm $VOL removes it)" >&2
  else
    docker volume rm -f "$VOL" >/dev/null 2>&1 || true
  fi
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
# breadstick-shm and breadstick-gl: their programs and the committed libraries every family ships (overlay.nix picks
# this architecture's); the architecture's Vulkan driver for native GPU mode, its tarball only (round 11, plan 5.14 P1).
for d in breadstick-shm breadstick-gl; do
  mkdir -p "$E/src/$d"
  cp -r "$PKGROOT/$d/src" "$PKGROOT/$d/prebuilt" "$E/src/$d/"
done
case "$ARCH" in arm64) MESA=breadstick-mesa-adreno ;; amd64) MESA=breadstick-mesa-intel ;; esac
mkdir -p "$E/src/$MESA/prebuilt/$ARCH"
cp "$PKGROOT/$MESA/prebuilt/$ARCH/$MESA.tar.gz" "$E/src/$MESA/prebuilt/$ARCH/"
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
V=$(nix-build /cfg/vm-image.nix --argstr nixpkgs "$NP_PATH" --argstr system "$NIXSYS" --no-out-link)
mkdir -p /out/vm
for f in vmlinuz initrd.img; do cp -L "$V/$f" /out/vm/$f; done
cp -L "$V/root.img" /out/vm/root.img
chmod 0644 /out/vm/*
for f in toplevel kernel-version nixpkgs; do cp "$V/$f" /out/vm/$f; done
echo "[vmstep] done"
BSL_NIX_VMSTEP_END

# The VM image without a helper VM (VM_ROUTE=tree; round 12): the system built and copied into a root tree with its
# own Nix database exactly as the proot image is (nix copy --to local?root=), the system profile set, and the tree made
# into the ext4 disk labeled bslroot by mkfs.ext4 -d. make-disk-image boots a helper VM, which for an amd64 image on
# this arm64 host is TCG ("hours"); this route builds the amd64 one under qemu-user like the proot image. What
# make-disk-image added besides: switch-to-configuration boot's /sbin/init, which nothing starts (the kernel line names
# the profile's init). The first boot's stage 2 activates the system, as on make-disk-image's disk.
cat > "$WORK/vmtree.sh" <<'BSL_NIX_VMTREE_END'
#!/bin/sh
set -eu
export NIX_CONFIG="sandbox = false
filter-syscalls = false
experimental-features = nix-command
extra-platforms = $NIXSYS
max-jobs = auto
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
NP=$(nix-prefetch-url --unpack --print-path --name "nixpkgs-$RELEASE" "$NIXPKGS_URL" | tail -n 2)
NP_SHA=$(echo "$NP" | head -n 1); NP_PATH=$(echo "$NP" | tail -n 1)
if [ -n "$NIXPKGS_SHA256" ] && [ "$NP_SHA" != "$NIXPKGS_SHA256" ]; then
  echo "ERROR: nixpkgs is $NP_SHA, not the pinned $NIXPKGS_SHA256" >&2; exit 1
fi
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
echo "[vmtree] building the VM system for $NIXSYS"
SYS=$(nix-build '<nixpkgs/nixos>' -A system --argstr system "$NIXSYS" --no-out-link)
[ -e "$SYS/kernel" ] && [ -e "$SYS/initrd" ] || { echo "ERROR: $SYS has no kernel or initrd" >&2; exit 1; }
R=/out/vmroot
rm -rf "$R"; mkdir -p "$R"
nix copy --no-check-sigs --to "local?root=$R" "$SYS" "$NP_PATH"
nix-env --store "local?root=$R" -p "$R/nix/var/nix/profiles/system" --set "$SYS"
rm -f "$R"/nix/var/nix/gcroots/auto/*
ln -sfn "$NP_PATH" "$R/nix/var/nix/gcroots/breadstick-nixpkgs"
mkdir -p "$R/etc/breadstick" "$R/etc/nixos" "$R/tmp" "$R/root" "$R/proc" "$R/dev" "$R/sys" "$R/run" "$R/var" \
  "$R/home" "$R/mnt" "$R/boot"
chmod 1777 "$R/tmp"; chmod 0700 "$R/root"
cp -r /etc/breadstick/nix "$R/etc/breadstick/nix"
cp /etc/nixos/configuration.nix "$R/etc/nixos/configuration.nix"
: > "$R/etc/NIXOS"
# The disk: this host's mkfs.ext4 from the same nixpkgs; the tree's size and a tenth more, 1 GiB free (as
# make-disk-image's additionalSpace), and an inode for every file with room to spare.
E2=$(nix-build "$NP_PATH" -A e2fsprogs.bin --no-out-link 2>/dev/null || nix-build "$NP_PATH" -A e2fsprogs --no-out-link)
BYTES=$(du -sb "$R" | cut -f1); FILES=$(find "$R" | wc -l)
MIB=$(( (BYTES / 10 * 11 + 1073741824) / 1048576 + 1 ))
mkdir -p /out/vm
rm -f /out/vm/root.img
truncate -s "${MIB}M" /out/vm/root.img
"$E2/bin/mkfs.ext4" -q -F -L bslroot -N $(( FILES * 3 / 2 + 65536 )) -E root_owner=0:0 -d "$R" /out/vm/root.img
"$E2/bin/e2fsck" -fn /out/vm/root.img >/dev/null
cp -L "$SYS/kernel" /out/vm/vmlinuz
cp -L "$SYS/initrd" /out/vm/initrd.img
chmod 0644 /out/vm/*
echo "$SYS" > /out/vm/toplevel
ls "$SYS/kernel-modules/lib/modules" | head -n 1 > /out/vm/kernel-version
echo "$NP_PATH" > /out/vm/nixpkgs
chmod -R u+w "$R"; rm -rf "$R"
echo "[vmtree] done (${MIB} MiB disk, $FILES files)"
BSL_NIX_VMTREE_END

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
    -v "$WORK/step.sh:/step.sh:ro" -v "$OUTV:/out" -v "$VOL:/nix" \
    "$NIX_IMAGE" sh /step.sh "$1" "${2:-}"
  docker rm -f "$C" >/dev/null
  log "first activation"
  docker run --rm --name "$C-act" --platform "linux/$HOST" --privileged --network none \
    -v "$WORK/activate.sh:/activate.sh:ro" -v "$OUTV:/out" "$ACT_IMAGE" sh /activate.sh
  log "writing $(basename "$3")"
  # As root (the tree's files are the container's root's): numeric owner 0, the store's modes kept.
  docker run --rm --name "$C-tar" --platform "linux/$HOST" -v "$OUTV:/out" -v "$VOL:/nix" "$NIX_IMAGE" \
    sh -c 'cd /out/root && tar --numeric-owner --owner=0 --group=0 -cf - .' | zstd -q $ZSTD_ULTRA -"$LEVEL" $ZSTD_LONG -T0 -o "$3.unchecked"
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
  if ! why="$(bsl_nix_listing_check "$WORK/list" "$1")"; then
    mv -f "$t" "$2.rejected"; echo "ERROR: $(basename "$2"): $why" >&2; return 1
  fi
  # The store against its own database, in a container with no network (nothing fetched or signed here).
  docker run --rm --name "$C-verify" --platform "linux/$HOST" --network none -v "$OUTV:/out" -v "$VOL:/nix" "$NIX_IMAGE" \
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
  # VM_ROUTE: disk-image (nixpkgs' make-disk-image, a helper VM under /dev/kvm: this host's architecture) or tree (no
  # helper VM, round 12: the amd64 image on this arm64 host). The default is disk-image where it can run, else tree.
  VM_ROUTE="${VM_ROUTE:-}"
  if [ -z "$VM_ROUTE" ]; then
    if [ "$ARCH" = "$HOST" ] && [ -e /dev/kvm ]; then VM_ROUTE=disk-image; else VM_ROUTE=tree; fi
  fi
  case "$VM_ROUTE" in disk-image|tree) ;; *) echo "ERROR: VM_ROUTE is disk-image or tree" >&2; exit 1 ;; esac
  [ "$VM_ROUTE" = tree ] || [ -e /dev/kvm ] || { echo "ERROR: the VM image's build needs /dev/kvm (or VM_ROUTE=tree)" >&2; exit 1; }
  NAME="nixos-$(echo "$RELEASE" | sed -E 's/^nixos-([0-9]+\.[0-9]+).*/\1/')-$ARCH-vm-$STAMP"
  VOUT="$OUT_DIR/vm/$NAME"
  mkdir -p "$VOUT"
  log "building $NAME"
  docker rm -f "$C" >/dev/null 2>&1 || true
  log "route: $VM_ROUTE"
  if [ "$VM_ROUTE" = tree ]; then
    docker run --name "$C" --platform "linux/$HOST" \
      -e NIXSYS="$NIXSYS" -e RELEASE="$RELEASE" -e NIXPKGS_URL="$NIXPKGS_URL" -e NIXPKGS_SHA256="$NIXPKGS_SHA256" \
      -e STATE_VERSION="$STATE_VERSION" \
      -v "$WORK/etc-nix:/cfg/etc-nix:ro" -v "$WORK/configuration.nix:/cfg/configuration.nix:ro" \
      -v "$WORK/vmtree.sh:/vmtree.sh:ro" -v "$OUTV:/out" -v "$VOL:/nix" "$NIX_IMAGE" sh /vmtree.sh
  else
  docker run --name "$C" --platform "linux/$HOST" --device /dev/kvm \
    -e NIXSYS="$NIXSYS" -e RELEASE="$RELEASE" -e NIXPKGS_URL="$NIXPKGS_URL" -e STATE_VERSION="$STATE_VERSION" \
    -v "$WORK/etc-nix:/cfg/etc-nix:ro" -v "$WORK/configuration.nix:/cfg/configuration.nix:ro" \
    -v "$WORK/vm-image.nix:/cfg/vm-image.nix:ro" -v "$WORK/vmstep.sh:/vmstep.sh:ro" -v "$OUTV:/out" \
    -v "$VOL:/nix" "$NIX_IMAGE" sh /vmstep.sh
  fi
  docker rm -f "$C" >/dev/null
  docker run --rm --name "$C-chown" --platform "linux/$HOST" -v "$OUTV:/out" "$NIX_IMAGE" sh -c 'chown -R '"$(id -u):$(id -g)"' /out/vm'
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
  "cmdline": "console=ttyS0 8250.nr_uarts=4 panic=-1 quiet init=/nix/var/nix/profiles/system/init",
  "files": {
    "kernel": { "name": "vmlinuz", "sha256": "$(sha "$VOUT/vmlinuz")", "size": $(size "$VOUT/vmlinuz") },
    "initrd": { "name": "initrd.img", "sha256": "$(sha "$VOUT/initrd.img")", "size": $(size "$VOUT/initrd.img") },
    "root": { "name": "root.img.zst", "sha256": "$(sha "$VOUT/root.img.zst")", "size": $(size "$VOUT/root.img.zst") }
  }
}
EOF
  if [ -n "${MANIFEST_DIR:-}" ]; then
    mkdir -p "$MANIFEST_DIR/nix"
    sed "s|\"name\": \"$NAME\",|\"name\": \"$NAME\",\n  \"base\": \"vm/$NAME/\",|" "$VOUT/image.json" > "$MANIFEST_DIR/nix/manifest-vm-$ARCH.json"
    log "local manifest $MANIFEST_DIR/nix/manifest-vm-$ARCH.json"
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
    # auto keeps documentation only with HEADROOM to spare under the cache limit (round 12: an image that just fits
    # stops fitting at its next update; 25,600,000 bytes is 5% of the limit).
    if [ "$f" = desktop ] && [ "$DOCS_LANGS" = auto ] && ! why="$(BSL_CACHE_LIMIT=$((BSL_CACHE_LIMIT - HEADROOM)) bsl_nix_size_check "$T.unchecked")"; then
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
docker run --rm --name "$C-clean" --platform "linux/$HOST" -v "$OUTV:/out" "$NIX_IMAGE" sh -c 'chmod -R u+w /out/root 2>/dev/null; rm -rf /out/root' || true
log "Nothing was uploaded."
