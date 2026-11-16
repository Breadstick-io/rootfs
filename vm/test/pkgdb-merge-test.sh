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
'; st bsltest-broken-by-backup ''; st bsltest-nofiles ''; st bsltest-vmlib ''; } > $w/dpkg-status
for p in bsltest-free bsltest-needy bsltest-chain bsltest-breaker bsltest-broken-by-backup bsltest-vmlib; do echo /. > /var/lib/dpkg/info/$p.list; done
. /m/merge.sh
for p in bsltest-free bsltest-needy bsltest-chain bsltest-breaker bsltest-broken-by-backup bsltest-nofiles bsltest-vmlib bsltest-oldbroken bsltest-user; do
  v=$(dpkg-query -W -f='${Status}' $p 2>/dev/null) || true
  [ "$v" = "install ok installed" ] || v=absent
  printf '%s=%s\n' $p "$v"
done
apt-get check -q -o Dir::State::lists=$w/apt-lists -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= 2>&1 | grep '^ ' | sed 's/^/broken: /' || true
grep '^left out' /var/log/breadstick-vm-restore.log | sort
sed 's/^/record: /' /var/lib/breadstick-vm/restore-left-out
BSL_PKGDB_DEB

cat > "$work/debian.want" <<'BSL_PKGDB_DEBW'
package database (dpkg): the VM's own packages put back: 1, left out: 5
bsltest-free=install ok installed
bsltest-needy=absent
bsltest-chain=absent
bsltest-breaker=absent
bsltest-broken-by-backup=absent
bsltest-nofiles=absent
bsltest-vmlib=absent
bsltest-oldbroken=install ok installed
bsltest-user=install ok installed
broken:  bsltest-oldbroken : Depends: bsltest-nowhere but it is not installable
broken:  bsltest-user : PreDepends: bsltest-vmlib (>= 2) but it is not installable
left out (dpkg): bsltest-breaker
left out (dpkg): bsltest-broken-by-backup
left out (dpkg): bsltest-chain
left out (dpkg): bsltest-needy
left out (dpkg): bsltest-vmlib
record: dpkg bsltest-breaker
record: dpkg bsltest-broken-by-backup
record: dpkg bsltest-chain
record: dpkg bsltest-needy
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
mk bsltest-chain2 1 bsltest-missing
o=/tmp/b/out/noarch
# The restored (backup's) database: the container's own, base 1 and a package it had broken already. The VM's
# packages' files are on the disk (they are the image's), not in the restored database.
rpm -i --nodeps --nosignature $o/bsltest-base-1-1.noarch.rpm $o/bsltest-oldbroken-1-1.noarch.rpm $o/bsltest-free-1-1.noarch.rpm \
  $o/bsltest-needy-1-1.noarch.rpm $o/bsltest-chain-1-1.noarch.rpm $o/bsltest-pinned-1-1.noarch.rpm $o/bsltest-missing-1-1.noarch.rpm \
  $o/bsltest-chain2-1-1.noarch.rpm
d=$(rpm -E %_dbpath)
cp -a "$d" /tmp/vmdb
rpm -e --justdb --nodeps bsltest-free bsltest-needy bsltest-chain bsltest-pinned bsltest-missing bsltest-chain2
# The VM's database: the container's own, base 2 and the three.
rpm --dbpath /tmp/vmdb -e --justdb --nodeps bsltest-oldbroken bsltest-base
rpm --dbpath /tmp/vmdb -i --justdb --nodeps --nosignature $o/bsltest-base-2-1.noarch.rpm
cp -a /tmp/vmdb $w/rpmdb
. /m/merge.sh
for p in bsltest-free bsltest-needy bsltest-chain bsltest-pinned bsltest-missing bsltest-chain2 bsltest-base bsltest-oldbroken; do
  v=$(rpm -q $p 2>/dev/null) || v=absent; printf '%s=%s\n' $p "$v"
