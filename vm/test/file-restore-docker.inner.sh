#!/bin/sh
# Inside a throwaway debian:trixie container (file-restore-docker.sh): the container's own / plays the VM's system, and
# the app's restore scripts (the copies in /t, checked against the app by VmFileBackupTest) run on it exactly as the VM
# runs them through its agent. Two restores: a proot system's backup (made from a copy of this system with proot's
# stand-ins, Arch's masks and DisableSandbox line put in, every folder 0755 as a 3.x backup stores them, and files the
# image never had) and then a VM's own backup (file-backup.sh of the system as it is then). Prints one "name: value"
# line per check. Then (round 12 review) a NixOS-shaped VM restore whose tools are store paths the backup lacks.
# Destroys the container's system on purpose: never run it anywhere else.
set -u
[ -f /.dockerenv ] || { echo "only inside the test's container" >&2; exit 2; }
say() { printf '%s: %s\n' "$1" "$2"; }
yn() { if "$@"; then echo yes; else echo no; fi; }
mode() { stat -c %a "$1" 2>/dev/null; }

# 1. The VM's "image": the guest's files, a real program for each stand-in name, the VM's hosts file, a group-owned file.
mkdir -p /usr/lib/breadstick-vm /etc/systemd/system/multi-user.target.wants /var/lib/breadstick-vm
printf 'agent\n' > /usr/lib/breadstick-vm/bsl-vmagent
printf '[Unit]\n' > /etc/systemd/system/bsl-vmagent.service
ln -s ../bsl-vmagent.service /etc/systemd/system/multi-user.target.wants/bsl-vmagent.service
# Docker's Debian images carry a policy-rc.d of their own; a VM image has none.
rm -f /usr/sbin/policy-rc.d
cp /bin/true /usr/bin/systemctl
cp /bin/true /usr/bin/systemd-tmpfiles
printf '127.0.0.1 localhost\n127.0.1.1 breadstick-vm\n' > /etc/hosts.vm
printf 'image only\n' > /usr/share/bsl-image-only.txt
chgrp shadow /etc/shadow && chmod 640 /etc/shadow
printf 'image\n' > /usr/share/bsl-image-group.txt && chgrp mail /usr/share/bsl-image-group.txt && chmod 2755 /usr/share/bsl-image-group.txt
chmod 1777 /var/tmp && chmod 0700 /root
# The VM's own identity; a proot system's is empty (round 9 review: laid over the VM's, it made the next boot a first boot).
printf '0123456789abcdef0123456789abcdef\n' > /etc/machine-id
useradd -m -u 1000 -s /bin/sh tester 2>/dev/null
# A package of the VM's image that a proot system never has (round 10, M6: the VM's kernel, systemd, D-Bus...), in dpkg's
# database with its file list, and one installed after the image list (the restore takes its files and its list away).
fakepkg() {  # name file
    printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nSection: misc\nMaintainer: Breadstick <test@invalid>\nArchitecture: all\nVersion: 1.0\nDescription: a test package\n\n' "$1" >> /var/lib/dpkg/status
    printf '/.\n%s\n' "$2" > "/var/lib/dpkg/info/$1.list"
    (cd / && md5sum "${2#/}") > "/var/lib/dpkg/info/$1.md5sums"
}
fakepkg bsl-vm-only /usr/share/bsl-image-only.txt
sh /t/image-files.sh > /tmp/r1 2>&1
say image-files "$(cat /tmp/r1) $(gzip -dc /var/lib/breadstick-vm/image-files.gz | grep -cx '/usr/share/bsl-image-only.txt')"
sh /t/image-files.sh > /tmp/r2 2>&1
say image-files-again "$(cat /tmp/r2 | wc -c)"
# Made after the list, as a user's later changes: a proot backup without them takes them away.
printf 'after\n' > /etc/bsl-after-image.conf
mkdir -p /opt/bsl-after/sub && printf 'x\n' > /opt/bsl-after/sub/x
printf 'after\n' > /home/tester/after.txt
fakepkg bsl-vm-later /etc/bsl-after-image.conf

# 2. A proot system's backup: this system copied, then made the way a proot system is.
P=/tmp/proot
mkdir -p "$P"
tar --create --file=- --one-file-system --exclude=./tmp --exclude=./proc --exclude=./sys --exclude=./dev \
    --exclude=./var/lib/breadstick-vm --exclude=./usr/lib/breadstick-vm --exclude='./etc/systemd/system/bsl-*' \
    --exclude='./etc/systemd/system/*.wants/bsl-*' -C / . | tar --extract --file=- -C "$P"
