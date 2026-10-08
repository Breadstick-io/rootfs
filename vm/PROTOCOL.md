# Breadstick VM: guest programs and their vsock protocols

The VM image (`bake-vm.sh`) carries three programs in `/usr/lib/breadstick-vm/`, each a systemd
unit. The app's half is in Android `app/src/main/java/io/breadstick/vm/` (branch `vm-2.0`);
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
| `i` info | none | `o` key=value lines (agent, kernel, machine, hostname, uptime, debian, systemd), `x` 0 |
| `t` time | `u64` Unix ms | `x` 0 or errno |
| `f` write file | path `\0` octal mode `\0` data | `x` 0 or errno (tmp file + rename, O_NOFOLLOW) |
| `o` power | `poweroff` or `reboot` | `x` 0, then `systemctl poweroff/reboot` |
| `r` run | `key=value\n`... `\n` command | frames both ways, below |

`r` keys: `user` (default root), `pty=1`, `cols`, `rows`, `cwd`, `term`, `env=K=V` (repeatable).
An empty command with `pty=1` is the user's login shell; otherwise `/bin/sh -c command`. Users are
read from `/etc/passwd` and `/etc/group` directly. A non-root user gets `XDG_RUNTIME_DIR` and
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

## Testing without a device

```
gcc -O2 -DTEST_HOST_PATH='"/tmp/a.sock"' -o /tmp/agent guest/bsl-vmagent.c && /tmp/agent &
test/bslvm.py --unix /tmp/a.sock run 'id; uname -a'
test/qemu-arm64.sh <image folder>      # boots the image under KVM with vhost-vsock (Docker)
```
