#!/usr/bin/env bash
# The Breadstick desktop session on a Breadstick-Nix image under the 4.0 proot, as the app starts it (round 9 review,
# plan 5.9 and 5.14): the account step as NixSystem.userSetupScript writes it, `bsl-nix keyrings` as
# LinuxEnvironment.nixSessionSteps runs it, then the session script on an Xvfb display, through proot with the app's
# flags, binds and environment (fake root, PATH as GuestEnv.NIX_PATH). The proot is AutoBuild's patched source built
# natively (as test-nix-proot.sh); Android's SELinux, its app seccomp and its /proc rules are not here, and nothing is
# drawn on a device. LOCAL ONLY: no network is used (the language fill is left for Wi-Fi: /run/bsl says mobile data).
#
#   PROOT=/abs/dir-with-proot-and-loader/loader rootfs/bootstrap/test-nix-session.sh /abs/nixos-26.05-arm64-desktop-<stamp>.tar.zst
#   (a lib/ folder beside them, e.g. libtalloc.so.2, is put on proot's own library path: the session image has no talloc)
#   SETUP_USER=/abs/Android/app/src/main/assets/setup-user.sh   (default: the Android checkout beside this one)
#   TAG=<an arm64 Debian image with Xvfb, xwininfo and setpriv>  (default bsl-desk-proot-test:1)
#
# Checks what the review found broken: /usr/local's shims found by the session (bsl-audio, bsl-notifyd), the notification
# bridge running, the Breadstick look applied (not stock XFCE), xsetroot and xrdb there, dconf and the keyring
# reachable (no dconf or gnome-keyring errors), the user's keyring, Breadstick's GTK programs from an `env -i`, and no
# Python traceback. PASS/FAIL lines; any FAIL exits 1. Container bsl-r9-nix-session-*, removed after; its files are
# removed by the container's root.
set -euo pipefail
IMG="${1:?image}"
P="${PROOT:?PROOT=folder with proot and loader/loader}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SETUP_USER="${SETUP_USER:-$HERE/../../Android/app/src/main/assets/setup-user.sh}"
[ -f "$SETUP_USER" ] || { echo "no setup-user.sh: set SETUP_USER" >&2; exit 2; }
TAG="${TAG:-bsl-desk-proot-test:1}"
C="bsl-r9-nix-session-$$"
W="$(mktemp -d)"
cleanup() {
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker run --rm --platform linux/arm64 -v "$W:/w" "$TAG" sh -c 'chmod -R u+w /w/g 2>/dev/null; rm -rf /w/g' >/dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT
mkdir -p "$W/bin"
cp "$P/proot" "$W/bin/proot"; cp "$P/loader/loader" "$W/bin/loader"
mkdir -p "$W/bin/lib"; [ -d "$P/lib" ] && cp "$P"/lib/* "$W/bin/lib/"
cp "$SETUP_USER" "$W/setup-user.sh"
zstd -dc "$IMG" > "$W/image.tar"
cat > "$W/run.sh" <<'BSL_NIXSESSION_RUN_END'
#!/bin/sh
# As uid 1010195 in the container.
set -u
G=/w/g; R=$G/nix
export PROOT_LOADER=/w/bin/loader PROOT_TMP_DIR=$G/tmp
mkdir -p $R $G/tmp $G/shm $G/share
tar -xpf /w/image.tar -C $R --no-same-owner 2>$G/tar.err; echo "[unpack] tar rc=$? ($(wc -l < $G/tar.err) error lines)"
cp /etc/resolv.conf $R/etc/resolv.conf
# What the app writes before the account step and the session (ensureSystemConfig, the bridges).
mkdir -p $R/run/bsl $R/root/.breadstick
printf 'breadstick\n' > $R/etc/hostname
printf 'VERSION=1\nLANGUAGE=de_DE:de\nLANG=de_DE.UTF-8\nREGION=DE\nTZ=Europe/Berlin\n' > $R/run/bsl/region
printf '1\n' > $R/run/bsl/online; printf '1\n' > $R/run/bsl/network_metered
printf 'notify-v2 clipboard-v1 print-v1 nested-apps-v1 gpu-v2 media-v1 region-v1 settings-v1 gpu-live-v1 mic-v1 theme-v1 cursor-v1 ai-v1 pad-v1 camera-v2\n' > $R/run/bsl/features
cp /w/setup-user.sh $R/root/.breadstick/setup-user.sh
GP=/run/wrappers/bin:/usr/local/sbin:/usr/local/bin:/nix/var/nix/profiles/system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin
# proot's own library path only: the env -i after it gives the guest none of it.
B="env LD_LIBRARY_PATH=/w/bin/lib /w/bin/proot --kill-on-exit --link2symlink --sysvipc"
BINDS="-r $R -b /dev -b /proc -b /sys -b $G/shm:/dev/shm -b $G/share:/mnt/host -b /tmp/.X11-unix:/tmp/.X11-unix"
asroot() { $B -0 $BINDS -w /root /usr/bin/env -i HOME=/root USER=root LOGNAME=root PATH=$GP ADW_DISABLE_PORTAL=1 TERM=xterm-256color LANG=C.UTF-8 LIBGL_KOPPER_DISABLE=1 /bin/bash -lc "$1"; }
asuser() { $B -i 1000:1000 $BINDS -w /home/tester /usr/bin/env -i HOME=/home/tester USER=tester LOGNAME=tester PATH=$GP TERM=xterm-256color LANG=C.UTF-8 DISPLAY=:0 "$@"; }
N=/nix/var/nix/profiles/system/sw/bin/bsl-nix
fails=0
check() { if [ "$2" = 0 ]; then echo "PASS $1${3:+: $3}"; else echo "FAIL $1${3:+: $3}"; fails=$((fails + 1)); fi; }
# The account step as NixSystem.userSetupScript writes it, then the start's keyrings step.
printf 'secret1\n' | asroot "$N boot </dev/null >/dev/null 2>&1; sh /root/.breadstick/setup-user.sh 'tester' && { $N account tester </dev/null >/dev/null 2>&1 || true; }" > $G/acct.log 2>&1
check "the account step" $? "$(tail -1 $G/acct.log)"
o=$(asroot "$N keyrings" 2>&1); check "bsl-nix keyrings" $? "$(echo "$o" | tail -1)"
[ "$(cat $R/home/tester/.local/share/keyrings/default 2>/dev/null)" = login ]; check "the user's keyring" $?
o=$(asroot "$N languages" 2>&1); r=$?; check "languages left for Wi-Fi (status 75)" $(( r != 75 )) "$(echo "$o" | tail -1)"
o=$(asuser python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk; print('gtk ok')" 2>&1 | tail -1)
[ "$o" = "gtk ok" ]; check "Breadstick's Python with GTK from env -i (the Apps drawer)" $? "$o"

Xvfb :0 -screen 0 1600x1000x24 -nolisten tcp >$G/xvfb.log 2>&1 &
XP=$!
sleep 2
( asroot "export BREADSTICK_WAYLAND=0 BREADSTICK_COMPOSITOR=0 BREADSTICK_DARK=0 BREADSTICK_LOCALE=de_DE.UTF-8 BREADSTICK_DPI=96 BREADSTICK_GPU=0; export BREADSTICK_VOLUMES=''; sh /usr/lib/breadstick/start-desktop-x11.sh 0 tester 0" > $G/share/session.log 2>&1 ) &
SP=$!
sleep 50
L=$G/share/session.log
kill -0 $SP 2>/dev/null; check "the session is up after 50 s" $?
! grep -q "command not found" $L; check "no command not found" $? "$(grep 'command not found' $L | head -2 | tr '\n' ' ')"
grep -q "notification bridge: running" $L; check "the notification bridge runs" $? "$(grep 'notification bridge' $L | head -1)"
! grep -q "look: theme assets missing" $L; check "the look is not skipped" $?
[ -n "$(ls $R/home/tester/.config/xfce4/xfconf/xfce-perchannel-xml/.bsl-look-v* 2>/dev/null)" ]; check "the look's stamp" $?
grep -q 'Breadstick' $R/home/tester/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml 2>/dev/null; check "GTK on the Breadstick theme" $?
grep -q "audio: pulseaudio running" $L; check "PulseAudio runs with Breadstick's modules" $? "$(grep 'audio:' $L | head -1)"
! grep -q "dconf-WARNING" $L; check "no dconf warnings" $? "$(grep -c dconf-WARNING $L) line(s)"
! grep -qE "gnome-keyring-daemon.*(No such file|aborting)" $L; check "the keyring's autostart runs" $? "$(grep gnome-keyring $L | head -1)"
# (The run has no capabilities, as an Android app: see the docker run below.)
! grep -qE "xsetroot failed|xrdb: command not found" $L; check "xsetroot and xrdb" $?
! grep -q Traceback $L; check "no Python traceback" $?
DISPLAY=:0 xwininfo -root -tree 2>/dev/null > $G/tree.txt
grep -q '"xfce4-panel"' $G/tree.txt; check "the shelf's panel is up" $?
grep -q 'status.py' $G/tree.txt; check "Breadstick's status area is up" $?
echo "== session log (first 60 lines)"; head -60 $L
kill $SP 2>/dev/null; sleep 1; kill $XP 2>/dev/null
echo "fails: $fails"
exit $fails
BSL_NIXSESSION_RUN_END
chmod 755 "$W" "$W/bin" "$W/bin/lib"; chmod 644 "$W"/*.sh "$W/image.tar"; chmod -R a+r "$W/bin/lib"; chmod 755 "$W/bin/proot" "$W/bin/loader"
# The folder made by the container's root, then the run as the app's uid with no capabilities at all, as an Android app
# has none (with a container's partial set, gnome-keyring aborts by design; setpriv alone does not drop them).
docker run --rm --platform linux/arm64 -v "$W:/w" "$TAG" sh -c 'mkdir -p /w/g && chown 1010195:1010195 /w/g && chmod 755 /w/g'
docker run --name "$C" --platform linux/arm64 --security-opt seccomp=unconfined --cap-drop ALL --user 1010195:1010195 \
  -e HOME=/w/g -v "$W:/w" "$TAG" sh -c 'mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix; grep CapEff /proc/self/status; exec sh /w/run.sh'
