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
check("the kernel line names the system profile's init", "init=/nix/var/nix/profiles/system/init" in cmdline, cmdline)
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
o2, st2 = run("/run/current-system/sw/bin/bsl-nix channel stable && test -w /etc/breadstick/nix/packages.json && echo writable")
check("the page's files are writable", st2 == 0 and "writable" in o2, o2.strip()[-200:])
check("bsl-nix status: the vm engine, generation 1", s.get("engine") == "vm" and s.get("generation") == 1, o.strip()[-300:])
o, st = run("bash -lc \"ls -d /nix/store/*-nixpkgs-* | head -1; nix-instantiate --eval -E '(import <nixpkgs> {}).hello.version'\"")
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

# The Nix packages page in the VM (X2): add, apply through switch-to-configuration (systemd is PID 1), roll back, gc.
B = "/run/current-system/sw/bin/bsl-nix"
t1 = time.time()
o, st = run(f"{B} add hello && {B} apply 2>&1 | grep -E '^\\[BSL\\]'")
check("apply in the VM", st == 0 and "switching to" in o and "applied: generation 2" in o,
      f"{time.time() - t1:.0f} s: " + o.strip().replace("\n", " | ")[-300:])
o, st = run("hello", user="tester")
check("hello as the user after the apply", o.strip() == "Hello, world!", o.strip()[-200:])
o, st = run(f"{B} rollback 2>&1 | tail -2; command -v hello || echo gone")
check("roll back in the VM", st == 0 and "rolled back to generation 1" in o and "gone" in o, o.strip().replace("\n", " | ")[-300:])
# Generation 1 is the image's own, made before the account: the account stays (round 10, F7; the Pixel's proot
# rollback removed it), and so does sudo for it.
o, st = run("id -un; sudo -n true && echo sudo-ok", user="tester")
check("the account and its sudo after the rollback to generation 1", st == 0 and "tester" in o and "sudo-ok" in o,
      o.strip().replace("\n", " | "))
o, st = run(f"{B} generations --json")
check("every generation keeps the account (generations --json)", st == 0 and '"keepsAccount": false' not in o and "keepsAccount" in o,
      o.strip()[-200:])
o, st = run("readlink /nix/var/nix/gcroots/breadstick-nixpkgs; readlink -f /etc/breadstick/nix/nixpkgs; "
            "for r in /nix/var/nix/gcroots/auto/*; do [ -L \"$r\" ] && [ ! -e \"$r\" ] && echo dangling; done; true")
lines = o.split()
check("nixpkgs is a gc root, no dangling roots (round 9 review)", len(lines) >= 2 and lines[0] == lines[1] and "dangling" not in o, o.strip())
o, st = run(f"{B} gc 2>&1 | tail -2")
check("gc in the VM", st == 0 and "freed" in o, o.strip().replace("\n", " | ")[-200:])
# After a clean up the page still works: nixpkgs stays (round 9 review: gc took it, and every add and apply failed).
o, st = run(f"{B} add hello && {B} apply 2>&1 | tail -2")
check("add and apply after gc", st == 0 and "applied: generation" in o, o.strip().replace("\n", " | ")[-300:])
o, st = run(f"{B} keyrings; cat /home/tester/.local/share/keyrings/default")
check("the user's desktop keyring in the VM", o.strip().endswith("login"), o.strip()[-200:])

# A switch that changes the guest's own units, through the agent as the app runs it (round 9 review: `bsl-nix
# languages` changed every unit, since NixOS gives them all LOCALE_ARCHIVE, and switch-to-configuration stopped the
# agent with the switch inside it; the VM was lost until a hard reset). The device state first, as the app now writes
# it before the fill (X11DesktopSession: region, online, network_metered).
UNITS = "bsl-vmagent bsl-vmnet bsl-x11-relay"
o, st = run(f"systemctl show -p InvocationID --value {UNITS}; readlink -f /etc/systemd/system/bsl-vmagent.service")
before = o.split()
o, st = run("mkdir -p /run/bsl && printf 'LANG=de_DE.UTF-8\\nLANGUAGE=de_DE:en_US\\n' > /run/bsl/region && "
            "echo 1 > /run/bsl/online && echo 0 > /run/bsl/network_metered && echo written")
t1 = time.time()
lang_out, lang_st = None, None
try:
    lang_out, lang_st = run(f"{B} languages > /tmp/languages.out 2>&1; rc=$?; grep -E '^\\[BSL\\]' /tmp/languages.out; exit $rc")
except (OSError, EOFError) as e:
    lang_out = f"the agent connection dropped: {e!r}"
check("languages through the agent in the VM", lang_st == 0 and "de_DE.UTF-8 filled in" in (lang_out or ""),
      f"{time.time() - t1:.0f} s: " + (lang_out or "").strip().replace("\n", " | ")[-300:])
agent = None
for _ in range(60):
    try:
        agent = bslvm.simple(args, "p")[0].decode()
        break
    except OSError:
        time.sleep(1)
check("the agent still answers after the switch", agent is not None and agent.startswith("PONG"), repr(agent))
o, st = run(f"systemctl is-active {UNITS}; systemctl show -p InvocationID --value {UNITS}; "
            "readlink -f /etc/systemd/system/bsl-vmagent.service; locale -a | grep -ix de_DE.utf8")
after = o.split()
check("the guest's units neither stopped nor restarted, though they changed",
      after[:3] == ["active"] * 3 and after[3:6] == before[:3] and len(after) > 6 and len(before) > 3 and after[6] != before[3],
      " ".join(before) + " -> " + " ".join(after))
check("German is a locale", any(w.lower() == "de_de.utf8" for w in after[7:]), " ".join(after[7:]))
o, st = run("getent hosts channels.nixos.org")
check("dns through the host after the switch", st == 0 and o.strip() != "", o.strip())
# And again: nothing more to do, and rolled back to before the fill it stays there (round 9 review).
o, st = run(f"{B} languages 2>&1 | tail -2")
check("languages the second time", st == 0 and "in" in o and "filling" not in o, o.strip().replace("\n", " | "))
o, st = run(f"{B} rollback 2>&1 | tail -1; {B} languages; echo rc=$?")
check("languages never undo a rollback", "one you rolled back to" in o and "rc=4" in o, o.strip().replace("\n", " | ")[-300:])
o, st = run(f"systemctl is-active {UNITS}")
check("the guest's units after the rollback's switch", o.split() == ["active"] * 3, o.strip().replace("\n", " "))

bslvm.simple(args, "o", b"poweroff")
try:
    q.wait(120)
    check("power off", True, f"qemu exit {q.returncode}")
except subprocess.TimeoutExpired:
    q.kill()
    check("power off", False, "qemu still running after 120 s")
print(f"{len(fails)} failed: {' '.join(fails)}" if fails else "all passed")
sys.exit(1 if fails else 0)
