set -e
s=/var/lib/breadstick-vm/restore
rm -rf "$s"
mkdir -p "$s"
chmod 0700 "$s"
tar --extract --file=- --directory="$s" --numeric-owner --same-permissions --xattrs --xattrs-include='*' --no-same-owner 2>/var/log/breadstick-vm-restore.log
[ -f "$s/etc/passwd" ] || exit 0
while IFS=: read -r n x uid gid g home sh; do
  case "$uid" in ''|*[!0-9]*) continue ;; esac
  [ "$uid" -ge 1000 ] && [ "$uid" -le 59999 ] || continue
  case "$home" in /home/?*) ;; *) continue ;; esac
  case "$home" in *..*) continue ;; esac
  [ -d "$s$home" ] && [ ! -L "$s$home" ] && chown -R -h "$uid:$gid" "$s$home"
done < "$s/etc/passwd"
exit 0
