#!/usr/bin/env python3
"""stdin: a proot system image as a tar (rootfs/dist's .tar, decompressed). stdout: the same files as the app's proot
Back up stores them (Android LinuxEnvironment.backupTo before 4.0): every folder 0755 (commons-compress's default for a
folder entry; 4.0 stores the folder's own mode), every entry root's (the app's one Android uid, which the restore into
the VM makes root's anyway). Files keep their modes. For qemu-test.sh's PROOT_IMAGE (plan 5.14 V20, round 9 review)."""
import sys
import tarfile

with tarfile.open(fileobj=sys.stdin.buffer, mode="r|*") as tin, \
        tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT) as tout:
    for m in tin:
        if m.isdir():
            m.mode = 0o755
        m.uid = m.gid = 0
        m.uname = m.gname = ""
        tout.addfile(m, tin.extractfile(m) if m.isreg() else None)
