#!/usr/bin/env bash
# Tests for arch-image-checks.sh (the size limit, the listing and the pacman configuration checks bootstrap-arch.sh
# runs on every image of the Arch based system).
#   rootfs/bootstrap/test-arch-image-checks.sh [image.tar.zst ...]
# Sparse files stand in for images (nothing is written but their sizes). Images named on the command line are listed
# and checked too, each result printed (a test of what was baked, not of the functions).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/arch-image-checks.sh"
T="$(mktemp -d)"
trap 'rm -f "$T"/img "$T"/img.unchecked "$T"/list "$T"/good "$T"/out "$T"/pc "$T"/pc.good "$T"/ml "$T"/ml.good; rmdir "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# The size limit: 512,000,000 bytes, refused AT the limit.
size_case() {  # $1 = size, $2 = pass|refuse, $3 = what
  truncate -s 0 "$T/img"; truncate -s "$1" "$T/img"
  if bsl_arch_size_check "$T/img" > "$T/out"; then got=pass; else got=refuse; fi
  if [ "$got" = "$2" ]; then ok "size $1 ($3): $got: $(cat "$T/out")"; else bad "size $1 ($3): $got, wanted $2: $(cat "$T/out")"; fi
}
[ "$BSL_CACHE_LIMIT" = 512000000 ] && ok "the limit is 512,000,000 bytes" || bad "the limit is $BSL_CACHE_LIMIT"
size_case 0 pass "empty"
size_case 511999999 pass "one byte under"
size_case 512000000 refuse "exactly the limit"
size_case 536870912 refuse "512 MiB"
truncate -s 0 "$T/img"; mv "$T/img" "$T/img.unchecked"
out="$(bsl_arch_size_check "$T/img.unchecked")"; mv "$T/img.unchecked" "$T/img"
case "$out" in "img is 0 bytes"*) ok "an image being checked (<name>.unchecked) is named as it will be: $out" ;; *) bad "an .unchecked image is named: $out" ;; esac
if bsl_arch_size_check /nonexistent >/dev/null 2>&1; then bad "a missing file passes the size check"; else ok "a missing file does not pass the size check"; fi

# The listing checks, on a listing shaped like a good image's (GNU tar tvf of the bake's export, numeric owners).
cat > "$T/good" <<'BSL_TEST_ARCH_LISTING_5e1b'
drwxr-xr-x 0/0               0 2026-11-14 03:10 ./
lrwxrwxrwx 0/0               0 2025-10-12 12:21 ./bin -> usr/bin
drwxr-xr-x 0/0               0 2026-11-14 03:10 ./dev/
drwxr-xr-x 0/0               0 2026-11-14 03:10 ./etc/
-rw-r--r-- 0/0             119 2025-10-12 12:21 ./etc/hosts
-rw-r--r-- 0/0              65 2025-10-12 12:21 ./etc/resolv.conf
lrwxrwxrwx 0/0               0 2025-10-12 12:21 ./etc/mtab -> ../proc/self/mounts
lrwxrwxrwx 0/0               0 2026-11-01 03:45 ./etc/os-release -> ../usr/lib/os-release
-rw-r--r-- 0/0            3100 2026-11-14 03:10 ./etc/pacman.conf
drwxr-xr-x 0/0               0 2026-11-14 03:10 ./etc/pacman.d/gnupg/
-rw-r--r-- 0/0         1373030 2026-11-14 03:10 ./etc/pacman.d/gnupg/pubring.gpg
drwx------ 0/0               0 2026-11-14 03:10 ./etc/pacman.d/gnupg/private-keys-v1.d/
drwx------ 0/0               0 2026-11-14 03:10 ./etc/pacman.d/gnupg/openpgp-revocs.d/
drwxr-x--- 0/0               0 2026-11-14 03:10 ./root/
drwxr-xr-x 0/0               0 2026-11-14 03:10 ./run/
drwxrwxrwt 0/0               0 2026-11-14 03:10 ./tmp/
-rwsr-xr-x 0/0          140512 2026-11-01 03:45 ./usr/bin/sudo
-rwxr-xr-x 0/0           64424 2026-11-01 03:45 ./usr/bin/perl
hrwxr-xr-x 0/0               0 2026-11-01 03:45 ./usr/bin/perl5.42.0 link to ./usr/bin/perl
-rw-r--r-- 0/0          100000 2026-09-27 12:35 ./usr/share/i18n/SUPPORTED
-rw-r--r-- 0/0           41000 2026-09-27 12:35 ./usr/share/locale/de/LC_MESSAGES/coreutils.mo
drwxr-xr-x 0/0               0 2026-11-14 03:10 ./var/cache/pacman/pkg/
drwxr-xr-x 0/0               0 2026-11-14 03:10 ./var/lib/pacman/sync/
drwxrwxrwt 0/0               0 2026-11-14 03:10 ./var/tmp/
BSL_TEST_ARCH_LISTING_5e1b
if out="$(bsl_arch_listing_check "$T/good")"; then ok "a good listing passes"; else bad "a good listing is refused: $out"; fi

