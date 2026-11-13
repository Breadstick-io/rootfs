#!/usr/bin/env bash
# Breadstick-RPM's images, a Fedora Remix (4.0; plan Android/docs/4.0/multi-distro.md 5.4 and 5.11). LOCAL ONLY:
# nothing here uploads anything, and no manifest is written anywhere a released app (or the CDN) reads.
#
#   [RELEASE=45] [ARCH=arm64|amd64] [RPM_STAGE=/abs/stage] rootfs/bootstrap/bootstrap-fedora.sh [base|desktop|both]
#
# From Fedora's official container image of that release and architecture (amd64 under qemu-user 10 on this arm64
# host), in a container that has the network and never the gpg-agent socket (nothing is signed here):
#   1. The Remix swap: breadstick-release, from Breadstick's repository with gpgcheck=1 and repo_gpgcheck=1 against
#      the archive key (bootstrap/RPM-GPG-KEY-breadstick, its fingerprint checked first), replaces every
#      fedora-release* package and fedora-logos in one transaction (dnf install --allowerasing).
#   2. Documentation and every language, as Debian's images have them: Fedora's container image installs neither
#      (tsflags=nodocs in /etc/dnf/dnf.conf, %_install_langs en_US in /etc/rpm/macros.image-language-conf), and a
#      system made from it would never install them for anything added later. Both settings go (dnf.conf is then
#      libdnf5's own file again), then dnf upgrade --refresh: the release's updates repository, security fixes
#      included.
#   3. The base set (what bootstrap-debian.sh's INCLUDE gives Debian): sudo, passwd, ncurses-term, nano, less,
#      procps-ng, openssh-clients, tmux, curl, gnupg2, ca-certificates, glibc-langpack-en. No weak dependencies, as
#      the app installs. Then every package the container image installed without some of its files (rpm's file
#      state "not installed": its documentation and translations) is reinstalled, and none may be left.
#   4. desktop: breadstick-desktop, then a browser through Breadstick's own install-browser.sh with no choice (its
#      default, Chromium; the owner: the image ships a browser), and the desktop-ok marker the app looks for.
#   5. sudo 4755 (Fedora ships 4111, which proot's fake root cannot read to run: plan section 11) and /root 0700
#      (Fedora's is 0550, which a fake root cannot write); the package database, caches, logs, /tmp and /var/tmp
#      cleaned. /etc/machine-id is emptied and systemd's random seed removed (systemd's scriptlets write both during
#      the bake): every device made from the image would otherwise share one machine-id, and the session gives a
#      device its own only when the file is empty, as in Debian's images. KIWI's build files, which Fedora's container
#      image carries and no package owns (/.profile with its kiwi_* settings, /etc/fstab.script), are removed.
# No proot shims are installed (Debian's provision.sh puts systemctl/systemd-tmpfiles stubs and a sysusers shim in
# /usr/local/bin and /usr/bin): rpm runs scriptlets with PATH=/sbin:/bin:/usr/sbin:/usr/bin, so /usr/local/bin is
# never seen, and stubs over /usr/bin would be files of systemd's package (rpm -V fails, every systemd update puts
# them back). Phase 0 ran Fedora's own systemd-sysusers and scriptlets under proot (504 packages, dnf rc 0).
#
# The image is the container's filesystem (docker export), minus Docker's own files (/.dockerenv, the stage's mount
# point), in dist/ (git-ignored): fedora-<release>-<arch>[-desktop]-<stamp>.tar.zst, zstd level 19 like the Debian
# images. Each image is checked after it is written (below), its size first: Cloudflare caches a file only up to
# 512 MB (plan 5.4), so an image at or over 512,000,000 bytes is refused (renamed <name>.rejected, the bake fails).
# OVER_CACHE_LIMIT=keep keeps such an image under its own name, checked like any other, with a warning that it would
# be served uncached: for local measurement only, the owner's call before anything like it is published.
# An image is written as <name>.unchecked and gets its name only when every check has passed; one that fails a check
# is renamed <name>.rejected. dist/ never holds an unchecked or failed image under a good name.
#
# RPM_STAGE: until rpm.breadstick.io serves packages, a local stage made by Apt/rpm/stage-rpm-repo.sh is the only
# repository there is. It is mounted read-only at /bsl-stage and the image's breadstick.repo points at
# file:///bsl-stage/fedora/$releasever/$basearch/, so a device installed from such an image would never see an
# update: those images are named fedora-...-staged-<stamp>.tar.zst and must never be published. Without RPM_STAGE the
# repository is https://rpm.breadstick.io (breadstick-release's own file, untouched).
#
# MANIFEST_DIR (optional): write manifest-fedora-<arch>[-desktop].json for each image there (version, file, size,
# sha256, arch, distro), the names the 4.0 app reads (RootfsDownloader.manifestName, plan 5.11), for a LOCAL check. Refused inside the workspace's mirror and
# anywhere under AutoBuild/dist.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RELEASE="${RELEASE:-45}"
case "$RELEASE" in [0-9][0-9]) ;; *) echo "ERROR: RELEASE must be a Fedora release number" >&2; exit 1 ;; esac
case "$(uname -m)" in aarch64|arm64) HOST=arm64 ;; x86_64) HOST=amd64 ;; *) echo "ERROR: unknown host" >&2; exit 1 ;; esac
ARCH="${ARCH:-$HOST}"
case "$ARCH" in arm64) RPMARCH=aarch64 ;; amd64) RPMARCH=x86_64 ;; *) echo "ERROR: ARCH must be arm64 or amd64" >&2; exit 1 ;; esac
WHAT="${1:-both}"
case "$WHAT" in base|desktop|both) ;; *) echo "usage: $0 [base|desktop|both]" >&2; exit 1 ;; esac
IMAGE="fedora:$RELEASE"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
STAMP="${STAMP:-$(date -u +%Y%m%d%H%M)}"
case "$STAMP" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) echo "ERROR: STAMP must be YYYYMMDDHHMM" >&2; exit 1 ;; esac
LEVEL="${BAKE_ZSTD_LEVEL:-19}"
case "${OVER_CACHE_LIMIT:-}" in ''|keep) ;; *) echo "ERROR: OVER_CACHE_LIMIT is keep or unset" >&2; exit 1 ;; esac
# shellcheck source=fedora-image-checks.sh
. "$HERE/fedora-image-checks.sh"
[ "$BSL_CACHE_LIMIT" -le 512000000 ] 2>/dev/null || { echo "ERROR: BSL_CACHE_LIMIT may only lower the 512,000,000-byte limit" >&2; exit 1; }
KEY="$HERE/RPM-GPG-KEY-breadstick"
FPR=EABBC4B5F0BD78B405AF005FF02A2D085AC691BC
log() { printf '\033[1;34m[bake-fedora]\033[0m %s\n' "$*"; }

