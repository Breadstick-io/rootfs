#!/usr/bin/env bash
#
# bootstrap-debian.sh — build the Breadstick Debian base rootfs (arm64) with mmdebstrap.
#
# Produces a compressed tarball under rootfs/dist/ that the app ships and extracts
# under proot on-device. GNOME and the rest are layered on later (provisioning,
# Phase 3). Runs fully unprivileged:
#   * build mode: tries user-namespace (unshare), falls back to fakeroot
#     (needed on Ubuntu 24.04, where AppArmor restricts unprivileged userns);
#   * keyring: uses the host's Debian archive keyring if present, otherwise
#     fetches it over HTTPS — so this works on an Ubuntu host with no root.
#
# Usage:
#   rootfs/bootstrap/bootstrap-debian.sh [output-tarball]
# Env overrides: SUITE, ARCH, MIRROR, INCLUDE, OUT_DIR
#
set -euo pipefail

SUITE="${SUITE:-bookworm}"
ARCH="${ARCH:-arm64}"
# HTTPS by default. Package integrity already comes from the archive signature, but over
# cleartext an observer still learns exactly which packages a device installs. The image
# ships ca-certificates (see INCLUDE), so apt inside the guest can use it too.
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
# Minimal-but-usable base; the desktop (GNOME) is added in the provisioning step.
# sudo + passwd for user accounts; ncurses-term for proper xterm-256color terminfo;
# a few QoL CLI tools so the terminal is usable out of the box.
# tmux: the terminal attaches to a persistent session so shells survive the app being killed.
INCLUDE="${INCLUDE:-ca-certificates,locales,apt-utils,gnupg,sudo,passwd,ncurses-term,nano,less,procps,openssh-client,tmux}"

# Anchor the output dir to THIS script's location (rootfs/dist), not the caller's CWD —
# running from inside rootfs/ used to produce a doubled rootfs/rootfs/dist path.
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/dist}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"   # absolute: unshare mode re-execs, so relative paths break
NAME="debian-${SUITE}-${ARCH}"
if command -v zstd >/dev/null 2>&1; then EXT="tar.zst"; else EXT="tar.gz"; fi
TARBALL="${1:-$OUT_DIR/$NAME.$EXT}"

KEYRING=""

log() { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }

# Provide the Debian archive keyring at a path that stays readable inside the
# unshare (user-namespace) mount. Paths deep under $HOME become unreadable once
# uids are remapped, so apt/gpgv there fails with NO_PUBKEY — hence we STAGE the
# keyring under $TMPDIR for the mmdebstrap call. The download stays cached in-repo.
ensure_keyring() {
    local stage="${TMPDIR:-/tmp}/breadstick-keyring"
    mkdir -p "$stage"
    KEYRING="$stage/debian-archive-keyring.gpg"

    # 1) Host keyring, if installed.
    local h
    for h in /usr/share/keyrings/debian-archive-keyring.gpg \
             /etc/apt/trusted.gpg.d/debian-archive-keyring.gpg; do
        if [ -e "$h" ]; then cat "$h" > "$KEYRING"; log "Using host keyring: $h"; return 0; fi
    done

    # 2) Previously fetched + extracted in the repo cache.
    local kdir="$OUT_DIR/.keyring"
    local cached="$kdir/usr/share/keyrings/debian-archive-keyring.pgp"
    if [ -s "$cached" ]; then
        cat "$cached" > "$KEYRING"; log "Using cached keyring -> $KEYRING"; return 0
    fi

    # 3) Fetch the keyring package over HTTPS (no root needed). Pinned to the bookworm
    # version + its sha256 (cross-checked against the signed bookworm Packages index) so a
    # compromised/MITM'd mirror can't hand us a malicious trust root. If the pin goes stale
    # (404 or hash mismatch), verify the new .deb out-of-band and update both lines.
    mkdir -p "$kdir"
    local base="https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/"
    local deb="debian-archive-keyring_2023.3+deb12u2_all.deb"
    local sha="f699e2f88dca05212f2a452b58475f2993cb6993dfbafb1d0205a3291eb8b4b8"
    log "Debian keyring not on host; fetching $deb over HTTPS (no root needed)…"
    curl -fsSL "${base}${deb}" -o "$kdir/dak.deb"
    echo "$sha  $kdir/dak.deb" | sha256sum -c --quiet - \
        || { echo "ERROR: $deb sha256 mismatch — refusing untrusted keyring" >&2; return 1; }
    dpkg-deb --fsys-tarfile "$kdir/dak.deb" | tar -C "$kdir" -x
    # The aggregate .gpg is a symlink to the new-format .pgp; cat dereferences it.
    local src="$kdir/usr/share/keyrings/debian-archive-keyring.gpg"
    [ -e "$src" ] || src="$kdir/usr/share/keyrings/debian-archive-keyring.pgp"
    [ -e "$src" ] || { echo "ERROR: keyring not found inside $deb" >&2; return 1; }
    cat "$src" > "$KEYRING"
    [ -s "$KEYRING" ] || { echo "ERROR: keyring staging failed" >&2; return 1; }
    log "Fetched keyring ($deb), staged at $KEYRING"
}

pick_modes() {
    if [ "$(id -u)" = 0 ]; then echo "root"; else echo "unshare fakeroot"; fi
}

build() {
    mkdir -p "$OUT_DIR"
    local built=0 m
    # Bake the Breadstick apt repo into the base so the rootfs ships pre-configured to pull
    # custom packages from apt.breadstick.io (the app also ensures this at runtime).
    local hookdir; hookdir="$(cd "$(dirname "$0")" && pwd)"
    for m in $(pick_modes); do
        log "Building ${SUITE}/${ARCH} base via mmdebstrap (mode=${m}) -> ${TARBALL}"
        if mmdebstrap \
                --mode="$m" \
                --arch="$ARCH" \
                --variant=minbase \
                --components=main \
                --include="$INCLUDE" \
                --keyring="$KEYRING" \
                --customize-hook="copy-in '$hookdir/breadstick-archive-keyring.gpg' /usr/share/keyrings" \
                --customize-hook="copy-in '$hookdir/breadstick.sources' /etc/apt/sources.list.d" \
                "$SUITE" "$TARBALL" "$MIRROR"; then
            built=1
            log "Base built successfully with mode=${m}"
            break
        fi
        log "mode=${m} failed; cleaning up and trying the next mode"
        rm -f "$TARBALL"
    done
    [ "$built" = 1 ] || { echo "ERROR: all mmdebstrap modes failed" >&2; exit 1; }
}

main() {
    ensure_keyring
    build
    log "Artifact: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
    log "Sample contents:"
    tar tf "$TARBALL" 2>/dev/null | head -n 8 || true
    log "Next: extract under proot and provision GNOME (Phase 3) — see docs/ROADMAP.md"
}

main "$@"