listing_case() {  # $1 = what, $2 = sed expression that breaks the good listing, $3 = text the refusal must have
  sed "$2" "$T/good" > "$T/list"
  if out="$(bsl_arch_listing_check "$T/list")"; then bad "$1: passes"
  elif printf '%s\n' "$out" | grep -qF "$3"; then ok "$1: refused ($(printf '%s' "$out" | paste -sd ';' -))"
  else bad "$1: refused for another reason: $out"; fi
}
listing_case "names without ./ (docker export's)" 's| \./usr/bin/perl$| usr/bin/perl|' "does not start with ./"
listing_case "the top folder at 0555 (the bootstrap's)" '1s/^drwxr-xr-x/dr-xr-xr-x/' "top folder is not ./ at 0755"
listing_case "sudo 0755 (setuid lost)" 's/^-rwsr-xr-x \(.*usr\/bin\/sudo\)$/-rwxr-xr-x \1/' "sudo is not 4755"
listing_case "/root 0700 (not Arch's)" 's/^drwxr-x--- \(.* \.\/root\/\)$/drwx------ \1/' "/root is not 0750"
listing_case "/run 0555 (the bootstrap's)" 's/^drwxr-xr-x \(.* \.\/run\/\)$/dr-xr-xr-x \1/' "/run is not 0755"
listing_case "Docker's /.dockerenv" '1a -rwxr-xr-x 0/0               0 2026-11-14 03:10 ./.dockerenv' "Docker's or the bake's own files"
listing_case "Docker's /etc/hostname" '/etc\/hosts$/a -rwxr-xr-x 0/0               0 2026-11-14 03:10 ./etc/hostname' "Docker's or the bake's own files"
listing_case "the bake's /etc/hosts.bsl-orig" '/etc\/hosts$/a -rw-r--r-- 0/0             119 2026-11-14 03:10 ./etc/hosts.bsl-orig' "Docker's or the bake's own files"
listing_case "the stage's mount point" '1a drwxr-xr-x 0/0               0 2026-11-14 03:10 ./bsl-stage/' "Docker's or the bake's own files"
listing_case "an empty /etc/hosts (docker export's)" 's/^\(-rw-r--r-- 0\/0  *\)119\( .*etc\/hosts\)$/\10\2/' "/etc/hosts is not"
listing_case "an empty /etc/resolv.conf" 's/^\(-rw-r--r-- 0\/0  *\)65\( .*etc\/resolv\.conf\)$/\10\2/' "/etc/resolv.conf is not"
listing_case "systemd's empty 0444 machine-id (the Linux user cannot write it)" '/etc\/hosts$/a -r--r--r-- 0/0               0 2026-11-14 03:10 ./etc/machine-id' "has an /etc/machine-id"
listing_case "an empty 0644 machine-id (Debian's and Fedora's state, which works there; this image ships none)" '/etc\/hosts$/a -rw-r--r-- 0/0               0 2026-11-14 03:10 ./etc/machine-id' "has an /etc/machine-id"
listing_case "a machine-id of the bake's own" '/etc\/hosts$/a -r--r--r-- 0/0              33 2026-11-14 03:10 ./etc/machine-id' "has an /etc/machine-id"
listing_case "a machine-id link" '/etc\/hosts$/a lrwxrwxrwx 0/0               0 2026-11-14 03:10 ./etc/machine-id -> /run/machine-id' "has an /etc/machine-id"
listing_case "/etc 0555 (its owner cannot make the machine-id)" 's/^drwxr-xr-x \(.* \.\/etc\/\)$/dr-xr-xr-x \1/' "/etc is not 0755"
sed '$a lrwxrwxrwx 0/0               0 2026-11-01 03:45 ./var/lib/dbus/machine-id -> /etc/machine-id' "$T/good" > "$T/list"
if out="$(bsl_arch_listing_check "$T/list")"; then ok "dbus's tmpfiles link /var/lib/dbus/machine-id -> /etc/machine-id passes (the session's root part replaces it with a file)"
else bad "dbus's /var/lib/dbus/machine-id link is refused: $out"; fi
listing_case "Docker's /etc/mtab (-> /proc/mounts)" 's| \./etc/mtab -> \.\./proc/self/mounts$| ./etc/mtab -> /proc/mounts|' "/etc/mtab is not"
listing_case "the bake's /etc/mtab.bsl-orig" '/etc\/hosts$/a -rw-r--r-- 0/0              30 2026-11-14 03:10 ./etc/mtab.bsl-orig' "Docker's or the bake's own files"
listing_case "a random seed" '$a -rw------- 0/0             512 2026-11-14 03:10 ./var/lib/systemd/random-seed' "random seed"
listing_case "SSH host keys" '$a -rw------- 0/0             411 2026-11-14 03:10 ./etc/ssh/ssh_host_ed25519_key' "SSH host keys"
listing_case "the keyring's secret key" '/private-keys-v1.d\/$/a -rw------- 0/0             321 2026-11-14 03:10 ./etc/pacman.d/gnupg/private-keys-v1.d/0A1B2C.key' "secret key"
listing_case "a revocation certificate" '/openpgp-revocs.d\/$/a -rw------- 0/0            1234 2026-11-14 03:10 ./etc/pacman.d/gnupg/openpgp-revocs.d/0A1B2C.rev' "revocation"
listing_case "gpg-agent's socket" '/pubring.gpg$/a srwx------ 0/0               0 2026-11-14 03:10 ./etc/pacman.d/gnupg/S.gpg-agent' "sockets"
listing_case "no keyring" '/pubring.gpg$/d' "keyring is missing"
listing_case "a sync database" '/var\/lib\/pacman\/sync\/$/a -rw-r--r-- 0/0         8000000 2026-11-14 03:10 ./var/lib/pacman/sync/extra.db' "sync databases"
listing_case "a cached package" '/var\/cache\/pacman\/pkg\/$/a -rw-r--r-- 0/0         8000000 2026-11-14 03:10 ./var/cache/pacman/pkg/bash-5.3-1-x86_64.pkg.tar.zst' "package cache"
listing_case "pacman's lock" '$a -rw-r--r-- 0/0               0 2026-11-14 03:10 ./var/lib/pacman/db.lck' "lock file"
listing_case "a file in /tmp" '/^drwxrwxrwt.* \.\/tmp\/$/a -rw-r--r-- 0/0               5 2026-11-14 03:10 ./tmp/x' "/tmp or /var/tmp"
listing_case "yay" '$a -rwxr-xr-x 0/0         9000000 2026-11-14 03:10 ./usr/bin/yay' "AUR helper"
listing_case "paru in /usr/local/bin" '$a -rwxr-xr-x 0/0         9000000 2026-11-14 03:10 ./usr/local/bin/paru' "AUR helper"
listing_case "hard links written as copies" '/^h/d' "no hard links"
listing_case "no locale list (NoExtract's work)" '/i18n\/SUPPORTED$/d' "SUPPORTED"
listing_case "no translations (NoExtract's work)" '/LC_MESSAGES/d' "translations"

