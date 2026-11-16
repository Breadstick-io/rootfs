# Breadstick VM: guest programs and their vsock protocols

The VM image (`bake-vm.sh`) carries three programs in `/usr/lib/breadstick-vm/`, each a systemd
unit. They are built static (agent 2, plan 5.14 V5), so the same binaries serve Debian, Fedora, Arch and NixOS;
`guest/install.sh ROOT` puts them, the units and the VM's settings into any of the first three, and
`guest/nixos/breadstick-vm.nix` is the same as a NixOS module. The app's half is in Android `app/src/main/java/io/breadstick/vm/` (branch `vm-2.0`);
`test/bslvm.py` is a reference host used to test the guest without a device.

Rules that shape all three, from W0 (Android docs/2.0/vm.md):
- Only the HOST opens vsock channels (an app cannot listen on vsock), on ports >= 1024.
- The app's vsock fds allow read, write, getattr and getopt: no `shutdown()`, no `FIONREAD`. Every
  message is framed, the guest closes a channel when it is done, and the host ends one by closing.
- The guest serves peer CID 2 (the host) only. CID 1 is the guest's own loopback: serving it would
  give any guest process what the host gets (root exec).

Integers are little-endian.

## bsl-vmagent, port 5000: control (BSA1)

Request: `"BSA1" u8 op, u32 len, payload`. Reply and later traffic: frames `u8 type, u32 len, data`.
Every exchange ends with an `x` frame (`i32` status) and the guest closing.

| op | payload | reply |
|---|---|---|
| `p` ping | none | `o` "PONG <uptime> <agent version>\n", `x` 0 |
| `i` info | none | `o` key=value lines (agent, kernel, machine, hostname, uptime, debian, systemd; since agent 2 also os_id, os_version_id, os_id_like from os-release), `x` 0 |
| `t` time | `u64` Unix ms | `x` 0 or errno |
| `f` write file | path `\0` octal mode `\0` data | `x` 0 or errno (tmp file + rename, O_NOFOLLOW) |
| `o` power | `poweroff` or `reboot` | `x` 0, then `systemctl poweroff/reboot` |
| `r` run | `key=value\n`... `\n` command | frames both ways, below |

`r` keys: `user` (default root), `pty=1`, `cols`, `rows`, `cwd`, `term`, `env=K=V` (repeatable).
An empty command with `pty=1` is the user's login shell; otherwise `/bin/sh -c command`. Users are
read from `/etc/passwd` and `/etc/group` directly. The command gets the distribution's PATH: Debian's on every
FHS system (root: `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`, a user:
`/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games`), and on NixOS (`/etc/NIXOS`) `/run/wrappers/bin`, the
user's profiles and `/run/current-system/sw/bin`. `o` runs the first systemctl of
`/run/current-system/sw/bin`, `/usr/bin`, `/bin`, else the kernel's reboot(). A non-root user gets `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS` when their systemd user session runs (the app enables linger).

During `r`: host to guest `d` stdin data (at most 64 KiB a frame), `e` stdin EOF (^D on a pty),
`w` `u16 cols, u16 rows`, `k` `u8 signal` (to the process group). Guest to host `o` output (stdout
and stderr merged, or the pty), then `x` status (exit code, or 128 + signal). The host closing the
channel first hangs the command up: SIGHUP to its process group, SIGKILL 2 s later.

## bsl-vmnet, port 5100: networking through the app (BSN1)

The VM has no network card. `vmnet-setup` gives it a dummy interface `bsl0` with the default
routes, and `vmnet.nft` redirects every TCP connection routed there to bsl-vmnet on
127.0.0.1:15001 / [::1]:15001 (SO_ORIGINAL_DST gives the destination). `resolv.conf` points at
bsl-vmnet on 127.0.0.1:53. The app keeps a pool of idle channels open to port 5100; the guest
speaks first on one when it needs it:

- `"BSN1" 'T' u8 family(4|6) addr[4|16] u16 port` -> host `u8` status (0 = connected), then raw
  bytes both ways. A refused connection is reset in the guest at once.
- `"BSN1" 'D' u16 len query` -> host `u16 len answer` (len 0 = no answer), then the host closes.