done
rpm -Va --nofiles --nodigest --nosignature --noscripts 2>&1 | sed 's/^/broken: /' || true
grep -e '^left out' -e '^a version apart' /var/log/breadstick-vm-restore.log | sort
sed 's/^/record: /' /var/lib/breadstick-vm/restore-left-out
BSL_PKGDB_FED

cat > "$work/fedora.want" <<'BSL_PKGDB_FEDW'
package database (rpm): the VM's own packages put back: 4, left out: 2
package database (rpm): a version apart from the system's (the next full upgrade levels them): 2
bsltest-free=bsltest-free-1-1.noarch
bsltest-needy=bsltest-needy-1-1.noarch
bsltest-chain=bsltest-chain-1-1.noarch
bsltest-pinned=bsltest-pinned-1-1.noarch
bsltest-missing=absent
bsltest-chain2=absent
bsltest-base=bsltest-base-1-1.noarch
bsltest-oldbroken=bsltest-oldbroken-1-1.noarch
broken: Unsatisfied dependencies for bsltest-oldbroken-1-1.noarch:
broken: 	bsltest-nowhere is needed by (installed) bsltest-oldbroken-1-1.noarch
broken: Unsatisfied dependencies for bsltest-needy-1-1.noarch:
broken: 	bsltest-base >= 2 is needed by (installed) bsltest-needy-1-1.noarch
broken: Unsatisfied dependencies for bsltest-pinned-1-1.noarch:
broken: 	bsltest-base = 2-1 is needed by (installed) bsltest-pinned-1-1.noarch
a version apart (rpm): bsltest-needy.noarch needs bsltest-base >= 2
a version apart (rpm): bsltest-pinned.noarch needs bsltest-base = 2-1
left out (rpm): bsltest-chain2.noarch
left out (rpm): bsltest-missing.noarch
record: rpm bsltest-chain2.noarch
record: rpm bsltest-missing.noarch
BSL_PKGDB_FEDW

cat > "$work/archlinux.sh" <<'BSL_PKGDB_ARCH'
set -e
LC_ALL=C; export LC_ALL
w=/work; s=/stage; mkdir -p $w $s/usr $s/etc $s/var/lib/pacman
l=/var/lib/pacman/local
entry() { # dir name depends conflicts [version]
  mkdir -p $l/$1
  { printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%ARCH%%\nany\n\n' "$2" "${5:-1-1}"
    [ -z "$3" ] || printf '%%DEPENDS%%\n%s\n\n' "$3"
    [ -z "$4" ] || printf '%%CONFLICTS%%\n%s\n\n' "$4"; } > $l/$1/desc
  printf '%%FILES%%\n\n' > $l/$1/files
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
. /m/merge.sh
for p in bsltest-free bsltest-needy bsltest-chain bsltest-conflicted bsltest-pinned bsltest-pinchain bsltest-lib bsltest-oldbroken bsltest-picky; do
  printf '%s=%s\n' $p "$(pacman -Q $p 2>/dev/null || echo absent)"
done
pacman -Dk 2>&1 | grep -v "^warning: database file for '.*' does not exist" | sed 's/^/broken: /' || true
grep -e '^left out' -e '^a version apart' /var/log/breadstick-vm-restore.log | sort
[ ! -e /var/lib/breadstick-vm/restore-left-out ] || echo "a record, which only dpkg and rpm write"
BSL_PKGDB_ARCH

cat > "$work/archlinux.want" <<'BSL_PKGDB_ARCHW'
package database (pacman): the VM's own packages kept: 3, left out: 3
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
broken: error: missing 'bsltest-nowhere' dependency for 'bsltest-oldbroken'
broken: error: missing 'bsltest-lib=1-1' dependency for 'bsltest-pinned'
a version apart (pacman): bsltest-pinned needs bsltest-lib=1-1
left out (pacman): bsltest-chain
left out (pacman): bsltest-conflicted
left out (pacman): bsltest-needy
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
