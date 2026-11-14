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
# The guest's vsock CID, host-wide: two tests with one CID clash, and the second one's requests would reach the first
# one's VM. qemu-test.sh passes CID= (default 77); give each test running at once its own.
CID = int(os.environ.get("CID", "77"))
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


def boot(label="", kernel="/w/vmlinuz", initrd="/w/initrd.img", wait=None, must=True):
    """Starts QEMU on /w/root.img with [kernel] and [initrd] and waits for the agent. Returns the QEMU process, or
    (must=False) None after killing it when the agent did not answer within [wait] seconds."""
    q = subprocess.Popen(qemu + [
        "-m", "2048", "-smp", "4", "-kernel", kernel, "-initrd", initrd, "-append", cmdline,
        "-drive", "file=/w/root.img,if=virtio,format=raw,discard=unmap", "-device", f"vhost-vsock-pci,guest-cid={CID}",
        "-nic", "none", "-display", "none", "-serial", f"file:/w/console{label}.log", "-monitor", "none",
    ])
    t0 = time.time()
    up = None
    last = None
    while time.time() - t0 < (wait or (120 if ARCH == "arm64" else 900)):
        try:
            out, st = bslvm.simple(args, "p")
            up = out.decode()
            break
        except OSError as e:
            last = e
            time.sleep(0.5)
    if not must:
        if up is None:
            q.kill()
            q.wait()
            return None
        return q
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
# Agent 2 (plan 5.14 V5: static, os-release in 'i'), when qemu-test.sh put today's programs in (AGENT_DIR).
if os.environ.get("AGENT") == "2":
    info = dict(l.split("=", 1) for l in out.decode().splitlines() if "=" in l)
    check("agent 2: version and os-release", info.get("agent") == "2" and info.get("os_id") in ("debian", "breadstick"),
          f"agent={info.get('agent')} os_id={info.get('os_id')} os_version_id={info.get('os_version_id')} os_id_like={info.get('os_id_like')}")
    o, st = run("for p in bsl-vmagent bsl-vmnet bsl-x11-relay; do ldd /usr/lib/breadstick-vm/$p 2>&1 | grep -q 'not a dynamic' && echo $p static; done")
    check("agent 2: the three programs are static", o.split().count("static") == 3, o.strip().replace("\n", " | "))
out, st = bslvm.simple(args, "t", struct.pack("<Q", int(time.time() * 1000)))
check("set time", st == 0)
o, st = run("date +%s")
check("clock", st == 0 and abs(int(o.strip()) - time.time()) < 30, o.strip())
out, st = bslvm.simple(args, "f", b"/run/bsl-test\0" + b"640\0" + b"hello\n")
o, _ = run("stat -c %a /run/bsl-test; cat /run/bsl-test")
check("write file", st == 0 and o.split() == ["640", "hello"], o)

o, st = run("systemctl is-system-running --wait; systemctl --failed --no-legend")
check("systemd", "running" in o or "degraded" in o, o.strip().replace("\n", " | "))

# The app's user preparation: Android vm/VmCommands.prepareUserScript("tester"), copied in prepare-user.sh (the app's
# VmCommandsTest checks the copy).
PREPARE_USER = open("/t/prepare-user.sh").read()
o, st = run(PREPARE_USER)
check("prepare user", st == 0 and "bus ok" in o, o.strip())
o, st = run("id -un; echo $XDG_RUNTIME_DIR; echo $DBUS_SESSION_BUS_ADDRESS; sudo -n true && echo sudo-ok", user="tester")
check("user session", st == 0 and "tester" in o and "/run/user/" in o and "sudo-ok" in o, o.strip().replace("\n", " | "))
# Plan 5.14 V6: Debian's result unchanged (the groups, the shell, the image's own sudoers rule) and the user's PATH.
o, st = run("id -Gn tester; getent passwd tester | cut -d: -f7; loginctl show-user tester -p Linger; "
            "cat /etc/sudoers.d/breadstick-vm; ls /etc/sudoers.d")
check("user: Debian's groups, shell, linger and sudoers rule", all(x in o.split() for x in ("sudo", "audio", "video", "plugdev", "users"))
      and "/bin/bash" in o and "Linger=yes" in o and "%sudo ALL=(ALL:ALL) NOPASSWD: ALL" in o and ".tmp" not in o, o.strip().replace("\n", " | "))
