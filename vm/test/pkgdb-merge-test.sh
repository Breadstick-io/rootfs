#!/bin/sh
# The cross-engine restore's package database step (file-restore-proot.sh, the app's VmFileBackup.PACKAGE_DB_MERGE),
# run in a container for each family against made-up packages: a VM package whose dependencies the restored system
# does not meet is left out, and so is one that needs it; one the system meets is put back; a package that breaks a
# package of the backup is left out, and so is one a backup package's Pre-Depends asks a newer version of (apt-get check
# names it `PreDepends:`); what the backup itself had broken stays as it was. After the step the family's
# own dependency check is clean, or names only what the backup had broken, and the restore's log names each one left out.
# rpm and pacman (round 10, third review) keep a VM package whose only unmet need is a version of something the system
# has (the VM's systemd pinning the image's systemd-libs), and one that needs it; the log says so. Every package dpkg and
# rpm leave out is in the record the VM's refresh installs again (/var/lib/breadstick-vm/restore-left-out).
# Round 11 (H3): two kernels in each family, the second installed after the image and missing a file the restore took
# away. Each installed package is judged on its own (rpm by NVRA, pacman by name, version and processor, dpkg by its
# file list): the whole kernel stays, the other is left out, and every package left out is named in the log and the
# record, a package with no file list (dpkg) or whose entry the restore took away (pacman) included. rpm judges a
# package with no file of its own by its needs (round 11 review): a kernel meta-package goes with its kernel, one
# needing only a package taken away is taken away, one needing nothing is put back. A package none of
# whose files the restore kept (it came after the image and the backup lacks it) was taken away with the restore: named
# so, never recorded. dpkg reads a list the restore took away from the copy kept before it and puts its info back.
#
#   vm/test/pkgdb-merge-test.sh [debian] [fedora] [archlinux]     (all three by default)
#
# Debian and Fedora run as arm64 (native here), Arch as amd64 under qemu-x86_64 10 (AutoBuild/tools/qemu-x86_64-setup.sh).
# Fedora needs rpmbuild: FEDORA_TOOLS_IMAGE (default bsl-pkg-run-test:fedora45-arm64, packages' test image), built
# from fedora:45 when missing. Containers are bsl-<RUN>-pkgdb-*, run with no network, removed after.
set -u
here=$(cd "$(dirname "$0")" && pwd)
RUN=${RUN:-vmtest}
FTOOLS=${FEDORA_TOOLS_IMAGE:-bsl-pkg-run-test:fedora45-arm64}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The step itself, exactly as the restore runs it: from the dpkg line to the line before the stage goes.
awk '/^if \[ -s "\$w\/dpkg-status" \]/ { on = 1 } /^rm -rf "\$s" "\$w"$/ { on = 0 } on' "$here/file-restore-proot.sh" > "$work/merge.sh"
grep -q 'package database (pacman)' "$work/merge.sh" || { echo "FAIL: no package database step in file-restore-proot.sh"; exit 1; }

