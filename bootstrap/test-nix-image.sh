#!/usr/bin/env bash
# A Breadstick-Nix image as a device's first start uses it, in a container (4.0, plan 5.9; round 9). Not proot: the
# image's own NixOS, as real root in Docker, so it tests what bootstrap-nix.sh baked and what bsl-nix does with it
# (the stage-2 stand-in, the account step, the Nix packages page's operations, switch-to-configuration against
# breadstick-systemd), never the app's proot. LOCAL ONLY: the container reaches cache.nixos.org for the one package
# it adds (hello) and nothing else; nothing is signed or uploaded.
#
#   rootfs/bootstrap/test-nix-image.sh /abs/nixos-26.05-arm64-desktop-<stamp>.tar.zst [arm64|amd64]
#   SETUP_USER=/abs/Android/app/src/main/assets/setup-user.sh   (default: the Android checkout beside this one)
#   ORDER=session-first (default) | account-first: whether a session started before the account step (it leaves the
#   bsl-app entry for the app's real uid, 10362 here, as start-desktop-x11.sh does: round 9's F8 path, where the
#   account got uid 10363) or the account came first (the in-app order; test-nix-session.sh and the gate run it too)
#
# Each check prints PASS or FAIL; any FAIL exits 1. Containers and images bsl-<RUN>-test-* (RUN, default nixtest), removed after.
set -euo pipefail
IMG="${1:?image}"
ARCH="${2:-arm64}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SETUP_USER="${SETUP_USER:-$HERE/../../Android/app/src/main/assets/setup-user.sh}"
[ -f "$SETUP_USER" ] || SETUP_USER="$HERE/../../plan-4.0-android/app/src/main/assets/setup-user.sh"
[ -f "$SETUP_USER" ] || { echo "no setup-user.sh: set SETUP_USER" >&2; exit 2; }
T="bsl-${RUN:-nixtest}-test:$ARCH-$$"
C="bsl-${RUN:-nixtest}-test-$ARCH-$$"
W="$(mktemp -d)"
cleanup() { docker rm -f "$C" >/dev/null 2>&1 || true; docker rmi -f "$T" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
cp "$SETUP_USER" "$W/setup-user.sh"
ORDER="${ORDER:-session-first}"
case "$ORDER" in session-first|account-first) printf '%s\n' "$ORDER" > "$W/order" ;; *) echo "ORDER is session-first or account-first" >&2; exit 2 ;; esac
cat > "$W/run.sh" <<'BSL_NIXTEST_RUN_END'
#!/bin/sh
# In the image's own NixOS, as root. PATH as the app gives a Nix system (GuestEnv.NIX_PATH). Docker binds its own
# /etc/hosts, /etc/hostname and /etc/resolv.conf over the image's: NixOS's hosts is read from /etc/static.
export PATH=/run/wrappers/bin:/usr/local/sbin:/usr/local/bin:/nix/var/nix/profiles/system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin
P=/nix/var/nix/profiles/system/sw/bin
fails=0
check() { if [ "$2" = 0 ]; then echo "PASS $1${3:+: $3}"; else echo "FAIL $1${3:+: $3}"; fails=$((fails + 1)); fi; }
t() { s=$(date +%s); "$@"; r=$?; echo "  ($(( $(date +%s) - s )) s)"; return $r; }

[ -s /etc/machine-id ]; check "the image's machine id is empty" $(( $? == 0 ))
t $P/bsl-nix boot > /tmp/boot.log 2>&1; check "bsl-nix boot" $? "$(tail -1 /tmp/boot.log)"
[ -s /etc/machine-id ]; check "boot made a machine id" $?
[ -x /run/wrappers/bin/sudo ] && [ -u "$(readlink -f /run/wrappers/bin/sudo)" -o -u /run/wrappers/bin/sudo ]; check "setuid sudo wrapper" $?
[ -d /usr/local/bin ] && [ ! -L /usr/local/bin ] && [ ! -L /usr/local/sbin ] && command -v xfce4-session >/dev/null && \
  [ -e /usr/lib/breadstick/start-desktop-x11.sh ] && [ -e /usr/share/zoneinfo/Europe/Paris ] && grep -q breadstick /etc/static/hosts
