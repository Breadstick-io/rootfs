set -u
u='tester'
etc='/etc'
has() { getent group "$1" >/dev/null 2>&1; }
admin=
for g in sudo wheel; do has "$g" && { admin=$g; break; }; done
if ! id -u "$u" >/dev/null 2>&1; then
  groups=$admin
  for g in audio video plugdev users; do has "$g" && groups="${groups:+$groups,}$g"; done
  # /bin/bash where it is (Debian's passwd line unchanged), else the system's bash (NixOS), else sh.
  sh=/bin/bash
  [ -x "$sh" ] || sh=$(command -v bash 2>/dev/null) || sh=/bin/sh
  useradd -m -s "$sh" ${groups:+-G "$groups"} "$u" 2>/dev/null || useradd -m -s "$sh" ${admin:+-G "$admin"} "$u" || exit 1
  passwd -d "$u" >/dev/null 2>&1 || true
elif [ -n "$admin" ] && ! id -Gn "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$admin"; then
  usermod -aG "$admin" "$u" || true
fi
f="$etc/sudoers.d/breadstick-vm"
if [ -n "$admin" ] && [ -d "$etc/sudoers.d" ] && ! grep -qsxF "%$admin ALL=(ALL:ALL) NOPASSWD: ALL" "$f"; then
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
loginctl enable-linger "$u" 2>/dev/null || true
i=0
while [ ! -S "/run/user/$uid/bus" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
[ -S "/run/user/$uid/bus" ] && echo "bus ok" || echo "no user bus (session apps may complain)"
systemctl --user -M "$u@" stop pulseaudio.socket pulseaudio.service >/dev/null 2>&1 || true
