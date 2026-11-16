sync
cd / || exit 2
LC_ALL=C tar --create --file=- --format=posix --numeric-owner --xattrs --xattrs-include='*' --one-file-system \
  --exclude='./tmp/*' --exclude='./lost+found' \
  --exclude='./var/lib/breadstick-vm/restore' --exclude='./var/lib/breadstick-vm/restore/*' \
  --exclude='./var/lib/breadstick-vm/restore.work' \
  . 2>/var/log/breadstick-vm-backup.log
st=$?
log=${BSL_TAR_LOG:-/var/log/breadstick-vm-backup.log}
if [ "$st" = 1 ]; then
  if grep -v -E '^tar: \./var/log/.*: (file changed as we read it|File removed before we read it|File shrank by [0-9]+ bytes; padding with zeros)$|^tar: .*: socket ignored$|^tar: \./(sys|proc|dev|run): file changed as we read it$' "$log" | grep -q .; then
    exit 3
  fi
  exit 0
fi
exit "$st"
