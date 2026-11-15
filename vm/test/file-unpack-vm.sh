set -e
s=/var/lib/breadstick-vm/restore
rm -rf "$s"
mkdir -p "$s"
chmod 0700 "$s"
tar --extract --file=- --directory="$s" --numeric-owner --same-permissions --xattrs --xattrs-include='*' 2>/var/log/breadstick-vm-restore.log
