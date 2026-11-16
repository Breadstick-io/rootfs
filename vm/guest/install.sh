#!/bin/sh
# Installs the Breadstick VM guest into a system tree: the three programs (built static by bake-vm.sh, so one
# build serves every distribution), their systemd units and the VM's settings. The same on Debian, Fedora and
# Arch (plan 5.14 V5); NixOS takes nixos/breadstick-vm.nix instead.
#
#   vm/guest/install.sh ROOT BINDIR     # ROOT: the system's / (a bake's chroot, or / inside a container)
#                                       # BINDIR: bsl-vmagent, bsl-vmnet and bsl-x11-relay
#
# What it writes, all outside any package's files:
#   /usr/lib/breadstick-vm/{bsl-vmagent,bsl-vmnet,bsl-x11-relay,vmnet-setup,vmnet.nft}
#   /etc/systemd/system/{bsl-vmagent,bsl-vmnet,bsl-vmnet-setup,bsl-x11-relay}.service, enabled
#   /etc/fstab, /etc/modules-load.d/breadstick-vm.conf, /etc/systemd/journald.conf.d/breadstick-vm.conf,
#   /etc/systemd/zram-generator.conf, /etc/profile.d/breadstick-vm.sh (files/profile.sh, then files/terminal.sh: a
#   Terminal tab gets the agent's runtime dir and bus back after Stop, V9)
#   /etc/sudoers.d/breadstick-vm: NOPASSWD for the administrators' group the system has, sudo (Debian) or wheel
#   (Fedora, Arch); none when it has neither or no /etc/sudoers.d (no sudo installed).
# Units are enabled with the target's own systemctl (chroot when ROOT is not /), so their WantedBy links are the
# ones that system's systemd expects.
set -eu
ROOT="${1:?ROOT}"
BIN="${2:?BINDIR with bsl-vmagent, bsl-vmnet, bsl-x11-relay}"
here=$(cd "$(dirname "$0")" && pwd)
F="$here/files"
ROOT=${ROOT%/}

for p in bsl-vmagent bsl-vmnet bsl-x11-relay; do
  [ -x "$BIN/$p" ] || { echo "install.sh: no $BIN/$p" >&2; exit 2; }
done
mkdir -p "$ROOT/usr/lib/breadstick-vm" "$ROOT/etc/systemd/system" "$ROOT/etc/modules-load.d" \
  "$ROOT/etc/systemd/journald.conf.d" "$ROOT/etc/profile.d"
for p in bsl-vmagent bsl-vmnet bsl-x11-relay; do
  install -m 0755 "$BIN/$p" "$ROOT/usr/lib/breadstick-vm/$p"
done
install -m 0755 "$F/vmnet-setup" "$ROOT/usr/lib/breadstick-vm/vmnet-setup"
install -m 0644 "$F/vmnet.nft" "$ROOT/usr/lib/breadstick-vm/vmnet.nft"
for u in bsl-vmagent bsl-vmnet bsl-vmnet-setup bsl-x11-relay; do
  install -m 0644 "$F/$u.service" "$ROOT/etc/systemd/system/$u.service"
done
install -m 0644 "$F/fstab" "$ROOT/etc/fstab"
install -m 0644 "$F/modules.conf" "$ROOT/etc/modules-load.d/breadstick-vm.conf"
install -m 0644 "$F/journald.conf" "$ROOT/etc/systemd/journald.conf.d/breadstick-vm.conf"
install -m 0644 "$F/zram-generator.conf" "$ROOT/etc/systemd/zram-generator.conf"
cat "$F/profile.sh" "$F/terminal.sh" > "$ROOT/etc/profile.d/breadstick-vm.sh"
chmod 0644 "$ROOT/etc/profile.d/breadstick-vm.sh"

# The administrators' group: the first of sudo and wheel that the system's own /etc/group has.
admin=
for g in sudo wheel; do
  if grep -q "^$g:" "$ROOT/etc/group" 2>/dev/null; then admin=$g; break; fi
done
if [ -n "$admin" ] && [ -d "$ROOT/etc/sudoers.d" ]; then
  sed "s/^%sudo /%$admin /; s/members of sudo /members of $admin /" "$F/sudoers" > "$ROOT/etc/sudoers.d/breadstick-vm"
  chmod 0440 "$ROOT/etc/sudoers.d/breadstick-vm"
else
  echo "install.sh: no sudo or wheel group, or no /etc/sudoers.d: no sudoers rule written" >&2
fi

units="bsl-vmagent.service bsl-vmnet-setup.service bsl-vmnet.service bsl-x11-relay.service"
if [ "$ROOT" = "" ]; then
  # shellcheck disable=SC2086
  systemctl enable $units
else
  # shellcheck disable=SC2086
  chroot "$ROOT" systemctl enable $units
fi
