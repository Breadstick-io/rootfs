#!/usr/bin/env bash
# Tests for fedora-image-checks.sh (the size limit and the listing checks bootstrap-fedora.sh runs on every image).
#   rootfs/bootstrap/test-fedora-image-checks.sh [image.tar.zst ...]
# Sparse files stand in for images (nothing is written but their sizes). Images named on the command line are listed
# and their listing checked too, each line printed with the result (a test of what was baked, not of the functions).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fedora-image-checks.sh"
T="$(mktemp -d)"
trap 'rm -f "$T"/img "$T"/img.unchecked "$T"/list "$T"/good "$T"/out; rmdir "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# The size limit: 512,000,000 bytes, refused AT the limit.
size_case() {  # $1 = size, $2 = pass|refuse, $3 = what
  truncate -s 0 "$T/img"; truncate -s "$1" "$T/img"
  if bsl_fedora_size_check "$T/img" > "$T/out"; then got=pass; else got=refuse; fi
  if [ "$got" = "$2" ]; then ok "size $1 ($3): $got: $(cat "$T/out")"; else bad "size $1 ($3): $got, wanted $2: $(cat "$T/out")"; fi
}
[ "$BSL_CACHE_LIMIT" = 512000000 ] && ok "the limit is 512,000,000 bytes" || bad "the limit is $BSL_CACHE_LIMIT"
size_case 0 pass "empty"
size_case 511999999 pass "one byte under"
size_case 512000000 refuse "exactly the limit"
size_case 536870912 refuse "512 MiB"
size_case 502692218 pass "the 202611132012 amd64 desktop image"
size_case 510251302 pass "the 202611132049 arm64 desktop image"
size_case 546825875 refuse "the 202611132053 amd64 desktop image, with documentation and every language"
truncate -s 0 "$T/img"; mv "$T/img" "$T/img.unchecked"
out="$(bsl_fedora_size_check "$T/img.unchecked")"; mv "$T/img.unchecked" "$T/img"
case "$out" in "img is 0 bytes"*) ok "an image being checked (<name>.unchecked) is named as it will be: $out" ;; *) bad "an .unchecked image is named: $out" ;; esac
if out="$(BSL_CACHE_LIMIT=100 bsl_fedora_size_check /nonexistent 2>/dev/null)"; then bad "a missing file passes the size check"; else ok "a missing file does not pass the size check"; fi

# The listing checks, on a listing shaped like a good image's (GNU tar tvf of docker export, numeric owners).
cat > "$T/good" <<'BSL_TEST_LISTING_3f9a'
drwxr-xr-x 0/0               0 2026-11-13 20:49 ./
dr-xr-xr-x 0/0               0 2026-07-15 00:00 afs/
lrwxrwxrwx 0/0               0 2026-07-15 00:00 bin -> usr/bin
drwxr-xr-x 0/0               0 2026-11-13 20:49 etc/
-rw-r--r-- 0/0             158 2026-11-13 20:49 etc/hosts
-rw-r--r-- 0/0               0 2026-11-13 20:49 etc/machine-id
-rw-r--r-- 0/0              43 2026-11-01 01:47 etc/fstab
-rw-r--r-- 0/0              94 2026-11-01 01:47 etc/profile
drwx------ 0/0               0 2026-11-13 20:49 root/
-rw-r--r-- 0/0             575 2026-07-16 00:00 root/.bashrc
-rw-r--r-- 0/0             141 2026-07-16 00:00 root/.profile
drwxrwxrwt 0/0               0 2026-11-13 20:49 tmp/
-rwsr-xr-x 0/0          262144 2026-11-01 01:47 usr/bin/sudo
-rw-r--r-- 0/0            1074 2026-11-01 01:47 usr/share/doc/bash/.profile
drwxrwxrwt 0/0               0 2026-11-13 20:49 var/tmp/
BSL_TEST_LISTING_3f9a
if out="$(bsl_fedora_listing_check "$T/good")"; then ok "a good listing passes (a .profile below / is not KIWI's)"; else bad "a good listing is refused: $out"; fi

listing_case() {  # $1 = what, $2 = sed expression that breaks the good listing, $3 = text the refusal must have
  sed "$2" "$T/good" > "$T/list"
  if out="$(bsl_fedora_listing_check "$T/list")"; then bad "$1: passes"
  elif printf '%s\n' "$out" | grep -qF "$3"; then ok "$1: refused ($out)"
  else bad "$1: refused for another reason: $out"; fi
}
listing_case "KIWI's /.profile" '1a -rw-r--r-- 0/0            1074 2026-11-01 01:47 .profile' "KIWI's build files"
listing_case "KIWI's /.profile, ./ prefix" '1a -rw-r--r-- 0/0            1074 2026-11-01 01:47 ./.profile' "KIWI's build files"
listing_case "KIWI's /etc/fstab.script" '/etc\/fstab$/a -rwxr-xr-x 0/0             209 2026-11-01 01:47 etc/fstab.script' "KIWI's build files"
listing_case "KIWI's /.kconfig" '1a -rw-r--r-- 0/0             300 2026-11-01 01:47 .kconfig' "KIWI's build files"
listing_case "sudo 4111" 's/^-rwsr-xr-x \(.*usr\/bin\/sudo\)$/---s--x--x \1/' "sudo is not 4755"
listing_case "/root 0550" 's/^drwx------ \(.* root\/\)$/dr-xr-x--- \1/' "/root is not 0700"
listing_case "Docker's /.dockerenv" '1a -rwxr-xr-x 0/0               0 2026-11-13 20:49 .dockerenv' "Docker's files"
listing_case "an empty /etc/hosts" 's/^\(-rw-r--r-- 0\/0  *\)158\( .*etc\/hosts\)$/\10\2/' "/etc/hosts is not"
listing_case "a machine-id" 's/^\(-rw-r--r-- 0\/0  *\)0\( .*etc\/machine-id\)$/\133\2/' "machine-id is not empty"
listing_case "a random seed" '$a -rw------- 0/0             512 2026-11-13 20:49 var/lib/systemd/random-seed' "random seed"
listing_case "a file in /tmp" '/^drwxrwxrwt.* tmp\/$/a -rw-r--r-- 0/0               5 2026-11-13 20:49 tmp/x' "/tmp or /var/tmp"

# Images named on the command line: their real listings.
for img in "$@"; do
  zstd -dc "$img" | tar tvf - > "$T/list" 2>/dev/null || { bad "$(basename "$img"): does not list"; continue; }
  if out="$(bsl_fedora_listing_check "$T/list")"; then echo "     $(basename "$img"): listing passes"
  else echo "     $(basename "$img"): listing refused: $(printf '%s' "$out" | paste -sd ';' -)"; fi
  if out="$(bsl_fedora_size_check "$img")"; then echo "     $out"; else echo "     REFUSED: $out"; fi
done

echo "$fails failed"
[ "$fails" -eq 0 ]
