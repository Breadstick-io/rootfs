l=/var/lib/breadstick-vm/image-files.gz
[ -s "$l" ] && exit 0
mkdir -p /var/lib/breadstick-vm
nl='
'
find / -xdev -name "*$nl*" -prune -o -print 2>/dev/null | gzip -c > "$l.new"
mv -f "$l.new" "$l"
echo recorded
