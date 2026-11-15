sync
cd / || exit 2
exec tar --create --file=- --format=posix --numeric-owner --xattrs --xattrs-include='*' --one-file-system \
  --exclude='./tmp/*' --exclude='./var/tmp/*' --exclude='./lost+found' \
  --exclude='./var/lib/breadstick-vm/restore' --exclude='./var/lib/breadstick-vm/restore/*' \
  --exclude='./var/lib/breadstick-vm/restore.work' \
  --exclude='./var/cache/apt/archives/*.deb' --exclude='./var/cache/pacman/pkg/*' \
  --exclude='./var/cache/libdnf5/*' --exclude='./var/cache/dnf/*' \
  . 2>/var/log/breadstick-vm-backup.log
