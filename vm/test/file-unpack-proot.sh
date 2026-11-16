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
sr=$(readlink -f "$s")
bsl_instage() {
  q=$(readlink -f "$(dirname "$1")") || return 1
  case "$q/" in "$sr"/*) return 0 ;; esac
  return 1
}
x=breadstick-systemd
d=$s/var/lib/dpkg
if bsl_instage "$d/info/x" && { { [ -f "$d/status" ] && grep -qx "Package: $x" "$d/status"; } || { [ -f "$d/diversions" ] && grep -qx "$x" "$d/diversions"; }; }; then
  : > "$d/$x.bsl-files"
  for l in "$d/info/$x.list" "$d/info/$x:all.list"; do
    if [ -f "$l" ]; then cat "$l" >> "$d/$x.bsl-files"; fi
  done
  if [ -f "$d/status" ] && [ ! -L "$d/status" ]; then
    awk -v x="$x" -v cf="$d/$x.bsl-files" 'BEGIN { RS = ""; ORS = "\n\n" }
      { c = split($0, L, "\n"); m = 0; for (j = 1; j <= c; j++) if (L[j] == "Package: " x) m = 1
        if (!m) { print; next }
        for (j = 1; j <= c; j++) if (L[j] ~ /^ \//) { f = substr(L[j], 2); sub(/ .*/, "", f); printf "%s\n", f >> cf } }' "$d/status" > "$d/status.bsl-new"
    cat "$d/status.bsl-new" > "$d/status"
    rm -f "$d/status.bsl-new"
  fi
  while IFS= read -r f; do
    case "$f" in /?*) ;; *) continue ;; esac
    case "$f" in *..*) continue ;; esac
    if [ -d "$s$f" ] && [ ! -L "$s$f" ]; then continue; fi
    if [ -e "$s$f" ] || [ -L "$s$f" ]; then
      if bsl_instage "$s$f"; then rm -f "$s$f"; fi
    fi
  done < "$d/$x.bsl-files"
  n=0
  dv=$d/diversions
  if [ -f "$dv" ] && [ ! -L "$dv" ]; then
    : > "$dv.bsl-new"
    while IFS= read -r a && IFS= read -r b && IFS= read -r c; do
      if [ "$c" != "$x" ]; then printf '%s\n%s\n%s\n' "$a" "$b" "$c" >> "$dv.bsl-new"; continue; fi
      n=$((n + 1))
      case "$a" in /?*) ;; *) continue ;; esac
      case "$b" in /?*) ;; *) continue ;; esac
      case "$a$b" in *..*) continue ;; esac
      bsl_instage "$s$a" && bsl_instage "$s$b" || continue
      if [ -d "$s$a" ] && [ ! -L "$s$a" ]; then continue; fi
      rm -f "$s$a"
      if [ -f "$s$b" ] || [ -L "$s$b" ]; then mv -f "$s$b" "$s$a"; fi
      if standin "$s$a"; then
        rm -f "$s$a"
        if [ -f "$a" ] && ! standin "$a"; then cp -a "$a" "$s$a"; fi
      fi
    done < "$dv"
    cat "$dv.bsl-new" > "$dv"
    rm -f "$dv.bsl-new"
  fi
  if bsl_instage "$s/var/lib/$x" && [ -d "$s/var/lib/$x" ] && [ ! -L "$s/var/lib/$x" ]; then rm -rf "$s/var/lib/$x"; fi
  rm -f "$d/info/$x".* "$d/info/$x":all.* "$d/$x.bsl-files"
  echo "$x taken out (the VM runs systemd itself): $n diversions undone" >>"${BSL_RESTORE_LOG:-/var/log/breadstick-vm-restore.log}"
fi
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