mkdir -p "$P/tmp" "$P/proc" "$P/sys" "$P/dev"
rm -f "$P/etc/bsl-after-image.conf" "$P/home/tester/after.txt" "$P/usr/share/bsl-image-only.txt" "$P/etc/hosts.vm"
rm -rf "$P/opt/bsl-after"
# The proot system's own database: without the two packages above.
awk 'BEGIN { RS = ""; ORS = "\n\n" } !/^Package: bsl-vm-(only|later)\n/' "$P/var/lib/dpkg/status" > "$P/var/lib/dpkg/status.new"
mv "$P/var/lib/dpkg/status.new" "$P/var/lib/dpkg/status"
rm -f "$P"/var/lib/dpkg/info/bsl-vm-only.* "$P"/var/lib/dpkg/info/bsl-vm-later.*
printf 'from the backup\n' > "$P/etc/bsl-from-backup.conf"
printf 'kept\n' > "$P/home/tester/keep.txt"
printf 'backup copy\n' > "$P/usr/share/bsl-image-group.txt"
printf '127.0.0.1 localhost proot\n' > "$P/etc/hosts"
: > "$P/etc/machine-id"
mkdir -p "$P/usr/local/bin"
for t in systemctl systemd-tmpfiles dpkg-statoverride; do
    printf '#!/bin/sh\nexit 0\n' > "$P/usr/local/bin/$t"; cp "$P/usr/local/bin/$t" "$P/usr/bin/$t"
done
printf '#!/bin/sh\n# Breadstick Linux: systemd-sysusers under proot (sysusers shim version 2).\nexit 0\n' > "$P/usr/local/bin/systemd-sysusers"
cp "$P/usr/local/bin/systemd-sysusers" "$P/usr/bin/systemd-sysusers"
printf '#!/bin/sh\nwhile [ "$#" -gt 0 ]; do shift; done\nexec "$@"\n' > "$P/usr/local/bin/setpriv"
cp "$P/usr/local/bin/setpriv" "$P/usr/bin/setpriv"
printf '#!/bin/sh\nexit 101\n' > "$P/usr/sbin/policy-rc.d"
chmod 755 "$P/usr/local/bin/"* "$P/usr/bin/systemctl" "$P/usr/bin/systemd-tmpfiles" "$P/usr/bin/dpkg-statoverride" \
    "$P/usr/bin/systemd-sysusers" "$P/usr/bin/setpriv" "$P/usr/sbin/policy-rc.d"
mkdir -p "$P/etc/pacman.d/hooks"
ln -sfn /dev/null "$P/etc/pacman.d/hooks/25-systemd-binfmt.hook"
ln -sfn /dev/null "$P/etc/pacman.d/hooks/36-systemd-modules-load.hook"
printf '[options]\n# Breadstick Linux (the image bake): no download sandbox under proot.\nDisableSandbox\nHoldPkg = pacman\n# Breadstick Linux (package-fixups): no download sandbox under proot.\nDisableSandbox\n\n[core]\n' > "$P/etc/pacman.conf"
# A 3.x proot backup: every folder 0755, every file the app's uid (here root's), as the app writes it.
find "$P" -type d -exec chmod 0755 {} +
chown -R -h 0:0 "$P"
chmod 2755 "$P/usr/share/bsl-image-group.txt"
tar --create --file=/tmp/proot.tar --format=posix --numeric-owner -C "$P" .
rm -rf "$P"

sh /t/file-unpack-proot.sh < /tmp/proot.tar > /tmp/u.log 2>&1
say proot-unpack-rc "$?"
S=/var/lib/breadstick-vm/restore
say proot-stage-home "$(stat -c '%u %a' "$S/home/tester")"
say proot-stage-standins "$(for p in usr/local/bin/systemctl usr/local/bin/setpriv usr/local/bin/dpkg-statoverride usr/local/bin/systemd-sysusers usr/sbin/policy-rc.d; do [ -e "$S/$p" ] && echo "$p"; done | wc -l)"
say proot-stage-real "$(yn cmp -s "$S/usr/bin/systemctl" /bin/true) $(yn cmp -s "$S/usr/bin/setpriv" /usr/bin/setpriv) $(yn cmp -s "$S/usr/bin/dpkg-statoverride" /usr/bin/dpkg-statoverride) $(grep -c '^DisableSandbox' "$S/etc/pacman.conf") $(grep -c '^HoldPkg' "$S/etc/pacman.conf") $(ls "$S/etc/pacman.d/hooks" | wc -l)"
sh /t/file-restore-proot.sh > /tmp/r.log 2>&1
say proot-restore-rc "$?"
say proot-restore-said "$(tail -n 1 /tmp/r.log)"
say proot-systemctl "$(yn cmp -s /usr/bin/systemctl /bin/true) $(yn test ! -e /usr/local/bin/systemctl) $(yn test ! -e /usr/sbin/policy-rc.d) $(head -c 4 /usr/bin/setpriv | od -An -c | tr -d ' ')"
say proot-modes "$(mode /var/tmp) $(mode /root) $(mode /home/tester) $(stat -c %U /home/tester/keep.txt)"
say proot-owners "$(stat -c %G /etc/shadow) $(stat -c '%G %a' /usr/share/bsl-image-group.txt) $(cat /usr/share/bsl-image-group.txt)"
say proot-guest "$(cat /usr/lib/breadstick-vm/bsl-vmagent) $(yn test -L /etc/systemd/system/multi-user.target.wants/bsl-vmagent.service) $(yn test -f /etc/systemd/system/bsl-vmagent.service)"
say proot-hosts "$(grep -c proot /etc/hosts)"
say proot-machine-id "$(cat /etc/machine-id)"
say proot-files "$(yn test -f /etc/bsl-from-backup.conf) $(yn test ! -e /etc/bsl-after-image.conf) $(yn test ! -e /opt/bsl-after) $(yn test ! -e /home/tester/after.txt) $(yn test -f /usr/share/bsl-image-only.txt) $(yn test -f /etc/hosts.vm)"
say proot-left "$(yn test ! -e $S) $(yn test ! -e /var/lib/breadstick-vm/restore.work) $(yn test -s /var/lib/breadstick-vm/image-files.gz)"
# The VM's own package is in the database again, the later one is not, nothing is listed twice, and dpkg and apt find
# it sound (apt-get check: its dependencies, round 10 review).
say proot-dpkg "$(sed -n 's/^package database (dpkg): .*put back: \([0-9]*\).*/\1/p' /tmp/r.log) $(dpkg-query -W -f='${Status}' bsl-vm-only 2>&1) | $(yn test ! -e /var/lib/dpkg/info/bsl-vm-later.list) $(dpkg-query -W bsl-vm-later >/dev/null 2>&1 && echo listed || echo unlisted) $(grep -c '^Package: base-files$' /var/lib/dpkg/status) $(dpkg --audit 2>&1 | wc -l) $(apt-get -qq check 2>&1 | wc -l)"

