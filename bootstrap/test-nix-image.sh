#!/usr/bin/env bash
# A Breadstick-Nix image as a device's first start uses it, in a container (4.0, plan 5.9; round 9). Not proot: the
# image's own NixOS, as real root in Docker, so it tests what bootstrap-nix.sh baked and what bsl-nix does with it
# (the stage-2 stand-in, the account step, the Nix packages page's operations, switch-to-configuration against
# breadstick-systemd), never the app's proot. LOCAL ONLY: the container reaches cache.nixos.org for the one package
# it adds (hello) and nothing else; nothing is signed or uploaded.
#
#   rootfs/bootstrap/test-nix-image.sh /abs/nixos-26.05-arm64-desktop-<stamp>.tar.zst [arm64|amd64]
#   SETUP_USER=/abs/Android/app/src/main/assets/setup-user.sh   (default: the Android checkout beside this one)
#
# Each check prints PASS or FAIL; any FAIL exits 1. Containers and images bsl-r9-nix-test-*, removed after.
set -euo pipefail
IMG="${1:?image}"
ARCH="${2:-arm64}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SETUP_USER="${SETUP_USER:-$HERE/../../Android/app/src/main/assets/setup-user.sh}"
[ -f "$SETUP_USER" ] || SETUP_USER="$HERE/../../plan-4.0-android/app/src/main/assets/setup-user.sh"
[ -f "$SETUP_USER" ] || { echo "no setup-user.sh: set SETUP_USER" >&2; exit 2; }
T="bsl-r9-nix-test:$ARCH-$$"
C="bsl-r9-nix-test-$ARCH-$$"
W="$(mktemp -d)"
cleanup() { docker rm -f "$C" >/dev/null 2>&1 || true; docker rmi -f "$T" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
cp "$SETUP_USER" "$W/setup-user.sh"
cat > "$W/run.sh" <<'BSL_NIXTEST_RUN_END'
#!/bin/sh
# In the image's own NixOS, as root. PATH as the app gives every Breadstick system (GuestEnv.PATH).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
P=/nix/var/nix/profiles/system/sw/bin
fails=0
check() { if [ "$2" = 0 ]; then echo "PASS $1${3:+: $3}"; else echo "FAIL $1${3:+: $3}"; fails=$((fails + 1)); fi; }
t() { s=$(date +%s); "$@"; r=$?; echo "  ($(( $(date +%s) - s )) s)"; return $r; }

[ -s /etc/machine-id ]; check "the image's machine id is empty" $(( $? == 0 ))
t $P/bsl-nix boot > /tmp/boot.log 2>&1; check "bsl-nix boot" $? "$(tail -1 /tmp/boot.log)"
[ -s /etc/machine-id ]; check "boot made a machine id" $?
[ -x /run/wrappers/bin/sudo ] && [ -u "$(readlink -f /run/wrappers/bin/sudo)" -o -u /run/wrappers/bin/sudo ]; check "setuid sudo wrapper" $?
[ -L /usr/local/bin ] && [ -x /usr/local/bin/xfce4-session ] && [ -e /usr/lib/breadstick/start-desktop-x11.sh ]; check "the paths Breadstick systems have" $?
grep -q '^ID=nixos' /etc/os-release; check "os-release says nixos" $?
[ "$(cat /etc/breadstick/version)" = "$(cat /etc/breadstick/nix/src/VERSION)" ]; check "Breadstick's version in /etc" $? "$(cat /etc/breadstick/version)"
# The shell programs' Python finds GTK 3 (GI_TYPELIB_PATH from the system's environment, as a login shell gets it), and
# the session script parses.
o=$(bash -lc "python3 -c \"import gi; gi.require_version('Gtk', '3.0'); gi.require_version('Gdk', '3.0'); from gi.repository import Gtk, Gdk, Pango, GdkPixbuf; import dbus, cairo; print('gi ok')\"" 2>&1)
[ "$o" = "gi ok" ]; check "Python with GTK 3, D-Bus and cairo" $? "$(echo "$o" | tail -1)"
sh -n /usr/lib/breadstick/start-desktop-x11.sh; check "the session script parses" $?
for p in xfce4-session xfwm4 xfce4-panel xfdesktop xfsettingsd xfce4-terminal thunar openbox xdotool wmctrl pulseaudio dbus-daemon tmux; do
  command -v $p >/dev/null || { echo "  missing $p"; miss=1; }
done
check "the desktop's programs" ${miss:-0}

# The app's account step: setup-user.sh (the asset, unchanged), then bsl-nix account.
printf 'secret1\n' | sh /t/setup-user.sh tester > /tmp/user.log 2>&1; r=$?
check "setup-user.sh" $r "$(tail -1 /tmp/user.log)"
$P/bsl-nix account tester > /tmp/acct.log 2>&1; check "bsl-nix account" $? "$(tail -1 /tmp/acct.log)"
o=$(su tester -s /bin/sh -c 'PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin; sudo -n id -u' 2>&1); [ "$o" = 0 ]; check "sudo -n as the user" $? "$o"

s=$($P/bsl-nix status --json); echo "$s" | grep -q '"generation": 1'; check "status: generation 1" $? "$s"
$P/bsl-nix add 'hello; reboot' > /tmp/bad.log 2>&1; check "a bad name is refused" $(( $? != 2 )) "$(tail -1 /tmp/bad.log)"
$P/bsl-nix add no-such-package-xyz > /tmp/bad2.log 2>&1; check "a missing package is refused" $(( $? == 0 )) "$(tail -1 /tmp/bad2.log)"
$P/bsl-nix add hello > /tmp/add.log 2>&1; check "add hello" $? "$(tail -1 /tmp/add.log)"
[ "$($P/bsl-nix packages)" = hello ]; check "the page's list" $?
t $P/bsl-nix apply > /tmp/apply.log 2>&1; r=$?; check "apply" $r "$(tail -2 /tmp/apply.log | head -1)"
[ $r = 0 ] || tail -30 /tmp/apply.log
command -v hello >/dev/null && [ "$(hello)" = "Hello, world!" ]; check "hello runs from the PATH" $?
[ "$(readlink /nix/var/nix/profiles/system)" = system-2-link ]; check "generation 2" $?
o=$($P/bsl-nix generations); [ "$(echo "$o" | wc -l)" = 2 ]; check "two generations" $? "$(echo "$o" | tr '\n' ' ')"
t $P/bsl-nix rollback > /tmp/rb.log 2>&1; check "rollback" $? "$(tail -2 /tmp/rb.log | head -1)"
[ "$(readlink /nix/var/nix/profiles/system)" = system-1-link ] && ! command -v hello >/dev/null; check "back on 1, hello gone" $?
$P/bsl-nix rollback > /tmp/rb2.log 2>&1; check "no generation before 1" $(( $? == 0 )) "$(tail -1 /tmp/rb2.log)"
t $P/bsl-nix rollback 2 > /tmp/rb3.log 2>&1; check "forward to 2" $? "$(tail -2 /tmp/rb3.log | head -1)"

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
echo "fails: $fails"
exit $fails
BSL_NIXTEST_RUN_END
zstd -dc "$IMG" | docker import --platform "linux/$ARCH" - "$T" >/dev/null
docker run --name "$C" --platform "linux/$ARCH" --privileged -v "$W:/t:ro" "$T" /bin/sh /t/run.sh
