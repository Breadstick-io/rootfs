set -e
s=/var/lib/breadstick-vm/restore
w=/var/lib/breadstick-vm/restore.work
[ -d "$s/usr" ] && [ -d "$s/etc" ] || { echo "no system in $s"; exit 3; }
LC_ALL=C
export LC_ALL
nl='
'
rm -rf "$w"
rm -f /var/lib/breadstick-vm/restore-left-out
mkdir -p "$w"
chmod 0700 "$w"
awk '$5 != "/" { print "." $5 }' /proc/self/mountinfo | sort -u > "$w/mounts"
if [ -e /etc/NIXOS ] && [ -d "$s/nix/store" ]; then
  grep -vxF ./nix/store "$w/mounts" > "$w/mounts.1" || true
  echo ./var/empty >> "$w/mounts.1"
  mv -f "$w/mounts.1" "$w/mounts"
  if awk '$5 == "/nix/store" { f = 1 } END { exit !f }' /proc/self/mountinfo; then
    mount -o remount,bind,rw /nix/store 2>/dev/null || mount -o remount,rw /nix/store
  fi
fi
cd "$s"
tar --create --file=- --format=posix --numeric-owner --xattrs --xattrs-include='*' --exclude-from="$w/mounts" --exclude='./usr/lib/breadstick-vm' --exclude='./etc/systemd/system/bsl-*' --exclude='./etc/systemd/system/*.wants/bsl-*' --exclude='./etc/fstab' --exclude='./etc/modules-load.d/breadstick-vm.conf' --exclude='./etc/systemd/journald.conf.d/breadstick-vm.conf' --exclude='./etc/systemd/zram-generator.conf' --exclude='./etc/profile.d/breadstick-vm.sh' --exclude='./etc/sudoers.d/breadstick-vm' --exclude='./etc/hostname' --exclude='./etc/hosts' --exclude='./etc/resolv.conf' --exclude='./etc/machine-id' . \
  | tar --extract --file=- --directory=/ --numeric-owner --same-permissions --xattrs --xattrs-include='*' --keep-directory-symlink
cd /
find / -xdev -name "*$nl*" -prune -o \( -path /usr/lib/breadstick-vm -o -path /var/lib/breadstick-vm -o -path /boot -o -path /usr/lib/modules -o -path /lib/modules -o -path /tmp -o -path /var/tmp -o -path /lost+found -o -path /var/cache/apt/archives -o -path /var/cache/pacman/pkg -o -path /var/cache/libdnf5 -o -path /var/cache/dnf \) -prune -o -print > "$w/all"
while IFS= read -r p; do
  if [ -e "$s$p" ] || [ -L "$s$p" ]; then continue; fi
  case "$p" in /|/usr/lib/breadstick-vm|/etc/systemd/system/bsl-*|/etc/systemd/system/*.wants/bsl-*|/etc/fstab|/etc/modules-load.d/breadstick-vm.conf|/etc/systemd/journald.conf.d/breadstick-vm.conf|/etc/systemd/zram-generator.conf|/etc/profile.d/breadstick-vm.sh|/etc/sudoers.d/breadstick-vm|/etc/hostname|/etc/hosts|/etc/resolv.conf|/etc/machine-id|/var/log/breadstick-vm-*) continue ;; esac
  printf '%s\n' "$p"
done < "$w/all" > "$w/gone"
sort -r "$w/gone" | while IFS= read -r p; do
  if [ -d "$p" ] && [ ! -L "$p" ]; then rmdir "$p" 2>/dev/null || true; else rm -f "$p" || true; fi
done
echo "taken away: $(wc -l < "$w/gone")"
rm -rf "$s" "$w"
sync
echo restored
