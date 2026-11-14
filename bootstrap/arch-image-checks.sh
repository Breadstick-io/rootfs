# Checks on an image of the Arch based system as written (4.0, x86-64 only; plan Android/docs/4.0/multi-distro.md
# 5.12), sourced by bootstrap-arch.sh and tested by test-arch-image-checks.sh. Plain sh functions, no state: each
# prints why it refuses and returns non-zero. What needs the image running (pacman -Qkk, the keyring, the locales) is
# bootstrap-arch.sh's own check, run in the imported image with no network.

# Cloudflare caches a file only up to 512 MB (plan 5.4; AutoBuild deploy/r2/PLAN.md). Past it every download of the
# image comes from R2 uncached. Read as 512,000,000 bytes, the smaller of the two readings of "512 MB", as for the
# Fedora images (fedora-image-checks.sh). BSL_CACHE_LIMIT exists for the tests; a bake never needs to set it.
BSL_CACHE_LIMIT="${BSL_CACHE_LIMIT:-512000000}"

# The one URL the image's [breadstick] section may name (pacman.conf, plan 5.12; PacmanChannel.SERVER in the app).
BSL_PACMAN_SERVER='https://pacman.breadstick.io/$repo/os/$arch'

# $1 = image file (or <name>.unchecked). Under the limit: prints the size and returns 0. At or over it: says so and
# returns 1. A file that cannot be read returns 2.
bsl_arch_size_check() {
  _s=$(stat -Lc %s "$1" 2>/dev/null) || { echo "$1: cannot read its size"; return 2; }
  _b=$(basename "${1%.unchecked}")
  if [ "$_s" -ge "$BSL_CACHE_LIMIT" ]; then
    echo "$_b is $_s bytes, $((_s - BSL_CACHE_LIMIT)) over Cloudflare's per-file cache limit ($BSL_CACHE_LIMIT bytes): every download of it would come from R2 uncached"
    return 1
  fi
  echo "$_b is $_s bytes, $((BSL_CACHE_LIMIT - _s)) under Cloudflare's per-file cache limit ($BSL_CACHE_LIMIT bytes)"
}

# $1 = the image's listing (GNU tar tvf). Every refusal is printed; returns the number of them (0 = the listing is right).
bsl_arch_listing_check() {
  _n=0
  _bad() { echo "$1"; _n=$((_n + 1)); }
  # Entries as the Debian images name them: ./ first, numeric owners.
  grep -Eq '^drwxr-xr-x (root/root|0/0) .* \./$' "$1" || _bad "the image's top folder is not ./ at 0755"
  ! grep -Ev '^[-dlhcbps][-rwxsStT]{9} ' "$1" | grep -q . || _bad "the listing has lines that are not tar entries"
  ! grep -E '^[-dlhcbps][-rwxsStT]{9} ' "$1" | grep -Ev ' [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{5} \./' | grep -q . \
    || _bad "an entry does not start with ./"
  # Arch's own modes (plan 5.12): sudo 4755 as Arch packages it, /root 0750 as the filesystem package does.
  grep -Eq '^-rwsr-xr-x (root/root|0/0) .* \./usr/bin/sudo$' "$1" || _bad "sudo is not 4755 root in the listing"
  grep -Eq '^drwxr-x--- (root/root|0/0) .* \./root/$' "$1" || _bad "/root is not 0750 in the listing"
  grep -Eq '^drwxr-xr-x (root/root|0/0) .* \./run/$' "$1" || _bad "/run is not 0755 (the app writes /run/bsl)"
  grep -Eq '^drwxrwxrwt (root/root|0/0) .* \./tmp/$' "$1" || _bad "/tmp is not 1777"
  ! grep -Eq ' \./(\.dockerenv|bsl-stage|bsl-key|bake\.sh|check\.sh|etc/hostname|etc/[^ ]*\.bsl-orig|etc/pacman\.conf\.bsl-new)(/|$)' "$1" \
    || _bad "Docker's or the bake's own files are in the image"
  grep -Eq '^-rw-r--r-- (root/root|0/0) +[1-9][0-9]* .* \./etc/hosts$' "$1" || _bad "/etc/hosts is not the filesystem package's"
  grep -Eq '^-rw-r--r-- (root/root|0/0) +[1-9][0-9]* .* \./etc/resolv\.conf$' "$1" || _bad "/etc/resolv.conf is not the filesystem package's"
  # No machine-id, in an /etc its owner can write: the session makes the file as the Linux user (fake uid 1000 under
  # proot, which lifts permissions only for fake root), so systemd's empty 0444 file would refuse it. This is THIS
  # image's choice: Debian's images ship an empty 0644 file and Fedora's keep theirs that way, which the Linux user can
  # write too. Do not carry this refusal over to them.
  grep -Eq '^drwxr-xr-x (root/root|0/0) .* \./etc/$' "$1" || _bad "/etc is not 0755 (the session writes /etc/machine-id there as its owner)"
  ! grep -Eq ' \./etc/machine-id( -> .*)?$' "$1" || _bad "the image has an /etc/machine-id (this image ships none; the session makes one per device, as the Linux user)"
  grep -Eq '^lrwxrwxrwx (root/root|0/0) .* \./etc/mtab -> \.\./proc/self/mounts$' "$1" || _bad "/etc/mtab is not the filesystem package's link (../proc/self/mounts)"
  ! grep -Eq ' \./(var/lib/systemd/random-seed|var/lib/systemd/credential\.secret|etc/ssh/ssh_host_[^ ]*)$' "$1" \
    || _bad "the image carries a random seed, a credential secret or SSH host keys of the bake's own"
  # pacman's keyring without its master key's secret half: every device made from the image would share it, and anyone
  # with the image could certify a key every such device trusts (Arch's own Docker image removes it the same way).
  ! grep -Eq ' \./etc/pacman\.d/gnupg/(private-keys-v1\.d|openpgp-revocs\.d)/[^ ]+$' "$1" \
    || _bad "pacman's keyring carries a secret key or a revocation certificate"
  ! grep -Eq ' \./etc/pacman\.d/gnupg/S\.[^ ]*$' "$1" || _bad "pacman's keyring folder has gpg-agent sockets"
  grep -Eq ' \./etc/pacman\.d/gnupg/pubring\.gpg$' "$1" || _bad "pacman's keyring is missing"
  ! grep -Eq ' \./var/lib/pacman/sync/[^ ]+$' "$1" || _bad "the image carries sync databases (they go stale; Updates syncs)"
  ! grep -Eq ' \./var/cache/pacman/pkg/[^ ]+$' "$1" || _bad "pacman's package cache is not empty"
  ! grep -Eq ' \./var/lib/pacman/db\.lck$' "$1" || _bad "pacman's lock file is in the image"
  ! grep -Eq ' \./(var/)?tmp/[^ ]+' "$1" || _bad "/tmp or /var/tmp is not empty in the listing"
  # No AUR helper (section 10, item 7: the AUR stays out of 4.0).
  ! grep -Eq ' \./usr/(local/)?bin/(yay|paru|pikaur|trizen|aurman|pacaur|aura|pakku|aurutils|aur)$' "$1" \
    || _bad "an AUR helper is in the image"
  # Hard links kept as hard links, as in the Debian images (the app makes them again when it unpacks).
  grep -Eq '^h.* \./[^ ]+ link to \./' "$1" || _bad "the image has no hard links (they were not kept)"
  grep -Eq ' \./usr/share/i18n/SUPPORTED$' "$1" || _bad "the locale list (/usr/share/i18n/SUPPORTED) is not in the image"
  grep -Eq ' \./usr/share/locale/de/LC_MESSAGES/[^ ]+\.mo$' "$1" || _bad "translations under /usr/share/locale are not in the image"
  return "$_n"
}

