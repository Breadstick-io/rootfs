# rootfs/

Scripts to build/provision the Debian (bookworm) `arm64` root filesystem that
runs inside `proot`.

- `bootstrap/bootstrap-debian.sh` — reference bootstrap (Phase 1, WIP). Documents
  the intended flow; not yet wired into the app or hardened for on-device use.
- `dist/` — generated rootfs tarballs (git-ignored; never committed — large).

## Two ways to get a base rootfs

1. **Host-built (recommended on this aarch64 box):** `mmdebstrap`/`debootstrap`
   builds a clean Debian arm64 base *natively* — no QEMU needed because the host
   is already `aarch64`. Reproducible and minimal.
2. **Prebuilt tarball:** fetch a vetted Debian arm64 rootfs and verify its
   checksum. Fastest to iterate with.

## Provisioning GNOME
After the base is in place, GNOME + audio + a default app set are installed with
`apt` inside `proot` (Phase 3). This can run on first launch or be pre-baked into
a larger shipped image — a size-vs-convenience tradeoff we'll settle during Phase 3.

## Breadstick-RPM images (4.0, local only)

`bootstrap/bootstrap-fedora.sh [base|desktop|both]` bakes Breadstick-RPM, a Fedora Remix (plan
`Android/docs/4.0/multi-distro.md` 5.4 and 5.11), from Fedora's official container image (`RELEASE`, default 45;
`ARCH` arm64 natively or amd64 under qemu-user 10) into `dist/fedora-<release>-<arch>[-desktop]-<stamp>.tar.zst`:
breadstick-release swapped in for every `fedora-release*` package and `fedora-logos` (one transaction, signatures
checked against `bootstrap/RPM-GPG-KEY-breadstick`), `dnf upgrade --refresh`, the base set, and for the desktop
breadstick-desktop, Chromium through install-browser.sh and the desktop-ok marker; sudo 4755 and /root 0700. The
bake container has the network and never the gpg-agent socket. Each image is checked after it is written (its
listing, then the image run in Docker with no network). Nothing uploads anything.

Until rpm.breadstick.io serves packages, `RPM_STAGE=` (a stage from Apt's `rpm/stage-rpm-repo.sh`) is required in
practice: its images name the stage as their repository and are called `fedora-...-staged-<stamp>.tar.zst`, never to
be published. `MANIFEST_DIR=` writes local `manifest-fedora-<arch>[-desktop].json` files (the names the 4.0 app reads) beside nothing a device
reads (refused under AutoBuild/dist or a mirror).