# The pacman configuration as the bake writes it.
cat > "$T/pc.good" <<'BSL_TEST_ARCH_PACCONF_5e1b'
#
# /etc/pacman.conf
#
[options]
# Breadstick Linux (the image bake): no download sandbox under proot.
DisableSandbox
#RootDir     = /
HoldPkg     = pacman glibc
Architecture = auto
#DownloadUser = alpm
CheckSpace
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

#[core-testing]
#Include = /etc/pacman.d/mirrorlist

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

#[multilib]
#Include = /etc/pacman.d/mirrorlist

# An example of a custom package repository.  See the pacman manpage for
# tips on creating your own repositories.
#[custom]
#SigLevel = Optional TrustAll
#Server = file:///home/custompkgs

# Breadstick Linux: Breadstick's own packages, after every Arch repository.
[breadstick]
SigLevel = Required DatabaseRequired
Server = https://pacman.breadstick.io/$repo/os/$arch
BSL_TEST_ARCH_PACCONF_5e1b
cat > "$T/ml.good" <<'BSL_TEST_ARCH_MIRRORS_5e1b'
## Breadstick Linux: Arch's own mirrors, then tier 1 mirrors
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
BSL_TEST_ARCH_MIRRORS_5e1b
if out="$(bsl_arch_pacman_conf_check "$T/pc.good" "$T/ml.good")"; then ok "the bake's pacman.conf passes (Arch's commented file:// example is not a URL in use)"
else bad "the bake's pacman.conf is refused: $out"; fi
awk '/^#\[core-testing\]$/ { print "[core-testing]"; getline; sub(/^#/, ""); print; next } { print }' "$T/pc.good" > "$T/pc"
if out="$(bsl_arch_pacman_conf_check "$T/pc" "$T/ml.good")"; then bad "core-testing on: passes"; else ok "core-testing on: refused ($out)"; fi
awk '{ print } /^#\[multilib\]$/ { getline; print "[multilib]"; print "Include = /etc/pacman.d/mirrorlist"; next }' "$T/pc.good" | sed '/^#\[multilib\]$/d' > "$T/pc"
if out="$(bsl_arch_pacman_conf_check "$T/pc" "$T/ml.good")"; then ok "multilib on (the Steam card's): passes"; else bad "multilib on is refused: $out"; fi