check "the paths Breadstick systems have" $?
grep -q '^ID=nixos' /etc/os-release; check "os-release says nixos" $?
[ "$(cat /etc/breadstick/version)" = "$(cat /etc/breadstick/nix/src/VERSION)" ]; check "Breadstick's version in /etc" $? "$(cat /etc/breadstick/version)"
# The shell programs' Python finds GTK 3 in a login shell and in an `env -i` as Android launches apps (its own
# environment: round 9 review), and the session script parses.
GI="import gi; gi.require_version('Gtk', '3.0'); gi.require_version('Gdk', '3.0'); from gi.repository import Gtk, Gdk, Pango, GdkPixbuf; import dbus, cairo; print('gi ok')"
o=$(bash -lc "python3 -c \"$GI\"" 2>&1)
[ "$o" = "gi ok" ]; check "Python with GTK 3, D-Bus and cairo" $? "$(echo "$o" | tail -1)"
o=$(env -i HOME=/root PATH=$PATH python3 -c "$GI" 2>&1)
[ "$o" = "gi ok" ]; check "the same from env -i (the Apps drawer, Floating mode)" $? "$(echo "$o" | tail -1)"
# A login shell keeps /usr/local's folders, after the setuid wrappers (round 9 review: bsl-audio was not found).
mkdir -p /usr/local/bin; printf '#!/bin/sh\necho shim\n' > /usr/local/bin/bsl-test-shim; chmod 755 /usr/local/bin/bsl-test-shim
o=$(env -i HOME=/root PATH=$PATH bash -lc 'echo "$PATH"; bsl-test-shim' 2>&1)
case "$(echo "$o" | head -1)" in /run/wrappers/bin:/usr/local/sbin:/usr/local/bin:*) r=0 ;; *) r=1 ;; esac
[ "$(echo "$o" | tail -1)" = shim ] || r=1
check "a login shell's PATH has /usr/local after the wrappers" $r "$(echo "$o" | head -1 | cut -c1-90)"
rm -f /usr/local/bin/bsl-test-shim
# The desktop's parts the review found missing: the marker, the look's themes at /usr/share, xsetroot and xrdb,
# dconf's and the keyring's D-Bus services, the keyring's wrapper.
[ -f /etc/breadstick/desktop-ok ]; check "the desktop marker" $?
m=""; for d in themes/Breadstick/gtk-3.0 backgrounds/breadstick icons applications X11/xkb locale/de/LC_MESSAGES; do [ -d /usr/share/$d ] || m="$m $d"; done
[ -z "$m" ]; check "the profile's themes, wallpapers, icons, menu entries, keyboard data and translations at /usr/share" $? "${m:+missing:$m}"
command -v xsetroot >/dev/null && command -v xrdb >/dev/null; check "xsetroot and xrdb" $?
SD=$(grep -o '<servicedir>[^<]*' /etc/dbus-1/session.conf 2>/dev/null | sed 's|<servicedir>||')
ls $SD 2>/dev/null | grep -q '^ca.desrt.dconf.service$'; check "dconf's D-Bus service on the session bus" $? "$(echo $SD | wc -w) service folder(s)"
ls $SD 2>/dev/null | grep -q '^org.freedesktop.secrets.service$'; check "the keyring's D-Bus service on the session bus" $?
[ -x /run/wrappers/bin/gnome-keyring-daemon ]; check "the keyring's wrapper" $?
[ "$(readlink /nix/var/nix/gcroots/breadstick-nixpkgs)" = "$(readlink -f /etc/breadstick/nix/nixpkgs)" ]; check "nixpkgs is a gc root" $?
sh -n /usr/lib/breadstick/start-desktop-x11.sh; check "the session script parses" $?
for p in xfce4-session xfwm4 xfce4-panel xfdesktop xfsettingsd xfce4-terminal thunar openbox xdotool wmctrl pulseaudio dbus-daemon tmux; do
  command -v $p >/dev/null || { echo "  missing $p"; miss=1; }
done
check "the desktop's programs" ${miss:-0}

