#!/usr/bin/env python3
"""Breadstick-Nix's VM image under QEMU (round 9, plan 5.14 V4): runs inside bsl-vmtest:3 (qemu-test-nix.sh). Boots
/w/{vmlinuz,initrd.img,root.img} with the image's own kernel line (image.json's cmdline: init=/sbin/init) and checks
the agent, systemd, the guest units, the app's user preparation, bsl-nix and the network relay, then powers off."""
import json
import os
import subprocess
import sys
import threading
import time
import types

sys.path.insert(0, "/t")
import bslvm  # noqa: E402

ARCH = os.environ.get("ARCH", "arm64")
CID = int(os.environ.get("CID", "79"))
args = types.SimpleNamespace(unix=None, cid=CID)
fails = []
manifest = json.load(open("/w/image.json"))


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
# The image's own line, its console swapped for QEMU's machine's.
line = " ".join(w for w in manifest["cmdline"].split() if not w.startswith("console=") and w != "quiet")
cmdline = f"{console} {line} bsl.vm=1"
check("the kernel line names the system's init", "init=/sbin/init" in cmdline, cmdline)
check("image.json says nix", manifest.get("distro") == "nix", str(manifest.get("distro")))

q = subprocess.Popen(qemu + [
    "-m", "3072", "-smp", "4", "-kernel", "/w/vmlinuz", "-initrd", "/w/initrd.img", "-append", cmdline,
    "-drive", "file=/w/root.img,if=virtio,format=raw,discard=unmap", "-device", f"vhost-vsock-pci,guest-cid={CID}",
    "-nic", "none", "-display", "none", "-serial", "file:/w/console.log", "-monitor", "none",
])
t0 = time.time()
up = None
while time.time() - t0 < (240 if ARCH == "arm64" else 1800):
    try:
        out, st = bslvm.simple(args, "p")
        up = out.decode()
        break
    except OSError:
        time.sleep(0.5)
check("agent answers", up is not None and up.startswith("PONG"), f"{up!r} after {time.time() - t0:.1f}s")
if up is None:
    print(open("/w/console.log", errors="replace").read()[-4000:])
    q.kill()
    sys.exit(1)

out, st = bslvm.simple(args, "i")
info = dict(l.split("=", 1) for l in out.decode().splitlines() if "=" in l)
check("info: systemd and os-release", st == 0 and info.get("systemd") == "1" and info.get("os_id") == "nixos",
      out.decode().replace("\n", " "))
o, st = run("systemctl is-system-running --wait; systemctl --failed --no-legend")
check("systemd", "running" in o or "degraded" in o, o.strip().replace("\n", " | "))
o, st = run("systemctl is-active bsl-vmagent bsl-vmnet bsl-x11-relay")
check("the guest's units", o.split() == ["active", "active", "active"], o.strip().replace("\n", " "))
o, st = run("nixos-version; readlink /run/current-system; test -e /etc/NIXOS && echo nixos-marker")
check("NixOS, its running generation", st == 0 and "nixos-marker" in o and "/nix/store/" in o, o.strip().replace("\n", " | "))
o, st = run("/run/current-system/sw/bin/bsl-nix status --json")
try:
    s = json.loads(o.strip().splitlines()[-1])
except Exception:
    s = {}
check("bsl-nix status: the vm engine, generation 1", s.get("engine") == "vm" and s.get("generation") == 1, o.strip()[-300:])
o, st = run("ls -d /nix/store/*-nixpkgs-* | head -1; nix-instantiate --eval -E '(import <nixpkgs> {}).hello.version'")
check("nixpkgs is in the image and evaluates", st == 0 and '"' in o, o.strip().replace("\n", " | ")[-200:])

PREPARE_USER = open("/t/prepare-user.sh").read()
o, st = run(PREPARE_USER)
check("prepare user", st == 0 and "bus ok" in o, o.strip().replace("\n", " | ")[-300:])
o, st = run("id -un; echo $XDG_RUNTIME_DIR; sudo -n true && echo sudo-ok; command -v xfce4-session", user="tester")
check("user session, sudo, the desktop's programs", st == 0 and "tester" in o and "sudo-ok" in o and "xfce4-session" in o,
      o.strip().replace("\n", " | "))

threading.Thread(target=bslvm.net_serve, args=(args, 8), daemon=True).start()
time.sleep(1)
o, st = run("getent hosts channels.nixos.org")
check("dns through the host", st == 0 and o.strip() != "", o.strip())
o, st = run("/run/current-system/sw/bin/bsl-nix check")
check("bsl-nix check (the channel through the host)", st == 0 and o.strip().splitlines()[-1:] in (["0"], ["1"]), o.strip()[-200:])

bslvm.simple(args, "o", b"poweroff")
try:
    q.wait(120)
    check("power off", True, f"qemu exit {q.returncode}")
except subprocess.TimeoutExpired:
    q.kill()
    check("power off", False, "qemu still running after 120 s")
print(f"{len(fails)} failed: {' '.join(fails)}" if fails else "all passed")
sys.exit(1 if fails else 0)
