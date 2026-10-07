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
q = subprocess.Popen(qemu + [
    "-m", "2048", "-smp", "4", "-kernel", "/w/vmlinuz", "-initrd", "/w/initrd.img", "-append", cmdline,
    "-drive", "file=/w/root.img,if=virtio,format=raw", "-device", f"vhost-vsock-pci,guest-cid={CID}",
    "-nic", "none", "-display", "none", "-serial", "file:/w/console.log", "-monitor", "none",
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
check("agent answers", up is not None and up.startswith("PONG"), f"{up!r} after {time.time() - t0:.1f}s")
if up is None:
    print("last error:", last)
    print(open("/w/console.log", errors="replace").read()[-3000:])
    q.kill()
    sys.exit(1)

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

# The app's user preparation (VmCommands.prepareUserScript).
prep = open("/t/prepare-user.sh").read() if os.path.exists("/t/prepare-user.sh") else None
o, st = run(prep or "true")
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

# Clean power-off.
out, st = bslvm.simple(args, "o", b"poweroff")
try:
    q.wait(120)
    check("power off", True, f"qemu exit {q.returncode}")
except subprocess.TimeoutExpired:
    q.kill()
    check("power off", False, "qemu still running after 120 s")

print(f"\n{len(fails)} failed: {fails}" if fails else "\nALL PASS")
sys.exit(1 if fails else 0)