# A session before the account (ORDER=session-first): start-desktop-x11.sh's bsl-app entry for the app's real uid.
if [ "$(cat /t/order)" = session-first ]; then
  useradd -r -M -N -g nogroup -u 10362 -d /nonexistent -s /run/current-system/sw/bin/nologin -c "Breadstick Linux, the Android app itself" bsl-app
  check "a session first: bsl-app is uid 10362" $(( $(id -u bsl-app 2>/dev/null || echo 0) != 10362 ))
fi
# The app's account step: setup-user.sh (the asset), then bsl-nix account.
printf 'secret1\n' | sh /t/setup-user.sh tester > /tmp/user.log 2>&1; r=$?
check "setup-user.sh ($(cat /t/order))" $r "$(tail -1 /tmp/user.log)"
$P/bsl-nix account tester > /tmp/acct.log 2>&1; check "bsl-nix account" $? "$(tail -1 /tmp/acct.log)"
# F8 and pixeltest finding 5: uid 1000 and a group of its own, gid 1000, whatever came first; local.json has both.
acct_ok() {  # $1 = when
  [ "$(id -u tester 2>/dev/null)" = 1000 ] && [ "$(id -g tester 2>/dev/null)" = 1000 ] && [ "$(id -gn tester 2>/dev/null)" = tester ] \
    && grep -q '"uid": 1000,' /etc/breadstick/nix/local.json && [ -d /home/tester ] && [ -s /etc/sudoers.d/zz-breadstick-admin ]
  check "the account ($1): tester is uid 1000, gid 1000 (tester), with its home and sudo rule" $? "$(grep '^tester:' /etc/passwd)"
}
acct_ok "after the account step"
[ "$(cat /home/tester/.local/share/keyrings/default 2>/dev/null)" = login ]; check "the user's desktop keyring" $?

o=$(su tester -s /bin/sh -c 'PATH=/run/wrappers/bin:/usr/local/sbin:/usr/local/bin:/nix/var/nix/profiles/system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin; sudo -n id -u' 2>&1); [ "$o" = 0 ]; check "sudo -n as the user" $? "$o"

s=$($P/bsl-nix status --json); echo "$s" | grep -q '"generation": 1'; check "status: generation 1" $? "$s"
# The user's language at the first start (round 9 review): German from Android, filled in by bsl-nix languages.
mkdir -p /run/bsl
printf 'VERSION=1\nLANGUAGE=de_DE:de\nLANG=de_DE.UTF-8\n' > /run/bsl/region
printf '1\n' > /run/bsl/online; printf '1\n' > /run/bsl/network_metered
$P/bsl-nix languages > /tmp/lang0.log 2>&1; check "languages wait for Wi-Fi" $(( $? != 75 )) "$(tail -1 /tmp/lang0.log)"
printf '0\n' > /run/bsl/network_metered
t $P/bsl-nix languages > /tmp/lang.log 2>&1; r=$?; check "languages: German filled in" $r "$(grep 'languages:' /tmp/lang.log | tail -1)"
[ $r = 0 ] || tail -20 /tmp/lang.log
o=$(LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive locale -a 2>/dev/null | tr '\n' ' ')
case " $o" in *" de_DE.utf8 "*) r=0 ;; *) r=1 ;; esac; check "de_DE.UTF-8 is a locale now" $r "$o"
$P/bsl-nix languages > /tmp/lang2.log 2>&1; check "languages again: nothing to do" $? "$(tail -2 /tmp/lang2.log | head -1)"
G0=$(readlink /nix/var/nix/profiles/system)
$P/bsl-nix add 'hello; reboot' > /tmp/bad.log 2>&1; check "a bad name is refused" $(( $? != 2 )) "$(tail -1 /tmp/bad.log)"
$P/bsl-nix add no-such-package-xyz > /tmp/bad2.log 2>&1; check "a missing package is refused" $(( $? == 0 )) "$(tail -1 /tmp/bad2.log)"
$P/bsl-nix add vscode > /tmp/bad3.log 2>&1; r=$?; grep -q "not free software" /tmp/bad3.log || r=0
check "an unfree package is refused" $(( r == 0 )) "$(grep 'vscode' /tmp/bad3.log | tail -1)"
[ -z "$($P/bsl-nix packages)" ]; check "the list is still empty" $?
# The first change as Get apps, the website's Install and MCP make it: install (add and apply as one). On an image baked
# without documentation it brings documentation back (round 9 review: only apply lifted the trim). add and apply on
# their own are checked below (after gc, and through switch-to-configuration).
trimmed=0; grep -q '"imageTrim": true' /etc/breadstick/nix/local.json && trimmed=1
t $P/bsl-nix install hello > /tmp/apply.log 2>&1; r=$?; check "install hello" $r "$(tail -2 /tmp/apply.log | head -1)"
[ $r = 0 ] || tail -30 /tmp/apply.log
! grep -q "UID change\|removing user" /tmp/apply.log; check "the first apply leaves the account's uid alone" $? "$(grep 'UID change\|removing user' /tmp/apply.log | head -1)"
acct_ok "after the first apply"
[ "$($P/bsl-nix packages)" = hello ]; check "the page's list" $?
if [ $trimmed = 1 ]; then
  ! grep -q '"imageTrim": true' /etc/breadstick/nix/local.json && [ -n "$(ls /run/current-system/sw/share/man/man1 2>/dev/null)" ]
  check "a trimmed image's first install brings documentation back" $? "$(ls /run/current-system/sw/share/man/man1 2>/dev/null | wc -l) pages in man1"
