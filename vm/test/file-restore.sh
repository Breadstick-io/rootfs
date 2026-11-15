set -e
s=/var/lib/breadstick-vm/restore
[ -d "$s/usr" ] && [ -d "$s/etc" ] || { echo "no system in $s"; exit 3; }
cd "$s"
tar --create --file=- --format=posix --numeric-owner --xattrs --xattrs-include='*' \
  --exclude='./usr/lib/breadstick-vm' --exclude='./etc/systemd/system/bsl-*' \
  --exclude='./etc/systemd/system/*.wants/bsl-*' --exclude='./etc/fstab' \
  --exclude='./etc/modules-load.d/breadstick-vm.conf' --exclude='./etc/hostname' --exclude='./etc/resolv.conf' . \
  | tar --extract --file=- --directory=/ --numeric-owner --same-permissions --xattrs --xattrs-include='*' \
      --keep-directory-symlink
cd /
rm -rf "$s"
sync
echo restored