cat > "$work/debian.sh" <<'BSL_PKGDB_DEB'
set -e
LC_ALL=C; export LC_ALL
w=/work; s=/stage; mkdir -p $w $s/usr $s/etc /var/lib/breadstick-vm
st() { printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nArchitecture: all\nVersion: 1\nMaintainer: t <t@t>\n%sDescription: test\n\n' "$1" "$2"; }
# The restored (backup's) database: the container's own, a package it had broken already, and one that breaks a VM one.
cp /var/lib/dpkg/status /var/lib/dpkg/status.orig
{ cat /var/lib/dpkg/status.orig; echo; st bsltest-oldbroken 'Depends: bsltest-nowhere
'; st bsltest-picky 'Breaks: bsltest-broken-by-backup
'; st bsltest-user 'Pre-Depends: bsltest-vmlib (>= 2)
'; } > /var/lib/dpkg/status
# The VM's database: the container's own and the VM's packages.
{ cat /var/lib/dpkg/status.orig; echo
  st bsltest-free 'Depends: dpkg
'; st bsltest-needy 'Depends: apt (>= 99)
'; st bsltest-chain 'Depends: bsltest-needy
'; st bsltest-breaker 'Breaks: apt (<< 99)
'; st bsltest-broken-by-backup ''; st bsltest-nofiles ''; st bsltest-vmlib ''
  # Two kernels: the image's, whole, and the one installed after it, missing a file; a package that needs the second;
  # a foreign package whose list the restore took away.
  st bsltest-kernel-1 ''; st bsltest-kernel-2 ''; st bsltest-kernel-meta 'Depends: bsltest-kernel-2
'; st bsltest-foreign '' | sed 's/^Architecture: all$/Architecture: i386/'; st bsltest-kernel-3 ''; st bsltest-cowsay ''; } > $w/dpkg-status
for p in bsltest-free bsltest-needy bsltest-chain bsltest-breaker bsltest-broken-by-backup bsltest-vmlib bsltest-kernel-meta; do echo /. > /var/lib/dpkg/info/$p.list; done
mkdir -p /usr/lib/bsltest-kernel-1
echo k > /usr/lib/bsltest-kernel-1/vmlinuz
printf '/.\n/usr/lib/bsltest-kernel-1\n/usr/lib/bsltest-kernel-1/vmlinuz\n' > /var/lib/dpkg/info/bsltest-kernel-1.list
mkdir -p /usr/lib/bsltest-modules-2 /usr/lib/bsltest-kernel-3
echo m > /usr/lib/bsltest-modules-2/m.ko
echo k > /usr/lib/bsltest-kernel-3/vmlinuz
printf '/.\n/usr/lib/bsltest-modules-2\n/usr/lib/bsltest-modules-2/m.ko\n/usr/lib/bsltest-kernel-2\n/usr/lib/bsltest-kernel-2/vmlinuz\n' > /var/lib/dpkg/info/bsltest-kernel-2.list
# Lists the restore took away, in the copy kept before it: a kernel whose files are all there, a program none of whose are.
mkdir -p $w/dpkg-info
printf '/.\n/usr/lib/bsltest-kernel-3\n/usr/lib/bsltest-kernel-3/vmlinuz\n' > $w/dpkg-info/bsltest-kernel-3.list
echo 'd41d8cd98f00b204e9800998ecf8427e  usr/lib/bsltest-kernel-3/vmlinuz' > $w/dpkg-info/bsltest-kernel-3.md5sums
echo other > $w/dpkg-info/bsltest-kernel-3.13.list
printf '/.\n/usr/games\n/usr/games/bsltest-cowsay\n' > $w/dpkg-info/bsltest-cowsay.list
. /m/merge.sh
for p in bsltest-free bsltest-needy bsltest-chain bsltest-breaker bsltest-broken-by-backup bsltest-nofiles bsltest-vmlib bsltest-oldbroken bsltest-user \
  bsltest-kernel-1 bsltest-kernel-2 bsltest-kernel-meta bsltest-kernel-3 bsltest-cowsay; do
  v=$(dpkg-query -W -f='${Status}' $p 2>/dev/null) || true
  [ "$v" = "install ok installed" ] || v=absent
  printf '%s=%s\n' $p "$v"
done
apt-get check -q -o Dir::State::lists=$w/apt-lists -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= 2>&1 | grep '^ ' | sed 's/^/broken: /' || true
ls /var/lib/dpkg/info | grep '^bsltest-kernel-3' | sed 's/^/info: /'
dpkg -S /usr/lib/bsltest-kernel-3/vmlinuz 2>/dev/null | sed 's/^/owner: /'
grep -e '^left out' -e '^taken away' /var/log/breadstick-vm-restore.log | sort
sed 's/^/record: /' /var/lib/breadstick-vm/restore-left-out
BSL_PKGDB_DEB

cat > "$work/debian.want" <<'BSL_PKGDB_DEBW'
package database (dpkg): the VM's own packages put back: 3, left out: 9, taken away with the restore: 1
bsltest-free=install ok installed
bsltest-needy=absent
bsltest-chain=absent
bsltest-breaker=absent
bsltest-broken-by-backup=absent
bsltest-nofiles=absent
bsltest-vmlib=absent
bsltest-oldbroken=install ok installed
bsltest-user=install ok installed
bsltest-kernel-1=install ok installed
bsltest-kernel-2=absent
bsltest-kernel-meta=absent
bsltest-kernel-3=install ok installed
bsltest-cowsay=absent
broken:  bsltest-oldbroken : Depends: bsltest-nowhere but it is not installable
broken:  bsltest-user : PreDepends: bsltest-vmlib (>= 2) but it is not installable
info: bsltest-kernel-3.list
info: bsltest-kernel-3.md5sums
owner: bsltest-kernel-3: /usr/lib/bsltest-kernel-3/vmlinuz
left out (dpkg): bsltest-breaker
left out (dpkg): bsltest-broken-by-backup
left out (dpkg): bsltest-chain
left out (dpkg): bsltest-foreign:i386
left out (dpkg): bsltest-kernel-2
left out (dpkg): bsltest-kernel-meta
left out (dpkg): bsltest-needy
left out (dpkg): bsltest-nofiles
left out (dpkg): bsltest-vmlib
taken away (dpkg): bsltest-cowsay
record: dpkg bsltest-breaker
record: dpkg bsltest-broken-by-backup
record: dpkg bsltest-chain
record: dpkg bsltest-foreign:i386
record: dpkg bsltest-kernel-2
record: dpkg bsltest-kernel-meta
record: dpkg bsltest-needy
record: dpkg bsltest-nofiles
record: dpkg bsltest-vmlib
BSL_PKGDB_DEBW

cat > "$work/fedora.sh" <<'BSL_PKGDB_FED'
set -e
LC_ALL=C; export LC_ALL
w=/work; s=/stage; mkdir -p $w $s/usr $s/etc /tmp/b /var/lib/breadstick-vm
mk() { # name version requires...
  n=$1 v=$2; shift 2
  { printf 'Name: %s\nVersion: %s\nRelease: 1\nSummary: t\nLicense: none\nBuildArch: noarch\n' "$n" "$v"
    for r in "$@"; do printf 'Requires: %s\n' "$r"; done
    printf '%%description\nt\n%%install\nmkdir -p %%{buildroot}/usr/share/bsltest\necho %s > %%{buildroot}/usr/share/bsltest/%s\n%%files\n/usr/share/bsltest/%s\n' "$n" "$n" "$n"
  } > /tmp/b/$n-$v.spec
  rpmbuild -bb --quiet --define "_topdir /tmp/b" --define "_rpmdir /tmp/b/out" /tmp/b/$n-$v.spec >/dev/null 2>&1
}
mk bsltest-base 1; mk bsltest-base 2; mk bsltest-free 1 rpm; mk bsltest-needy 1 'bsltest-base >= 2'; mk bsltest-chain 1 bsltest-needy
mk bsltest-oldbroken 1 bsltest-nowhere; mk bsltest-pinned 1 'bsltest-base = 2-1'; mk bsltest-missing 1 bsltest-absent
mk bsltest-chain2 1 bsltest-missing; mk bsltest-gone 1
mkk() { # a kernel: version, its own file
  { printf 'Name: bsltest-kernel\nVersion: %s\nRelease: 1\nSummary: t\nLicense: none\nBuildArch: noarch\n' "$1"
    printf '%%description\nt\n%%install\nmkdir -p %%{buildroot}/usr/lib/bsltest-kernel-%s\necho %s > %%{buildroot}/usr/lib/bsltest-kernel-%s/vmlinuz\n' "$1" "$1" "$1"
    printf 'echo %s > %%{buildroot}/usr/lib/bsltest-kernel-%s/LICENSE\n' "$1" "$1"
    printf '%%files\n%%dir /usr/lib/bsltest-kernel-%s\n/usr/lib/bsltest-kernel-%s/vmlinuz\n/usr/lib/bsltest-kernel-%s/LICENSE\n' "$1" "$1" "$1"
  } > /tmp/b/bsltest-kernel-$1.spec
  rpmbuild -bb --quiet --define "_topdir /tmp/b" --define "_rpmdir /tmp/b/out" /tmp/b/bsltest-kernel-$1.spec >/dev/null 2>&1
}
mkk 1; mkk 2
mkm() { # a package with no file of its own (Fedora's kernel meta-package): name version requires...
  n=$1 v=$2; shift 2
  { printf 'Name: %s\nVersion: %s\nRelease: 1\nSummary: t\nLicense: none\nBuildArch: noarch\n' "$n" "$v"
    for r in "$@"; do printf 'Requires: %s\n' "$r"; done
    printf '%%description\nt\n%%files\n'
  } > /tmp/b/$n-$v.spec
  rpmbuild -bb --quiet --define "_topdir /tmp/b" --define "_rpmdir /tmp/b/out" /tmp/b/$n-$v.spec >/dev/null 2>&1
}
# Round 11 review: the kernel meta-package of each kernel (no files), one needing only a package taken away, one
# needing nothing.
mkm bsltest-kmeta 1 'bsltest-kernel = 1-1'; mkm bsltest-kmeta 2 'bsltest-kernel = 2-1'; mkm bsltest-gonemeta 1 bsltest-gone
mkm bsltest-emptymeta 1
o=/tmp/b/out/noarch
# The restored (backup's) database: the container's own, base 1 and a package it had broken already. The VM's
# packages' files are on the disk (they are the image's), not in the restored database.
rpm -i --nodeps --nosignature $o/bsltest-base-1-1.noarch.rpm $o/bsltest-oldbroken-1-1.noarch.rpm $o/bsltest-free-1-1.noarch.rpm \
  $o/bsltest-needy-1-1.noarch.rpm $o/bsltest-chain-1-1.noarch.rpm $o/bsltest-pinned-1-1.noarch.rpm $o/bsltest-missing-1-1.noarch.rpm \
  $o/bsltest-chain2-1-1.noarch.rpm $o/bsltest-gone-1-1.noarch.rpm $o/bsltest-kernel-1-1.noarch.rpm $o/bsltest-kernel-2-1.noarch.rpm \
  $o/bsltest-kmeta-1-1.noarch.rpm $o/bsltest-kmeta-2-1.noarch.rpm $o/bsltest-gonemeta-1-1.noarch.rpm $o/bsltest-emptymeta-1-1.noarch.rpm
# The second kernel lost a file the restore took away (its licence; its kernel is kept); bsltest-gone came after the
# image and lost every file (taken away with the restore, not recorded).
rm -f /usr/lib/bsltest-kernel-2/LICENSE /usr/share/bsltest/bsltest-gone
d=$(rpm -E %_dbpath)
cp -a "$d" /tmp/vmdb
rpm -e --justdb --nodeps --allmatches bsltest-free bsltest-needy bsltest-chain bsltest-pinned bsltest-missing bsltest-chain2 bsltest-gone bsltest-kernel \
  bsltest-kmeta bsltest-gonemeta bsltest-emptymeta
# The VM's database: the container's own, base 2 and the three.
rpm --dbpath /tmp/vmdb -e --justdb --nodeps bsltest-oldbroken bsltest-base
rpm --dbpath /tmp/vmdb -i --justdb --nodeps --nosignature $o/bsltest-base-2-1.noarch.rpm
cp -a /tmp/vmdb $w/rpmdb
. /m/merge.sh
for p in bsltest-free bsltest-needy bsltest-chain bsltest-pinned bsltest-missing bsltest-chain2 bsltest-base bsltest-oldbroken bsltest-gone bsltest-kernel \
  bsltest-kmeta bsltest-gonemeta bsltest-emptymeta; do
  if v=$(rpm -q $p 2>/dev/null); then v=$(printf '%s' "$v" | tr '\n' ' '); else v=absent; fi; printf '%s=%s\n' $p "$v"
done
rpm -Va --nofiles --nodigest --nosignature --noscripts 2>&1 | sed 's/^/broken: /' || true
grep -e '^left out' -e '^a version apart' -e '^taken away' /var/log/breadstick-vm-restore.log | sort
sed 's/^/record: /' /var/lib/breadstick-vm/restore-left-out
BSL_PKGDB_FED

cat > "$work/fedora.want" <<'BSL_PKGDB_FEDW'
package database (rpm): the VM's own packages put back: 7, left out: 4, taken away with the restore: 2
package database (rpm): a version apart from the system's (the next full upgrade levels them): 2
bsltest-free=bsltest-free-1-1.noarch
bsltest-needy=bsltest-needy-1-1.noarch
bsltest-chain=bsltest-chain-1-1.noarch
bsltest-pinned=bsltest-pinned-1-1.noarch
bsltest-missing=absent
bsltest-chain2=absent
bsltest-base=bsltest-base-1-1.noarch
bsltest-oldbroken=bsltest-oldbroken-1-1.noarch
bsltest-gone=absent
bsltest-kernel=bsltest-kernel-1-1.noarch
bsltest-kmeta=bsltest-kmeta-1-1.noarch
bsltest-gonemeta=absent
bsltest-emptymeta=bsltest-emptymeta-1-1.noarch
broken: Unsatisfied dependencies for bsltest-oldbroken-1-1.noarch:
broken: 	bsltest-nowhere is needed by (installed) bsltest-oldbroken-1-1.noarch
broken: Unsatisfied dependencies for bsltest-needy-1-1.noarch:
broken: 	bsltest-base >= 2 is needed by (installed) bsltest-needy-1-1.noarch
broken: Unsatisfied dependencies for bsltest-pinned-1-1.noarch:
broken: 	bsltest-base = 2-1 is needed by (installed) bsltest-pinned-1-1.noarch
a version apart (rpm): bsltest-needy-1-1.noarch needs bsltest-base >= 2
a version apart (rpm): bsltest-pinned-1-1.noarch needs bsltest-base = 2-1
left out (rpm): bsltest-chain2-1-1.noarch
left out (rpm): bsltest-kernel-2-1.noarch
left out (rpm): bsltest-kmeta-2-1.noarch
left out (rpm): bsltest-missing-1-1.noarch
taken away (rpm): bsltest-gone-1-1.noarch
taken away (rpm): bsltest-gonemeta-1-1.noarch
record: rpm bsltest-chain2-1-1.noarch bsltest-chain2.noarch
record: rpm bsltest-kernel-2-1.noarch
record: rpm bsltest-kmeta-2-1.noarch
record: rpm bsltest-missing-1-1.noarch bsltest-missing.noarch
BSL_PKGDB_FEDW

cat > "$work/archlinux.sh" <<'BSL_PKGDB_ARCH'
set -e
LC_ALL=C; export LC_ALL
w=/work; s=/stage; mkdir -p $w $s/usr $s/etc $s/var/lib/pacman /var/lib/breadstick-vm
l=/var/lib/pacman/local
entry() { # dir name depends conflicts [version [database [files]]]
  e=${6:-$l}/$1
  mkdir -p $e
  { printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%ARCH%%\nany\n\n' "$2" "${5:-1-1}"
    [ -z "$3" ] || printf '%%DEPENDS%%\n%s\n\n' "$3"
    [ -z "$4" ] || printf '%%CONFLICTS%%\n%s\n\n' "$4"; } > $e/desc
  printf '%%FILES%%\n%s\n' "${7:-}" > $e/files
}
# The restored (backup's) database: the container's own, a package it had broken already, and one that conflicts
# with a VM one. The stage holds the backup's entries.
entry bsltest-oldbroken-1-1 bsltest-oldbroken bsltest-nowhere ''
entry bsltest-picky-1-1 bsltest-picky '' bsltest-conflicted
entry bsltest-lib-2-1 bsltest-lib '' '' 2-1
cp -a $l $s/var/lib/pacman/local
# The image's own entry for the library, at the VM's version: the backup's wins (no package listed twice).
entry bsltest-lib-1-1 bsltest-lib '' 
# The VM's own entries (the image's, kept as files): one met, one not, one needing that, one the backup conflicts with,
# one pinning the library at the image's version and one needing that.
entry bsltest-free-1-1 bsltest-free 'pacman' ''
entry bsltest-needy-1-1 bsltest-needy 'bsltest-absent' ''
entry bsltest-chain-1-1 bsltest-chain 'bsltest-needy' ''
entry bsltest-conflicted-1-1 bsltest-conflicted '' ''
entry bsltest-pinned-1-1 bsltest-pinned 'bsltest-lib=1-1' ''
entry bsltest-pinchain-1-1 bsltest-pinchain 'bsltest-pinned' ''
# The VM's database before the restore: all of the above, and two kernels the VM installed after its image, whose
# entries the restore took away with the files no list named: one whose files are all there, one missing its kernel.
mkdir -p $w/pacdb
cp -a $l $w/pacdb/local
mkdir -p /usr/lib/bsltest-linux-2
echo k > /usr/lib/bsltest-linux-2/vmlinuz
entry bsltest-linux-2-1 bsltest-linux '' '' 2-1 $w/pacdb/local 'usr/
usr/lib/
usr/lib/bsltest-linux-2/
usr/lib/bsltest-linux-2/vmlinuz
'
mkdir -p /usr/lib/modules-bsltest-lts
echo m > /usr/lib/modules-bsltest-lts/m.ko
entry bsltest-linux-lts-1-1 bsltest-linux-lts '' '' 1-1 $w/pacdb/local 'usr/
usr/lib/bsltest-linux-lts/
usr/lib/bsltest-linux-lts/vmlinuz
usr/lib/modules-bsltest-lts/
usr/lib/modules-bsltest-lts/m.ko
'
entry bsltest-cowsay-1-1 bsltest-cowsay '' '' 1-1 $w/pacdb/local 'usr/
usr/bin/
usr/bin/bsltest-cowsay
'
. /m/merge.sh
for p in bsltest-free bsltest-needy bsltest-chain bsltest-conflicted bsltest-pinned bsltest-pinchain bsltest-lib bsltest-oldbroken bsltest-picky \
  bsltest-linux bsltest-linux-lts bsltest-cowsay; do
  printf '%s=%s\n' $p "$(pacman -Q $p 2>/dev/null || echo absent)"
done
pacman -Dk 2>&1 | grep -v "^warning: database file for '.*' does not exist" | sed 's/^/broken: /' || true
grep -e '^left out' -e '^a version apart' -e '^taken away' /var/log/breadstick-vm-restore.log | sort
sed 's/^/record: /' /var/lib/breadstick-vm/restore-left-out
BSL_PKGDB_ARCH

cat > "$work/archlinux.want" <<'BSL_PKGDB_ARCHW'
package database (pacman): the VM's own packages kept: 4, left out: 4, taken away with the restore: 1
package database (pacman): a version apart from the system's (the next full upgrade levels them): 1
bsltest-free=bsltest-free 1-1
bsltest-needy=absent
bsltest-chain=absent
bsltest-conflicted=absent
bsltest-pinned=bsltest-pinned 1-1
bsltest-pinchain=bsltest-pinchain 1-1
bsltest-lib=bsltest-lib 2-1
bsltest-oldbroken=bsltest-oldbroken 1-1
bsltest-picky=bsltest-picky 1-1
bsltest-linux=bsltest-linux 2-1
bsltest-linux-lts=absent
bsltest-cowsay=absent
broken: error: missing 'bsltest-nowhere' dependency for 'bsltest-oldbroken'
broken: error: missing 'bsltest-lib=1-1' dependency for 'bsltest-pinned'
a version apart (pacman): bsltest-pinned needs bsltest-lib=1-1
left out (pacman): bsltest-chain-1-1-any
left out (pacman): bsltest-conflicted-1-1-any
left out (pacman): bsltest-linux-lts-1-1-any
left out (pacman): bsltest-needy-1-1-any
taken away (pacman): bsltest-cowsay-1-1-any
record: pacman bsltest-chain-1-1-any
record: pacman bsltest-conflicted-1-1-any
record: pacman bsltest-linux-lts-1-1-any
record: pacman bsltest-needy-1-1-any
BSL_PKGDB_ARCHW

fails=0
for fam in ${*:-debian fedora archlinux}; do
  case $fam in
    debian) img=debian:trixie plat=linux/arm64 ;;
    fedora) img=$FTOOLS plat=linux/arm64
      if ! docker image inspect "$img" >/dev/null 2>&1; then
        printf 'FROM fedora:45\nRUN dnf -y install --setopt=install_weak_deps=False rpm-build && dnf clean all\n' \
          | docker build -q --platform=$plat -t "$img" - >/dev/null || { echo "FAIL fedora: cannot build $img"; fails=$((fails + 1)); continue; }
      fi ;;
    archlinux) img=archlinux:base plat=linux/amd64 ;;
    *) echo "unknown family $fam"; exit 2 ;;
  esac
  docker run --rm --platform=$plat --network none --name "bsl-$RUN-pkgdb-$fam" -v "$work:/m:ro" --entrypoint sh "$img" /m/$fam.sh \
    > "$work/$fam.out" 2>&1
  if diff -u "$work/$fam.want" "$work/$fam.out"; then echo "PASS $fam"; else echo "FAIL $fam"; fails=$((fails + 1)); fi
done
[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails failed"; exit 1; }
