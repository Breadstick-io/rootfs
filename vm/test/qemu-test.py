#!/usr/bin/env python3
"""Runs inside bsl-vmtest:1 (see qemu-test.sh): boots /w/{vmlinuz,initrd.img,root.img} and tests it."""
import os
import struct
import subprocess
import sys
import threading
import time
import types

sys.path.insert(0, "/t")
import bslvm  # noqa: E402

ARCH = os.environ.get("ARCH", "arm64")
CID = 77
args = types.SimpleNamespace(unix=None, cid=CID)
fails = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}", flush=True)
    if not ok:
        fails.append(name)


def run(cmd, user="root", **kw):
    out, st = bslvm.run(args, cmd, user, **kw)
    return out.decode(errors="replace"), st


if ARCH == "arm64":
    qemu = ["qemu-system-aarch64", "-M", "virt", "-cpu", "host", "-accel", "kvm"]
    console = "console=ttyAMA0"
else:
    qemu = ["qemu-system-x86_64", "-M", "q35", "-cpu", "max", "-accel", "tcg"]
    console = "console=ttyS0"
cmdline = f"{console} root=/dev/vda rw panic=-1 bsl.vm=1"


def boot(label=""):
    """Starts QEMU on /w/root.img and waits for the agent. Returns the QEMU process."""
    q = subprocess.Popen(qemu + [
        "-m", "2048", "-smp", "4", "-kernel", "/w/vmlinuz", "-initrd", "/w/initrd.img", "-append", cmdline,
        "-drive", "file=/w/root.img,if=virtio,format=raw,discard=unmap", "-device", f"vhost-vsock-pci,guest-cid={CID}",
        "-nic", "none", "-display", "none", "-serial", f"file:/w/console{label}.log", "-monitor", "none",
    ])
    t0 = time.time()
    up = None
    last = None
    while time.time() - t0 < (120 if ARCH == "arm64" else 900):
        try:
            out, st = bslvm.simple(args, "p")
            up = out.decode()
            break
        except OSError as e:
            last = e
            time.sleep(0.5)
    check(f"agent answers{label}", up is not None and up.startswith("PONG"), f"{up!r} after {time.time() - t0:.1f}s")
    if up is None:
        print("last error:", last)
        print(open(f"/w/console{label}.log", errors="replace").read()[-3000:])
        q.kill()
        sys.exit(1)
    return q


def power_off(q, label=""):
    bslvm.simple(args, "o", b"poweroff")
    try:
        q.wait(120)
        check(f"power off{label}", True, f"qemu exit {q.returncode}")
    except subprocess.TimeoutExpired:
        q.kill()
        check(f"power off{label}", False, "qemu still running after 120 s")


def stored_mib(path):
    return os.stat(path).st_blocks * 512 // (1 << 20)


q = boot()

out, st = bslvm.simple(args, "i")
check("info", st == 0 and b"systemd=1" in out, out.decode().replace("\n", " "))
out, st = bslvm.simple(args, "t", struct.pack("<Q", int(time.time() * 1000)))
check("set time", st == 0)
o, st = run("date +%s")
check("clock", st == 0 and abs(int(o.strip()) - time.time()) < 30, o.strip())
out, st = bslvm.simple(args, "f", b"/run/bsl-test\0" + b"640\0" + b"hello\n")
o, _ = run("stat -c %a /run/bsl-test; cat /run/bsl-test")
check("write file", st == 0 and o.split() == ["640", "hello"], o)

o, st = run("systemctl is-system-running --wait; systemctl --failed --no-legend")
check("systemd", "running" in o or "degraded" in o, o.strip().replace("\n", " | "))

# The app's user preparation: a copy of Android vm/VmCommands.prepareUserScript("tester").
PREPARE_USER = r"""
set -u
u='tester'
if ! id -u "$u" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,audio,video,plugdev,users "$u" 2>/dev/null || useradd -m -s /bin/bash -G sudo "$u" || exit 1
  passwd -d "$u" >/dev/null 2>&1 || true
fi
mkdir -p /run/bsl && echo vm > /run/bsl/engine
uid=$(id -u "$u")
loginctl enable-linger "$u" 2>/dev/null || true
i=0
while [ ! -S "/run/user/$uid/bus" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
[ -S "/run/user/$uid/bus" ] && echo "bus ok" || echo "no user bus (session apps may complain)"
"""
o, st = run(PREPARE_USER)
check("prepare user", st == 0 and "bus ok" in o, o.strip())
o, st = run("id -un; echo $XDG_RUNTIME_DIR; echo $DBUS_SESSION_BUS_ADDRESS; sudo -n true && echo sudo-ok", user="tester")
check("user session", st == 0 and "tester" in o and "/run/user/" in o and "sudo-ok" in o, o.strip().replace("\n", " | "))

o, st = run("tty; stty size", user="tester", pty=True)
check("pty", st == 0 and "/dev/pts/" in o, o.strip().replace("\r\n", " | "))
o, st = run("cat | tr a-z A-Z", stdin=b"stdin works\n")
check("stdin", o.strip() == "STDIN WORKS", o.strip())
o, st = run("exit 42")
check("exit status", st == 42, str(st))

# Hangup: closing the channel kills the command.
s = bslvm.connect(args, bslvm.AGENT_PORT)
bslvm.request(s, "r", bslvm.run_payload("exec sleep 4242"))
time.sleep(0.5)
s.close()
time.sleep(1.5)
o, _ = run("pgrep -x -f 'sleep 4242' || echo gone")
check("hangup ends the command", "gone" in o, o.strip())

o, st = run("ip route; ip -6 route; nft list ruleset | grep -c redirect; cat /etc/resolv.conf; systemctl is-active bsl-vmnet bsl-x11-relay")
check("net plumbing", "default dev bsl0" in o and "active\nactive" in o, o.strip().replace("\n", " | "))

