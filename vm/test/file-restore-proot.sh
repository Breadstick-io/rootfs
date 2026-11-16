set -e
s=/var/lib/breadstick-vm/restore
w=/var/lib/breadstick-vm/restore.work
[ -d "$s/usr" ] && [ -d "$s/etc" ] || { echo "no system in $s"; exit 3; }
LC_ALL=C
export LC_ALL
nl='
'
rm -rf "$w"
mkdir -p "$w"
chmod 0700 "$w"
find / -xdev -name "*$nl*" -prune -o \( -path /var/lib/breadstick-vm -o -path /home -o -path /tmp -o -path /var/tmp \) -prune -o ! -type d \( ! -uid 0 -o ! -gid 0 \) -printf '%u:%g\t%p\n' > "$w/owners"
if [ -f /var/lib/dpkg/status ]; then cp -p /var/lib/dpkg/status "$w/dpkg-status"; fi
if command -v rpm >/dev/null 2>&1; then
  d=$(rpm -E %_dbpath 2>/dev/null) || d=
  if [ "${d#/}" != "$d" ] && [ -d "$d" ]; then cp -a "$d" "$w/rpmdb"; fi
fi
awk '$5 != "/" { print "." $5 }' /proc/self/mountinfo | sort -u > "$w/mounts"
cd "$s"
tar --create --file=- --format=posix --numeric-owner --xattrs --xattrs-include='*' --exclude-from="$w/mounts" --exclude='./usr/lib/breadstick-vm' --exclude='./etc/systemd/system/bsl-*' --exclude='./etc/systemd/system/*.wants/bsl-*' --exclude='./etc/fstab' --exclude='./etc/modules-load.d/breadstick-vm.conf' --exclude='./etc/systemd/journald.conf.d/breadstick-vm.conf' --exclude='./etc/systemd/zram-generator.conf' --exclude='./etc/profile.d/breadstick-vm.sh' --exclude='./etc/sudoers.d/breadstick-vm' --exclude='./etc/hostname' --exclude='./etc/hosts' --exclude='./etc/resolv.conf' --exclude='./etc/machine-id' . \
  | tar --extract --file=- --directory=/ --numeric-owner --same-permissions --xattrs --xattrs-include='*' --keep-directory-symlink --no-overwrite-dir
cd /
if [ -x /usr/bin/systemd-sysusers ] && [ "$(head -c 4 /usr/bin/systemd-sysusers)" = "$(printf '\177ELF')" ]; then
  /usr/bin/systemd-sysusers >>/var/log/breadstick-vm-restore.log 2>&1 || echo "systemd-sysusers: exit $?"
fi
t=$(printf '\t')
while IFS="$t" read -r o p; do
  [ -e "$s$p" ] || [ -L "$s$p" ] || continue
  if [ -L "$p" ]; then chown -h "$o" "$p" 2>/dev/null || true
  elif [ -e "$p" ]; then m=$(stat -c %a "$p") && chown "$o" "$p" 2>/dev/null && chmod "$m" "$p" || true
  fi
