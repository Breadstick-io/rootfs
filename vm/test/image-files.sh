l=/var/lib/breadstick-vm/image-files.gz
[ -s "$l" ] && exit 0
mkdir -p /var/lib/breadstick-vm
nl='
'
find / -xdev -name "*$nl*" -prune -o -print 2>/dev/null | gzip -c > "$l.new"
# Only a whole list: a cut-off one would let a restore take away the image's files it misses.
if gzip -t "$l.new" && gzip -dc "$l.new" | grep -qx -e /etc/fstab; then
  mv -f "$l.new" "$l"
  echo recorded
else
  rm -f "$l.new"
  echo "not recorded"
  exit 1
fi
