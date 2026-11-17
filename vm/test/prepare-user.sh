set -u
u='tester'
etc='/etc'
has() { getent group "$1" >/dev/null 2>&1; }
admin= made=
for g in sudo wheel; do has "$g" && { admin=$g; break; }; done
if ! id -u "$u" >/dev/null 2>&1; then
  groups=$admin
  for g in audio video plugdev users; do has "$g" && groups="${groups:+$groups,}$g"; done
  # /bin/bash where it is (Debian's passwd line unchanged), else the system's bash (NixOS), else sh.
  sh=/bin/bash
  [ -x "$sh" ] || sh=$(command -v bash 2>/dev/null) || sh=/bin/sh
  # NixOS: uid 1000 with a group of its own, 1000 (round 12, R11-4). Its useradd gave the group users (100):
  # NixOS's login.defs has no USERGROUPS_ENAB, where Debian's, Fedora's and Arch's make the user's own group.
  # The proot account is uid 1000 with group 1000 (setup-user.sh), and a move between engines keeps owners.
  own=
  if [ -e "$etc/NIXOS" ]; then
    if has "$u"; then own="-g $u"; else own=-U; fi
    getent passwd 1000 >/dev/null 2>&1 || own="$own -u 1000"
  fi
  useradd -m -s "$sh" $own ${groups:+-G "$groups"} "$u" 2>/dev/null || useradd -m -s "$sh" $own ${admin:+-G "$admin"} "$u" || exit 1
  passwd -d "$u" >/dev/null 2>&1 || true
  made=1
  # The account in local.json, as the proot account step records it (bsl-nix account): every generation keeps
  # it, and a move to the Standard engine finds it.
  if [ -e "$etc/NIXOS" ] && [ -x /nix/var/nix/profiles/system/sw/bin/bsl-nix ]; then
    /nix/var/nix/profiles/system/sw/bin/bsl-nix account "$u" </dev/null >/dev/null 2>&1 || echo "bsl-nix account failed"
  fi
fi
f="$etc/sudoers.d/breadstick-vm"
if [ -n "${made:-}" ] && [ -n "$admin" ] && [ -d "$etc/sudoers.d" ] && [ ! -e "$f" ] && [ ! -L "$f" ]; then
  printf '# Breadstick VM: members of %s run anything without a password, as in the Standard engine.\n%%%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$admin" "$admin" > "$f.tmp" &&
    chmod 0440 "$f.tmp" &&
    { ! command -v visudo >/dev/null 2>&1 || visudo -cqf "$f.tmp"; } &&
    mv -f "$f.tmp" "$f" || { rm -f "$f.tmp"; echo "no sudoers rule for $admin"; }
fi
u='tester'
mkdir -p /run/bsl && echo vm > /run/bsl/engine
uid=$(id -u "$u")
# The session's own programs keep files in /run/bsl as the Linux user (bsl-notifyd's
# microphone watcher, mic-v1): its group may add files there, and the sticky bit keeps
# what the app writes as root the app's to replace.
chgrp "$(id -g "$u")" /run/bsl 2>/dev/null && chmod 1775 /run/bsl
# One PulseAudio: the desktop session's (bsl-audio), as on the Standard system. systemd's
# per-user one also loads breadstick.pa, took the stream port first, and the app played
# its silence while every program played into the session's (Lenovo, 2026-10-08).
[ -L /etc/systemd/user/pulseaudio.socket ] || systemctl --global mask pulseaudio.service pulseaudio.socket >/dev/null 2>&1 || true
i=0
while [ ! -S /run/dbus/system_bus_socket ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done
[ -S /run/dbus/system_bus_socket ] || echo "no system bus"
i=0
until loginctl enable-linger "$u" 2>/dev/null; do
  [ $i -lt 50 ] || { echo "no linger for $u"; break; }
  sleep 0.2; i=$((i+1))
done
i=0
while [ ! -S "/run/user/$uid/bus" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
[ -S "/run/user/$uid/bus" ] && echo "bus ok" || echo "no user bus (session apps may complain)"
systemctl --user -M "$u@" stop pulseaudio.socket pulseaudio.service >/dev/null 2>&1 || true