done < "$w/owners"
find / -xdev -name "*$nl*" -prune -o \( -path /usr/lib/breadstick-vm -o -path /var/lib/breadstick-vm -o -path /boot -o -path /usr/lib/modules -o -path /lib/modules -o -path /tmp -o -path /var/tmp -o -path /lost+found -o -path /var/cache/apt/archives -o -path /var/cache/pacman/pkg -o -path /var/cache/libdnf5 -o -path /var/cache/dnf \) -prune -o -print > "$w/all"
while IFS= read -r p; do
  if [ -e "$s$p" ] || [ -L "$s$p" ]; then continue; fi
  case "$p" in /|/usr/lib/breadstick-vm|/etc/systemd/system/bsl-*|/etc/systemd/system/*.wants/bsl-*|/etc/fstab|/etc/modules-load.d/breadstick-vm.conf|/etc/systemd/journald.conf.d/breadstick-vm.conf|/etc/systemd/zram-generator.conf|/etc/profile.d/breadstick-vm.sh|/etc/sudoers.d/breadstick-vm|/etc/hostname|/etc/hosts|/etc/resolv.conf|/etc/machine-id|/var/log/breadstick-vm-*) continue ;; esac
  printf '%s\n' "$p"
done < "$w/all" > "$w/gone"
l=/var/lib/breadstick-vm/image-files.gz
if [ -s "$l" ] && gzip -dc "$l" > "$w/image"; then
  grep -vxF -f "$w/image" "$w/gone" > "$w/gone.1" || true
  mv -f "$w/gone.1" "$w/gone"
else
  : > "$w/gone"
fi
sort -r "$w/gone" | while IFS= read -r p; do
  if [ -d "$p" ] && [ ! -L "$p" ]; then rmdir "$p" 2>/dev/null || true; else rm -f "$p" || true; fi
done
echo "taken away: $(wc -l < "$w/gone")"
if [ -s "$w/dpkg-status" ] && [ -f /var/lib/dpkg/status ]; then
  set +e
  ( set -e
    : > "$w/dpkg-add"
    awk -v info=/var/lib/dpkg/info -v out="$w/dpkg-add" '
      function flush() {
        if (f == 1 && n != "") have[n ":" a] = 1
        if (f == 2 && n != "" && st == "install ok installed" && !((n ":" a) in have) && !((n ":all") in have)) {
          l1 = info "/" n ".list"; l2 = info "/" n ":" a ".list"
          if ((getline x < l1) > 0 || (getline x < l2) > 0) { printf "%s\n", buf > out; k++ }
          close(l1); close(l2)
        }
        n = ""; a = ""; st = ""; buf = ""
      }
      FNR == 1 { flush(); f++ }
      /^$/ { flush(); next }
      { buf = buf $0 "\n" }
      /^Package: / { n = $2 }
      /^Architecture: / { a = $2 }
      /^Status: / { st = substr($0, 9) }
      END { flush(); print k + 0 }' /var/lib/dpkg/status "$w/dpkg-status" > "$w/dpkg-n"
    if [ -s "$w/dpkg-add" ]; then
      { cat /var/lib/dpkg/status; [ -z "$(tail -c 1 /var/lib/dpkg/status)" ] || echo; echo; cat "$w/dpkg-add"; } > /var/lib/dpkg/status.bsl-new
      chmod 0644 /var/lib/dpkg/status.bsl-new
      mv -f /var/lib/dpkg/status.bsl-new /var/lib/dpkg/status
    fi
    echo "package database (dpkg): the VM's own packages put back: $(cat "$w/dpkg-n")"
  )
  r=$?
  set -e
  [ "$r" = 0 ] || echo "package database (dpkg): not put back (exit $r)"
fi
if [ -d "$w/rpmdb" ] && command -v rpm >/dev/null 2>&1; then
  set +e
  ( set -e
    rpm -qa --qf '%{NAME}.%{ARCH}\n' 2>/dev/null | sort -u > "$w/rpm-have"
    rpm --dbpath "$w/rpmdb" -qa --qf '%{NAME}.%{ARCH}\t%{NAME}-%{VERSION}-%{RELEASE}%|ARCH?{.%{ARCH}}:{}|\n' 2>/dev/null | sort -u > "$w/rpm-vm"
    : > "$w/rpm-add"
    cut -f 1 "$w/rpm-vm" | grep -v '^gpg-pubkey[.]' | sort -u | comm -13 "$w/rpm-have" - | while IFS= read -r pk; do
      rpm --dbpath "$w/rpmdb" -q --qf '[%{FILESTATES:fstate} f%{FILEFLAGS:fflags} %{FILENAMES}\n]' "$pk" > "$w/rpm-files" 2>/dev/null || continue
      fs=
      while read -r fs ff fp; do
        [ "$fs" = normal ] || continue
        case "$ff" in *g*|*m*) continue ;; esac
        [ -e "$fp" ] || [ -L "$fp" ] || { fs=missing; break; }
      done < "$w/rpm-files"
      [ "$fs" = missing ] || printf '%s\n' "$pk" >> "$w/rpm-add"
    done
    if [ -s "$w/rpm-add" ]; then
      awk -F '\t' 'FILENAME == ARGV[1] { add[$0] = 1; next } !($1 in add) { print $2 }' "$w/rpm-add" "$w/rpm-vm" > "$w/rpm-drop"
      [ ! -s "$w/rpm-drop" ] || xargs rpm --dbpath "$w/rpmdb" -e --justdb --nodeps --noscripts --notriggers --allmatches < "$w/rpm-drop" 2>>/var/log/breadstick-vm-restore.log
      rpmdb --dbpath "$w/rpmdb" --exportdb | rpmdb --importdb
    fi
    echo "package database (rpm): the VM's own packages put back: $(wc -l < "$w/rpm-add")"
  )
  r=$?
  set -e
  [ "$r" = 0 ] || echo "package database (rpm): not put back (exit $r)"
fi
if [ -d /var/lib/pacman/local ] && [ -d "$s/var/lib/pacman/local" ]; then
  set +e
  ( set -e
    for e in "$s"/var/lib/pacman/local/*/desc; do
      [ ! -f "$e" ] || awk '/^%NAME%$/ { getline; print; exit }' "$e"
    done | sort -u > "$w/pac-have"
    k=0
    for d in /var/lib/pacman/local/*/; do
      d=${d%/}
      [ -f "$d/desc" ] && [ ! -e "$s$d" ] || continue
      pn=$(awk '/^%NAME%$/ { getline; print; exit }' "$d/desc")
      if [ -n "$pn" ] && grep -qxF -e "$pn" "$w/pac-have"; then rm -rf "$d"; else k=$((k + 1)); fi
    done
    echo "package database (pacman): the VM's own packages kept: $k"
  )
  r=$?
  set -e
  [ "$r" = 0 ] || echo "package database (pacman): not checked (exit $r)"
fi
rm -rf "$s" "$w"
sync
echo restored
