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
