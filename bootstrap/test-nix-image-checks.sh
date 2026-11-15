#!/bin/sh
# nix-image-checks.sh against made-up `tar tvf` listings: a good image passes, each defect is caught. No Docker.
#   rootfs/bootstrap/test-nix-image-checks.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/nix-image-checks.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0
good() {
  for f in ./nix/var/nix/db/db.sqlite ./etc/NIXOS ./etc/breadstick/nix/system.nix ./etc/breadstick/nix/local.json \
           ./etc/breadstick/nix/packages.json ./etc/breadstick/nix/module/module.nix ./etc/breadstick/nix/src/VERSION \
           ./etc/nixos/configuration.nix; do
    echo "-rw-r--r-- 0/0 12 2026-11-15 09:00 $f"
  done
  echo "-rw-r--r-- 0/0 0 2026-11-15 09:00 ./etc/machine-id"
  echo "drwxr-xr-x 0/0 0 2026-11-15 09:00 ./run/"
  for l in ./nix/var/nix/profiles/system ./bin/sh ./bin/bash ./etc/os-release ./etc/breadstick/nix/nixpkgs \
           ./nix/var/nix/gcroots/breadstick-nixpkgs; do
    echo "lrwxrwxrwx 0/0 0 2026-11-15 09:00 $l -> /nix/store/x"
  done
}
expect() {  # $1 = pass|fail, $2 = name, stdin = the listing
  cat > "$W/l"
  if bsl_nix_listing_check "$W/l" > "$W/o"; then r=pass; else r=fail; fi
  if [ "$r" = "$1" ]; then echo "ok $2"; else echo "FAIL $2 ($(cat "$W/o"))"; fails=$((fails + 1)); fi
}
good | expect pass "a good image"
good | grep -v ' ./etc/NIXOS$' | expect fail "no /etc/NIXOS"
good | grep -v 'profiles/system ->' | expect fail "no system profile"
good | sed 's|0 2026-11-15 09:00 ./etc/machine-id|33 2026-11-15 09:00 ./etc/machine-id|' | expect fail "a machine id in the image"
{ good; echo "srw-rw-rw- 0/0 0 2026-11-15 09:00 ./run/dbus/system_bus_socket"; } | expect fail "something in /run"
{ good; echo "hrw-r--r-- 0/0 0 2026-11-15 09:00 ./a link to ./b"; } | expect fail "a hard link"
{ good; echo "lrwxrwxrwx 0/0 0 2026-11-15 09:00 ./nix/var/nix/gcroots/auto/abc -> /tmp/x"; } | expect fail "the build's gcroot"
head -c 1000 /dev/zero > "$W/small"
if bsl_nix_size_check "$W/small" >/dev/null; then echo "ok size: small"; else echo "FAIL size: small"; fails=$((fails + 1)); fi
BSL_CACHE_LIMIT=999 bsl_nix_size_check "$W/small" >/dev/null && { echo "FAIL size: over"; fails=$((fails + 1)); } || echo "ok size: over the limit"
echo "fails: $fails"
exit $fails