# 3. A VM's own backup of the system as it is now, restored after changes: exactly the backup comes back.
printf 'vm kept\n' > /home/tester/vm-keep.txt && chown tester /home/tester/vm-keep.txt
sh /t/file-backup.sh > /tmp/vm.tar
say vm-backup-rc "$?"
printf 'after\n' > /home/tester/vm-after.txt
printf 'after\n' > /etc/bsl-vm-after.conf
rm -f /home/tester/vm-keep.txt /etc/bsl-from-backup.conf
chmod 0711 /home/tester
# Restored into another VM: that VM's identity stays.
printf 'fedcba9876543210fedcba9876543210\n' > /etc/machine-id
sh /t/file-unpack-vm.sh < /tmp/vm.tar > /tmp/u2.log 2>&1
say vm-unpack-rc "$?"
sh /t/file-restore.sh > /tmp/r2.log 2>&1
say vm-restore-rc "$?"
say vm-files "$(cat /home/tester/vm-keep.txt) $(stat -c %U /home/tester/vm-keep.txt) $(yn test -f /etc/bsl-from-backup.conf) $(yn test ! -e /home/tester/vm-after.txt) $(yn test ! -e /etc/bsl-vm-after.conf) $(mode /home/tester)"
say vm-guest "$(cat /usr/lib/breadstick-vm/bsl-vmagent) $(yn test -L /etc/systemd/system/multi-user.target.wants/bsl-vmagent.service) $(mode /var/tmp)"
say vm-left "$(yn test ! -e $S) $(yn test ! -e /var/lib/breadstick-vm/restore.work)"
say vm-machine-id "$(cat /etc/machine-id)"
# 4. A stage with no system in it is refused and nothing is taken away.
mkdir -p $S && printf 'x\n' > $S/x
sh /t/file-restore.sh > /tmp/r3.log 2>&1
say empty-stage-rc "$?"
say empty-stage-kept "$(yn test -f /etc/bsl-from-backup.conf)"
# 5. Round 12 review: the Nix based instance's own VM backup restored over it after `bsl-nix update` and `bsl-nix gc`.
# NixOS's marker and a store (here not a mount; the restore makes the real one writable): the backup has the old
# generation's path, the running system then has only a newer one, and the restore runs with its tools from that newer
# path, as NixOS's do. No store path is taken away: the backup's comes back, the running one stays, the restore ends.
rm -rf $S
touch /etc/NIXOS
old=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-old
new=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-coreutils-9.7
mkdir -p $old /nix/var/nix/db && printf 'old\n' > $old/marker && printf 'db\n' > /nix/var/nix/db/db.sqlite
sh /t/file-backup.sh > /tmp/nix.tar
mkdir -p $new/bin
for t in rm rmdir mv mkdir chmod sort grep find tar wc sync awk cat; do cp "$(command -v $t)" $new/bin/; done
rm -rf $old
sh /t/file-unpack-vm.sh < /tmp/nix.tar > /tmp/u4.log 2>&1
PATH=$new/bin:$PATH sh /t/file-restore.sh > /tmp/r4.log 2>&1
say nix-restore-rc "$?"
say nix-restore-said "$(tail -n 1 /tmp/r4.log)"
say nix-store "$(cat $old/marker 2>/dev/null) $(yn test -x $new/bin/rm) $(yn test -x $new/bin/tar) $(cat /nix/var/nix/db/db.sqlite)"
exit 0