# $1 = the image's /etc/pacman.conf (a file), $2 = the image's /etc/pacman.d/mirrorlist. A text check, with no pacman:
# what the bake writes (plan 5.12) and nothing of the bake's own stage. Every refusal printed; returns their number.
bsl_arch_pacman_conf_check() {
  _n=0
  _bad() { echo "$1"; _n=$((_n + 1)); }
  # Active section headers, in order.
  _secs=$(sed -n 's/^[[:space:]]*\[\([^]]*\)\][[:space:]]*$/\1/p' "$1" | tr '\n' ' ')
  case "$_secs" in
    "options core extra breadstick "|"options core extra multilib breadstick ") ;;
    *) _bad "pacman.conf's sections are \"$_secs\", not options, core, extra (multilib) and then breadstick" ;;
  esac
  grep -Eq '^[[:space:]]*\[breadstick-test\]' "$1" && _bad "pacman.conf names the test channel [breadstick-test]"
  # The [breadstick] section: exactly the SigLevel and the one Server.
  _blk=$(awk '/^[[:space:]]*\[/ { inb = ($0 ~ /^[[:space:]]*\[breadstick\][[:space:]]*$/); next } inb && !/^[[:space:]]*(#|$)/ { print }' "$1")
  [ "$_blk" = "SigLevel = Required DatabaseRequired
Server = $BSL_PACMAN_SERVER" ] || _bad "[breadstick] is not SigLevel = Required DatabaseRequired and Server = $BSL_PACMAN_SERVER: $(printf '%s' "$_blk" | tr '\n' ';')"
  # Active lines only: Arch's own pacman.conf carries a commented-out example, #Server = file:///home/custompkgs.
  grep -hEv '^[[:space:]]*#' "$1" "$2" | grep -Eqi 'file://|bsl-stage|127\.0\.0\.1|localhost' \
    && _bad "pacman.conf or the mirrorlist names a local URL (the bake's stage)"
  awk '/^[[:space:]]*\[/ { o = ($0 ~ /^[[:space:]]*\[options\]/); next } o && /^[[:space:]]*DisableSandbox[[:space:]]*$/ { f = 1 } END { exit !f }' "$1" \
    || _bad "pacman.conf does not set DisableSandbox in [options]"
  grep -Eq '^[[:space:]]*DownloadUser[[:space:]]*=' "$1" && _bad "pacman.conf sets DownloadUser"
  grep -Eq '^[[:space:]]*NoExtract[[:space:]]*=' "$1" && _bad "pacman.conf has NoExtract rules (Breadstick runs in 35 languages: no locale or manual may be dropped)"
  grep -E '^[[:space:]]*Include[[:space:]]*=' "$1" | grep -Evq '=[[:space:]]*/etc/pacman\.d/mirrorlist[[:space:]]*$' \
    && _bad "pacman.conf includes a file other than the mirrorlist"
  grep -Eq '^[[:space:]]*Server[[:space:]]*=[[:space:]]*https://' "$2" || _bad "the mirrorlist has no active https mirror"
  grep -E '^[[:space:]]*Server[[:space:]]*=' "$2" | grep -Evq '=[[:space:]]*https://[^ ]+/\$repo/os/\$arch[[:space:]]*$' \
    && _bad "the mirrorlist has a mirror that is not https://.../\$repo/os/\$arch"
  return "$_n"
}