The app opens real sockets, so Android's VPN, Data Saver and per-app rules apply to the VM. Not
carried: UDP other than DNS, ICMP, connections into the VM. With `bsl.net=tap` on the kernel line
(the app's TAP option) none of this runs and systemd-networkd does DHCP on the TAP device.

## bsl-x11-relay, port 6000: the display

From the W0 spike (vm-spike d103e87), unchanged: it listens on `/tmp/.X11-unix/X0`, the app keeps
a pool of idle channels to port 6000, and each X client is paired with one and copied both ways,
no framing. The app connects each channel to its in-process X server when the client's first bytes
arrive. MIT-SHM and DRI3 cannot cross (a byte relay drops SCM_RIGHTS); clients fall back.

## Bridges: sound, microphone, notifications, clipboard (agent runs, no new port)

The host integration of a VM desktop session (Android `vm/VmBridges.kt`) rides on the agent's `r`
op: each bridge is a command the app runs in the VM, started after the session script and hung up
when the session stops. Nothing in the image is specific to them, so a VM system installed before
they existed gets them with the app. stderr always goes to `/dev/null` or a log: the agent merges it
into the output, which is the bridge's data.

| Bridge | Runs as | Command | Data |
|---|---|---|---|
| sound out | user | `bash`: wait for `127.0.0.1:4713`, then `cat </dev/tcp/127.0.0.1/4713` | output: s16le 48 kHz stereo from PulseAudio's simple protocol (`bsl-audio`), as AudioBridge reads it from TCP in the Standard engine; the app passes whole 4-byte frames only |
| microphone | user | `[ -p /tmp/bsl-mic.fifo ] && exec cat > /tmp/bsl-mic.fifo` | stdin: s16le 48 kHz mono into PulseAudio's pipe source; exit 3 = no FIFO yet (retried) |
| notifications, links, rich clipboard | user | `python3 -I -c <assets/vm/bsl-vmbridge.py>` | lines both ways, below |

`/run/bsl/features` is written first with the `f` op: `notify-v2 clipboard-v1`. Programs the app
starts as the user get `PULSE_SERVER=unix:/tmp/runtime-<user>/pulse/native`, the session's daemon:
the agent gives them `XDG_RUNTIME_DIR=/run/user/<uid>`, where systemd would socket-activate a second
PulseAudio with no stream to Android.

`bsl-vmbridge.py` carries the files the Standard engine shares in `/tmp` to a mirror folder in the
app (`files/vm-share/tmp/`), where the Standard engine's own GuestEventBridge and ClipboardBridge
run unchanged. One ASCII line per record, payloads base64:

- guest to host: `A <name> <b64>` (what was appended to `/tmp/<name>`: `.bsl-open`, `.bsl-notify`,
  `.bsl-notify2`, `.bsl-notify-action`; the file is taken by renaming it away), `B <path>` /
  `D <b64>` (48 KiB at most) / `E` (a whole file, only `.bsl-clip/to-android/<name>`, `clip.json`
  last), `R 0|1` (`bsl-clipboard` runs).
- host to guest: `B`/`D`/`E` into `.bsl-clip/to-linux/` or its `files/`, `offer.json` last;
  `X .bsl-clip/to-linux/files` empties that folder first.

Both ends refuse any other path, write beside the name and rename (never through a link), and the
host caps a line at 256 KiB and a file at 64 MiB.

## Files: /mnt/host and /mnt/android over SFTP (agent runs)

A custom VM gets no shared directories from Android, so each shared folder is an SFTP version 3
server in the app (Android `vm/SftpServer.kt`, confined to the folder: paths resolved by name with
".." stopping at the top, no links made or followed out, NUL refused) and Debian's
`sshfs -o passive` in the VM, run by the agent as root with the channel as its stdin and stdout
(`vm/VmFiles.kt` `mountCommand`, copied in `test/mount-share.sh`). Mounted with `allow_other,
default_permissions,uid=<user>,gid=<user>,dcache_timeout=5`: files show as the Linux user's, folders
0775 and files 0664 (Android stores no modes; chmod and chown succeed and change nothing). The shell
around sshfs unmounts on the agent's hangup, so a stopped session leaves no dead mount. /mnt/host is
the app's shared folder; /mnt/android all of shared storage, only with All files access. An image
without sshfs gets it from Debian at the first mount (`apt-get install sshfs`; `bake-vm.sh` now
includes it). Measured: arm64 KVM with OpenSSH's sftp-server as the host, 600-830 MB/s writing and
610-780 MB/s reading 64 MB; the app's server against Debian's sshfs over pipes, 87 / 143 MB/s.

## Images per distribution (4.0, plan 5.14 V4)

`bake-vm.sh` bakes Debian's image; `DISTRO=fedora|archlinux FROM=<proot image> bake-vm.sh` runs `bake-vm-distro.sh`,
which turns the proot image bootstrap-fedora.sh or bootstrap-arch.sh made into a VM image: the kernel and its
initramfs builder (Fedora: dracut with `hostonly=no` and kernel-install's `layout=other` with
`/etc/kernel/install.d/95-breadstick-vm.install`, which keeps `/boot/vmlinuz-<release>` as a raw Image, unpacked from
Fedora's arm64 EFI zboot file by `files/bsl-unzboot`; Arch: mkinitcpio with `files/archlinux/mkinitcpio.conf` and the
default preset only, and the `keep-modules` pacman hooks, which keep the running kernel's modules through a `linux`
update), the guest above through `guest/install.sh`, and the proot workarounds taken out (Fedora's sudo and /root
modes back to its own, Arch's stubs, masked hooks and DisableSandbox). Fedora boots with `selinux=0` (no policy is
installed). The manifest is `<distro>/manifest-vm-<arch>.json` beside Debian's `manifest-vm-<arch>.json`; image.json
carries `"distro"`.

A desktop VM image (round 10) is baked from the `-desktop-` proot image, which brings breadstick-desktop (the session
script the app runs in the VM, the theme, the tools) and XFCE; package-fixups' own DisableSandbox block in pacman.conf
comes out too, and `/run/bsl/engine` says `vm` while the step runs, so no Breadstick hook puts a proot workaround back.
`STAGE=<RPM or pacman stage>` brings Breadstick's installed packages up to a local stage's versions first (the image is
then named `-staged-`). `test/rpm-refresh.sh` is a copy of the RPM VM's daily refresh (Android
`VmGuestUpdate.refreshScript`, the proot RPM system's own `PackageOps.Dnf.refreshRun`), which qemu-test.py runs with
`RPM_STAGE=`.

## Terminal tabs (agent runs, plan 5.14 V9)

A tab is the user's tmux on a socket of the tab's own (`/tmp/.breadstick-tmux-<uid>-<key>`, `new-session -A`), so it
reattaches after the tab or the app closed, with a seed that hands the agent's `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS` over to breadstick-terminal.sh: while a desktop session runs, the app writes
`/run/bsl/session` in the VM (`f` op) and the tab takes the session's display, bus and sound at each prompt, and gets
the agent's back after Stop. Giving them back is the VM's own wrapper of breadstick-terminal.sh's hook
(`guest/files/terminal.sh`, after `profile.sh` in `/etc/profile.d/breadstick-vm.sh`; on NixOS in `/etc/bashrc` after
the Breadstick module's), so Debian's breadstick-terminal.sh stays as 3.x ships it; `test/terminal-agent.sh` checks it
step by step against round 9's in-package version. `test/tab-command.sh` is a copy of the app's command for tab "q1".

## File-level backups (agent runs, plan 5.14 V20)

`test/file-backup.sh` (Android `VmFileBackup.TAR_SCRIPT`) streams the root file system as a POSIX tar with numeric
owners and extended attributes; the app writes it into the same format-2 archive a proot system's backup is. A restore
streams the backup's files into `test/file-unpack-vm.sh` (a VM's backup: owners kept) or `test/file-unpack-proot.sh`
(a proot system's: everything root's, each home folder given to its account), which unpack into
`/var/lib/breadstick-vm/restore`; only a whole backup is then laid over the system by `test/file-restore.sh`, which
leaves the image's VM guest in place, and the app restarts the VM. A proot system's backup is laid over by
`test/file-restore-proot.sh`, which also keeps the image's own files (its kernel, systemd, D-Bus), makes the system
accounts their packages declare (`systemd-sysusers`) and, at the end, puts the VM's own packages back in the restored
package database (dpkg's status, rpm's database through `rpmdb --importdb`, pacman's kept entries without duplicates),
round 10. None it puts back may break the restored system's dependencies: a package the family's own check names
(`apt-get check` over a trial status, `rpm -Va --nofiles` after the import, `pacman -Dk`), or one it alone breaks, is left
out again until the check is clean or names only what the backup itself had broken (round 10 review: Debian's base image
got the VM's breadstick-desktop back, which needs a newer apt, and every `apt-get install` exited 100).
The restore's log (`/var/log/breadstick-vm-restore.log`) names each one left out. `test/pkgdb-merge-test.sh` runs
that step for each family in a container on made-up packages.

## Ways in: Breadstick Settings, bsl-mcp, SSH (agent runs, plan 5.14 V13, V18)

Only the host opens channels, so each way into the VM is a channel the app opens, and none needs a new guest program
(an image published before 4.0 takes them as it is). Android `vm/VmInbound.kt`, `vm/VmSocketRelay.kt`,
`vm/VmPortForward.kt`; the commands are `VmCommands`', copied here byte for byte from Android's
`app/src/test/resources/vm/` (VmInboundTest checks those are the app's text). qemu-test.py prints each one's sha256 as
`SCRIPT <name> <sha256>` when it runs it, and AutoBuild's parity gate compares that with Android's copy, so a copy
here that drifted fails the cells it backs.

- **/run/bsl/settings.sock** (Breadstick Settings in Linux): at the boot the app runs `test/settings-relay.sh` as root:
  the image's bsl-x11-relay on vsock **6100**, listening at `/run/breadstick-vm/relay/settings.sock` (the relay makes
  its socket's folder 1777, which /run/bsl must not be), with /run/bsl/settings.sock a link to it. The app keeps two
  idle channels to 6100 and serves each paired one as a connection to its settings socket (same protocol, same rules).
  The link and the relay go when the app hangs the command up.
- **bsl-mcp**: `/run/bsl/mcp` (port, key) written by `test/mcp-file.sh` from stdin, 0600 and the Linux user's, while the
  app's MCP server runs; `test/host-ports.sh` gives the table `ip breadstick_vm_host`, which sends the VM's own
  127.0.0.1:<that port> to bsl-vmnet (as vmnet.nft does for bsl0), and VmNetRelay connects it to the app's 127.0.0.1.
- **SSH on 2222**: the app's own setup (`test/ssh-setup-<distro>.sh`, the proot script with the distribution's sshd
  units left off and `PerSourcePenaltyExemptList 127.0.0.1` in `/etc/ssh/sshd_config.d/breadstick-vm.conf` when sshd
  knows the option), `test/sshd-start.sh` held by the app (sshd makes a session of its own even with -D, so the shell
  around it ends it and its sessions on the hangup), `test/authkeys.sh` for ~/.ssh/authorized_keys: an edit read from
  stdin ("+ KEY" adds, "- KEY" removes) applied to the file the VM has, never a copy of the app's list written over it;
  it prints `OK added=N removed=M`. The app listens on 2222 on Android and runs `test/port-forward.sh` for each
  connection (its stdin and output are the connection; stderr nowhere, exit 7 when nothing listens): python3 connects
  to 127.0.0.1:2222 FROM a loopback address of the client's own, 127. and the client's last three bytes
  (192.168.1.20 is 127.168.1.20, the copy's), so sshd's per-source penalties (OpenSSH 9.8 and later) fall on the
  client that earned them, as under proot, and its log names the client; without python3, bash's /dev/tcp from
  127.0.0.1, the exempt address.

qemu-test.py's "parity: ..." checks run all three against the image (PARITY=0 skips them); AutoBuild
`test/parity/parity-gate.py` reads them per distribution.

## Testing without a device

```
gcc -O2 -DTEST_HOST_PATH='"/tmp/a.sock"' -o /tmp/agent guest/bsl-vmagent.c && /tmp/agent &
test/bslvm.py --unix /tmp/a.sock run 'id; uname -a'
test/qemu-arm64.sh <image folder>      # boots the image under KVM with vhost-vsock (Docker)
guest/build.sh arm64 /tmp/bin && AGENT_DIR=/tmp/bin test/qemu-test.sh <image folder> arm64   # today's programs on a published image
test/guest-distros.sh                   # install.sh, the units, the user script and the agent on Debian, Fedora and Arch
```

`test/prepare-user.sh` and `test/boot-pair.sh` are copies of Android `VmCommands.prepareUserScript("tester")` and
`VmCommands.BOOT_PAIR_SCRIPT` (Android's VmCommandsTest checks its own copies). qemu-test.py's kernel test (plan 5.14
V7) installs a newer kernel in the VM, copies the pair the disk then boots out through the agent as the app does,
boots it, boots a truncated kernel (which must never answer), and boots the copied pair again.
