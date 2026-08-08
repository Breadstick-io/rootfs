#!/bin/sh
# Build the DESKTOP-BAKED rootfs image: the base system plus the entire Breadstick
# desktop stack pre-installed and pre-configured, so first-run desktop setup becomes
# download + extract instead of a 250-package apt run under proot.
#
# The bake runs the SAME provision.sh the app ships, inside mmdebstrap's real chroot —
# where maintainer scripts configure more reliably than under proot. The proot runtime
# shims (systemctl/setpriv/... in /usr/local/bin) are installed by provision.sh, so the
# baked image behaves identically to a runtime-provisioned one, marker file included.
#
# Usage: [SUITE=trixie] bootstrap/bake-desktop.sh
#   -> rootfs/dist/debian-<suite>-arm64-desktop.tar.zst
set -eu

log() { printf '\033[1;34m[bake]\033[0m %s\n' "$*"; }

HOOKDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HOOKDIR/.." && pwd)"
SUITE="${SUITE:-trixie}"
ARCH=arm64
# HTTPS by default. Package integrity already comes from the archive signature, but over
# cleartext an observer still learns exactly which packages a device installs. The image
# ships ca-certificates (see INCLUDE), so apt inside the guest can use it too.
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
OUT_DIR="$ROOT/dist"
TARBALL="$OUT_DIR/debian-${SUITE}-${ARCH}-desktop.tar.zst"
PROVISION="$ROOT/../Android/app/src/main/assets/desktop/provision.sh"
[ -f "$PROVISION" ] || { echo "ERROR: $PROVISION not found" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# Stage the archive keyring under /tmp: paths under $HOME become unreadable inside the
# unshare user namespace, so gpgv fails with NO_PUBKEY (same trap bootstrap-debian.sh
# documents). Prefer the host keyring; fall back to the repo-cached extraction.
STAGE="${TMPDIR:-/tmp}/breadstick-keyring"
mkdir -p "$STAGE"
KEYRING="$STAGE/debian-archive-keyring.gpg"
# Both extensions: the keyring package has shipped .gpg historically and .pgp in newer
# versions, and which one the cache holds depends on when it was extracted. Checking only
# .pgp made this script fail with "run bootstrap-debian.sh once first" on a workspace that
# had already been bootstrapped — the cached keyring was right there under the other name.
for src in /usr/share/keyrings/debian-archive-keyring.gpg \
           /etc/apt/trusted.gpg.d/debian-archive-keyring.gpg \
           "$OUT_DIR/.keyring/usr/share/keyrings/debian-archive-keyring.gpg" \
           "$OUT_DIR/.keyring/usr/share/keyrings/debian-archive-keyring.pgp"; do
    if [ -s "$src" ]; then cat "$src" > "$KEYRING"; break; fi
done
[ -s "$KEYRING" ] || { echo "ERROR: no keyring found — run bootstrap-debian.sh once first" >&2; exit 1; }

INCLUDE="ca-certificates,locales,apt-utils,gnupg,sudo,passwd,ncurses-term,nano,less,procps,openssh-client"

log "Baking ${SUITE}/${ARCH} desktop image -> $TARBALL"
mmdebstrap \
    --mode=unshare \
    --arch="$ARCH" \
    --variant=minbase \
    --components=main \
    --include="$INCLUDE" \
    --keyring="$KEYRING" \
    --customize-hook="copy-in '$HOOKDIR/breadstick-archive-keyring.gpg' /usr/share/keyrings" \
    --customize-hook="copy-in '$HOOKDIR/breadstick.sources' /etc/apt/sources.list.d" \
    --customize-hook="copy-in '$PROVISION' /root" \
    --customize-hook='chroot "$1" sh /root/provision.sh' \
    --customize-hook='chroot "$1" rm -f /root/provision.sh' \
    "$SUITE" "$TARBALL" "$MIRROR"

log "Verifying the bake marker + desktop stack in the image..."
zstd -dc "$TARBALL" | tar tf - | grep -qE '\./etc/breadstick/desktop-ok' || {
    echo "ERROR: desktop-ok marker missing — provision did not complete" >&2; exit 1; }
zstd -dc "$TARBALL" | tar tf - | grep -qE '\./usr/bin/openbox' || {
    echo "ERROR: openbox missing from the baked image" >&2; exit 1; }
log "Artifact: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
