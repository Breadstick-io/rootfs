sync
cd / || exit 2
cat /proc/self/mountinfo > /run/breadstick-vm-backup.mounts 2>/dev/null || true
LC_ALL=C tar --create --file=- --format=posix --numeric-owner --xattrs --xattrs-include='*' --one-file-system \
  --exclude='./tmp/*' --exclude='./lost+found' \
  --exclude='./var/lib/breadstick-vm/restore' --exclude='./var/lib/breadstick-vm/restore/*' \
  --exclude='./var/lib/breadstick-vm/restore.work' \
  . 2>/var/log/breadstick-vm-backup.log
st=$?
log=${BSL_TAR_LOG:-/var/log/breadstick-vm-backup.log}
if [ "$st" = 1 ]; then
  awk -v mounts="${BSL_MOUNTINFO:-/proc/self/mountinfo /run/breadstick-vm-backup.mounts}" '
    BEGIN {
      c = split(mounts, M, " ")
      for (i = 1; i <= c; i++) {
        while ((getline l < M[i]) > 0) {
          split(l, F, " ")
          p = F[5]
          gsub(/\\040/, " ", p); gsub(/\\011/, "\t", p); gsub(/\\012/, "\n", p); gsub(/\\134/, "\\\\", p)
          if (p != "/") mp["." p] = 1
        }
        close(M[i])
      }
      mp["./tmp"] = 1
    }
    /^tar: \.\/var\/log\/.*: (file changed as we read it|File removed before we read it|File shrank by [0-9]+ bytes; padding with zeros)$/ { next }
    /^tar: .*: socket ignored$/ { next }
    /^tar: .*: file changed as we read it$/ { p = $0; sub(/^tar: /, "", p); sub(/: file changed as we read it$/, "", p); if (p in mp) next }
    { bad = 1 }
    END { exit bad }' "$log" || exit 3
  exit 0
fi
exit "$st"