gpg --batch --show-keys --with-colons "$KEY" 2>/dev/null | grep -q "^fpr:::::::::$FPR:" \
  || { echo "ERROR: $KEY is not the archive key $FPR" >&2; exit 1; }
STAGED=""
MOUNT=()
if [ -n "${RPM_STAGE:-}" ]; then
  case "$RPM_STAGE" in /*) ;; *) echo "ERROR: RPM_STAGE must be an absolute path" >&2; exit 1 ;; esac
  [ -f "$RPM_STAGE/RPM-GPG-KEY-breadstick" ] && [ -f "$RPM_STAGE/fedora/$RELEASE/$RPMARCH/repodata/repomd.xml.asc" ] \
    || { echo "ERROR: $RPM_STAGE is not an RPM stage for Fedora $RELEASE $RPMARCH (Apt/rpm/stage-rpm-repo.sh)" >&2; exit 1; }
  cmp -s "$RPM_STAGE/RPM-GPG-KEY-breadstick" "$KEY" || { echo "ERROR: the stage's key is not $KEY" >&2; exit 1; }
  STAGED=1
  MOUNT=(-v "$RPM_STAGE:/bsl-stage:ro")
  log "NOTE: RPM_STAGE is a local stage: the images are named -staged- and must never be published"
fi
if [ -n "${MANIFEST_DIR:-}" ]; then
  case "$MANIFEST_DIR" in /*) ;; *) echo "ERROR: MANIFEST_DIR must be an absolute path" >&2; exit 1 ;; esac
  case "$(realpath -m "$MANIFEST_DIR")/" in
    */AutoBuild/dist/*|*/mirror/*) echo "ERROR: MANIFEST_DIR may not be under AutoBuild/dist or a mirror" >&2; exit 1 ;;
  esac
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
name_of() {  # $1 = base|desktop
  local n="fedora-$RELEASE-$ARCH"
  [ "$1" = desktop ] && n="$n-desktop"
  [ -n "$STAGED" ] && n="$n-staged"
  echo "$OUT_DIR/$n-$STAMP.tar.zst"
}

WORK="$(mktemp -d)"
CONTAINERS=()
IMAGES=()
cleanup() {
  for c in "${CONTAINERS[@]}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  for i in "${IMAGES[@]}"; do docker rmi -f "$i" >/dev/null 2>&1 || true; done
  rm -f "$WORK"/bake.sh "$WORK"/check.sh "$WORK"/filter.py "$WORK"/bsl-os.sh "$WORK"/list "$WORK"/hosts
  rmdir "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

docker pull -q --platform "linux/$ARCH" "$IMAGE" >/dev/null
[ "$(docker image inspect -f '{{.Architecture}}' "$IMAGE")" = "$ARCH" ] || { echo "ERROR: $IMAGE is not $ARCH" >&2; exit 1; }
BASE_ID="$(docker image inspect -f '{{.Id}}' "$IMAGE")"

# The bake itself, run as root in the container. Its own file (no heredoc that its content could end early).
cat > "$WORK/bake.sh" <<'BSL_FEDORA_BAKE_7d41'
set -eu
STEP=$1 REL=$2 STAGED=$3
A=$(uname -m)
D="dnf -y --setopt=install_weak_deps=False"
if [ -n "$STAGED" ]; then BSL="file:///bsl-stage"; else BSL="https://rpm.breadstick.io"; fi
if [ "$STEP" = base ]; then
    [ "$(rpm -E %fedora)" = "$REL" ] || { echo "this image is not Fedora $REL" >&2; exit 1; }
    echo "[bake] 1. the Remix swap: breadstick-release in place of fedora-release* and fedora-logos"
    $D --repofrompath=bslbake,"$BSL/fedora/$REL/$A/" --setopt=bslbake.gpgcheck=1 --setopt=bslbake.repo_gpgcheck=1 \
        --setopt=bslbake.gpgkey=file:///bsl-key/RPM-GPG-KEY-breadstick install --allowerasing breadstick-release
    left=$(rpm -qa 'fedora-release*' 'fedora-logos*' 'fedora-release-notes*')
    [ -z "$left" ] || { echo "Fedora's branding is still installed: $left" >&2; exit 1; }
    if [ -n "$STAGED" ]; then
        # A local test image: the repository is the stage, at the path it is mounted on.
        sed -i "s|^baseurl=.*|baseurl=$BSL/fedora/\$releasever/\$basearch/|" /etc/yum.repos.d/breadstick.repo
    fi
    echo "[bake] 2. documentation and every language, then dnf upgrade --refresh"
    sed -i '/^tsflags=nodocs$/d' /etc/dnf/dnf.conf
    rm -f /etc/rpm/macros.image-language-conf
    ! grep -q '^tsflags' /etc/dnf/dnf.conf || { echo "dnf.conf still has tsflags: $(grep '^tsflags' /etc/dnf/dnf.conf)" >&2; exit 1; }
    [ "$(rpm -E %_install_langs)" = all ] || { echo "rpm installs only these languages: $(rpm -E %_install_langs)" >&2; exit 1; }
    $D upgrade --refresh
    echo "[bake] 3. the base set"
    $D install sudo passwd shadow-utils ncurses-term nano less procps-ng openssh-clients tmux curl gnupg2 \
        ca-certificates glibc-langpack-en
    left=$(rpm -qa --qf '[%{FILESTATES:fstate}\t%{=NAME}\n]' | sed -n 's/^not installed\t//p' | sort -u)
    if [ -n "$left" ]; then
        echo "[bake] 3. reinstalling $(echo "$left" | wc -l) packages the container image installed without their documentation or translations"
        # shellcheck disable=SC2086
        $D reinstall $left
    fi
else
    echo "[bake] 4. breadstick-desktop and a browser"
    $D upgrade --refresh
    $D install breadstick-desktop
    sh /usr/lib/breadstick/install-browser.sh
    if command -v xfce4-session >/dev/null 2>&1 || command -v openbox >/dev/null 2>&1; then
        mkdir -p /etc/breadstick
        : > /etc/breadstick/desktop-ok
    else
        echo "no desktop session after breadstick-desktop" >&2; exit 1
    fi
fi
echo "[bake] 5. modes and cleaning"
# The setup package's own /etc/hosts, which docker export replaces with an empty file (the export puts it back).
mkdir -p /tmp/bsl-setup
dnf -q download --destdir /tmp/bsl-setup setup >/dev/null
rpm2archive -n < "$(ls /tmp/bsl-setup/setup-*.rpm)" | tar -xO ./etc/hosts > /etc/hosts.bsl-setup
[ -s /etc/hosts.bsl-setup ] || { echo "no /etc/hosts in the setup package" >&2; exit 1; }
chmod 4755 /usr/bin/sudo
chmod 0700 /root
left=$(rpm -qa 'fedora-release*' 'fedora-logos*' 'fedora-release-notes*')
[ -z "$left" ] || { echo "Fedora's branding came back: $left" >&2; exit 1; }
left=$(rpm -qa --qf '[%{FILESTATES:fstate}\t%{=NAME}\t%{FILENAMES}\n]' | grep '^not installed' || true)
[ -z "$left" ] || { echo "files rpm left out (documentation or translations): $(echo "$left" | head -n 5)" >&2; exit 1; }
# No machine-id or random seed of the bake's own: each device makes its own (the session, when the file is empty).
: > /etc/machine-id
rm -f /var/lib/systemd/random-seed
# KIWI's leftovers in Fedora's container image (the tool that builds it; no package owns them): removed when they are
# unowned and KIWI's. Anything else unowned at those paths is not known, and the bake stops.
for f in /.profile /.kconfig /etc/fstab.script; do
    [ -e "$f" ] || continue
    if rpm -qf "$f" >/dev/null 2>&1; then echo "$f belongs to $(rpm -qf "$f"): left alone"; continue; fi
    grep -q kiwi "$f" || { echo "$f is unowned and not KIWI's" >&2; exit 1; }
    rm -f "$f"
done
dnf -q clean all
rm -rf /var/cache/dnf/* /var/cache/libdnf5/* /var/log/dnf* /var/lib/dnf/repos/* /root/.cache \
    /tmp/* /tmp/.[!.]* /var/tmp/* /var/tmp/.[!.]*
echo "[bake] $STEP done: $(rpm -qa | wc -l) packages"
BSL_FEDORA_BAKE_7d41

# docker export, minus Docker's own entries: the stream is rewritten entry by entry (owners, modes, links and hard
# links as they are), never unpacked on this host.
cat > "$WORK/filter.py" <<'BSL_FEDORA_FILTER_7d41'
# docker export writes its own /.dockerenv and empty 0755 files at etc/hostname, etc/hosts and etc/resolv.conf over
# the image's. They are left out (no package owns hostname or resolv.conf; the app writes resolv.conf), and etc/hosts
# gets the setup package's own file back (argv[1], copied out of the bake as etc/hosts.bsl-setup, also left out).
import io, sys, tarfile
hosts = open(sys.argv[1], "rb").read()
DROP = {".dockerenv", "bsl-stage", "bsl-key", "bake.sh", "etc/hostname", "etc/resolv.conf", "etc/hosts.bsl-setup"}
src = tarfile.open(fileobj=sys.stdin.buffer, mode="r|")
dst = tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT)
seen_hosts = False
for m in src:
    name = m.name[2:] if m.name.startswith("./") else m.name
    name = name.rstrip("/")
    if name in DROP or name.split("/")[0] in {"bsl-stage", "bsl-key"}:
        continue
    if name == "etc/hosts":
        m.size, m.mode, m.uid, m.gid, m.uname, m.gname = len(hosts), 0o644, 0, 0, "root", "root"
        dst.addfile(m, io.BytesIO(hosts))
        seen_hosts = True
        continue
    dst.addfile(m, src.extractfile(m) if m.isreg() else None)
dst.close()
if not seen_hosts:
    sys.exit("etc/hosts was not in the export")
BSL_FEDORA_FILTER_7d41

run_step() {  # $1 = base|desktop, $2 = image to start from; leaves the container's name in $C
  C="bsl-fedora-bake-$1-$ARCH-$$"
  CONTAINERS+=("$C")
  log "Fedora $RELEASE $ARCH: $1 step in $C"
  docker create --name "$C" --platform "linux/$ARCH" "${MOUNT[@]}" -v "$HERE:/bsl-key:ro" -v "$WORK/bake.sh:/bake.sh:ro" \
    "$2" sh /bake.sh "$1" "$RELEASE" "$STAGED" >/dev/null
  docker start -a "$C"
  [ "$(docker inspect -f '{{.State.ExitCode}}' "$C")" = 0 ] || { echo "ERROR: the $1 step failed" >&2; exit 1; }
}
export_image() {  # $1 = container, $2 = tarball
  log "exporting $1 -> $2"
  rm -f "$WORK/hosts"
  docker cp "$1:/etc/hosts.bsl-setup" "$WORK/hosts"
  [ -s "$WORK/hosts" ] || { echo "ERROR: no copy of the setup package's /etc/hosts in $1" >&2; exit 1; }
  docker export "$1" | python3 -I "$WORK/filter.py" "$WORK/hosts" | zstd -q -"$LEVEL" -T0 -o "$2.part"
  zstd -q -t "$2.part"
  mv -f "$2.part" "$2.unchecked"
}

# Each image, checked as a device would get it: the listing (modes as written), then the image imported into Docker
# and run with no network (the stage mounted where the image's repository names it), never unpacked on this host.
# The base image has no Breadstick package, so its family check runs bsl-os.sh from a packages tree: PKGROOT when it
# is set (the release-4.0 tree the stage was built from), else the packages checkout beside this one, whatever it has
# checked out. Which one, and its commit, is printed.
BSLOS_TREE="${PKGROOT:-$ROOT/../packages}"
[ -f "$BSLOS_TREE/breadstick-session/src/lib/bsl-os.sh" ] \
  || { echo "ERROR: no bsl-os.sh in $BSLOS_TREE (set PKGROOT= to the packages tree)" >&2; exit 1; }
cp "$BSLOS_TREE/breadstick-session/src/lib/bsl-os.sh" "$WORK/bsl-os.sh"
log "the base image's bsl-os.sh: $BSLOS_TREE ($(git -C "$BSLOS_TREE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?') $(git -C "$BSLOS_TREE" rev-parse --short HEAD 2>/dev/null || echo '?'))"
cat > "$WORK/check.sh" <<'BSL_FEDORA_CHECK_7d41'
set -u
FLAVOR=$1 REL=$2 STAGED=$3
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
check() { _w=$1; shift; if "$@" >/tmp/out 2>&1; then ok "$_w"; else bad "$_w"; sed 's/^/     /' /tmp/out | tail -n 8; fi; }
check "os-release: the Remix (NAME, PRETTY_NAME, ID=fedora, VERSION_ID=$REL), breadstick-release's link" sh -c \
    "test \"\$(readlink /etc/os-release)\" = ../usr/lib/os-release && grep -qx 'NAME=\"Breadstick-RPM\"' /etc/os-release && grep -qx 'PRETTY_NAME=\"Breadstick-RPM, a Fedora Remix\"' /etc/os-release && grep -qx ID=fedora /etc/os-release && grep -qx VERSION_ID=$REL /etc/os-release && test \"\$(rpm -qf --qf '%{NAME}' /usr/lib/os-release)\" = breadstick-release"
check "no fedora-release*, fedora-logos* or fedora-release-notes" sh -c 'test -z "$(rpm -qa "fedora-release*" "fedora-logos*" "fedora-release-notes*")"'
check "system-release($REL) from breadstick-release, dnf's releasever $REL" sh -c \
    "test \"\$(rpm -q --qf '%{NAME}' --whatprovides 'system-release($REL)')\" = breadstick-release && dnf5 --dump-variables 2>/dev/null | grep -qx 'releasever = $REL'"
# A -staged- image's breadstick.repo names the stage (its one changed file, a %config one).
check "rpm -V breadstick-release clean${STAGED:+ (breadstick.repo aside)}" rpm -V ${STAGED:+--noconfig} breadstick-release
check "dnf repolist shows the Breadstick repository" sh -c 'dnf repolist 2>/dev/null | grep -q "^breadstick "'
if [ -n "$STAGED" ]; then
    check "breadstick.repo names the local stage (a -staged- image)" grep -qx 'baseurl=file:///bsl-stage/fedora/$releasever/$basearch/' /etc/yum.repos.d/breadstick.repo
    check "the Breadstick repository answers offline, signature checked" sh -c \
        'dnf -q -y --repo=breadstick --setopt=breadstick.skip_if_unavailable=False repoquery --available breadstick-desktop | grep -q breadstick-desktop'
else
    check "breadstick.repo is breadstick-release's own (rpm.breadstick.io)" sh -c \
        'grep -qx "baseurl=https://rpm.breadstick.io/fedora/\$releasever/\$basearch/" /etc/yum.repos.d/breadstick.repo && rpm -V breadstick-release'
fi
check "sudo is 4755 root:root" test "$(stat -c '%a %U:%G' /usr/bin/sudo)" = "4755 root:root"
check "rpm -V sudo: clean but for the mode of /usr/bin/sudo (4755 in place of Fedora's 4111)" sh -c \
    'rpm -V --nomode sudo && rpm -V sudo > /tmp/v; test "$(wc -l < /tmp/v)" = 1 && grep -Eq "^\.M\.{7} +/usr/bin/sudo$" /tmp/v'
check "/root is 0700" test "$(stat -c %a /root)" = 700
check "bsl-os.sh: family fedora" sh -c '. "${BSLOS:-/usr/lib/breadstick/bsl-os.sh}"; test "$(bsl_os_family)" = fedora'
check "no KIWI build files (/.profile, /.kconfig, /etc/fstab.script)" sh -c 'test ! -e /.profile && test ! -e /.kconfig && test ! -e /etc/fstab.script'
check "/etc/machine-id is empty and there is no random seed (each device makes its own)" sh -c \
    'test -f /etc/machine-id && test ! -s /etc/machine-id && test ! -e /var/lib/systemd/random-seed'
check "documentation and every language: no tsflags in dnf.conf, %_install_langs all" sh -c \
    '! grep -q "^tsflags" /etc/dnf/dnf.conf && test ! -e /etc/rpm/macros.image-language-conf && test "$(rpm -E %_install_langs)" = all'
check "no file rpm left out (file state 'not installed'): documentation and translations are on disk" sh -c \
    '! rpm -qa --qf "[%{FILESTATES:fstate} %{=NAME} %{FILENAMES}\n]" | grep "^not installed"'
check "bash's man page and a translation are installed" sh -c \
    'rpm -qd bash | grep -q "/man1/bash\.1" && test -e "$(rpm -qd bash | grep "/man1/bash\.1" | head -n 1)" && rpm -ql bash | grep -q "^/usr/share/locale/de/LC_MESSAGES/bash\.mo$" && test -e /usr/share/locale/de/LC_MESSAGES/bash.mo'
if [ "$FLAVOR" = desktop ]; then
    check "breadstick-desktop installed, from the Breadstick repository" sh -c \
        'test "$(dnf -q repoquery --installed --qf "%{from_repo}" breadstick-desktop)" = breadstick'
    check "the desktop-ok marker and a session (xfce4-session)" sh -c 'test -f /etc/breadstick/desktop-ok && command -v xfce4-session'
    check "the session script applies the Breadstick look" grep -q apply-look /usr/lib/breadstick/start-desktop-x11.sh
    check "a browser is installed and set as the default" sh -c 'test -s /etc/breadstick/browser && rpm -q chromium && test -x /usr/local/bin/breadstick-browser-chromium'
    check "every breadstick package is signed by the archive key" sh -c \
        "! rpm -qa --qf '%{NAME} %{RSAHEADER:pgpsig}\n' 'breadstick-*' | grep -vi f02a2d085ac691bc"
fi
check "every installed package's dependencies hold (rpm -Va --nofiles)" rpm -Va --nofiles --nodigest --nosignature
if [ "$FLAVOR" = desktop ]; then
    # Last, as it writes a machine-id: the session's own two lines give this device an id of its own.
    grep -E '^\[ -s /(etc|var/lib/dbus)/machine-id \]' /usr/lib/breadstick/start-desktop-x11.sh > /tmp/mid.sh
    check "the session's machine-id lines make one for this device" sh -c \
        'test "$(wc -l < /tmp/mid.sh)" = 2 && sh /tmp/mid.sh && grep -Eqx "[0-9a-f]{32}" /etc/machine-id && test "$(cat /var/lib/dbus/machine-id)" = "$(cat /etc/machine-id)"'
fi
echo "$FLAVOR: $fails failed"
[ "$fails" -eq 0 ]
BSL_FEDORA_CHECK_7d41

reject() {  # $1 = the image as written (<name>.unchecked), $2 = why: it becomes <name>.rejected, and the bake fails
  mv -f "$1" "${1%.unchecked}.rejected"
  echo "ERROR: $2; the image is now $(basename "${1%.unchecked}").rejected" >&2
  exit 1
}
OVER_LIMIT=()
verify_image() {  # $1 = base|desktop, $2 = tarball (written as $2.unchecked, renamed $2 when it passes)
  local t="$2.unchecked" v="bsl-fedora-verify-$1-$ARCH-$$" img="bsl-fedora-verify:$1-$ARCH-$STAMP-$$" why
  log "checking $(basename "$2")"
  if why="$(bsl_fedora_size_check "$t")"; then
    log "$why"
  elif [ "${OVER_CACHE_LIMIT:-}" = keep ]; then
    log "WARNING: $why (kept: OVER_CACHE_LIMIT=keep)"
    OVER_LIMIT+=("$2")
  else
    reject "$t" "$why (OVER_CACHE_LIMIT=keep keeps it, for a local measurement only)"
  fi
  zstd -dc "$t" | tar tvf - > "$WORK/list" 2>/dev/null || reject "$t" "the image does not list"
  why="$(bsl_fedora_listing_check "$WORK/list")" || reject "$t" "$(echo "$why" | paste -sd ';' - | sed 's/;/; /g')"
  rm -f "$WORK/list"
  IMAGES+=("$img")
  zstd -dc "$t" | docker import --platform "linux/$ARCH" - "$img" >/dev/null
  CONTAINERS+=("$v")
  docker create --name "$v" --platform "linux/$ARCH" --network none "${MOUNT[@]}" \
    -v "$WORK/check.sh:/check.sh:ro" -v "$WORK/bsl-os.sh:/bsl-os.sh:ro" -e BSLOS=$([ "$1" = base ] && echo /bsl-os.sh || echo /usr/lib/breadstick/bsl-os.sh) \
    "$img" sh /check.sh "$1" "$RELEASE" "$STAGED" >/dev/null
  docker start -a "$v" || reject "$t" "$(basename "$2") failed its checks"
  docker rm -f "$v" >/dev/null
  docker rmi -f "$img" >/dev/null
  mv -f "$t" "$2"
}
write_manifest() {  # $1 = base|desktop, $2 = tarball
  [ -n "${MANIFEST_DIR:-}" ] || return 0
  mkdir -p "$MANIFEST_DIR"
  local m="manifest-fedora-$ARCH.json"
  [ "$1" = desktop ] && m="manifest-fedora-$ARCH-desktop.json"
  printf '{\n  "version": "%s",\n  "file": "%s",\n  "size": %s,\n  "sha256": "%s",\n  "arch": "%s",\n  "distro": "fedora"\n}\n' \
    "$STAMP" "$(basename "$2")" "$(stat -c %s "$2")" "$(sha256sum "$2" | cut -d' ' -f1)" "$ARCH" > "$MANIFEST_DIR/$m"
  log "local manifest $MANIFEST_DIR/$m"
}

BASE_T="$(name_of base)"
DESK_T="$(name_of desktop)"
run_step base "$BASE_ID"
BASE_C="$C"
if [ "$WHAT" != desktop ]; then
  export_image "$BASE_C" "$BASE_T"
fi
if [ "$WHAT" != base ]; then
  STEP_IMG="bsl-fedora-bake:base-$ARCH-$STAMP-$$"
  IMAGES+=("$STEP_IMG")
  docker commit "$BASE_C" "$STEP_IMG" >/dev/null
  run_step desktop "$STEP_IMG"
  export_image "$C" "$DESK_T"
fi
# docker run --platform of another architecture re-points the tag at it (the classic image store keeps one per tag):
# point it back at this host's, as Apt/rpm/build-rpms.py does.
[ "$ARCH" = "$HOST" ] || docker pull -q --platform "linux/$HOST" "$IMAGE" >/dev/null
if [ "$WHAT" != desktop ]; then verify_image base "$BASE_T"; write_manifest base "$BASE_T"; fi
if [ "$WHAT" != base ]; then verify_image desktop "$DESK_T"; write_manifest desktop "$DESK_T"; fi
for t in "$BASE_T" "$DESK_T"; do
  [ -f "$t" ] || continue
  over=""
  for o in "${OVER_LIMIT[@]}"; do
    if [ "$o" = "$t" ]; then over=", OVER Cloudflare's cache limit: never publish it as it is"; fi
  done
  log "Artifact: $t ($(stat -c %s "$t") bytes$over)"
done
log "Nothing was uploaded."
