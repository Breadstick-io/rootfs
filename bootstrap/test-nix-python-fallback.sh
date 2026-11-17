#!/usr/bin/env bash
# R11-5 (4.0 round 12): the app's Python helper commands on the Nix based instance when python3 cannot start. A Nix
# desktop image under the same proot as test-nix-proot.sh, a real X server (Xvfb in bsl-vmtest:3, its socket shared
# with the proot), an xterm window, and the app's own texts (Android GuestPythonTest writes them to
# app/build/guest-python: Close, drag and drop, a GPU check):
#   - before: the 3.x/4.0-round-11 Close text with /usr/bin/python3 gone leaves the window open (the device's R11-5);
#   - Close with /usr/bin/python3: bsl-close closes the window;
#   - Close with /usr/bin/python3 gone and python3 only on PATH (NixOS's profile): bsl-close through it;
#   - Close with no python3 at all: xdotool closes the window;
#   - drag and drop with no python3: exit 77 (the app's "needs an update"), not a refusal;
#   - the GPU check with no python3: exit 127, no shell left behind.
#
#   PROOT=/abs/proot-dir TEXTS=/abs/Android/app/build/guest-python rootfs/bootstrap/test-nix-python-fallback.sh <image.tar.zst>
#
# PASS/FAIL lines; any FAIL exits 1. Containers bsl-r12-nixfix-pyfb-*, removed after.
set -euo pipefail
IMG="${1:?image}"
P="${PROOT:?PROOT=folder with proot and loader/loader}"
T="${TEXTS:?TEXTS=Android app/build/guest-python}"
TAG="${TAG:-bsl-proot-host-build:1}"
C="bsl-r12-nixfix-pyfb-$$"
W="$(mktemp -d)"
U="$(id -u)"; G="$(id -g)"
cleanup() {
  docker rm -f "$C" "$C-x" >/dev/null 2>&1 || true
  # The X server's socket is its container's root's.
  docker run --rm --name "$C-clean" --platform linux/arm64 -v "$W/x11:/x" bsl-vmtest:3 sh -c 'rm -rf /x/* /x/.[!.]*' >/dev/null 2>&1 || true
  [ -d "$W/g" ] && chmod -R u+w "$W/g" 2>/dev/null || true
  rm -rf --one-file-system "$W"
}
trap cleanup EXIT
mkdir -p "$W/bin" "$W/x11" "$W/texts"
chmod 1777 "$W/x11"
cp "$P/proot" "$W/bin/proot"; cp "$P/loader/loader" "$W/bin/loader"
cp "$T/close.sh" "$T/drop.sh" "$T/gpu-check.sh" "$W/texts/"
cp "$IMG" "$W/image.tar.zst"
docker run -d --name "$C-x" --platform linux/arm64 -v "$W/x11:/tmp/.X11-unix" bsl-vmtest:3 Xvfb :7 -nolisten tcp -screen 0 800x600x24 >/dev/null
cat > "$W/run.sh" <<'BSL_NIXPYFB_RUN_END'
#!/bin/sh
set -u
G=/w/g; R=$G/nix
export PROOT_LOADER=/w/bin/loader PROOT_TMP_DIR=$G/tmp
mkdir -p $R $G/tmp $G/shm $G/share
zstd -dc /w/image.tar.zst | tar -xpf - -C $R --no-same-owner 2>$G/tar.err
cp -r /w/texts $G/share/texts
GP=/run/wrappers/bin:/usr/local/sbin:/usr/local/bin:/nix/var/nix/profiles/system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin
B="/w/bin/proot --kill-on-exit --link2symlink --sysvipc"
BINDS="-r $R -b /dev -b /proc -b /sys -b $G/shm:/dev/shm -b $G/share:/mnt/host -b /w/x11:/tmp/.X11-unix"
asroot() { $B -0 $BINDS -w /root /usr/bin/env -i HOME=/root USER=root LOGNAME=root PATH=$GP DISPLAY=:7 TERM=xterm LANG=C.UTF-8 /bin/bash -c "$1"; }
fails=0
check() { if [ "$2" = 0 ]; then echo "PASS $1${3:+: $3}"; else echo "FAIL $1${3:+: $3}"; fails=$((fails + 1)); fi; }
asroot "/nix/var/nix/profiles/system/sw/bin/bsl-nix boot" >/dev/null 2>&1; check "bsl-nix boot" $?
# Python where the session looks (module.nix's link), and where else this system has one.
o=$(asroot 'readlink /usr/bin/python3; command -v python3 || echo "no python3 on PATH"'); echo "python3: $(echo "$o" | tr '\n' ' ')"
# A scenario: an xterm, its window id, [text] run with the id, the window gone within 10 s or not. $1 = name,
# $2 = how python is set up (keep | nopath | none), $3 = the text file, $4 = 0 when the window must close.
scenario() {
  o=$(asroot "
    set -u
    real=\$(readlink /usr/bin/python3)
    case $2 in
      keep) ;;
      nopath|none) rm -f /usr/bin/python3 ;;
    esac
    xterm -geometry 40x5 -e sleep 300 & x=\$!
    i=0; id=; while [ -z \"\$id\" ] && [ \$i -lt 100 ]; do id=\$(xdotool search --pid \$x 2>/dev/null | head -1); sleep 0.1; i=\$((i+1)); done
    [ -n \"\$id\" ] || { echo no-window; kill \$x; ln -sfn \"\$real\" /usr/bin/python3; exit 9; }
    text=\$(sed \"s/123456789/\$id/g\" /mnt/host/texts/$3)
    if [ $2 = none ]; then
      # No python3 anywhere: PATH holds only what the text needs besides the shell.
      mkdir -p /tmp/nopy; ln -sfn \$(command -v xdotool) /tmp/nopy/xdotool
      PATH=/tmp/nopy /bin/sh -c \"\$text\"; rc=\$?
    else
      /bin/sh -c \"\$text\"; rc=\$?
    fi
    # Closed: the X window is gone (what the app watches for; xterm's process may outlive a destroyed window).
    i=0; while xwininfo -id \$id >/dev/null 2>&1 && [ \$i -lt 100 ]; do sleep 0.1; i=\$((i+1)); done
    if xwininfo -id \$id >/dev/null 2>&1; then echo \"rc=\$rc open\"; else echo \"rc=\$rc closed\"; fi
    kill \$x 2>/dev/null
    ln -sfn \"\$real\" /usr/bin/python3
  " 2>&1)
  last=$(echo "$o" | tail -1)
  if [ "$4" = 0 ]; then case "$last" in *closed) r=0 ;; *) r=1 ;; esac; else case "$last" in *open) r=0 ;; *) r=1 ;; esac; fi
  check "$1" $r "$last"
}
# The text before round 12, for the failure the device saw.
printf '%s\n' 'if [ -x /usr/lib/breadstick/bsl-close ]; then exec /usr/bin/python3 -I /usr/lib/breadstick/bsl-close 123456789; fi; xdotool windowclose 123456789 2>/dev/null || xdotool windowkill 123456789 2>/dev/null' > $G/share/texts/close-old.sh
scenario "before (round 11's text): no python3 and Close leaves the window open (R11-5)" none close-old.sh 1
scenario "Close with /usr/bin/python3: bsl-close" keep close.sh 0
scenario "Close with python3 only on PATH" nopath close.sh 0
scenario "Close with no python3: xdotool" none close.sh 0
o=$(asroot "real=\$(readlink /usr/bin/python3); rm -f /usr/bin/python3; mkdir -p /tmp/nopy; PATH=/tmp/nopy /bin/sh -c \"\$(cat /mnt/host/texts/drop.sh)\" bsl-drop 10 20 /mnt/host/x; echo rc=\$?; ln -sfn \"\$real\" /usr/bin/python3" 2>&1)
[ "$(echo "$o" | tail -1)" = rc=77 ]; check "drag and drop with no python3: 77" $? "$(echo "$o" | tail -1)"
o=$(asroot "real=\$(readlink /usr/bin/python3); rm -f /usr/bin/python3; PATH=/tmp/nopy /bin/sh -c \"\$(cat /mnt/host/texts/gpu-check.sh)\"; echo rc=\$?; ln -sfn \"\$real\" /usr/bin/python3" 2>&1)
[ "$(echo "$o" | tail -1)" = rc=127 ]; check "the GPU check with no python3: 127" $? "$(echo "$o" | tail -1)"
o=$(asroot "PATH=/tmp/nopy:\$PATH /bin/sh -c \"\$(cat /mnt/host/texts/drop.sh)\" bsl-drop --window 1 10 20 /mnt/host/none; echo rc=\$?" 2>&1)
echo "drag and drop with python3 and no window: $(echo "$o" | tail -1) (bsl-drop's own answer)"
echo "fails: $fails"
exit $fails
BSL_NIXPYFB_RUN_END
rc=0
docker run --name "$C" --platform linux/arm64 --security-opt seccomp=unconfined -v "$W:/w" "$TAG" sh -c "
  mkdir -p /w/g && chown $U:$G /w/g && exec setpriv --reuid $U --regid $G --clear-groups env HOME=/w/g sh /w/run.sh" || rc=$?
exit $rc
