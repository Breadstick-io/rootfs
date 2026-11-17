#!/usr/bin/env bash
# The proot half of moving the Nix based instance between the engines (4.0 round 12, plan 5.14 V21; Android
# linux/NixEngineMove.kt). Under the same proot as test-nix-proot.sh (AutoBuild's patched source built natively, the
# app's flags and binds), in an arm64 container, as the host's own uid so the app's Kotlin can work on the tree from
# the host between the steps (as the app does on a restore's staging folder).
#
#   PROOT=/abs/dir-with-proot-and-loader WORK=/abs/empty-or-kept-dir rootfs/bootstrap/test-nix-move-proot.sh make <image.tar.zst> <out.tar>
#     A real Standard instance: the image unpacked, bsl-nix boot, setup-user.sh tester, bsl-nix account, hello added and
#     applied, a file in the home; then its tree as a proot backup holds it (the VM test lays it over the VM).
#   PROOT=... WORK=... test-nix-move-proot.sh unpack <vm-backup.tar>
#     The VM's backup (rootfs vm/test file-backup.sh after NixEngineMove.PREPARE_PROOT) into WORK/g/nix.
#   (the host then runs Android's NixEngineMoveTest with BSL_NIX_MOVE_TREE=WORK/g/nix: NixEngineMove.toProot on it)
#   PROOT=... WORK=... test-nix-move-proot.sh start
#     The moved instance started as the app starts it (bsl-nix boot) and checked: the proot generation runs, local.json
#     says proot, hello and the account and its group 1000 and the file came along, sudo, a rollback to a VM generation
#     is refused, the store verifies.
#   WORK=... test-nix-move-proot.sh clean
#
# PASS/FAIL lines; any FAIL exits 1. Containers bsl-r12-nixfix-move-*, removed after each step.
set -euo pipefail
MODE="${1:?make|unpack|start|clean}"
HERE="$(cd "$(dirname "$0")" && pwd)"
W="${WORK:?WORK=folder}"
TAG="${TAG:-bsl-proot-host-build:1}"
C="bsl-r12-nixfix-move-$MODE-$$"
U="$(id -u)"; G="$(id -g)"
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
mkdir -p "$W/bin"
if [ "$MODE" = clean ]; then
  [ -d "$W/g" ] && chmod -R u+w "$W/g" 2>/dev/null || true
  rm -rf --one-file-system "$W/g"
  exit 0
fi
P="${PROOT:?PROOT=folder with proot and loader/loader}"
cp "$P/proot" "$W/bin/proot"; cp "$P/loader/loader" "$W/bin/loader"
SETUP_USER="${SETUP_USER:-$HERE/../../Android/app/src/main/assets/setup-user.sh}"
cp "$SETUP_USER" "$W/setup-user.sh"
case "$MODE" in
  make) cp "${2:?image}" "$W/image.tar.zst"; OUT="${3:?out.tar}" ;;
  unpack) IN="$(cd "$(dirname "${2:?vm backup}")" && pwd)/$(basename "$2")" ;;
  start) ;;
  *) echo "usage: $0 make|unpack|start|clean" >&2; exit 2 ;;
