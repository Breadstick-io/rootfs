#!/bin/sh
# The app's VM restore scripts (Android vm/VmFileBackup: file-unpack-proot.sh, file-restore-proot.sh, file-backup.sh,
# file-unpack-vm.sh, file-restore.sh, image-files.sh; copies checked by VmFileBackupTest) run on a real Debian 13 tree
# in a throwaway container (--rm, --network none), which plays the VM's system (file-restore-docker.inner.sh). Round 9
# review: a proot system's backup restored into the VM gets the image's programs for proot's stand-ins, loses Arch's
# masks and DisableSandbox line, keeps the image's folder modes, owners and own files, the VM's hosts file and guest,
# and loses every file the system got after the image that the backup does not have; a VM's own backup comes back
# exactly. Exit 1 on any difference from the lines below. qemu-test.py runs the same scripts in a booted VM.
#
#   vm/test/file-restore-docker.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
want() { cat <<'BSL_FRD_WANT_4k8'
image-files: recorded 1
image-files-again: 0
proot-unpack-rc: 0
proot-stage-home: 1000 700
proot-stage-standins: 0
proot-stage-real: yes yes yes 0 1 0
proot-restore-rc: 0
proot-restore-said: restored
proot-systemctl: yes yes yes 177ELF
proot-modes: 1777 700 700 tester
proot-owners: shadow mail 2755 backup copy
proot-guest: agent yes yes
proot-hosts: 0
proot-files: yes yes yes yes yes yes
proot-left: yes yes yes
vm-backup-rc: 0
vm-unpack-rc: 0
vm-restore-rc: 0
vm-files: vm kept tester yes yes yes 700
vm-guest: agent yes 1777
vm-left: yes yes
empty-stage-rc: 3
empty-stage-kept: yes
BSL_FRD_WANT_4k8
}
got=$(docker run --rm --network none --platform "linux/$(dpkg --print-architecture)" --name "bsl-r9-vm-frd-$$" \
    -v "$here:/t:ro" debian:trixie sh /t/file-restore-docker.inner.sh 2>&1)
if [ "$got" = "$(want)" ]; then
    echo "ok   file-restore-docker: $(want | wc -l) checks"
    exit 0
fi
echo "FAIL file-restore-docker"
w=$(mktemp "${TMPDIR:-/tmp}/bsl-frd.XXXXXX") || exit 1
want > "$w"
printf '%s\n' "$got" | diff "$w" - | sed 's/^/    /'
rm -f "$w"
exit 1
