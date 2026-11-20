#!/usr/bin/env python3
"""Flatpak updates in a Breadstick VM image under QEMU (4.0, r14): runs inside bsl-vmtest:3
(qemu-test-flatpak-updates.sh). Breadstick Updates (packages breadstick-theme updater.py, this run's copy in /u) and the
app's Settings (Android FlatpakSetup.COUNT_UPDATES, withCount, withUpdates; the copies here are flatpak-count.sh,
flatpak-updates-count-<distro>.sh and flatpak-updates-<distro>.sh) against a real update: a small Flathub ref with no
dependencies is installed in the system installation, put back to its previous commit, and must then be listed and
updated by those very commands. The app's Upgrade all text runs the distribution's real upgrade first."""
import json, os, subprocess, sys, threading, time, types
sys.path.insert(0, "/t")
import bslvm
CID = int(os.environ["CID"])
args = types.SimpleNamespace(unix=None, cid=CID)
IMAGE = json.load(open("/w/image.json"))
DISTRO = IMAGE.get("distro") or "debian"
fails = []
def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}", flush=True)
    if not ok:
        fails.append(name)
def run(cmd, user="root", **kw):
    out, st = bslvm.run(args, cmd, user, **kw)
    return out.decode(errors="replace"), st
def one(s):
    return " | ".join(l.strip() for l in s.strip().splitlines() if l.strip())[-700:]
cmdline = "console=ttyAMA0 root=/dev/vda rw panic=-1 bsl.vm=1"
OWN = ("console=", "root=", "rw", "panic=", "quiet", "8250.")
cmdline += "".join(" " + w for w in (IMAGE.get("cmdline") or "").split() if not w.startswith(OWN))
q = subprocess.Popen(["qemu-system-aarch64", "-M", "virt", "-cpu", "host", "-accel", "kvm", "-m", "3072", "-smp", "4",
    "-kernel", "/w/vmlinuz", "-initrd", "/w/initrd.img", "-append", cmdline, "-drive", "file=/w/root.img,if=virtio,format=raw,discard=unmap",
    "-device", f"vhost-vsock-pci,guest-cid={CID}", "-nic", "none", "-display", "none", "-serial", "file:/w/console.log", "-monitor", "none"])
t0 = time.time(); up = None
while time.time() - t0 < 120:
    try:
        up = bslvm.simple(args, "p")[0].decode(); break
    except OSError:
        time.sleep(0.5)
check("agent answers", bool(up), repr(up))
if not up:
    q.kill(); sys.exit(1)
run("systemctl is-system-running --wait >/dev/null 2>&1")
threading.Thread(target=bslvm.net_serve, args=(args, 16), daemon=True).start()
time.sleep(1)
o, st = run(open("/t/prepare-user.sh").read())
check("prepare user", st == 0, one(o))
bslvm.simple(args, "f", b"/run/bsl/engine\x00" + b"644\x00" + b"vm\n")
o, st = run(open(f"/t/flatpak-setup-{DISTRO}.sh").read())
check(f"Get apps > Flatpak ({DISTRO})", st == 0 and "Done." in o, one(o)[-200:])
# The updater from this tree, beside the image's own Breadstick programs.
src = open("/u/updater.py", "rb").read()
bslvm.simple(args, "f", b"/tmp/r14/updater.py\x00644\x00" + src) if run("mkdir -p /tmp/r14")[1] == 0 else None
# breadstick-session's bsl-engine comes with the same release as this updater.py (one version for every package); an
# image whose session is older gets this tree's.
if run("[ -x /usr/lib/breadstick/bsl-engine ]")[1] != 0:
    bslvm.simple(args, "f", b"/usr/lib/breadstick/bsl-engine\x00755\x00" + open("/u/bsl-engine", "rb").read())
    print("NOTE bsl-engine: this tree's, written into the image (its breadstick-session has none)", flush=True)
PY = ("import sys; sys.dont_write_bytecode = True; sys.path[:0] = ['/tmp/r14', '/usr/lib/breadstick']; import updater as U; ")
o, st = run("ls /usr/lib/breadstick/bsl-engine /usr/lib/breadstick/bslui.py 2>&1; /usr/lib/breadstick/bsl-engine")
print("NOTE image:", one(o), flush=True)
o, st = run(f"python3 -c \"{PY}print('here', U.flatpak_here()); print('class', U.Updater.__name__); print('rows', U.flatpak_updates())\" 2>&1", user="tester")
check("updater.py in the VM with Flatpak: the Flatpak window is chosen, nothing waits yet",
      "here True" in o and "class FlatpakUpdater" in o and "rows []" in o, one(o))
