# Checks on a Fedora image as written, sourced by bootstrap-fedora.sh and tested by test-fedora-image-checks.sh.
# Plain sh functions, no state: each prints why it refuses and returns non-zero.

# Cloudflare caches a file only up to 512 MB (plan 5.4; AutoBuild deploy/r2/PLAN.md). Past it every download of the
# image comes from R2 uncached. Read as 512,000,000 bytes, the smaller of the two readings of "512 MB", so an image
# that passes fits either. BSL_CACHE_LIMIT exists for the tests; a bake never needs to set it.
BSL_CACHE_LIMIT="${BSL_CACHE_LIMIT:-512000000}"

# $1 = image file (or <name>.unchecked). Under the limit: prints the size and returns 0. At or over it: says so and returns 1.
bsl_fedora_size_check() {
  _s=$(stat -Lc %s "$1") || return 2
  _b=$(basename "${1%.unchecked}")  # the bake checks <name>.unchecked: named as it will be
  if [ "$_s" -ge "$BSL_CACHE_LIMIT" ]; then
    echo "$_b is $_s bytes, $((_s - BSL_CACHE_LIMIT)) over Cloudflare's per-file cache limit ($BSL_CACHE_LIMIT bytes): every download of it would come from R2 uncached"
    return 1
  fi
  echo "$_b is $_s bytes, $((BSL_CACHE_LIMIT - _s)) under Cloudflare's per-file cache limit ($BSL_CACHE_LIMIT bytes)"
}

# $1 = the image's listing (tar tvf). Every refusal is printed; returns the number of them (0 = the listing is right).
bsl_fedora_listing_check() {
  _n=0
  grep -Eq '^-rwsr-xr-x (root/root|0/0) .* (\./)?usr/bin/sudo$' "$1" || { echo "sudo is not 4755 root in the listing"; _n=$((_n + 1)); }
  grep -Eq '^drwx------ (root/root|0/0) .* (\./)?root/?$' "$1" || { echo "/root is not 0700 in the listing"; _n=$((_n + 1)); }
  ! grep -Eq ' (\./)?(\.dockerenv|bsl-stage|bsl-key|bake\.sh|etc/hostname|etc/resolv\.conf|etc/hosts\.bsl-setup)(/|$)' "$1" \
    || { echo "Docker's files are in the image"; _n=$((_n + 1)); }
  # KIWI's own files, left in Fedora's container image by the tool that builds it (no package owns them): its build
  # settings at /.profile (kiwi_displayname='Fedora-Container-Base-Generic' and the rest) and its fstab script.
  ! grep -Eq ' (\./)?(\.profile|\.kconfig|etc/fstab\.script)$' "$1" || { echo "KIWI's build files (/.profile, /etc/fstab.script) are in the image"; _n=$((_n + 1)); }
  grep -Eq '^-rw-r--r-- (root/root|0/0) +[1-9][0-9]* .* (\./)?etc/hosts$' "$1" || { echo "/etc/hosts is not the setup package's"; _n=$((_n + 1)); }
  grep -Eq '^-rw-r--r-- (root/root|0/0) +0 .* (\./)?etc/machine-id$' "$1" || { echo "/etc/machine-id is not empty in the listing"; _n=$((_n + 1)); }
  ! grep -Eq ' (\./)?(var/lib/systemd/random-seed|var/lib/systemd/credential\.secret|etc/ssh/ssh_host_[^ ]*)$' "$1" \
    || { echo "the image carries a random seed, a credential secret or SSH host keys of the bake's own"; _n=$((_n + 1)); }
  ! grep -Eq ' (\./)?(var/)?tmp/[^ ]+' "$1" || { echo "/tmp or /var/tmp is not empty in the listing"; _n=$((_n + 1)); }
  return "$_n"
}