o, st = run("command -v xterm; command -v sudo", user="tester")
check("user: which xterm and sudo", st == 0 and "/usr/bin/xterm" in o and "/usr/bin/sudo" in o, o.strip().replace("\n", " | "))

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


def share_open():
    """/mnt/host in the VM = this container's / (OpenSSH's sftp-server over an agent channel, as the
    app's VmFiles does with its own server). Returns (channel, server) once mounted, or None."""
    if not os.path.exists("/usr/lib/openssh/sftp-server"):
        return None
    sftp = subprocess.Popen(["/usr/lib/openssh/sftp-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    s = bslvm.connect(args, bslvm.AGENT_PORT)
    bslvm.request(s, "r", bslvm.run_payload(open("/t/mount-share.sh").read().strip()))

    def guest_to_server():
        try:
            for t, d in bslvm.frames(s):
                if t == "o":
                    sftp.stdin.write(d)
                    sftp.stdin.flush()
        except (OSError, EOFError, ValueError):
            pass

    def server_to_guest():
        try:
            while True:
                d = sftp.stdout.read1(65536)
                if not d:
                    break
                bslvm.send_frame(s, "d", d)
        except (OSError, ValueError):
            pass

    threading.Thread(target=guest_to_server, daemon=True).start()
    threading.Thread(target=server_to_guest, daemon=True).start()
    o, st = run("n=0; while ! mountpoint -q /mnt/host && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done; mountpoint -q /mnt/host")
    if st != 0:
        sftp.kill()
        return None
    return s, sftp


def share_close(h):
    s, sftp = h
    s.shutdown(__import__("socket").SHUT_RDWR)
    s.close()
    run("n=0; while mountpoint -q /mnt/host && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done")
    sftp.kill()


def staged_upgrade():
    """The gate's VM stage (AutoBuild test/gate.sh, VM=1): the image upgraded from a STAGED repo the
    way an installed system upgrades from apt.breadstick.io (apt-get install breadstick-desktop), before
    the session tests below run on the result. The stage is mounted at /repo in this container
    (qemu-test.sh STAGED_REPO=) and reaches the VM as /mnt/host/repo."""
    suite = os.environ.get("STAGED_SUITE", "breadstick")
    pool = "pool/test" if suite == "breadstick-test" else "pool/main"
    want = None
    for f in sorted(os.listdir("/repo/" + pool)):
        if f.startswith("breadstick-desktop_") and f.endswith("_all.deb"):
            want = f.split("_")[1]
    check("staged: the stage has breadstick-desktop", want is not None, f"/repo/{pool}")
    if want is None:
        return
    o, _ = run("dpkg-query -W -f='${Version}' breadstick-desktop")
    before = o.strip()
    h = share_open()
    check("staged: the stage reaches the VM", h is not None)
    if h is None:
        return
    script = (f"set -e; echo 'deb [trusted=yes] file:/mnt/host/repo {suite} main' > /etc/apt/sources.list.d/zz-gate.list; "
              "export DEBIAN_FRONTEND=noninteractive; apt-get -o DPkg::Lock::Timeout=180 update >/tmp/gate-update.log 2>&1; "
              "apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends breadstick-desktop >/tmp/gate-install.log 2>&1; "
              "echo installed")
    o, st = run(script)
    tail, _ = run("tail -n 4 /tmp/gate-install.log")
    check("staged: apt-get install breadstick-desktop", st == 0 and "installed" in o, tail.strip().replace("\n", " | "))
    o, _ = run("dpkg-query -W -f='${Package} ${Version} ${db:Status-Abbrev}\\n' 'breadstick-*' | awk '$3 == \"ii\"'")
    rows = [l.split() for l in o.strip().splitlines() if l.strip()]
    stale = [r[0] + " " + r[1] for r in rows if r[1] != want]
    check(f"staged: breadstick-* {before} -> {want}", rows and not stale, ", ".join(stale) or f"{len(rows)} packages at {want}")
    o, st = run("dpkg --audit; echo rc=$?")
    check("staged: dpkg --audit clean", o.strip() == "rc=0", o.strip().replace("\n", " | "))
    run("rm -f /etc/apt/sources.list.d/zz-gate.list; apt-get update >/dev/null 2>&1 || true")
    share_close(h)


if os.path.isdir("/repo"):
    staged_upgrade()

class Chan:
    """An agent 'r' run kept open: stdin sent as it comes, output gathered by a thread (bytes)."""

    def __init__(self, cmd, user="root", env=()):
        self.s = bslvm.connect(args, bslvm.AGENT_PORT)
        bslvm.request(self.s, "r", bslvm.run_payload(cmd, user, env=env))
        self.buf = bytearray()
        self.status = None
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            for t, d in bslvm.frames(self.s):
                if t == "o":
                    with self.lock:
                        self.buf += d
                elif t == "x":
                    self.status = struct.unpack("<i", d)[0]
        except (OSError, EOFError):
            pass

    def send(self, data):
        for i in range(0, len(data), 65536):
            bslvm.send_frame(self.s, "d", data[i:i + 65536])

    def take(self):
        with self.lock:
            b = bytes(self.buf)
            self.buf.clear()
            return b

    def lines(self, timeout, until):
        """Collected output lines until one matches until(line) or the time is up."""
        got, t0, rest = [], time.time(), b""
        while time.time() - t0 < timeout:
            rest += self.take()
            while b"\n" in rest:
                line, rest = rest.split(b"\n", 1)
                got.append(line.decode("ascii", "replace"))
                if until(got[-1]):
                    return got
            time.sleep(0.1)
        return got

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


# Android's VmAudio.OUT_CMD / MIC_CMD and VmShare's helper command, as the app sends them.
AUDIO_OUT = ("exec bash -c 'exec 2>/dev/null; until (exec 3</dev/tcp/127.0.0.1/4713); do sleep 1; done; "
             "exec cat </dev/tcp/127.0.0.1/4713'")
MIC_IN = "exec 2>/dev/null; [ -p /tmp/bsl-mic.fifo ] || exit 3; exec cat > /tmp/bsl-mic.fifo"
HELPER = "/a/bsl-vmbridge.py"


def b64(b):
    import base64
    return base64.b64encode(b).decode()


def bridges_test():
    """The VM session's bridges (Android vm/VmBridges.kt): the session script in Floating mode as the app
    starts it in the VM, then sound out, the microphone in, a notification and the clipboard both ways."""
    if not os.path.exists(HELPER):
        print("SKIP bridges (no Android assets mounted at /a)")
        return
    o, st = run("[ -f /usr/lib/breadstick/start-desktop-x11.sh ] || exit 77")
    if st == 77:
        print("SKIP bridges (no breadstick-session in this image)")
        return
    # VmBridges.beforeSession: what the app speaks.
    _, st = bslvm.simple(args, "f", b"/run/bsl/features\0" + b"644\0" + b"notify-v2 clipboard-v1\n")
    check("bridges: features written", st == 0)
    # LinuxEnvironment.desktopSessionScript(0, rootless=true, vm=true), run as root with displayEnv(true).
    session = Chan("export BREADSTICK_WAYLAND=0 BREADSTICK_COMPOSITOR=0 BREADSTICK_DARK=0 BREADSTICK_LOCALE=en_US.UTF-8 "
                   "BREADSTICK_DPI=96 BREADSTICK_GPU=0; export BREADSTICK_VOLUMES=''; "
                   "F=/usr/lib/breadstick/start-desktop-x11.sh; sh \"$F\" 0 tester 1",
                   env=["DISPLAY=:0", "NO_AT_BRIDGE=1", "LIBGL_KOPPER_DISABLE=1", "BREADSTICK_ROOTLESS=1"])
    up = session.lines(90, lambda l: "rootless mode" in l)
    check("bridges: session up (Floating)", any("rootless mode" in l for l in up), " | ".join(up[-6:]))
    time.sleep(3)
    o, st = run("bsl-audio status; pgrep -u tester -f bsl-notifyd >/dev/null && echo notifyd; "
                "pgrep -u tester -f bsl-clipboard >/dev/null && echo clipboard",
                user="tester", env=["XDG_RUNTIME_DIR=/tmp/runtime-tester", "PULSE_RUNTIME_PATH=/tmp/runtime-tester/pulse"])
    check("bridges: session daemons", "tcp-modules=1" in o and "notifyd" in o and "clipboard" in o, o.strip().replace("\n", " | "))

    # Sound out: a tone played in the VM arrives on the stream.
    out = Chan(AUDIO_OUT, user="tester")
    time.sleep(1)
    out.take()
    tone = ("import math,sys\n"
            "f=bytearray()\n"
            "for i in range(48000*2):\n"
            "    v=int(12000*math.sin(i*2*math.pi*440/48000)); f+=v.to_bytes(2,'little',signed=True)*2\n"
            "sys.stdout.buffer.write(f)")
    o, st = run(f"python3 -c \"{tone}\" | pacat --raw --rate=48000 --channels=2 --format=s16le",
                user="tester", env=["PULSE_SERVER=unix:/tmp/runtime-tester/pulse/native"])
    time.sleep(0.5)
    pcm = out.take()
    nonzero = sum(1 for i in range(0, len(pcm) - 1, 2) if pcm[i] or pcm[i + 1])
    check("bridges: sound reaches the stream", st == 0 and len(pcm) > 48000 * 4 and nonzero > 48000,
          f"pacat status {st}, {len(pcm)} bytes, {nonzero} non-silent samples")
    out.close()

    # The microphone: PCM written into the FIFO is what the VM records from breadstick_mic.
    mic = Chan(MIC_IN, user="tester")
    rec = Chan("timeout 3 parecord -d breadstick_mic --raw --rate=48000 --channels=1 --format=s16le | wc -c; "
               "true", user="tester", env=["PULSE_SERVER=unix:/tmp/runtime-tester/pulse/native"])
    sine = b"".join(int(12000 * __import__("math").sin(i * 0.0575)).to_bytes(2, "little", signed=True) for i in range(48000))
    for _ in range(5):
        mic.send(sine[:19200])
        time.sleep(0.1)
        mic.send(sine[19200:38400])
        time.sleep(0.3)
    time.sleep(1)
    got = rec.lines(10, lambda l: l.strip().isdigit())
    check("bridges: microphone reaches PulseAudio", mic.status is None and got and got[-1].strip().isdigit() and int(got[-1]) > 0,
          f"mic {'running' if mic.status is None else 'exited ' + str(mic.status)}, recorded {got[-1:]} bytes")
    mic.close()
    rec.close()

    # Notifications and the clipboard through the helper the app ships.
    helper = Chan("exec python3 -I -c '" + open(HELPER).read().replace("'", "'\\''") + "' 2>>/tmp/bsl-vmbridge.log", user="tester")
    first = helper.lines(10, lambda l: l.startswith("R "))
    check("bridges: helper sees bsl-clipboard", "R 1" in first, " | ".join(first))
    notify = ("import dbus; b=dbus.SessionBus(); n=dbus.Interface(b.get_object('org.freedesktop.Notifications',"
              "'/org/freedesktop/Notifications'),'org.freedesktop.Notifications'); "
              "print(n.Notify('qemu-test',0,'','Hello from the VM','it works',[],{},5000))")
    o, st = run(f"python3 -c \"{notify}\"", user="tester", env=["DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/runtime-tester/bus"])
    got = helper.lines(10, lambda l: l.startswith("A .bsl-notify"))
    import base64
    note = [base64.b64decode(l.split(" ", 2)[2]).decode() for l in got if l.startswith("A .bsl-notify")]
    check("bridges: a notification reaches the app", st == 0 and any("Hello from the VM" in n for n in note), (o.strip(), note).__repr__())
    o, st = run("(printf 'copied in the VM' | timeout 10 xclip -quiet -selection clipboard >/dev/null 2>&1 &); echo ok",
                user="tester", env=["DISPLAY=:0"])
    got = helper.lines(8, lambda l: False)
    text = None
    path = None
    for l in got:
        if l.startswith("B "):
            path, data = l[2:], b""
        elif l.startswith("D "):
            data += base64.b64decode(l[2:])
        elif l == "E" and path and path.endswith("text.txt"):
            text = data.decode()
    check("bridges: a Linux copy reaches the app", text == "copied in the VM", repr([l[:60] for l in got]))
    offer = [f"B .bsl-clip/to-linux/text.txt", "D " + b64(b"copied on Android"), "E",
             "B .bsl-clip/to-linux/offer.json", "D " + b64(b'{"serial": 41, "text": "text.txt"}'), "E"]
    helper.send(("\n".join(offer) + "\n").encode())
    time.sleep(3)
    o, st = run("timeout 5 xclip -o -selection clipboard", user="tester", env=["DISPLAY=:0"])
    check("bridges: an Android copy pastes in the VM", o == "copied on Android", repr(o))
    helper.close()
    session.close()
    time.sleep(2)


def desktop_test():
    """The session in Desktop mode (whole screen, XFCE), as the app starts it in the VM:
    LinuxEnvironment.desktopSessionScript(0, rootless=false, vm=true)."""
    o, st = run("[ -f /usr/lib/breadstick/start-desktop-x11.sh ] || exit 77")
    if st == 77:
        print("SKIP desktop session (no breadstick-session in this image)")
        return
    o, _ = run("pgrep -u tester -x xfce4-session || true")
    old = set(o.split())
    session = Chan("export BREADSTICK_WAYLAND=0 BREADSTICK_COMPOSITOR=0 BREADSTICK_DARK=0 BREADSTICK_LOCALE=en_US.UTF-8 "
                   "BREADSTICK_DPI=96 BREADSTICK_GPU=0; export BREADSTICK_VOLUMES=''; "
                   "F=/usr/lib/breadstick/start-desktop-x11.sh; sh \"$F\" 0 tester 0",
                   env=["DISPLAY=:0", "NO_AT_BRIDGE=1", "LIBGL_KOPPER_DISABLE=1", "BREADSTICK_ROOTLESS=0"])
    up = session.lines(120, lambda l: "starting XFCE" in l)
    check("desktop: session up (Desktop)", any("starting XFCE" in l for l in up), " | ".join(up[-6:]))
    new, shown = set(), ""
    for _ in range(40):
        time.sleep(1.5)
        o, _ = run("pgrep -u tester -x xfce4-session || true")
        new = set(o.split()) - old
        w, _ = run("DISPLAY=:0 xwininfo -root -children 2>/dev/null | grep -c -E 'xfce4-panel|xfdesktop|Xfwm4'", user="tester")
        shown = w.strip()
        if new and shown not in ("", "0"):
            break
    check("desktop: XFCE runs and draws (Desktop)", bool(new) and shown not in ("", "0"),
          f"new xfce4-session {sorted(new)}, {shown} shell windows on the screen")
    session.close()
    time.sleep(2)


def files_test():
    """The shared folders (Android vm/VmFiles.kt): sshfs -o passive in the VM over an agent run, mounted
    as the app mounts /mnt/host. The host end here is OpenSSH's sftp-server (the app's own SftpServer is
    tested against Debian's sshfs on the build machine: SftpServerTest), serving this container, whose
    /w/share stands in for the app's shared folder."""
    if not os.path.exists("/usr/lib/openssh/sftp-server"):
        print("SKIP files (no sftp-server in the test container)")
        return
    install = ("command -v sshfs >/dev/null 2>&1 && exit 0; export DEBIAN_FRONTEND=noninteractive; "
               "apt-get -o DPkg::Lock::Timeout=180 install -y -q --no-install-recommends sshfs 2>&1 | tail -n 3; "
               "command -v sshfs >/dev/null 2>&1")
    o, st = run(install)
    check("files: sshfs present (or installed)", st == 0, o.strip()[-200:])
    os.makedirs("/w/share", exist_ok=True)
    with open("/w/share/from-android.txt", "w") as f:
        f.write("made on Android\n")
    sftp = subprocess.Popen(["/usr/lib/openssh/sftp-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    s = bslvm.connect(args, bslvm.AGENT_PORT)
    bslvm.request(s, "r", bslvm.run_payload(open("/t/mount-share.sh").read().strip()))

    def guest_to_server():
        try:
            for t, d in bslvm.frames(s):
                if t == "o":
                    sftp.stdin.write(d)
                    sftp.stdin.flush()
        except (OSError, EOFError, ValueError):
            pass

    def server_to_guest():
        try:
            while True:
                d = sftp.stdout.read1(65536)
                if not d:
                    break
                bslvm.send_frame(s, "d", d)
        except (OSError, ValueError):
            pass

    threading.Thread(target=guest_to_server, daemon=True).start()
    threading.Thread(target=server_to_guest, daemon=True).start()
    o, st = run("n=0; while ! mountpoint -q /mnt/host && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done; "
                "mountpoint /mnt/host; findmnt -no FSTYPE,OPTIONS /mnt/host")
    check("files: /mnt/host mounted", st == 0 and "fuse.sshfs" in o, o.strip().replace("\n", " | "))
    o, st = run("cat /mnt/host/w/share/from-android.txt; stat -c %U /mnt/host/w/share/from-android.txt; "
                "echo hello > /mnt/host/w/share/from-vm.txt && echo wrote", user="tester")
    check("files: the user reads and writes", "made on Android" in o and "tester" in o and "wrote" in o and
          open("/w/share/from-vm.txt").read() == "hello\n", o.strip().replace("\n", " | "))
    o, st = run("t0=$(date +%s%N); dd if=/dev/zero of=/mnt/host/w/share/big bs=1M count=64 conv=fsync status=none; t1=$(date +%s%N); "
                "echo write $((64000000000 / (t1 - t0))) MB/s; sync; echo 3 > /proc/sys/vm/drop_caches; "
                "t0=$(date +%s%N); cat /mnt/host/w/share/big >/dev/null; t1=$(date +%s%N); echo read $((64000000000 / (t1 - t0))) MB/s; "
                "rm /mnt/host/w/share/big")
    check("files: 64 MB through the mount", st == 0 and "write" in o and "read" in o, o.strip().replace("\n", " | "))
    # The app closes the channel (Android's close wakes the thread reading it). Here a thread is in
    # recv() on it, and Linux keeps a socket open under a blocked recv: shutdown is what reaches the VM.
    s.shutdown(__import__("socket").SHUT_RDWR)
    s.close()
    o, st = run("n=0; while mountpoint -q /mnt/host && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done; "
                "mountpoint -q /mnt/host && echo still-mounted || echo unmounted")
    check("files: closing the channel unmounts", "unmounted" in o, o.strip())
    sftp.kill()
    # Made as root in this container: qemu-test.sh, which is not, could not remove it from /w.
    __import__("shutil").rmtree("/w/share", ignore_errors=True)


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
    bridges_test()
    desktop_test()
    xvfb.kill()

files_test()

BOOT_PAIR = open("/t/boot-pair.sh").read()


def boot_pair():
    """Android VmCommands.BOOT_PAIR_SCRIPT (copied in boot-pair.sh): (release, [sums], kernel, initrd) or None. A 7th
    word, NixOS's init, is not expected on the Debian image this test boots."""
    o, st = run(BOOT_PAIR)
    for l in o.splitlines():
        w = l.split()
        if len(w) == 6 and w[0] == "BSL_BOOT":
            return w[1], w[2:4], w[4], w[5]
    return None


def sha256_file(p):
    import hashlib
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


KERNEL = {}


def kernel_prepare():
    """Plan 5.14 V7, while the network is up: the disk boots the image's pair; a new kernel is installed the way a
    user's update installs one, and the pair the disk now boots is copied out as the app does (boot-pair.sh, then cat)."""
    if os.environ.get("KERNEL", "1") != "1":
        print("SKIP kernel (KERNEL=0)")
        return
    p = boot_pair()
    o, _ = run("uname -r")
    check("kernel: the disk boots the image's pair", p is not None and p[0] == o.strip()
          and p[1] == [sha256_file("/w/vmlinuz"), sha256_file("/w/initrd.img")], f"{p and p[0]} {p and p[2]}, running {o.strip()}")
    if p is None:
        return
    KERNEL["old"] = p[0]
    o, st = run("export DEBIAN_FRONTEND=noninteractive; a=$(dpkg --print-architecture); "
                "c=$(apt-cache policy linux-image-$a | sed -n 's/ *Candidate: //p'); i=$(dpkg-query -W -f='${Version}' linux-image-$a); "
                "if [ \"$c\" != \"$i\" ]; then pk=linux-image-$a; else pk=linux-image-rt-$a; fi; "
                "apt-get -o DPkg::Lock::Timeout=180 install -y -q --no-install-recommends $pk >/tmp/kernel.log 2>&1 && echo \"installed $pk\"; "
                "tail -n 3 /tmp/kernel.log")
    check("kernel: a new kernel installs", st == 0 and "installed" in o, o.strip().replace("\n", " | ")[-300:])
    q2 = boot_pair()
    check("kernel: the disk now boots another pair", q2 is not None and q2[0] != p[0], f"{q2 and q2[0]} ({q2 and q2[2]})")
    if q2 is None or q2[0] == p[0]:
        return
    for i, (src, dst) in enumerate(((q2[2], "/w/next-vmlinuz"), (q2[3], "/w/next-initrd.img"))):
        data, st = bslvm.run(args, "exec cat '" + src + "'", "root")
        with open(dst, "wb") as f:
            f.write(data)
    ok = [sha256_file("/w/next-vmlinuz"), sha256_file("/w/next-initrd.img")] == q2[1]
    check("kernel: the pair copies out through the agent, sums match", ok,
          f"{os.path.getsize('/w/next-vmlinuz') >> 20} + {os.path.getsize('/w/next-initrd.img') >> 20} MiB")
    if ok:
        KERNEL["new"] = q2[0]


def kernel_boots():
    """Plan 5.14 V7, after the image's own pair booted the upgraded disk (the grown-disk boot): the copied pair boots
    as the new kernel with networking; a broken kernel never answers, and the last good pair boots after it."""
    if "new" not in KERNEL:
        return
    q = boot(" (new kernel)", kernel="/w/next-vmlinuz", initrd="/w/next-initrd.img")
    # After boot settles: the agent answers from sysinit, and under TCG bsl-vmnet's start job was still queued
    # ("inactive") when this ran (amd64, 2026-11-14).
    o, st = run("systemctl is-system-running --wait >/dev/null 2>&1; uname -r; systemctl is-active bsl-vmnet bsl-x11-relay; ip route | grep -c 'default dev bsl0'; "
                "lsmod | grep -c -e '^nft_redir' -e '^dummy'")
    w = o.split()
    check("kernel: the new kernel runs, with its modules", w[:1] == [KERNEL["new"]] and w[1:3] == ["active", "active"]
          and w[3:4] == ["1"] and w[4:5] == ["2"], o.strip().replace("\n", " | "))
    o, _ = run("journalctl -k -b -o cat | grep -c -i -e 'recovery complete' -e 'orphan cleanup' || true")
    check("power off left a clean journal (no ext4 replay at this boot)", o.strip() == "0", o.strip())
    power_off(q, " (new kernel)")
    with open("/w/next-vmlinuz", "rb") as f:
        head = f.read(1 << 20)
    with open("/w/bad-vmlinuz", "wb") as f:
        f.write(head)
    bad = boot(" (broken kernel)", kernel="/w/bad-vmlinuz", initrd="/w/next-initrd.img", wait=60 if ARCH == "arm64" else 240, must=False)
    check("kernel: a broken kernel never brings the agent up", bad is None)
    if bad is not None:
        power_off(bad, " (broken kernel)")
    q = boot(" (last good after the broken one)", kernel="/w/next-vmlinuz", initrd="/w/next-initrd.img")
    o, _ = run("uname -r")
    check("kernel: the last good pair boots after it", o.strip() == KERNEL["new"], o.strip())
    power_off(q, " (last good)")


kernel_prepare()

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
    if "new" in KERNEL:
        o, _ = run("uname -r")
        check("kernel: the image's own pair still boots the upgraded disk (Debian keeps the old modules)", o.strip() == KERNEL["old"], o.strip())
    power_off(q, " (grown disk)")

kernel_boots()

print(f"\n{len(fails)} failed: {fails}" if fails else "\nALL PASS")
sys.exit(1 if fails else 0)