pc_case() {  # $1 = what, $2 = sed expression on pacman.conf, $3 = text the refusal must have, [$4 = sed on the mirrorlist]
  sed "$2" "$T/pc.good" > "$T/pc"
  sed "${4:-p;d}" "$T/ml.good" > "$T/ml"
  [ -n "${4:-}" ] || cp "$T/ml.good" "$T/ml"
  if out="$(bsl_arch_pacman_conf_check "$T/pc" "$T/ml")"; then bad "$1: passes"
  elif printf '%s\n' "$out" | grep -qF "$3"; then ok "$1: refused ($(printf '%s' "$out" | paste -sd ';' -))"
  else bad "$1: refused for another reason: $out"; fi
}
pc_case "the bake's stage left in [breadstick]" 's|^Server = https://pacman.breadstick.io/\$repo/os/\$arch$|Server = file:///bsl-stage/$repo/os/$arch|' "local URL"
pc_case "the test channel's section" 's/^\[breadstick\]$/[breadstick-test]/' "test channel"
pc_case "[breadstick] first" '/^\[core\]$/i [breadstick]\nSigLevel = Required DatabaseRequired\nServer = https://pacman.breadstick.io/$repo/os/$arch\n' "sections are"
pc_case "no [breadstick]" '/^\[breadstick\]$/,$d' "sections are"
pc_case "SigLevel Optional on [breadstick]" 's/^SigLevel = Required DatabaseRequired$/SigLevel = Optional TrustAll/' "is not SigLevel = Required DatabaseRequired"
pc_case "a second Server in [breadstick]" '$a Server = http://pacman.breadstick.io/$repo/os/$arch' "is not SigLevel = Required DatabaseRequired"
pc_case "the sandbox on" '/^DisableSandbox$/d' "DisableSandbox"
pc_case "DownloadUser set" 's/^#DownloadUser = alpm$/DownloadUser = alpm/' "DownloadUser"
pc_case "NoExtract (the Docker image's)" '/^LocalFileSigLevel/a NoExtract  = usr/share/locale/* usr/share/i18n/*' "NoExtract"
pc_case "an included file" '/^\[extra\]$/a Include = /etc/pacman.d/other' "includes a file"
pc_case "a local mirror" '' "local URL" '1a Server = http://127.0.0.1:8080/$repo/os/$arch'
pc_case "a plain-http mirror" '' "is not https" '1a Server = http://mirror.example.org/archlinux/$repo/os/$arch'
pc_case "no active mirror" '' "no active https mirror" 's/^Server/#Server/'

# Images named on the command line: their real listings and pacman configuration.
for img in "$@"; do
  zstd -dc "$img" | tar tvf - > "$T/list" 2>/dev/null || { bad "$(basename "$img"): does not list"; continue; }
  if out="$(bsl_arch_listing_check "$T/list")"; then echo "     $(basename "$img"): listing passes ($(grep -c . "$T/list") entries, $(grep -c '^h' "$T/list") hard links)"
  else echo "     $(basename "$img"): listing refused: $(printf '%s' "$out" | paste -sd ';' -)"; fi
  zstd -dc "$img" | tar xOf - ./etc/pacman.conf > "$T/pc" 2>/dev/null
  zstd -dc "$img" | tar xOf - ./etc/pacman.d/mirrorlist > "$T/ml" 2>/dev/null
  if out="$(bsl_arch_pacman_conf_check "$T/pc" "$T/ml")"; then echo "     $(basename "$img"): pacman.conf and mirrorlist pass"
  else echo "     $(basename "$img"): pacman.conf refused: $(printf '%s' "$out" | paste -sd ';' -)"; fi
  if out="$(bsl_arch_size_check "$img")"; then echo "     $out"; else echo "     REFUSED: $out"; fi
done

echo "$fails failed"
[ "$fails" -eq 0 ]
