#!/usr/bin/env python3
"""The Nix based instance moved between the engines, the VM half (4.0 round 12, plan 5.14 V21; Android
linux/NixEngineMove.kt and vm/VmFileBackup.kt's NIX_SAVE, NIX_STORE_WRITABLE and NIX_ENGINE_VM). Runs inside bsl-vmtest:3
(qemu-test-nix-move.sh), with /w/root.img the Nix VM image's disk and /w/instance.tar a real Standard instance's tree
(bootstrap/test-nix-move-proot.sh make: the desktop image, its account tester, hello applied, a file in the home).

  1. The app's first boot of a VM disk: the image's files recorded (image-files.sh), the account made (prepare-user.sh):
     uid 1000 with its own group 1000 (R11-4).
  2. Standard to the VM, as the app's move runs it: the instance streamed into the stage (file-unpack-proot.sh) and laid
     over the VM (file-restore-proot.sh), which builds the instance's configuration for the VM; the next boot runs that
     generation with the instance's hello, account and files, the VM guest, sudo, the page, and a rollback to the
     Standard engine's generation refused.
  3. The VM to Standard, its VM half: NixEngineMove.PREPARE_PROOT (nix-prepare-proot.sh) builds the proot generation,
     then the move's archive of the VM (file-backup-strict.sh) to /w/vm-backup.tar, which the proot half (test-nix-move-proot.sh unpack,
     NixEngineMoveTest, start) moves on.
"""
import json
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
CID = int(os.environ.get("CID", "81"))
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


def app_text(name):
    return open(f"/t/{name}").read()


if ARCH == "arm64":
    qemu = ["qemu-system-aarch64", "-M", "virt", "-cpu", "host", "-accel", "kvm"]
    console = "console=ttyAMA0"
else:
    qemu = ["qemu-system-x86_64", "-M", "q35", "-cpu", "max", "-accel", "tcg"]
    console = "console=ttyS0"
line = " ".join(w for w in manifest["cmdline"].split() if not w.startswith("console=") and w != "quiet")
cmdline = f"{console} {line} bsl.vm=1"
print(f"image: {manifest.get('name', '(no name)')}, distro nix, the move test, kernel line: {cmdline}", flush=True)


def boot(label):
    q = subprocess.Popen(qemu + [
        "-m", "4096", "-smp", "4", "-kernel", "/w/vmlinuz", "-initrd", "/w/initrd.img", "-append", cmdline,
        "-drive", "file=/w/root.img,if=virtio,format=raw,discard=unmap", "-device", f"vhost-vsock-pci,guest-cid={CID}",
        "-nic", "none", "-display", "none", "-serial", f"file:/w/console{label}.log", "-monitor", "none",
    ])
    t0 = time.time()
    up = None
    while time.time() - t0 < (300 if ARCH == "arm64" else 2400):
        try:
            out, _ = bslvm.simple(args, "p")
            up = out.decode()
            break
        except OSError:
            time.sleep(0.5)
    check(f"agent answers{label}", up is not None and up.startswith("PONG"), f"after {time.time() - t0:.1f}s")
    if up is None:
        print(open(f"/w/console{label}.log", errors="replace").read()[-4000:])
        q.kill()
        sys.exit(1)
    o, _ = run("systemctl is-system-running --wait")
    check(f"systemd{label}", o.strip() in ("running", "degraded"), o.strip())
    return q


def power_off(q, label):
    bslvm.simple(args, "o", b"poweroff")
    try:
        q.wait(180)
        check(f"power off{label}", True)
    except subprocess.TimeoutExpired:
        q.kill()
        check(f"power off{label}", False, "qemu still running after 180 s")


def stream_in(cmd, path):
    out, st = b"", None
    with bslvm.connect(args, bslvm.AGENT_PORT) as s:
        bslvm.request(s, "r", bslvm.run_payload(cmd, "root"))

        def feed():
            with open(path, "rb") as f:
                for b in iter(lambda: f.read(65536), b""):
                    bslvm.send_frame(s, "d", b)
            bslvm.send_frame(s, "e")

        threading.Thread(target=feed, daemon=True).start()
        for t, d in bslvm.frames(s):
            if t == "o":
                out += d
            elif t == "x":
                st = struct.unpack("<i", d)[0]
    return st, out.decode(errors="replace")


def stream_out(cmd, path):
    n, st = 0, None
    with bslvm.connect(args, bslvm.AGENT_PORT) as s, open(path, "wb") as f:
        bslvm.request(s, "r", bslvm.run_payload(cmd, "root"))
        bslvm.send_frame(s, "e")
        for t, d in bslvm.frames(s):
            if t == "o":
                f.write(d)
                n += len(d)
            elif t == "x":
                st = struct.unpack("<i", d)[0]
    return st, n


B = "/run/current-system/sw/bin/bsl-nix"
threading.Thread(target=bslvm.net_serve, args=(args, 8), daemon=True).start()

