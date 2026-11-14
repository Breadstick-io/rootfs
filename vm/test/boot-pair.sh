k= i= r=
pick() { [ -f "$1" ] && [ -f "$2" ] && k=$(readlink -f "$1") && i=$(readlink -f "$2"); }
if [ -e /run/current-system/kernel ]; then
  pick /run/current-system/kernel /run/current-system/initrd && r=$(ls /run/current-system/kernel-modules/lib/modules 2>/dev/null | head -n 1)
elif pick /vmlinuz /initrd.img || pick /boot/vmlinuz /boot/initrd.img; then
  r=${k##*/vmlinuz-}
elif [ -f /boot/vmlinuz-linux ]; then
  pick /boot/vmlinuz-linux /boot/initramfs-linux.img
  for d in /usr/lib/modules/*; do [ "$(cat "$d/pkgbase" 2>/dev/null)" = linux ] && r=${d##*/}; done
else
  v=$(grubby --default-kernel 2>/dev/null); v=${v##*/vmlinuz-}
  [ -n "$v" ] || v=$(ls /boot 2>/dev/null | sed -n 's/^vmlinuz-//p' | grep -v rescue | sort -V | tail -n 1)
  [ -n "$v" ] && pick "/boot/vmlinuz-$v" "/boot/initramfs-$v.img" && r=$v
fi
[ -n "$k" ] && [ -n "$i" ] && [ -n "$r" ] || { echo "BSL_BOOT none"; exit 3; }
set -- $(sha256sum "$k" "$i" | cut -d' ' -f1)
echo "BSL_BOOT $r $1 $2 $k $i"