fi
command -v hello >/dev/null && [ "$(hello)" = "Hello, world!" ]; check "hello runs from the PATH" $?
$P/bsl-nix query hello | grep -q "STATUS: install ok installed"; check "query: hello installed" $?
G1=$(readlink /nix/var/nix/profiles/system)
[ "$G1" != "$G0" ]; check "a new generation" $? "$G0 -> $G1"
o=$($P/bsl-nix generations); [ "$(echo "$o" | wc -l)" = 3 ]; check "three generations" $? "$(echo "$o" | tr '\n' ' ')"
t $P/bsl-nix rollback > /tmp/rb.log 2>&1; check "rollback" $? "$(tail -2 /tmp/rb.log | head -1)"
[ "$(readlink /nix/var/nix/profiles/system)" = "$G0" ] && ! command -v hello >/dev/null; check "back on the one before, hello gone" $?
o=$($P/bsl-nix query hello); echo "$o" | grep -q STATUS; check "query: hello not installed after the rollback" $(( $? == 0 ))
t $P/bsl-nix rollback 1 > /tmp/rb2.log 2>&1; check "back to generation 1" $? "$(tail -2 /tmp/rb2.log | head -1)"
# F7: the image's own generation keeps the account (round 9: "removing user 'tester'", then no sudo and no Desktop).
! grep -q "removing user" /tmp/rb2.log; check "the rollback to the image's generation removes no user" $? "$(grep 'removing user' /tmp/rb2.log | head -1)"
acct_ok "after the rollback to generation 1"
o=$(su tester -s /bin/sh -c 'PATH=/run/wrappers/bin:/nix/var/nix/profiles/system/sw/bin; sudo -n id -u' 2>&1); [ "$o" = 0 ]; check "sudo -n as the user on generation 1" $? "$o"
o=$($P/bsl-nix generations --json); echo "$o" | python3 -c 'import json,sys; g=json.load(sys.stdin); sys.exit(0 if g and all(x.get("keepsAccount") for x in g) else 1)'
check "every generation keeps the account (generations --json)" $? "$(echo "$o" | head -c 160)"
# Generation 1 is from before German was filled in: the next start must not build forward again (round 9 review).
$P/bsl-nix languages > /tmp/lang3.log 2>&1; r=$?
[ $r = 4 ] && grep -q "rolled back to" /tmp/lang3.log && [ "$(readlink /nix/var/nix/profiles/system)" = system-1-link ]
check "languages never undo a rollback" $? "rc $r: $(grep 'languages:' /tmp/lang3.log | tail -1)"
$P/bsl-nix rollback > /tmp/rb2b.log 2>&1; check "no generation before 1" $(( $? == 0 )) "$(tail -1 /tmp/rb2b.log)"
t $P/bsl-nix rollback "$(echo "$G1" | sed 's/system-//; s/-link//')" > /tmp/rb3.log 2>&1; check "forward again" $? "$(tail -2 /tmp/rb3.log | head -1)"
# install: add and apply as one; what does not build leaves the list as it was.
$P/bsl-nix install vscode > /tmp/inst.log 2>&1; r=$?
[ $r != 0 ] && [ "$($P/bsl-nix packages)" = hello ]; check "install of what cannot build changes nothing" $? "$(tail -1 /tmp/inst.log)"

