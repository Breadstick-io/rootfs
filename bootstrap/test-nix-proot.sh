#!/usr/bin/env bash
# A Breadstick-Nix image under the 4.0 proot, as the app runs it, in an arm64 container (round 9, plan 5.9 and 5.14
# P2). The proot is AutoBuild's patched source (build/proot-16kb.sh SRC_ONLY=) compiled natively against glibc, as
# AutoBuild's test/proot-host.sh does: it tests the source's logic, not the vendored bytes, and Android's SELinux, its
# app seccomp and its /proc rules are not here. The image is unpacked by uid 1010195 (an Android user-10 app uid), and
# every command runs through proot with the app's flags and binds (LinuxEnvironment.prootBase/prootBinds/envFor): fake
# root (-0) for the system's own steps, -i 1000:1000 for the user's.
#
#   PROOT=/abs/dir-with-proot-and-loader/loader rootfs/bootstrap/test-nix-proot.sh /abs/nixos-26.05-arm64-desktop-<stamp>.tar.zst
#
# Checks: bsl-nix boot (machine id, activation, tmpfiles, the setuid wrappers), setup-user.sh and bsl-nix account,
# sudo -n as the user through the wrapper, add + apply (one package from cache.nixos.org, the only network use), roll
# back, the same apply through switch-to-configuration against breadstick-systemd and a dbus-daemon inside the proot,
# and garbage collection. PASS/FAIL lines; any FAIL exits 1. Container bsl-r9-nix-proot-*, removed after; its files
# are removed by the container's root.
set -euo pipefail
IMG="${1:?image}"
P="${PROOT:?PROOT=folder with proot and loader/loader}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SETUP_USER="${SETUP_USER:-$HERE/../../Android/app/src/main/assets/setup-user.sh}"
[ -f "$SETUP_USER" ] || { echo "no setup-user.sh: set SETUP_USER" >&2; exit 2; }
TAG="${TAG:-bsl-proot-host-build:1}"
C="bsl-r9-nix-proot-$$"
W="$(mktemp -d)"
cleanup() {
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker run --rm --platform linux/arm64 -v "$W:/w" "$TAG" sh -c 'chmod -R u+w /w/g 2>/dev/null; rm -rf /w/g' >/dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT
mkdir -p "$W/bin"
cp "$P/proot" "$W/bin/proot"; cp "$P/loader/loader" "$W/bin/loader"
cp "$SETUP_USER" "$W/setup-user.sh"; cp "$IMG" "$W/image.tar.zst"
cat > "$W/run.sh" <<'BSL_NIXPROOT_RUN_END'
#!/bin/sh
# As uid 1010195 in the container.
set -u
G=/w/g; R=$G/nix
export PROOT_LOADER=/w/bin/loader PROOT_TMP_DIR=$G/tmp
mkdir -p $R $G/tmp $G/shm $G/share
cp /w/setup-user.sh $G/share/setup-user.sh
echo "[unpack]"; s=$(date +%s)
zstd -dc /w/image.tar.zst | tar -xpf - -C $R --no-same-owner 2>$G/tar.err; echo "  tar rc=$? ($(( $(date +%s) - s )) s, $(wc -l < $G/tar.err) error lines)"
# DNS as the app gives it (LinuxEnvironment writes the guest's resolv.conf; the image has none).
cp /etc/resolv.conf $R/etc/resolv.conf
GP=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/games:/usr/games
B="/w/bin/proot --kill-on-exit --link2symlink --sysvipc"
BINDS="-r $R -b /dev -b /proc -b /sys -b $G/shm:/dev/shm -b $G/share:/mnt/host"
asroot() { $B -0 $BINDS -w /root /usr/bin/env -i HOME=/root USER=root LOGNAME=root PATH=$GP TERM=xterm-256color LANG=C.UTF-8 /bin/bash -lc "$1"; }
asuser() { $B -i 1000:1000 $BINDS -w /home/tester /usr/bin/env -i HOME=/home/tester USER=tester LOGNAME=tester PATH=$GP TERM=xterm-256color LANG=C.UTF-8 /bin/sh -c "$1"; }
N=/nix/var/nix/profiles/system/sw/bin/bsl-nix
fails=0
check() { if [ "$2" = 0 ]; then echo "PASS $1${3:+: $3}"; else echo "FAIL $1${3:+: $3}"; fails=$((fails + 1)); fi; }
t0=$(date +%s); o=$(asroot "$N boot" 2>&1); r=$?; check "bsl-nix boot under proot" $r "$(echo "$o" | tail -1) ($(( $(date +%s) - t0 )) s)"
[ $r = 0 ] || echo "$o" | tail -20
[ -s $R/etc/machine-id ]; check "a machine id" $?
o=$(printf 'secret1\n' | asroot "sh /mnt/host/setup-user.sh tester" 2>&1); check "setup-user.sh" $? "$(echo "$o" | tail -1)"
o=$(asroot "$N account tester" 2>&1); check "bsl-nix account" $? "$(echo "$o" | tail -1)"
o=$(asuser "sudo -n id -u" 2>&1); [ "$(echo "$o" | tail -1)" = 0 ]; check "sudo -n as the user (wrapper, rule by name)" $? "$(echo "$o" | tail -1)"
o=$(asroot "$N add hello" 2>&1); check "add hello" $? "$(echo "$o" | tail -1)"
t0=$(date +%s); o=$(asroot "$N apply" 2>&1); r=$?; check "apply (activation path)" $r "$(echo "$o" | grep -v '^\[BSL\] done' | tail -1) ($(( $(date +%s) - t0 )) s)"
[ $r = 0 ] || echo "$o" | tail -25
o=$(asuser "hello" 2>&1); [ "$o" = "Hello, world!" ]; check "hello as the user" $? "$o"
o=$(asroot "$N rollback" 2>&1); check "rollback" $? "$(echo "$o" | grep -v '^\[BSL\] done' | tail -1)"
o=$(asuser "command -v hello || echo gone" 2>&1); [ "$o" = gone ]; check "hello gone after the rollback" $? "$o"
# switch-to-configuration: a system bus and breadstick-systemd in the same proot as the apply (as the app's
# Linux services run them), then the apply finds the supervisor and switches.
cat > $G/share/sysbus.conf <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>system</type><listen>unix:path=/run/dbus/system_bus_socket</listen><auth>EXTERNAL</auth><auth>ANONYMOUS</auth><allow_anonymous/>
<policy context="default"><allow user="*"/><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>
EOF
t0=$(date +%s)
o=$(asroot "mkdir -p /run/dbus; dbus-daemon --config-file=/mnt/host/sysbus.conf --fork --nopidfile;
  BSL_SYSTEMD_DBUS=1 /usr/lib/breadstick/bsl-systemd --no-boot > /mnt/host/sd.log 2>&1 &
  i=0; until dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:org.freedesktop.systemd1 2>/dev/null | grep -q true || [ \$i -ge 60 ]; do sleep 1; i=\$((i+1)); done
  $N add hello && $N apply; r=\$?; kill %1 2>/dev/null; exit \$r" 2>&1); r=$?
check "apply through switch-to-configuration under proot" $r "$(echo "$o" | grep -c 'switching to') switch line(s), $(( $(date +%s) - t0 )) s"
echo "$o" | grep -q "switching to"; check "it switched" $?
[ $r = 0 ] || { echo "$o" | tail -25; tail -20 $G/share/sd.log; }
o=$(asroot "$N gc 1" 2>&1); check "gc under proot" $? "$(echo "$o" | grep -E 'freed' | tail -1)"
o=$(asroot "nix-store --verify 2>&1 | tail -2; echo rc=\$?" 2>&1); check "the store verifies" $(( $(echo "$o" | grep -c 'rc=0') == 0 )) "$(echo "$o" | tail -1)"
echo "fails: $fails"
exit $fails
BSL_NIXPROOT_RUN_END
chmod 755 "$W" "$W/bin"; chmod 644 "$W"/*.sh "$W/image.tar.zst"; chmod 755 "$W/bin/proot" "$W/bin/loader"
docker run --name "$C" --platform linux/arm64 --security-opt seccomp=unconfined -v "$W:/w" "$TAG" sh -c '
  mkdir -p /w/g && chown 1010195:1010195 /w/g && chmod 755 /w/g &&
  exec setpriv --reuid 1010195 --regid 1010195 --clear-groups env HOME=/w/g sh /w/run.sh'
