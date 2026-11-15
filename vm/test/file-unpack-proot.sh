set -e
s=/var/lib/breadstick-vm/restore
rm -rf "$s"
mkdir -p "$s"
chmod 0700 "$s"
tar --extract --file=- --directory="$s" --numeric-owner --same-permissions --xattrs --xattrs-include='*' --no-same-owner 2>/var/log/breadstick-vm-restore.log
if [ -f "$s/etc/passwd" ]; then
  while IFS=: read -r n x uid gid g home sh; do
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    [ "$uid" -ge 1000 ] && [ "$uid" -le 59999 ] || continue
    case "$home" in /home/?*) ;; *) continue ;; esac
    case "$home" in *..*) continue ;; esac
    [ -d "$s$home" ] && [ ! -L "$s$home" ] || continue
    chown -R -h "$uid:$gid" "$s$home"
    [ "$(stat -c %a "$s$home")" != 755 ] || chmod 0700 "$s$home"
  done < "$s/etc/passwd"
fi
standin() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(wc -c < "$1")" -le 4096 ] && [ "$(head -n 1 "$1")" = '#!/bin/sh' ] || return 1
  grep -q -e 'Breadstick Linux' -e '^exit 0$' -e '^exit 101$' -e '^exec "\$@"$' "$1"
}
for p in usr/local/bin/systemctl usr/local/bin/systemd-tmpfiles usr/local/bin/systemd-sysusers usr/local/bin/setpriv usr/local/bin/dpkg-statoverride usr/bin/systemctl usr/bin/systemd-tmpfiles usr/bin/systemd-sysusers usr/bin/setpriv usr/bin/dpkg-statoverride usr/sbin/policy-rc.d; do
  standin "$s/$p" || continue
  rm -f "$s/$p"
  if [ -f "/$p" ] && ! standin "/$p"; then cp -a "/$p" "$s/$p"; fi
done
for h in 25-systemd-binfmt 36-systemd-modules-load; do
  f=$s/etc/pacman.d/hooks/$h.hook
  if [ -L "$f" ] && [ "$(readlink "$f")" = /dev/null ]; then rm -f "$f"; fi
done
c=$s/etc/pacman.conf
if [ -f "$c" ] && grep -Eq '^# Breadstick Linux \((the image bake|package-fixups)\): no download sandbox under proot\.$' "$c"; then
  awk '/^# Breadstick Linux \((the image bake|package-fixups)\): no download sandbox under proot\.$/ { d = 1; next }
    d && /^[ \t]*DisableSandbox[ \t]*$/ { d = 0; next } { d = 0; print }' "$c" > "$c.bsl-new"
  cat "$c.bsl-new" > "$c"
  rm -f "$c.bsl-new"
fi