# switch-to-configuration against breadstick-systemd (Phase 0's stand-in, now the real supervisor).
mkdir -p /run/dbus
cat > /tmp/sysbus.conf <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>system</type><listen>unix:path=/run/dbus/system_bus_socket</listen><auth>EXTERNAL</auth>
<policy context="default"><allow user="*"/><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>
EOF
$P/dbus-daemon --config-file=/tmp/sysbus.conf --fork --nopidfile
# --no-boot: only the D-Bus surface switch-to-configuration uses is under test here, not NixOS's units under it.
BSL_SYSTEMD_DBUS=1 /usr/lib/breadstick/bsl-systemd --no-boot > /tmp/sd.log 2>&1 &
i=0; until $P/dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:org.freedesktop.systemd1 2>/dev/null | grep -q true || [ $i -ge 60 ]; do sleep 1; i=$((i + 1)); done
check "breadstick-systemd owns systemd1" $(( i >= 60 ))
$P/bsl-nix remove hello > /dev/null 2>&1
t $P/bsl-nix apply > /tmp/sw.log 2>&1; r=$?; check "apply through switch-to-configuration" $r "$(grep -c 'switching to' /tmp/sw.log) switch line(s)"
[ $r = 0 ] || tail -30 /tmp/sw.log
grep -q "switching to" /tmp/sw.log; check "it switched (not activated)" $?

t $P/bsl-nix gc 1 > /tmp/gc.log 2>&1; check "gc" $? "$(grep -E 'freed|deleted' /tmp/gc.log | tail -1)"
# After a clean up the page still works (round 9 review: a gc without nixpkgs' root left nothing to evaluate).
[ -d "$(readlink -f /etc/breadstick/nix/nixpkgs)" ]; check "nixpkgs survives gc" $?
$P/bsl-nix add hello > /tmp/add2.log 2>&1 && t $P/bsl-nix apply > /tmp/apply2.log 2>&1; check "add and apply after gc" $? "$(tail -2 /tmp/apply2.log | head -1)"
# Android 17 refuses /proc/stat to apps, and Nix's garbage collector then warned at every nix command (plan 5.15
# pixeltest finding 5): an unreadable /proc/stat for the user, as on the Pixel; a login shell sets GC_NPROCS.
printf 'x' > /tmp/nostat; chmod 000 /tmp/nostat; mount --bind /tmp/nostat /proc/stat
o=$(su tester -s /bin/sh -c "env -u GC_NPROCS $P/nix-instantiate --eval -E 1+1" 2>&1); echo "$o" | grep -q "GC Warning: Could not open /proc/stat"
check "the probe: without GC_NPROCS Nix warns about /proc/stat" $? "$(echo "$o" | head -1)"
o=$(su - tester -c 'nix-instantiate --eval -E 1+1' 2>&1); echo "$o" | grep -q "GC Warning"
check "a login shell's nix commands do not warn about /proc/stat (GC_NPROCS)" $(( $? == 0 )) "$(echo "$o" | head -1)"
o=$(su tester -s /bin/sh -c "env -u GC_NPROCS $P/bsl-nix generations" 2>&1); echo "$o" | grep -q "GC Warning"
check "bsl-nix's own nix commands do not either (it sets GC_NPROCS)" $(( $? == 0 )) "$(echo "$o" | head -1)"
umount /proc/stat
echo "fails: $fails"
exit $fails
BSL_NIXTEST_RUN_END
zstd -dc "$IMG" | docker import --platform "linux/$ARCH" - "$T" >/dev/null
# An amd64 image runs under qemu-user here, which cannot install a seccomp filter from inside the program (EINVAL):
# Nix's builder filter is off for it (a device's x86-64 kernel takes it).
E=""; [ "$ARCH" = "$(uname -m | sed 's/aarch64/arm64/; s/x86_64/amd64/')" ] || E="filter-syscalls = false"
docker run --name "$C" --platform "linux/$ARCH" --privileged -e NIX_CONFIG="$E" -v "$W:/t:ro" "$T" /bin/sh /t/run.sh