bslvm.simple(args, "f", b"/run/bsl/engine\x00" + b"644\x00" + b"proot\n")
o, st = run(f"python3 -c \"{PY}print('here', U.flatpak_here()); print('class', U.Updater.__name__)\" 2>&1", user="tester")
check("the same system told it is the Standard engine: the plain window", "here False" in o and "class Updater" in o, one(o))
bslvm.simple(args, "f", b"/run/bsl/engine\x00" + b"644\x00" + b"vm\n")
# A small ref with history and no dependencies.
ref = None
for cand in ("runtime/org.gtk.Gtk3theme.Adwaita-dark/aarch64/3.22", "runtime/org.freedesktop.Platform.openh264/aarch64/2.5.1",
             "runtime/org.gtk.Gtk3theme.Breeze/aarch64/3.22", "runtime/org.kde.KStyle.Adwaita/aarch64/6.9"):
    o, st = run(f"flatpak remote-info --system --log flathub {cand} 2>/dev/null | awk '$1 == \"Commit:\" {{print $2}}' | head -n 3")
    commits = o.split()
    print(f"NOTE {cand}: {len(commits)} commits in the log", flush=True)
    if len(commits) >= 2:
        ref, old = cand, commits[1]
        break
check("a Flathub ref with history to go back in", ref is not None)
if ref:
    o, st = run(f"flatpak install --system -y --noninteractive --no-deps flathub {ref} 2>&1 | tail -n 3")
    check("installed in the system installation", st == 0, one(o))
    o, st = run(f"flatpak update --system -y --noninteractive --no-deps --commit={old} {ref} 2>&1 | tail -n 3; flatpak info --system -c {ref}")
    check("put back to its previous commit", old in o, one(o))
    o, st = run("env LC_ALL=C.UTF-8 LANG=C.UTF-8 flatpak remote-ls --updates --columns=name,application,version,branch,origin | cat -A", user="tester")
    print("NOTE the list as updater.py reads it:", one(o), flush=True)
    appid = ref.split("/")[1]
    o, st = run(f"python3 -c \"{PY}print('rows', U.flatpak_updates())\" 2>&1", user="tester")
    check("updater.py lists the update (flatpak remote-ls --updates, as the user)", appid in o or "rows [(" in o, one(o))
    o, st = run(open("/t/flatpak-count.sh").read())
    check("the app's count (FlatpakSetup.COUNT_UPDATES, root): one", o.strip() == "1", one(o))
    o, st = run(open(f"/t/flatpak-updates-count-{DISTRO}.sh").read())
    print("NOTE Settings' count with the packages' (withCount):", one(o), flush=True)
    check("Settings' count is a number that includes it", o.strip().isdigit() and int(o.strip()) >= 1, one(o))
    # Breadstick Updates' own commands, as the user: sudo -n for the system installation, then the user's.
    o, st = run(f"python3 -c \"{PY}import subprocess\nfor c in U.FLATPAK_UPDATES:\n    r = subprocess.run(c, capture_output=True, text=True); print('rc', r.returncode, (r.stdout + r.stderr).strip().splitlines()[-1:])\nprint('rows', U.flatpak_updates())\" 2>&1", user="tester")
    check("updater.py's update commands succeed as the user and nothing is left to update", o.count("rc 0") == 2 and "rows []" in o, one(o))
    o, st = run(f"flatpak info --system -c {ref}")
    check("the ref is at the newest commit again", st == 0 and old not in o, one(o))
    # The app's Upgrade all text: again from the old commit, after a stand-in package run.
    run(f"flatpak update --system -y --noninteractive --no-deps --commit={old} {ref} >/dev/null 2>&1")
    o, st = run(open(f"/t/flatpak-updates-{DISTRO}.sh").read())
    o2, _ = run(open("/t/flatpak-count.sh").read())
    check("the app's Upgrade all (withUpdates) updates Flatpak after the packages", st == 0 and "Updating Flatpak apps..." in o and o2.strip() == "0", one(o)[-300:] + " || count " + o2.strip())
    run(f"flatpak uninstall --system -y --noninteractive {ref} >/dev/null 2>&1")
bslvm.simple(args, "o", b"poweroff")
try:
    q.wait(120)
except subprocess.TimeoutExpired:
    q.kill()
print("all passed" if not fails else f"{len(fails)} failed: {', '.join(fails)}", flush=True)
sys.exit(1 if fails else 0)
