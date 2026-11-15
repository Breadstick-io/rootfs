# The checks every Breadstick-Nix image passes before it gets its name (sourced by bootstrap-nix.sh; tested by
# test-nix-image-checks.sh). POSIX sh functions; each prints why on failure and returns 1.
BSL_CACHE_LIMIT="${BSL_CACHE_LIMIT:-512000000}"

# Cloudflare caches a file only up to 512 MB (plan 5.4): an image at or over 512,000,000 bytes is refused.
bsl_nix_size_check() {  # $1 = the image file
  s=$(stat -c %s "$1") || { echo "$1: cannot read its size"; return 1; }
  if [ "$s" -ge "$BSL_CACHE_LIMIT" ]; then
    echo "$(basename "$1") is $s bytes, at or over the $BSL_CACHE_LIMIT-byte cache limit"
    return 1
  fi
  echo "$(basename "$1") is $s bytes, $((BSL_CACHE_LIMIT - s)) under the cache limit"
}

# What a device's system needs from the image, read from `tar tvf` (GNU tar's verbose listing): the Nix database,
# the system profile, NixOS's marker, Breadstick's configuration, the shell the app starts commands with, an EMPTY
# machine-id (each device makes its own), nothing in /run, and no hard link (app storage refuses them; proot's
# link2symlink would turn each into an absolute link into the app's folder). A desktop image ($2 = desktop) also has
# the desktop marker the app offers the desktop by (round 9 review: without it no session could start) and the
# profile's themes at /usr/share/themes, where the look finds them.
bsl_nix_listing_check() {  # $1 = the listing, $2 = base|desktop (desktop when not said)
  bad=0
  if [ "${2:-desktop}" = desktop ]; then
    awk '$6 == "./etc/breadstick/desktop-ok" && substr($1, 1, 1) == "-" { f = 1 } END { exit !f }' "$1" || { echo "missing ./etc/breadstick/desktop-ok"; bad=1; }
    awk '$6 == "./usr/share/themes" && substr($1, 1, 1) == "l" { f = 1 } END { exit !f }' "$1" || { echo "missing the link ./usr/share/themes"; bad=1; }
  fi
  for want in ./nix/var/nix/db/db.sqlite ./etc/NIXOS ./etc/breadstick/nix/system.nix ./etc/breadstick/nix/local.json \
              ./etc/breadstick/nix/packages.json ./etc/breadstick/nix/module/module.nix ./etc/breadstick/nix/src/VERSION \
              ./etc/nixos/configuration.nix; do
    awk -v w="$want" '$6 == w { f = 1 } END { exit !f }' "$1" || { echo "missing $want"; bad=1; }
  done
  for link in ./nix/var/nix/profiles/system ./bin/sh ./bin/bash ./etc/os-release ./etc/breadstick/nix/nixpkgs \
              ./nix/var/nix/gcroots/breadstick-nixpkgs; do
    awk -v w="$link" '$6 == w && substr($1, 1, 1) == "l" { f = 1 } END { exit !f }' "$1" || { echo "missing the link $link"; bad=1; }
  done
  awk '$6 == "./etc/machine-id" && $3 != 0 { f = 1 } END { exit !f }' "$1" && { echo "/etc/machine-id is not empty"; bad=1; }
  awk '$6 ~ /^\.\/run\/./ { f = 1 } END { exit !f }' "$1" && { echo "/run is not empty"; bad=1; }
  awk 'substr($1, 1, 1) == "h" { f = 1 } END { exit !f }' "$1" && { echo "the image holds hard links"; bad=1; }
  awk '$6 ~ /^\.\/nix\/var\/nix\/gcroots\/auto\/./ { f = 1 } END { exit !f }' "$1" && { echo "the build's gcroots are left"; bad=1; }
  return $bad
}
