#!/usr/bin/env python3
"""Runs inside bsl-vmtest:3 (see desktop-choice.sh): boots /w/{vmlinuz,initrd.img,root.img} and checks the desktop
choice of a VM instance (4.0, desktop-v1): KIND (plasma or gnome) installed at its first start, its shell process and
a panel window up on the display, XFCE's pieces left out, the bridges under it, the theme followed, a clean logout,
then XFCE again exactly as before, and KIND's second start. Prints its numbers (start times, memory, idle CPU, disk)
as "NUM name value" lines."""
import json
import os
import socket as so
import struct
import subprocess
import sys
import threading
import time
import types

sys.path.insert(0, "/t")
import bslvm  # noqa: E402

KIND = os.environ.get("KIND", "plasma")
CID = int(os.environ.get("CID", "79"))
MEM = os.environ.get("MEM", "2560")
args = types.SimpleNamespace(unix=None, cid=CID)
fails = []
LABEL = {"plasma": "KDE Plasma", "gnome": "GNOME"}[KIND]
SHELL = {"plasma": ("plasmashell", "kwin_x11"), "gnome": ("gnome-shell",)}[KIND]
# The app's words (Android vm/VmBridges.FEATURES, 4.0 r14).
FEATURES = b"notify-v2 clipboard-v1 print-v1 ai-v1 mic-v1 region-v1 media-v1 camera-v2 theme-v1 cursor-v1 desktop-v1\n"
# LinuxEnvironment.desktopSessionScript(0, rootless=false, vm=true), run as root with displayEnv(false).
SESSION = ("export BREADSTICK_WAYLAND=0 BREADSTICK_COMPOSITOR=0 BREADSTICK_DARK=0 BREADSTICK_LOCALE=en_US.UTF-8 "
           "BREADSTICK_DPI=96 BREADSTICK_GPU=0; export BREADSTICK_VOLUMES=''; "
           "F=/usr/lib/breadstick/start-desktop-x11.sh; sh \"$F\" 0 tester 0")
SESSION_ENV = ["DISPLAY=:0", "NO_AT_BRIDGE=1", "LIBGL_KOPPER_DISABLE=1", "BREADSTICK_ROOTLESS=0"]
USER_ENV = ["DISPLAY=:0", "XDG_RUNTIME_DIR=/tmp/runtime-tester", "DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/runtime-tester/bus",
            "PULSE_RUNTIME_PATH=/tmp/runtime-tester/pulse"]


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}", flush=True)
    if not ok:
        fails.append(name)


def num(name, value):
    print(f"NUM {name} {value}", flush=True)


def run(cmd, user="root", **kw):
    out, st = bslvm.run(args, cmd, user, **kw)
    return out.decode(errors="replace"), st


def urun(cmd):
    return run(cmd, user="tester", env=USER_ENV)