esac
cat > "$W/run.sh" <<'BSL_NIXMOVE_RUN_END'
#!/bin/sh
set -u
MODE=$1
G=/w/g; R=$G/nix
export PROOT_LOADER=/w/bin/loader PROOT_TMP_DIR=$G/tmp
mkdir -p $R $G/tmp $G/shm $G/share
cp /w/setup-user.sh $G/share/setup-user.sh
GP=/run/wrappers/bin:/usr/local/sbin:/usr/local/bin:/nix/var/nix/profiles/system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin
B="/w/bin/proot --kill-on-exit --link2symlink --sysvipc"
BINDS="-r $R -b /dev -b /proc -b /sys -b $G/shm:/dev/shm -b $G/share:/mnt/host"
asroot() { $B -0 $BINDS -w /root /usr/bin/env -i HOME=/root USER=root LOGNAME=root PATH=$GP TERM=xterm-256color LANG=C.UTF-8 /bin/bash -lc "$1"; }
asuser() { $B -i 1000:1000 $BINDS -w /home/tester /usr/bin/env -i HOME=/home/tester USER=tester LOGNAME=tester PATH=$GP TERM=xterm-256color LANG=C.UTF-8 /bin/sh -c "$1"; }
N=/nix/var/nix/profiles/system/sw/bin/bsl-nix
fails=0
check() { if [ "$2" = 0 ]; then echo "PASS $1${3:+: $3}"; else echo "FAIL $1${3:+: $3}"; fails=$((fails + 1)); fi; }
case "$MODE" in
make)
  zstd -dc /w/image.tar.zst | tar -xpf - -C $R --no-same-owner 2>$G/tar.err; check "unpack the image" $? "$(wc -l < $G/tar.err) error lines"
  cp /etc/resolv.conf $R/etc/resolv.conf
  o=$(asroot "$N boot" 2>&1); check "bsl-nix boot" $? "$(echo "$o" | tail -1)"
  o=$(printf 'secret1\n' | asroot "sh /mnt/host/setup-user.sh tester" 2>&1); check "setup-user.sh" $? "$(echo "$o" | tail -1)"
  o=$(asroot "$N account tester" 2>&1); check "bsl-nix account" $? "$(echo "$o" | tail -1)"
  o=$(asroot "$N add hello && $N apply" 2>&1); r=$?; check "add hello, apply" $r "$(echo "$o" | grep -v '^\[BSL\] done' | tail -1)"
  [ $r = 0 ] || echo "$o" | tail -20
  o=$(asuser "echo moved-with-me > /home/tester/move-marker; hello" 2>&1); [ "$o" = "Hello, world!" ]; check "hello as the user" $? "$o"
  o=$(asroot "$N status --json" 2>&1); echo "status: $(echo "$o" | tail -1)"
  # As a Standard instance's backup holds it: no session marker, no /run (the backup leaves out what the app does).
  rm -rf $R/run/* $R/tmp/* 2>/dev/null
  ( cd $R && tar --numeric-owner -cf /w/instance.tar . ); check "the instance's tree as a tar" $? "$(du -h /w/instance.tar | cut -f1)"
  ;;
unpack)
  tar -xpf /w/vm-backup.tar -C $R --no-same-owner 2>$G/tar.err; check "unpack the VM's backup" $? "$(wc -l < $G/tar.err) error lines"
  grep -v -e 'Cannot mknod' -e 'Cannot change ownership' $G/tar.err | head -5
  cp /etc/resolv.conf $R/etc/resolv.conf
  ;;
start)
  o=$(asroot "$N boot" 2>&1); r=$?; check "bsl-nix boot of the moved instance" $r "$(echo "$o" | tail -1)"
  [ $r = 0 ] || echo "$o" | tail -20
  o=$(asroot "$N status --json" 2>&1); echo "status: $(echo "$o" | tail -1)"
  echo "$o" | tail -1 | grep -q '"engine": "proot"'; check "local.json: the proot engine" $?
  cur=$(asroot "readlink -f /run/current-system" 2>&1); new=$(asroot "readlink -f /nix/var/nix/profiles/system" 2>&1)
  [ -n "$cur" ] && [ "$cur" = "$new" ] && [ ! -e "$R$cur/kernel" ]; check "the running generation is the newest, built for proot" $? "$cur"
  o=$(asroot "ls /nix/var/nix/profiles | tr '\n' ' '" 2>&1); echo "profiles: $o"
  o=$(asroot "id tester" 2>&1); echo "$o" | grep -q 'uid=1000(tester) gid=1000(tester)'; check "the account: uid 1000, its own group 1000" $? "$o"
  o=$(asuser "cat /home/tester/move-marker; cat /home/tester/vm-marker; hello" 2>&1)
  [ "$o" = "$(printf 'moved-with-me\nmade-in-the-vm\nHello, world!')" ]; check "the files from both engines and hello" $? "$(echo "$o" | tr '\n' '|')"
  o=$(asuser "sudo -n id -u" 2>&1); [ "$(echo "$o" | tail -1)" = 0 ]; check "sudo -n as the user" $? "$(echo "$o" | tail -1)"
  vmgen=$(asroot "for l in /nix/var/nix/profiles/system-*-link; do [ -e \$l/kernel ] && { n=\${l##*system-}; echo \${n%-link}; }; done | tail -1" 2>&1)
  o=$(asroot "$N rollback $vmgen" 2>&1); r=$?; [ $r = 3 ]; check "a rollback to the VM's generation $vmgen is refused" $? "rc $r: $(echo "$o" | tail -1)"
  o=$(asroot "$N add cowsay && $N apply" 2>&1); r=$?; check "an apply under proot after the move" $r "$(echo "$o" | grep -v '^\[BSL\] done' | tail -1)"
  o=$(asuser "cowsay moo | head -1" 2>&1); check "cowsay as the user" $([ -n "$o" ] && echo 0 || echo 1) "$o"
  o=$(asroot "nix-store --verify 2>&1 | tail -2; echo rc=\$?" 2>&1); check "the store verifies" $(( $(echo "$o" | grep -c 'rc=0') == 0 )) "$(echo "$o" | tail -1)"
  ;;
esac
echo "fails: $fails"
exit $fails
BSL_NIXMOVE_RUN_END
[ "$MODE" = unpack ] && cp "$IN" "$W/vm-backup.tar"
rc=0
docker run --name "$C" --platform linux/arm64 --security-opt seccomp=unconfined -v "$W:/w" "$TAG" sh -c "
  mkdir -p /w/g && chown $U:$G /w/g && exec setpriv --reuid $U --regid $G --clear-groups env HOME=/w/g sh /w/run.sh $MODE" || rc=$?
[ "$MODE" = make ] && mv -f "$W/instance.tar" "$OUT"
[ "$MODE" = unpack ] && rm -f "$W/vm-backup.tar"
exit $rc
