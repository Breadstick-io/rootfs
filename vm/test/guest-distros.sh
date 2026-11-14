#!/bin/sh
# The VM guest on Debian, Fedora and Arch, without a VM (plan 5.14 V5, V6): in each distribution's own container,
#  1. vm/guest/install.sh puts the static programs, the units and the settings in place, and the units are enabled
#     and pass `systemd-analyze verify` against that system's systemd;
#  2. the sudoers rule names the group the system has (sudo on Debian, wheel on Fedora and Arch) and visudo takes it;
#  3. the app's own user script (vm/test/prepare-user.sh, a copy of Android VmCommands.prepareUserScript("tester"))
#     makes the user in only groups that exist, and `sudo -n true` works for them;
#  4. the static agent, built with a Unix socket in place of vsock (-DTEST_HOST_PATH, the only difference), answers
#     from that system: `i` reports its os-release ID, `r` runs as root and as the user with Debian's PATH.
# Each line "ok" or "FAIL"; any FAIL exits 1. Fedora and Debian run natively on arm64; Arch (x86-64 only) under
# qemu-user 10 (AutoBuild tools/qemu-x86_64-setup.sh). Containers bsl-r8-vmguest-<distro>, removed after; they reach
# the distributions' mirrors to install systemd and sudo, and nothing else.
#   vm/test/guest-distros.sh [debian fedora arch]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
guest=$(cd "$here/../guest" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/bsl-vmguest.XXXXXX")
# The agent's socket in a short folder of its own: a Unix socket path is at most 107 bytes, which a TMPDIR deep in a
# session folder passes.
socks=$(mktemp -d /tmp/bsl-vgs.XXXXXX)
trap 'rm -rf "$work" "$socks"' EXIT
fails=0
DISTROS=${*:-debian fedora arch}

for d in $DISTROS; do
  case $d in
    debian) img=debian:trixie; arch=arm64; prep='apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends systemd sudo passwd python3 >/dev/null' ;;
    fedora) img=fedora:45; arch=arm64; prep='dnf -q -y install systemd sudo shadow-utils passwd util-linux python3 >/dev/null' ;;
    arch) img=archlinux:base; arch=amd64; prep='sed -i "s/^\[options\]$/[options]\nDisableSandbox/; s/^DownloadUser/#DownloadUser/" /etc/pacman.conf; pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinux >/dev/null 2>&1; pacman -Sy --noconfirm --needed sudo python >/dev/null' ;;
    *) echo "unknown distribution $d" >&2; exit 2 ;;
  esac
  case $arch in arm64) plat=linux/arm64 ;; amd64) plat=linux/amd64 ;; esac
  b="$work/$d"
  sock="$socks/$d"
  mkdir -p "$b/bin" "$b/test-bin" "$sock"
  chmod 777 "$sock"
  # The static programs for the image, and the agent once more with a Unix socket for step 4.
  sh "$guest/build.sh" "$arch" "$b/bin" >/dev/null
  if [ "$arch" = "$(dpkg --print-architecture)" ]; then cimg=debian:trixie; else cimg="bsl-debian-trixie:$arch"; fi
  docker run --rm --platform "$plat" -e OWNER="$(id -u):$(id -g)" -v "$guest:/src:ro" -v "$b/test-bin:/out" "$cimg" sh -ec '
    apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends gcc libc6-dev >/dev/null
    gcc -O2 -Wall -pthread -static -DTEST_HOST_PATH="\"/sock/a.sock\"" -o /out/bsl-vmagent /src/bsl-vmagent.c
    chown "$OWNER" /out/bsl-vmagent' >/dev/null
  name="bsl-r8-vmguest-$d"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --platform "$plat" -v "$guest:/g:ro" -v "$b/bin:/bin-static:ro" -v "$b/test-bin:/tb:ro" \
    -v "$here:/t:ro" -v "$sock:/sock" "$img" sleep 3600 >/dev/null
  cx() { docker exec "$name" sh -c "$1"; }
  check() { # name, command in the container
    if out=$(cx "$2" 2>&1); then echo "ok   $d: $1"; else echo "FAIL $d: $1: $(echo "$out" | tail -n 3 | tr '\n' ' ')"; fails=$((fails + 1)); fi
  }
  cx "$prep" || { echo "FAIL $d: could not install systemd and sudo"; fails=$((fails + 1)); docker rm -f "$name" >/dev/null; continue; }
  check "install.sh puts everything in place" 'sh /g/install.sh / /bin-static'
  check "the programs are the static ones" 'for p in bsl-vmagent bsl-vmnet bsl-x11-relay; do test "$(cksum < /bin-static/$p)" = "$(cksum < /usr/lib/breadstick-vm/$p)" || exit 1; done; test -x /usr/lib/breadstick-vm/vmnet-setup'
  check "the four units are enabled" 'for u in bsl-vmagent bsl-vmnet bsl-vmnet-setup bsl-x11-relay; do systemctl is-enabled $u.service | grep -qx enabled; done'
  check "systemd-analyze verify takes the units" 'systemd-analyze verify /etc/systemd/system/bsl-vmagent.service /etc/systemd/system/bsl-vmnet.service /etc/systemd/system/bsl-vmnet-setup.service /etc/systemd/system/bsl-x11-relay.service'
  case $d in debian) g=sudo ;; *) g=wheel ;; esac
  check "the sudoers rule names $g" "grep -qx '%$g ALL=(ALL:ALL) NOPASSWD: ALL' /etc/sudoers.d/breadstick-vm && test \"\$(stat -c %a /etc/sudoers.d/breadstick-vm)\" = 440 && visudo -c >/dev/null"
  # The whole script natively; under qemu-user only its account part (up to the session part's /run/bsl line):
  # `systemctl --user -M tester@` spins forever there with no systemd running (seen on Arch, 2026-11-14).
  if [ "$arch" = "$(dpkg --print-architecture)" ]; then
    check "the app's user script runs (status 0)" 'sh /t/prepare-user.sh >/tmp/prep.log 2>&1; rc=$?; cat /tmp/prep.log; test $rc = 0'
  else
    check "the app's user script's account part runs (status 0)" 'sed "/^mkdir -p \/run\/bsl/,\$d" /t/prepare-user.sh > /tmp/account.sh; grep -q useradd /tmp/account.sh && sh /tmp/account.sh'
  fi
  case $d in
    debian) want='sudo audio video plugdev users' ;;
    *) want='wheel audio video users' ;;
  esac
  check "tester is in: $want" "for x in $want; do id -Gn tester | tr ' ' '\n' | grep -qx \$x || { echo missing \$x; exit 1; }; done"
  check "tester's shell is /bin/bash" 'test "$(getent passwd tester | cut -d: -f7)" = /bin/bash'
  check "sudo -n true as tester" 'su -s /bin/sh tester -c "sudo -n true"'
  check "the script a second time changes nothing" 'cp -a /etc/sudoers.d/breadstick-vm /tmp/s1; cp /etc/group /tmp/g1; if [ -f /tmp/account.sh ]; then sh /tmp/account.sh; else sh /t/prepare-user.sh; fi >/dev/null 2>&1; test "$(cksum < /tmp/s1)" = "$(cksum < /etc/sudoers.d/breadstick-vm)" && test "$(cksum < /tmp/g1)" = "$(cksum < /etc/group)"'
  # Step 4: the agent of this system's userland, over a Unix socket in a shared folder.
  rm -f "$sock/a.sock"
  docker exec -d "$name" sh -c "umask 0; exec /tb/bsl-vmagent"
  i=0; while [ ! -S "$sock/a.sock" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
  case $d in debian) id=debian ;; fedora) id=fedora ;; arch) id=arch ;; esac
  if info=$(python3 "$here/bslvm.py" --unix "$sock/a.sock" info 2>&1) && echo "$info" | grep -qx "agent=2" && echo "$info" | grep -qx "os_id=$id"; then
    echo "ok   $d: the agent reports agent=2 and os_id=$id ($(echo "$info" | grep -e '^os_version_id=' -e '^os_id_like=' | tr '\n' ' '))"
  else echo "FAIL $d: agent info: $(echo "$info" | tr '\n' ' ')"; fails=$((fails + 1)); fi
  out=$(python3 "$here/bslvm.py" --unix "$sock/a.sock" --user tester run 'id -un; echo "$PATH"; command -v sudo; sudo -n id -un' 2>&1 || true)
  if echo "$out" | grep -qx tester && echo "$out" | grep -qx '/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games' && echo "$out" | grep -qx root; then
    echo "ok   $d: run as tester: Debian's user PATH, sudo found and works"
  else echo "FAIL $d: run as tester: $(echo "$out" | tr '\n' ' ')"; fails=$((fails + 1)); fi
  out=$(python3 "$here/bslvm.py" --unix "$sock/a.sock" run 'id -un; echo "$PATH"' 2>&1 || true)
  if echo "$out" | grep -qx root && echo "$out" | grep -qx '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; then
    echo "ok   $d: run as root: Debian's root PATH"
  else echo "FAIL $d: run as root: $(echo "$out" | tr '\n' ' ')"; fails=$((fails + 1)); fi
  docker rm -f "$name" >/dev/null
done
[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails failed"; exit 1; }