class Chan:
    """A command on its own channel, its output read in the background; close() hangs it up."""

    def __init__(self, cmd, user="root", env=()):
        self.s = bslvm.connect(args, bslvm.AGENT_PORT)
        bslvm.request(self.s, "r", bslvm.run_payload(cmd, user, env=env))
        self.buf = b""
        self.status = None
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            for t, d in bslvm.frames(self.s):
                with self.lock:
                    if t == "o":
                        self.buf += d
                    elif t == "x":
                        self.status = struct.unpack("<i", d)[0]
        except (OSError, EOFError, ValueError):
            pass

    def text(self):
        with self.lock:
            return self.buf.decode(errors="replace")

    def wait_line(self, word, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if word in self.text() or self.status is not None:
                break
            time.sleep(0.2)
        return word in self.text()

    def wait_end(self, timeout):
        end = time.time() + timeout
        while time.time() < end and self.status is None:
            time.sleep(0.2)
        return self.status

    def close(self):
        try:
            self.s.shutdown(so.SHUT_RDWR)
        except OSError:
            pass
        self.s.close()


def feed(cmd, data):
    """[cmd] as root with [data] on stdin, in frames the agent takes."""
    with bslvm.connect(args, bslvm.AGENT_PORT) as s:
        bslvm.request(s, "r", bslvm.run_payload(cmd))
        for i in range(0, len(data), 32768):
            bslvm.send_frame(s, "d", data[i:i + 32768])
        bslvm.send_frame(s, "e")
        out, st = b"", None
        for t, d in bslvm.frames(s):
            if t == "o":
                out += d
            elif t == "x":
                st = struct.unpack("<i", d)[0]
        return out.decode(errors="replace"), st


def used_mib():
    o, _ = run("free -m | awk 'NR==2 {print $3}'")
    return int(o.strip() or 0)


def disk_mib():
    o, _ = run("df -B1M --output=used / | tail -n 1")
    return int(o.strip() or 0)


def idle_cpu(seconds=10):
    """Percent of all CPUs busy over [seconds], from /proc/stat in the VM."""
    def snap():
        o, _ = run("head -n 1 /proc/stat")
        v = [int(x) for x in o.split()[1:9]]
        return sum(v), v[3] + v[4]
    t0, i0 = snap()
    time.sleep(seconds)
    t1, i1 = snap()
    return round(100.0 * (1 - (i1 - i0) / max(1, t1 - t0)), 1)


def shot(name):
    if os.path.isdir("/shots") and os.path.exists("/usr/bin/xwd"):
        with open(f"/shots/{name}.xwd", "wb") as f:
            subprocess.run(["xwd", "-root", "-silent", "-display", ":5"], stdout=f, check=False)


def start_session(expect, up_kind, wait=180):
    """The app's Desktop start; returns (channel, seconds until `bsl-desktop up` says yes or None)."""
    run("pkill -u tester -x pulseaudio; rm -f /tmp/.bsl-clip/ready; true")
    relay_on[0] = True
    time.sleep(0.5)
    t0 = time.time()
    ch = Chan(SESSION, env=SESSION_ENV)
    said = ch.wait_line(expect, wait)
    up = None
    end = time.time() + wait
    while said and time.time() < end and ch.status is None:
        _, st = urun(f"/usr/lib/breadstick/bsl-desktop up {up_kind}")
        if st == 0:
            up = round(time.time() - t0, 1)
            break
        time.sleep(0.5)
    return ch, up, said


IMAGE = json.load(open("/w/image.json")) if os.path.exists("/w/image.json") else {}
DISTRO = IMAGE.get("distro") or "debian"
cmdline = "console=ttyAMA0 root=/dev/vda rw panic=-1 bsl.vm=1"
OWN = ("console=", "root=", "rw", "panic=", "quiet", "8250.")
cmdline += "".join(" " + w for w in (IMAGE.get("cmdline") or "").split() if not w.startswith(OWN))
print(f"image: {IMAGE.get('name', '(no image.json)')}, distro {DISTRO}, desktop {KIND}, {MEM} MiB", flush=True)
q = subprocess.Popen(["qemu-system-aarch64", "-M", "virt", "-cpu", "host", "-accel", "kvm", "-m", MEM, "-smp", "4",
                      "-kernel", "/w/vmlinuz", "-initrd", "/w/initrd.img", "-append", cmdline,
                      "-drive", "file=/w/root.img,if=virtio,format=raw,discard=unmap", "-device", f"vhost-vsock-pci,guest-cid={CID}",
                      "-nic", "none", "-display", "none", "-serial", "file:/w/console.log", "-monitor", "none"])
t0 = time.time()
up = None
while time.time() - t0 < 180:
    try:
        up, _ = bslvm.simple(args, "p")
        break
    except OSError:
        time.sleep(0.5)
check("agent answers", up is not None and up.startswith(b"PONG"), f"after {time.time() - t0:.1f}s")
if up is None:
    q.kill()
    sys.exit(1)
bslvm.simple(args, "t", struct.pack("<Q", int(time.time() * 1000)))
run("systemctl is-system-running --wait")
run(open("/t/grow-fs.sh").read())
o, st = run(open("/t/prepare-user.sh").read())
check("prepare user", st == 0 and "bus ok" in o, o.strip())
threading.Thread(target=bslvm.net_serve, args=(args, 8), daemon=True).start()

xvfb = subprocess.Popen(["Xvfb", ":5", "-screen", "0", "1920x1080x24", "-nolisten", "tcp"], stderr=subprocess.DEVNULL)
time.sleep(1.5)
idle = [0]
lock = threading.Lock()


live = set()
waiting = set()
relay_on = [True]


def chan(c):
    try:
        first = c.recv(65536)
    except OSError:
        first = b""
    with lock:
        idle[0] -= 1
        waiting.discard(c)
    if not first:
        c.close()
        return
    x = so.socket(so.AF_UNIX, so.SOCK_STREAM)
    x.connect("/tmp/.X11-unix/X5")
    with lock:
        live.add(c)
    x.sendall(first)
    threading.Thread(target=lambda: (bslvm.splice(x, c), c.close()), daemon=True).start()
    bslvm.splice(c, x)
    try:
        x.shutdown(so.SHUT_WR)
    except OSError:
        pass


def pool():
    while True:
        with lock:
            n = idle[0]
        if not relay_on[0]:
            time.sleep(0.1)
        elif n < 6:
            try:
                c = bslvm.connect(args, 6000)
            except OSError:
                time.sleep(0.3)
                continue
            with lock:
                idle[0] += 1
                waiting.add(c)
            threading.Thread(target=chan, args=(c,), daemon=True).start()
        else:
            time.sleep(0.02)


def relay_drop():
    """The app's stopDisplayRelay at a session's end (X11DesktopSession.stop): every X connection of the VM closes,
    and no new one is taken until the next session starts (start_session turns the relay on again)."""
    relay_on[0] = False
    with lock:
        cs = list(live) + list(waiting)
        live.clear()
        waiting.clear()
    for c in cs:
        try:
            c.shutdown(so.SHUT_RDWR)
        except OSError:
            pass


threading.Thread(target=pool, daemon=True).start()
time.sleep(1)
o, st = run("DISPLAY=:0 xdpyinfo | grep dimensions", user="tester")
check("x11 relay", st == 0 and "1920x1080" in o, o.strip())

if os.path.exists("/w/session.tar"):
    o, st = feed("tar -C / -xf - && echo unpacked", open("/w/session.tar", "rb").read())
    check("today's breadstick-session files in the VM", st == 0 and "unpacked" in o, o.strip()[-200:])
o, st = run("[ -x /usr/lib/breadstick/bsl-desktop ] && [ -f /usr/lib/breadstick/start-desktop-x11.sh ] || exit 77")
if st == 77:
    print("SKIP: no bsl-desktop in this image (breadstick-session before 4.0 r14; pass SESSION_SRC=)")
    bslvm.simple(args, "o", b"poweroff")
    q.wait(120)
    sys.exit(0 if not fails else 1)

bslvm.simple(args, "f", b"/run/bsl/features\0" + b"644\0" + FEATURES)
bslvm.simple(args, "f", b"/run/bsl/desktop\0" + b"644\0" + KIND.encode() + b"\n")
bslvm.simple(args, "f", b"/run/bsl/theme\0" + b"644\0" + b"light\n")
o, _ = run("B=/usr/lib/breadstick/bsl-desktop; $B offered | tr '\\n' ' '; echo; $B wanted; $B kind; cat /run/bsl/engine")
w = o.split("\n")
if DISTRO != "debian":
    check(f"{DISTRO}: no choice (offered xfce only; wanted and kind are xfce)", w[0].split() == ["xfce"] and w[1:3] == ["xfce", "xfce"], o.strip().replace("\n", " | "))
    ch, t_up, said = start_session("starting XFCE", "xfce")
    check(f"{DISTRO}: XFCE starts with {KIND} asked for", said and t_up is not None, f"up after {t_up}s")
    ch.close()
    bslvm.simple(args, "o", b"poweroff")
    q.wait(120)
    print(f"{len(fails)} failed" if fails else "all passed")
    sys.exit(1 if fails else 0)
check("the choice reaches the guest (offered, wanted; kind is xfce until it is installed)",
      KIND in w[0].split() and w[1] == KIND and w[2] == "xfce" and w[3:4] == ["vm"], o.strip().replace("\n", " | "))

# ---- the first install, with the app's own text (Android DesktopChoiceContract.installScript; desktop-install-plasma.sh)
run("apt-get update >/dev/null 2>&1; apt-get clean")
base_disk, base_mem = disk_mib(), used_mib()
num("baseline_used_mib", base_mem)
install = open("/t/desktop-install-plasma.sh").read().replace("plasma", KIND)
t0 = time.time()
ch = Chan(install)
st = ch.wait_end(1800)
t_install = round(time.time() - t0)
text = ch.text()
ch.close()
o, st2 = run(f"/usr/lib/breadstick/bsl-desktop installed {KIND} && /usr/lib/breadstick/bsl-desktop kind")
check(f"{LABEL} installs at first use (apt, progress lines)", st == 0 and st2 == 0 and o.strip() == KIND
      and text.count("[BSL-PROGRESS] dlstatus:") > 3 and text.count("[BSL-PROGRESS] pmstatus:") > 3 and "[BSL-PROGRESS] done" in text,
      f"status {st}, {t_install}s, {text.count('dlstatus:')} download and {text.count('pmstatus:')} install lines, kind {o.strip()}")
num("install_seconds", t_install)
num("install_disk_mib", disk_mib() - base_disk)
o, st = run(install)
check("a second install does nothing", st == 0 and "PROGRESS" not in o, o.strip()[-120:])

# ---- the session with it
ch, t_up, said = start_session(f"starting {KIND}...", KIND)
check(f"{LABEL}: the session script starts it", said, " | ".join(l for l in ch.text().splitlines() if "[BSL]" in l and "PROGRESS" not in l)[-400:])
check(f"{LABEL}: shell process and panel window up (bsl-desktop up)", t_up is not None, f"after {t_up}s")
num("first_start_seconds", t_up)
time.sleep(8)
o, _ = urun("for p in " + " ".join(SHELL) + "; do pgrep -x $p >/dev/null && echo $p; done; "
            "xwininfo -root -tree 2>/dev/null | grep -E '\"plasmashell\".* [0-9]{3,}x[0-9]{2,}\\+|mutter guard window' | head -n 3")
check(f"{LABEL}: {' and '.join(SHELL)} run, the shell's window is on the display", all(p in o.split() for p in SHELL)
      and ("plasmashell" in o.split("\n", len(SHELL))[-1] or "mutter" in o), o.strip().replace("\n", " | ")[:300])
o, _ = urun("for p in xfce4-session xfwm4 xfce4-panel xfdesktop xfsettingsd xfconfd; do pgrep -x $p >/dev/null && echo $p; done; "
            "pgrep -u tester -f '/usr/lib/breadstick/[s]tatus.py' >/dev/null && echo status.py; echo .")
check(f"{LABEL}: XFCE and Breadstick's shelf programs are not running", o.split() == ["."], o.strip().replace("\n", " "))
o, _ = urun("own=$(dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner "
            "string:org.freedesktop.Notifications 2>/dev/null | sed -n 's/.*string \"\\(.*\\)\"/\\1/p'); "
            "pid=$(dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetConnectionUnixProcessID "
            "string:$own 2>/dev/null | sed -n 's/.*uint32 //p'); tr '\\0' ' ' < /proc/$pid/cmdline; echo; "
            "python3 -c \"import dbus; b=dbus.SessionBus(); n=dbus.Interface(b.get_object('org.freedesktop.Notifications',"
            "'/org/freedesktop/Notifications'),'org.freedesktop.Notifications'); print(n.Notify('desktop-choice',0,'','Hello from the desktop','it works',[],{},5000))\"; "
            "sleep 1.5; grep -l 'Hello from the desktop' /tmp/.bsl-notify2 /tmp/.bsl-notify-log 2>/dev/null | tr '\\n' ' '")
check(f"{LABEL}: notifications go to the app (bsl-notifyd owns the name, the outbox has it)", "bsl-notifyd" in o and ".bsl-notify2" in o, o.strip().replace("\n", " | "))
o, _ = urun("(printf 'copied under the desktop' | timeout 6 xclip -quiet -selection clipboard >/dev/null 2>&1 &); sleep 2.5; "
            "grep -rl 'copied under the desktop' /tmp/.bsl-clip/to-android 2>/dev/null | head -n 1; bsl-audio status 2>&1 | tail -n 1")
check(f"{LABEL}: the clipboard bridge and the sound server", "/tmp/.bsl-clip/to-android" in o and "tcp-modules=1" in o, o.strip().replace("\n", " | "))
num("used_mib_with_desktop", used_mib())
num("desktop_mib_over_baseline", used_mib() - base_mem)
o, _ = run("ps -u tester --no-headers | wc -l")
num("user_processes", o.strip())
num("idle_cpu_percent_of_4", idle_cpu(10))
shot(f"{KIND}-1-desktop")

# The theme while it runs (theme-v1): the app writes the file, bsl-desktop's watcher applies it.
bslvm.simple(args, "f", b"/run/bsl/theme\0" + b"644\0" + b"dark\n")
probe = {"plasma": "plasma-apply-colorscheme --list-schemes 2>/dev/null | grep current",
         "gnome": "gsettings get org.gnome.desktop.interface color-scheme"}[KIND]
want = {"plasma": "BreezeDark", "gnome": "prefer-dark"}[KIND]
o = ""
for _ in range(15):
    time.sleep(1)
    o, _ = urun(probe)
    if want in o:
        break
check(f"{LABEL}: follows the theme while it runs (dark)", want in o, o.strip())
shot(f"{KIND}-2-dark")
bslvm.simple(args, "f", b"/run/bsl/theme\0" + b"644\0" + b"light\n")
time.sleep(6)

# Logout from the desktop's own menu action ends the session, as XFCE's does.
out_cmd = {"plasma": "dbus-send --session --print-reply --dest=org.kde.Shutdown /Shutdown org.kde.Shutdown.logout >/dev/null 2>&1",
           "gnome": "gnome-session-quit --no-prompt --logout >/dev/null 2>&1"}[KIND]
t0 = time.time()
urun(out_cmd)
st = ch.wait_end(40)
o, _ = urun("for p in " + " ".join(SHELL) + "; do pgrep -x $p >/dev/null && echo $p; done; echo .")
check(f"{LABEL}: logging out ends the session", st is not None and o.split() == ["."], f"session status {st} after {time.time() - t0:.1f}s; left: {o.strip()}")
ch.close()
time.sleep(2)

# ---- XFCE again, as before
bslvm.simple(args, "f", b"/run/bsl/desktop\0" + b"644\0" + b"xfce\n")
ch, t_up, said = start_session("starting XFCE", "xfce")
XFCE_PROBE = r"""[ -L /tmp/runtime-tester/bus ] && echo link; [ -S /tmp/runtime-tester/bus ] && echo socket
echo "daemons=$(pgrep -u tester -x dbus-daemon -a | grep -c -F -- '--address=unix:path=/tmp/runtime-tester/bus ')"
echo "desk=$(tr '\0' '\n' < /proc/$(pgrep -u tester -x xfce4-session | head -n 1)/environ | sed -n 's/^XDG_CURRENT_DESKTOP=//p')"
echo "kde=$(dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -c -E 'org.kde.(plasmashell|KWin|ksmserver|kded6|kglobalaccel)|org.gnome.Shell\b')"
echo "shellwins=$(xwininfo -root -children 2>/dev/null | grep -c -E 'xfce4-panel|xfdesktop|Xfwm4')"
for p in SHELLS; do pgrep -x $p >/dev/null && echo $p; done; true"""
o, _ = urun(XFCE_PROBE.replace("SHELLS", " ".join(SHELL)))
log = ch.text()
check("XFCE again: starts, draws, on its own bus, the other shell gone", said and t_up is not None and "link" not in o.split()
      and "socket" in o.split() and not any(p in o.split() for p in SHELL) and "look:" in log
      and "daemons=1" in o.split() and "desk=XFCE" in o.split() and "kde=0" in o.split() and "shellwins=0" not in o.split(),
      f"up after {t_up}s | {' '.join(o.split())} | " + " | ".join(l for l in log.splitlines() if "look: applied" in l)[:160])
num("xfce_start_seconds", t_up)
time.sleep(6)
num("used_mib_with_xfce", used_mib())
shot("xfce-again")
urun("xfce4-session-logout --logout --fast >/dev/null 2>&1")
ch.wait_end(20)
ch.close()
time.sleep(2)

# ---- and the chosen desktop's second start
bslvm.simple(args, "f", b"/run/bsl/desktop\0" + b"644\0" + KIND.encode() + b"\n")
ch, t_up, said = start_session(f"starting {KIND}...", KIND)
check(f"{LABEL}: second start", said and t_up is not None, f"up after {t_up}s")
num("second_start_seconds", t_up)
ch.close()
relay_drop()
time.sleep(12)
o, _ = urun("for p in " + " ".join(SHELL) + "; do pgrep -x $p >/dev/null && echo $p; done; echo .")
check(f"{LABEL}: gone when the app stops the session (the channel hung up, the display relay stopped)", o.split() == ["."], o.strip())

bslvm.simple(args, "o", b"poweroff")
try:
    q.wait(120)
    check("power off", True, f"qemu exit {q.returncode}")
except subprocess.TimeoutExpired:
    q.kill()
    check("power off", False, "qemu still running after 120 s")
xvfb.kill()
print(f"{len(fails)} failed: {fails}" if fails else "all passed")
sys.exit(1 if fails else 0)