# --- 1. the app's first boot of the disk ------------------------------------------------------------------------
q = boot(" (first)")
image_sys, _ = run("readlink -f /nix/var/nix/profiles/system")
o, st = run(app_text("image-files.sh"))
check("the image's files recorded", st == 0 and "recorded" in o, o.strip()[-200:])
o, st = run(app_text("prepare-user.sh"))
check("prepare user", st == 0 and "bus ok" in o, o.strip().replace("\n", " | ")[-300:])
o, st = run("id tester; getent group tester")
check("R11-4: the account is uid 1000 with its own group 1000, as under proot",
      "uid=1000(tester) gid=1000(tester)" in o and o.strip().splitlines()[-1].split(":")[0::2][:2] == ["tester", "1000"], o.strip().replace("\n", " | "))
o, st = run("findmnt -no OPTIONS /nix/store")
print(f"/nix/store is mounted {o.strip()}", flush=True)

# --- 2. Standard to the VM --------------------------------------------------------------------------------------
t0 = time.time()
st, o = stream_in(app_text("file-unpack-proot.sh"), "/w/instance.tar")
check("move in: the instance in the stage", st == 0, f"exit {st} {o.strip()[-200:]} ({time.time() - t0:.0f} s)")
t0 = time.time()
o, st = run(app_text("file-restore-proot.sh"))
said = [l for l in o.splitlines() if l.startswith("nix:") or "Nix based" in l]
check("move in: laid over the VM and built for it", st == 0 and "restored" in o and any(l.startswith("nix: the generation") for l in said),
      f"{time.time() - t0:.0f} s; " + (" | ".join(said) or o.strip()[-400:]))
if st != 0:
    print(run("tail -30 /var/log/breadstick-vm-restore.log")[0])
power_off(q, " (moved in)")

q = boot(" (after the move in)")
o, _ = run(f"{B} status --json")
try:
    s = json.loads(o.strip().splitlines()[-1])
except Exception:
    s = {}
check("move in: bsl-nix says the vm engine", s.get("engine") == "vm", o.strip()[-300:])
o, _ = run("readlink -f /run/current-system; readlink -f /nix/var/nix/profiles/system; ls /nix/var/nix/profiles | tr '\\n' ' '")
w = o.split()
check("move in: the newest generation runs, built for the VM, not the image's", len(w) >= 2 and w[0] == w[1] and w[0] != image_sys.strip(),
      o.strip().replace("\n", " | "))
o, _ = run("test -e /run/current-system/kernel && echo has-kernel; systemctl is-active bsl-vmagent bsl-vmnet bsl-x11-relay")
check("move in: a VM generation with the guest's units", o.split() == ["has-kernel", "active", "active", "active"], o.strip().replace("\n", " "))
o, st = run(app_text("prepare-user.sh"))
check("move in: prepare user keeps the instance's account", st == 0 and "bus ok" in o, o.strip()[-200:])
o, st = run("id; cat ~/move-marker; hello; sudo -n true && echo sudo-ok; echo made-in-the-vm > ~/vm-marker", user="tester")
check("move in: the instance's account, file, hello and sudo",
      "uid=1000(tester) gid=1000(tester)" in o and "moved-with-me" in o and "Hello, world!" in o and "sudo-ok" in o,
      o.strip().replace("\n", " | "))
o, st = run(f"{B} generations --json")
gens = []
try:
    gens = [g["number"] for g in json.loads(o.strip().splitlines()[-1])]
except Exception:
    pass
first = min(gens) if gens else 1
o, st = run(f"{B} rollback {first}")
check(f"move in: a rollback to the Standard engine's generation {first} is refused", st == 3 and "cannot start here" in o, f"{st} {o.strip()[-200:]}")
o, st = run("NIX_REMOTE=daemon nix-store --verify 2>&1 | tail -3; echo rc=$?")
check("move in: the store verifies", "rc=0" in o, o.strip().replace("\n", " | ")[-300:])
o, st = run(f"{B} add cowsay && {B} apply 2>&1 | grep -E '^\\[BSL\\]' | tail -2")
check("move in: an apply in the VM after the move", st == 0 and "applied" in o, o.strip().replace("\n", " | ")[-300:])

# --- 3. the VM to Standard, its VM half -------------------------------------------------------------------------
t0 = time.time()
o, st = run(app_text("nix-prepare-proot.sh"))
ready = [l for l in o.splitlines() if l.startswith("BSL_ENGINE_READY ")]
check("move out: the proot generation built in the VM", st == 0 and len(ready) == 1, f"{time.time() - t0:.0f} s; " + o.strip()[-300:])
o, _ = run("readlink /nix/var/nix/gcroots/breadstick-engine-proot; test -e /run/current-system/kernel && echo still-vm")
check("move out: the VM runs on as it was, the proot generation rooted", "still-vm" in o and "/nix/store/" in o, o.strip().replace("\n", " | "))
t0 = time.time()
st, n = stream_out(app_text("file-backup-strict.sh"), "/w/vm-backup.tar")
check("move out: the VM's backup (the move's strict archive)", st == 0 and n > 100 << 20, f"{n >> 20} MiB, {time.time() - t0:.0f} s, exit {st}")
if st != 0:
    print(run("tail -n 8 /var/log/breadstick-vm-backup.log")[0], flush=True)
power_off(q, " (moved out)")

print(f"{'all passed' if not fails else str(len(fails)) + ' failed: ' + ', '.join(fails)}", flush=True)
sys.exit(1 if fails else 0)