# Networking through a host relay (the app's VmNetRelay does this on the device).
threading.Thread(target=bslvm.net_serve, args=(args, 8), daemon=True).start()
time.sleep(1)
o, st = run("getent hosts deb.debian.org")
check("dns through the host", st == 0 and o.strip() != "", o.strip())
o, st = run("curl -sS -o /dev/null -w '%{http_code}' https://deb.debian.org/debian/dists/trixie/Release")
check("https through the host", o.strip() == "200", o.strip())
o, st = run("apt-get update 2>&1 | tail -3", user="root")
check("apt-get update", st == 0 and "Reading package lists" in o and "Err" not in o, o.strip().replace("\n", " | "))
o, st = run("DEBIAN_FRONTEND=noninteractive apt-get install -y -q cowsay >/dev/null 2>&1 && /usr/games/cowsay moo | tail -1")
check("apt-get install", st == 0, o.strip())

# The display: a host X server (Xvfb here, the app's lorie on a device) behind a host-side pool of
# channels to the guest relay on vsock 6000, the way the app's VmX11Relay does it.
if os.path.exists("/usr/bin/Xvfb"):
    import socket as so
    xvfb = subprocess.Popen(["Xvfb", ":5", "-screen", "0", "1280x800x24", "-nolisten", "tcp"], stderr=subprocess.DEVNULL)
    time.sleep(1.5)

    def x11_pool():
        idle = [0]
        lock = threading.Lock()

        def chan(c):
            try:
                first = c.recv(65536)
            except OSError:
                first = b""
            with lock:
                idle[0] -= 1
            if not first:
                c.close()
                return
            x = so.socket(so.AF_UNIX, so.SOCK_STREAM)
            x.connect("/tmp/.X11-unix/X5")
            x.sendall(first)
            threading.Thread(target=lambda: (bslvm.splice(x, c), c.close()), daemon=True).start()
            bslvm.splice(c, x)
            try:
                x.shutdown(so.SHUT_WR)
            except OSError:
                pass

        while True:
            with lock:
                n = idle[0]
            if n < 4:
                try:
                    c = bslvm.connect(args, 6000)
                except OSError:
                    time.sleep(0.3)
                    continue
                with lock:
                    idle[0] += 1
                threading.Thread(target=chan, args=(c,), daemon=True).start()
            else:
                time.sleep(0.05)

    threading.Thread(target=x11_pool, daemon=True).start()
    time.sleep(1)
    o, st = run("DISPLAY=:0 xdpyinfo | grep -E 'dimensions|number of screens'", user="tester")
    check("x11 relay", st == 0 and "1280x800" in o, o.strip().replace("\n", " | "))
    o, st = run("command -v startxfce4 >/dev/null || exit 77; (DISPLAY=:0 timeout 25 startxfce4 >/tmp/xfce.log 2>&1 &); "
                "sleep 20; DISPLAY=:0 xwininfo -root -children | grep -c -E 'xfce4-panel|xfdesktop|Xfwm4' ; pgrep -c -u tester -x xfwm4",
                user="tester")
    if st == 77:
        print("SKIP xfce (no desktop in this image)")
    else:
        check("xfce draws through the relay", st == 0 and o.split()[0] != "0", o.strip().replace("\n", " | "))
    xvfb.kill()

# The disk grows without losing anything (Android vm/VmDisk.kt): data written now must be there
# after the app makes the file larger, and the file system must fill the larger disk.
o, st = run("dd if=/dev/urandom of=/var/tmp/bsl-keep bs=1M count=8 status=none && sha256sum /var/tmp/bsl-keep | cut -d' ' -f1; "
            "df -B1 --output=size / | tail -1")
keep_sum, size1 = (o.split() + ["", ""])[:2]
check("disk: data written before growing", st == 0 and len(keep_sum) == 64, o.strip().replace("\n", " | "))

power_off(q)

if os.environ.get("GROW", "1") == "1":
    before = os.path.getsize("/w/root.img")
    stored_before = stored_mib("/w/root.img")
    # What VmDisk.grow does: the file's length only (ftruncate), while nothing has it open.
    with open("/w/root.img", "r+b") as f:
        f.truncate(before + (4 << 30))
    q = boot(" (grown disk)")
    o, st = run("sha256sum /var/tmp/bsl-keep | cut -d' ' -f1; df -B1 --output=size / | tail -1; "
                "systemctl show -p ActiveState --value systemd-growfs-root.service 2>/dev/null || true")
    parts = o.split()
    check("disk: data kept after growing", st == 0 and parts[:1] == [keep_sum], o.strip().replace("\n", " | "))
    grown = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    check("disk: file system grew at boot", grown > int(size1 or 0) + (3 << 30), f"{int(size1 or 0) >> 20} MiB -> {grown >> 20} MiB")
    # The app's own grow step after the agent answers (VmDisk.GROW_FS_SCRIPT): nothing left to do.
    GROW_FS = open("/t/grow-fs.sh").read() if os.path.exists("/t/grow-fs.sh") else None
    if GROW_FS:
        o, st = run(GROW_FS)
        check("disk: the app's resize2fs step", st == 0 and ("Nothing to do" in o or "is now" in o), o.strip().replace("\n", " | "))
    check("disk: growing stored next to nothing", stored_mib("/w/root.img") - stored_before < 512,
          f"stored {stored_before} -> {stored_mib('/w/root.img')} MiB, length {before >> 20} -> {os.path.getsize('/w/root.img') >> 20} MiB")
    power_off(q, " (grown disk)")

print(f"\n{len(fails)} failed: {fails}" if fails else "\nALL PASS")
sys.exit(1 if fails else 0)
