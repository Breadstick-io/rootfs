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
# The image's distribution and the words of its kernel line this test does not set itself (Fedora's selinux=0), from
# image.json (plan 5.14 V4). Debian's images before 4.0 have no "distro": Debian.
import json  # noqa: E402
IMAGE = json.load(open("/w/image.json")) if os.path.exists("/w/image.json") else {}
DISTRO = IMAGE.get("distro") or "debian"
OWN = ("console=", "root=", "rw", "panic=", "quiet", "8250.")
cmdline += "".join(" " + w for w in (IMAGE.get("cmdline") or "").split() if not w.startswith(OWN))
FAMILY_OS_ID = {"debian": ("debian", "breadstick"), "fedora": ("fedora",), "archlinux": ("arch",)}
ADMIN = "sudo" if DISTRO == "debian" else "wheel"
# The family's own package commands, as root in the VM. Breadstick's repositories are left out of the refresh off
# Debian: rpm.breadstick.io and pacman.breadstick.io serve nothing until the 4.0 publish (the images' own files still
# name them). pacman: a configuration without [breadstick], full upgrades only (never a partial one).
NO_BSL_PACMAN = "sed '/^\\[breadstick/,/^$/d' /etc/pacman.conf > /tmp/pc; "
PKG = {
    "debian": {"refresh": "apt-get update 2>&1 | tail -3",
               "install": "DEBIAN_FRONTEND=noninteractive apt-get install -y -q {p} >/dev/null 2>&1"},
    "fedora": {"refresh": "dnf -y --disablerepo=breadstick makecache 2>&1 | tail -3; dnf -q -y --disablerepo=breadstick repoquery --available cowsay | grep -q cowsay && echo 'Reading package lists'",
               "install": "dnf -y -q --disablerepo=breadstick --setopt=install_weak_deps=False install {p} >/dev/null 2>&1"},
    "archlinux": {"refresh": NO_BSL_PACMAN + "pacman --config /tmp/pc -Sy 2>&1 | tail -3; pacman --config /tmp/pc -Si cowsay >/dev/null && echo 'Reading package lists'",
                  "install": NO_BSL_PACMAN + "pacman --config /tmp/pc -Syu --noconfirm --needed {p} >/dev/null 2>&1"},
}[DISTRO]
COWSAY = "/usr/games/cowsay" if DISTRO == "debian" else "cowsay"
print(f"image: {IMAGE.get('name', '(no image.json)')}, distro {DISTRO}, kernel line: {cmdline}", flush=True)


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
if os.environ.get("AGENT") == "2" or IMAGE.get("agent") == 2:
    info = dict(l.split("=", 1) for l in out.decode().splitlines() if "=" in l)
    check("agent 2: version and os-release", info.get("agent") == "2" and info.get("os_id") in FAMILY_OS_ID[DISTRO],
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

# The image's own files, recorded at the disk's first boot before the account is made, as the app's boot does
# (Android vm/VmFileBackup.IMAGE_FILES_SCRIPT, copied in image-files.sh): what a proot system's backup restored into the
# VM keeps (plan 5.14 V20, round 9 review). A second run changes nothing.
IMAGE_FILES = open("/t/image-files.sh").read()
o, st = run(IMAGE_FILES)
o2, st2 = run(IMAGE_FILES)
o3, _ = run("gzip -dc /var/lib/breadstick-vm/image-files.gz | grep -cx -e /usr/bin/systemctl -e /etc/fstab")
check("image files: recorded at the first boot, once", st == 0 and "recorded" in o and st2 == 0 and o2.strip() == "" and o3.strip() == "2",
      f"{o.strip()} | {o2.strip()} | {o3.strip()}")

# The app's user preparation: Android vm/VmCommands.prepareUserScript("tester"), copied in prepare-user.sh (the app's
# VmCommandsTest checks the copy).
PREPARE_USER = open("/t/prepare-user.sh").read()
o, st = run(PREPARE_USER)
check("prepare user", st == 0 and "bus ok" in o, o.strip())
o, st = run("id -un; echo $XDG_RUNTIME_DIR; echo $DBUS_SESSION_BUS_ADDRESS; sudo -n true && echo sudo-ok", user="tester")
check("user session", st == 0 and "tester" in o and "/run/user/" in o and "sudo-ok" in o, o.strip().replace("\n", " | "))
# Plan 5.14 V6: Debian's result unchanged (the groups, the shell, the image's own sudoers rule) and the user's PATH;
# on Fedora and Arch the wheel group and its rule (install.sh), with only the groups the system has.
o, st = run("id -Gn tester; getent passwd tester | cut -d: -f7; loginctl show-user tester -p Linger; "
            "cat /etc/sudoers.d/breadstick-vm; ls /etc/sudoers.d")
groups = ("sudo", "audio", "video", "plugdev", "users") if DISTRO == "debian" else ("wheel", "audio", "video", "users")
check(f"user: {DISTRO}'s groups, shell, linger and sudoers rule", all(x in o.split() for x in groups)
      and "/bin/bash" in o and "Linger=yes" in o and f"%{ADMIN} ALL=(ALL:ALL) NOPASSWD: ALL" in o and ".tmp" not in o, o.strip().replace("\n", " | "))
if DISTRO == "fedora":
    # SELinux off (selinux=0, no policy: plan 5.14 V4), Fedora's own modes for sudo and /root, and nothing from the proot image.
    o, st = run("test -e /sys/fs/selinux/enforce && echo selinuxfs; dmesg | grep -c 'avc:'; "
                "rpm -V sudo filesystem | grep -E '^.M' || echo modes-ok; stat -c '%a' /usr/bin/sudo /root; "
                "grep -c selinux=0 /proc/cmdline")
    check("fedora: SELinux off, no AVC, rpm -V sudo filesystem clean (4111, 0550)",
          "selinuxfs" not in o and o.split()[:1] == ["0"] and "modes-ok" in o and "4111" in o and "550" in o, o.strip().replace("\n", " | "))
    o, st = run("uname -r; ls /boot; cat /etc/kernel/install.conf | grep -v '^#'")
    check("fedora: the boot pair kernel-install keeps for the app (layout=other)", "layout=other" in o and "vmlinuz-" in o
          and "initramfs-" in o and "loader" not in o, o.strip().replace("\n", " | "))
if DISTRO == "archlinux":
    o, st = run("pacman-conf DisableSandbox; ls /usr/local/bin; ls -la /etc/pacman.d/hooks; ls /boot")
    check("arch: no proot workarounds (no DisableSandbox, no stubs, no masked hooks), the default initramfs only",
          "DisableSandbox" not in o and "systemctl" not in o and "/dev/null" not in o and "initramfs-linux.img" in o
          and "fallback" not in o and "keep-modules" in o, o.strip().replace("\n", " | "))
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
o, st = run(PKG["refresh"], user="root")
check(f"{DISTRO}: package index refresh", st == 0 and "Reading package lists" in o and "Err" not in o, o.strip().replace("\n", " | "))
o, st = run(PKG["install"].format(p="cowsay") + f" && {COWSAY} moo | tail -1")
check(f"{DISTRO}: package install", st == 0, o.strip())


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


def rpm_refresh():
    """Round 10 (plan 5.14 V15): the RPM VM's daily refresh, the app's own text (rpm-refresh.sh, a copy of Android
    VmGuestUpdate.refreshScript that VmGuestUpdateTest checks), run as root as the session start runs it, against an
    RPM stage (qemu-test.sh RPM_STAGE=: /rpmrepo in this container, bound at /bsl-stage in the VM, where a -staged-
    image's breadstick.repo names it). It must put back a Breadstick package that is missing, change nothing that is
    not Breadstick's, leave no package-run marker, and with the stage gone end 75 (the day not marked done), never 0."""
    o, st = run("grep -qx 'baseurl=file:///bsl-stage/fedora/$releasever/$basearch/' /etc/yum.repos.d/breadstick.repo || exit 77")
    if st == 77:
        print("SKIP rpm refresh (the image's breadstick.repo does not name /bsl-stage)")
        return
    h = share_open()
    check("rpm refresh: the stage reaches the VM", h is not None)
    if h is None:
        return
    o, st = run("mkdir -p /bsl-stage && mount --bind /mnt/host/rpmrepo /bsl-stage && test -s /bsl-stage/RPM-GPG-KEY-breadstick && echo bound")
    check("rpm refresh: the stage bound at /bsl-stage", "bound" in o, o.strip())
    others = "rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\\n' | grep -v -e '^breadstick-' -e '^gpg-pubkey-' | sort"
    # The first refresh of an image from the desktop proot image installs breadstick-print, which the image does not
    # carry (the refresh installs it "when the repository has it", on proot as here), with its own dependencies (CUPS).
    o, st = run(open("/t/rpm-refresh.sh").read())
    tail = " | ".join(o.strip().splitlines()[-4:])
    check("rpm refresh: ends 0 with Breadstick's index fresh", st == 0 and "refresh exit 0" in o, f"exit {st}: {tail}")
    # Then, with nothing else to do: breadstick-print taken away (its dependencies left), the refresh puts back only it.
    run(f"{others} > /tmp/r10-before; rpm -e --nodeps breadstick-print")
    o, st = run(open("/t/rpm-refresh.sh").read())
    check("rpm refresh: again, ends 0", st == 0 and "refresh exit 0" in o, f"exit {st}: {' | '.join(o.strip().splitlines()[-2:])}")
    o, _ = run(f"rpm -q breadstick-print; {others} > /tmp/r10-after; diff /tmp/r10-before /tmp/r10-after | grep -c '^[<>]'; "
               "test -e /var/lib/breadstick/package-run || echo no-marker; test -e /var/lib/breadstick/package-run.cut || echo no-cut")
    lines = o.split()
    check("rpm refresh: the missing Breadstick package back, nothing else changed, no marker left",
          o.startswith("breadstick-print-") and "0" in lines and "no-marker" in lines and "no-cut" in lines, o.strip().replace("\n", " | "))
    run("umount /bsl-stage")
    o, st = run(open("/t/rpm-refresh.sh").read())
    check("rpm refresh: with the stage gone, exit 75 (not marked done)", st == 75 and "did not refresh" in o,
          f"exit {st}: {' | '.join(o.strip().splitlines()[-2:])}")
    run("test -e /var/lib/breadstick/package-run && echo marker-left")
    share_close(h)


if os.path.isdir("/rpmrepo") and DISTRO == "fedora":
    rpm_refresh()

class Chan:
    """An agent 'r' run kept open: stdin sent as it comes, output gathered by a thread (bytes)."""

    def __init__(self, cmd, user="root", env=(), pty=False):
        self.s = bslvm.connect(args, bslvm.AGENT_PORT)
        bslvm.request(self.s, "r", bslvm.run_payload(cmd, user, pty, env=env))
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
    # Plan 5.14 V9: a Terminal tab reaches the session's bus. The app writes /run/bsl/session in the VM while the
    # session runs (Android VmCommands.sessionEnvLines); breadstick-terminal.sh gives a tab its lines at the prompt.
    marker = ("BSL_SESSION_USER=tester\nXDG_RUNTIME_DIR=/tmp/runtime-tester\nDBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/runtime-tester/bus\n"
              "DISPLAY=:0\nPULSE_SERVER=unix:/tmp/runtime-tester/pulse/native\nLIBGL_ALWAYS_SOFTWARE=1\n").encode()
    _, st = bslvm.simple(args, "f", b"/run/bsl/session\0" + b"644\0" + marker)
    tab_note = ("python3 -c \"import dbus; b=dbus.SessionBus(); n=dbus.Interface(b.get_object('org.freedesktop.Notifications',"
                "'/org/freedesktop/Notifications'),'org.freedesktop.Notifications'); print(n.Notify('tab',0,'','From a VM tab','bus',[],{},5000))\"")
    # The tab as the app starts it (tab-command.sh), without tmux, so its output comes straight back: the seed that hands
    # the agent's runtime dir and bus over to breadstick-terminal.sh, then a login shell.
    seed = open("/t/tab-command.sh").read().split("if command -v tmux", 1)[0]
    tab = Chan(seed + "exec bash -li", user="tester", env=["BREADSTICK_TERMINAL=1"], pty=True)
    time.sleep(2)
    tab.send(("echo BUS=$DBUS_SESSION_BUS_ADDRESS; " + tab_note + "; exit\n").encode())
    out_tab = tab.lines(20, lambda l: False if "BUS=" not in l else False)
    got = helper.lines(10, lambda l: l.startswith("A .bsl-notify"))
    note = [base64.b64decode(l.split(" ", 2)[2]).decode() for l in got if l.startswith("A .bsl-notify")]
    check("tabs (V9): a Terminal tab is on the session's bus (/run/bsl/session)",
          st == 0 and any("BUS=unix:path=/tmp/runtime-tester/bus" in l for l in out_tab) and any("From a VM tab" in n for n in note),
          repr([l[-80:] for l in out_tab if "BUS=" in l][:2]) + " " + repr(note)[:200])
    tab.close()
    run("rm -f /run/bsl/session")
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
               "command -v sshfs >/dev/null 2>&1") if DISTRO == "debian" else "command -v sshfs"
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


# ----------------------------------------------------------------------------- ways in (plan 5.14 V13, V18)
# Each check below is named "parity: ..." for AutoBuild test/parity-gate.py, which reads them per distribution. Every
# command the VM runs here is the app's own text: rootfs vm/test/<name>, a byte copy of Android's
# app/src/test/resources/vm/<name>, which VmInboundTest checks is the app's text. app_text() prints each one's sha256
# ("SCRIPT <name> <sha256>"), and the parity gate's "same" evidence checks it against Android's copy, so a stale copy
# here fails the cells it backs.

_SCRIPTS = {}


def app_text(name):
    b = open("/t/" + name, "rb").read()
    if name not in _SCRIPTS:
        import hashlib
        _SCRIPTS[name] = hashlib.sha256(b).hexdigest()
        print(f"SCRIPT {name} {_SCRIPTS[name]}", flush=True)
    return b.decode()


def hangup(ch):
    """What the app's closing of a channel is to the agent: shut down first, since Linux keeps a socket open under the
    reader thread's blocked recv() (as files_test does)."""
    import socket as so
    try:
        getattr(ch, "s", ch).shutdown(so.SHUT_RDWR)  # a Chan, or a bare channel socket (ssh_test's carry)
    except OSError:
        pass
    ch.close()


def relay_pool(port, target, size=2):
    """The app's VmSocketRelay: [size] idle channels to [port]; a channel's first bytes pair it with a new connection
    to the unix socket [target] here."""
    import socket as so
    idle = [0]
    lock = threading.Lock()
    stop = [False]

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
        x.connect(target)
        x.sendall(first)
        threading.Thread(target=lambda: (bslvm.splice(x, c), c.close()), daemon=True).start()
        bslvm.splice(c, x)
        try:
            x.shutdown(so.SHUT_WR)
        except OSError:
            pass

    def loop():
        while not stop[0]:
            with lock:
                n = idle[0]
            if n < size:
                try:
                    c = bslvm.connect(args, port)
                except OSError:
                    time.sleep(0.3)
                    continue
                with lock:
                    idle[0] += 1
                threading.Thread(target=chan, args=(c,), daemon=True).start()
            else:
                time.sleep(0.05)

    threading.Thread(target=loop, daemon=True).start()
    return stop


def settings_relay_test():
    """Breadstick Settings in Linux (V13): /run/bsl/settings.sock in the VM reaches the app's settings server."""
    import socket as so
    path = "/tmp/bsl-fake-settings.sock"
    if os.path.exists(path):
        os.remove(path)
    srv = so.socket(so.AF_UNIX, so.SOCK_STREAM)
    srv.bind(path)
    srv.listen(4)

    def serve():
        while True:
            try:
                c, _ = srv.accept()
            except OSError:
                return
            f = c.makefile("rwb")
            for line in f:
                f.write(b'{"v":1,"ok":true,"echo":' + json.dumps(line.decode().strip()).encode() + b'}\n')
                f.flush()
            c.close()

    threading.Thread(target=serve, daemon=True).start()
    stop = relay_pool(6100, path)
    o, _ = run("stat -c %a /run/bsl")
    bsl_mode = o.strip()
    relay = Chan(app_text("settings-relay.sh"))
    o, st = run("n=0; while [ ! -S /run/bsl/settings.sock ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done; "
                "python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(\"/run/bsl/settings.sock\"); "
                "s.sendall(b\"{\\\"v\\\":1,\\\"op\\\":\\\"hello\\\"}\\n\"); print(s.makefile().readline().strip())'", user="tester")
    check("parity: settings.sock reaches the app (V13)", st == 0 and '"echo":"{\\"v\\":1,\\"op\\":\\"hello\\"}"' in o, o.strip()[-300:])
    o2, _ = run("stat -c %a /run/bsl; stat -c %a /run/breadstick-vm/relay; readlink /run/bsl/settings.sock")
    w = o2.split()
    check("parity: the relay keeps /run/bsl as it was, its own folder 1777", len(w) == 3 and w[0] == bsl_mode and w[1] == "1777"
          and w[2] == "/run/breadstick-vm/relay/settings.sock", f"before {bsl_mode} | " + o2.strip().replace("\n", " | "))
    hangup(relay)
    time.sleep(2.5)
    o, _ = run("[ -e /run/bsl/settings.sock ] || [ -L /run/bsl/settings.sock ] && echo left || echo gone; pgrep -f 'bsl-x11-relay 610[0]' || true")
    check("parity: the settings relay goes with its channel", o.split()[:1] == ["gone"] and len(o.split()) == 1, o.strip().replace("\n", " | "))
    stop[0] = True
    srv.close()


def mcp_test():
    """bsl-mcp in the VM (V13): /run/bsl/mcp and the loopback port that leads to the app's MCP server."""
    from http.server import BaseHTTPRequestHandler, HTTPServer
    seen = {}

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            seen["auth"] = self.headers.get("Authorization")
            seen["body"] = body
            ans = json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2025-06-18", "capabilities": {},
                                                                     "serverInfo": {"name": "fake-breadstick", "version": "1"}}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(ans)))
            self.end_headers()
            self.wfile.write(ans)

        def log_message(self, *a):
            pass

    httpd = HTTPServer(("127.0.0.1", 18765), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    o, st = run(app_text("host-ports.sh"))
    check("parity: host ports table (V13)", st == 0, o.strip())
    o, st = run(app_text("mcp-file.sh"), stdin=b"18765\nk3y-r10\n")
    o2, _ = run("stat -c '%a %U' /run/bsl/mcp")
    check("parity: /run/bsl/mcp is the user's, 0600 (V13)", st == 0 and o2.strip() == "600 tester", (o + o2).strip())
    init = b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"qemu","version":"1"}}}\n'
    o, st = run("command -v bsl-mcp >/dev/null || exit 77; timeout 20 bsl-mcp", user="tester", stdin=init)
    if st == 77:
        # No breadstick-tools in this image (a base image): the same route with curl, as bsl-mcp connects.
        o, st = run("curl -sS -m 10 -H 'Authorization: Bearer k3y-r10' -d '{}' http://127.0.0.1:18765/mcp", user="tester")
    check("parity: bsl-mcp reaches the app's MCP server (V13)", "fake-breadstick" in o and seen.get("auth") == "Bearer k3y-r10",
          f"status {st} auth {seen.get('auth')!r}: {o.strip()[-200:]}")
    # The route is ours: without the table nothing answers there.
    run("nft delete table ip breadstick_vm_host")
    o, st = run("curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:18765/mcp; echo \" rc=$?\"", user="tester")
    check("parity: without the table the VM's own loopback answers (the check can fail)", "rc=0" not in o, o.strip())
    run(app_text("host-ports.sh"))
    httpd.shutdown()


def ssh_test():
    """SSH on 2222 for a system in the VM (V18): the app's setup and sshd, the app's key file, and a login through the
    app's forward (an Android port carried to the VM's 127.0.0.1:2222 by an agent run of port-forward.sh)."""
    import socket as so
    o, _ = run("[ -r /usr/lib/breadstick/bsl-os.sh ] || command -v sshd >/dev/null 2>&1 || echo bare")
    if "bare" in o and DISTRO != "debian":
        # Off Debian, an image without 4.0's breadstick-session (the app's installs there go through its bsl-os.sh;
        # Debian's apt line needs none, so Debian always takes the app's own install): the server
        # from the distribution first, so the rest of the app's setup is what runs. A desktop VM image has the session.
        print("NOTE ssh: no breadstick-session in this image; openssh-server installed by the test", flush=True)
        run(PKG["install"].format(p="openssh-server" if DISTRO != "archlinux" else "openssh"))
    o, st = run(app_text(f"ssh-setup-{DISTRO}.sh"))
    check(f"parity: ssh setup ({DISTRO}, V18)", st == 0 and "sshd" in o, o.strip().replace("\n", " | ")[-300:])
    if st != 0:
        return
    sshd = Chan(app_text("sshd-start.sh"))
    time.sleep(2)
    o, st = run("ss -ltn | grep -c ':2222 '; systemctl is-active ssh.service sshd.service 2>/dev/null | grep -c '^active' || true")
    w = o.split()
    check("parity: the app's sshd on 2222, the distribution's own units off (V18)", w[:1] in (["1"], ["2"]) and w[1:2] in (["0"], []),
          o.strip().replace("\n", " | "))
    # The banner through the forward, as an Android client gets it.
    fwd = Chan(app_text("port-forward.sh"))
    got = fwd.lines(15, lambda l: l.startswith("SSH-2.0-"))
    check("parity: the forward carries sshd's banner (V18)", any(l.startswith("SSH-2.0-OpenSSH") for l in got), " | ".join(got[-3:]))
    hangup(fwd)
    # A key in the app's authorized_keys file, and a real login. The client runs in the VM and goes out through the
    # VM's network relay to this container, where a listener does what VmPortForward does: each connection carried
    # back in by port-forward.sh. VM -> host -> VM, the way a LAN client's connection goes in.
    o, _ = run("command -v ssh >/dev/null 2>&1 && echo have")
    if "have" not in o:
        # The client is the test's, not the product's (the app's setup installs the server only).
        run(PKG["install"].format(p={"debian": "openssh-client", "fedora": "openssh-clients"}.get(DISTRO, "openssh")))
    o, st = run("rm -f /tmp/bslk /tmp/bslk.pub; ssh-keygen -q -t ed25519 -N '' -f /tmp/bslk && cat /tmp/bslk.pub")
    pub = o.strip().splitlines()[-1:] if st == 0 else []
    o, st = run(app_text("authkeys.sh"), stdin=("+ " + pub[0] + "\n").encode() if pub else b"")
    o2, _ = run("stat -c '%a %U' /home/tester/.ssh /home/tester/.ssh/authorized_keys")
    check("parity: authorized_keys written with sshd's modes (V18)", st == 0 and "OK added=1 removed=0" in o
          and o2.split() == ["700", "tester", "600", "tester"], (o + " | " + o2).strip().replace("\n", " | "))
    # A change is an edit of the file the VM has (critic, round 10): a key added in the VM itself stays when the app
    # adds one, and a removal takes only its own line.
    other = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBSLparityOtherKeyAddedInsideTheVMxxxxxxxxxx in-vm"
    run(f"echo '{other}' >> /home/tester/.ssh/authorized_keys")
    o, st = run(app_text("authkeys.sh"), stdin=("+ " + pub[0] + "\n+ ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBSLparityThirdKeyFromTheAppxxxxxxxxxxxxxx app\n").encode())
    o3, st3 = run(app_text("authkeys.sh"), stdin=b"- ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBSLparityThirdKeyFromTheAppxxxxxxxxxxxxxx app\n")
    o2, _ = run("cat /home/tester/.ssh/authorized_keys")
    lines = o2.strip().splitlines()
    check("parity: a key change keeps the file's other keys (V18)", st == 0 and st3 == 0 and "OK added=1 removed=0" in o
          and "OK added=0 removed=1" in o3 and pub and lines == [pub[0], other],
          (o + " | " + o3 + " | " + str(lines)).strip().replace("\n", " | ")[-400:])
    lst = so.socket(so.AF_INET, so.SOCK_STREAM)
    lst.setsockopt(so.SOL_SOCKET, so.SO_REUSEADDR, 1)
    lst.bind(("0.0.0.0", 12222))
    lst.listen(4)
    me = subprocess.run(["hostname", "-I"], capture_output=True, text=True).stdout.split()

    # port-forward.sh is the app's command for a client at 192.168.1.20 (127.168.1.20 in the VM); a second client,
    # 192.168.1.21, is the same text with its address.
    fwd_owner = app_text("port-forward.sh").strip()
    fwd_other = fwd_owner.replace(" 127.168.1.20 ", " 127.168.1.21 ")

    def carry(c, text):
        ch = bslvm.connect(args, bslvm.AGENT_PORT)
        bslvm.request(ch, "r", bslvm.run_payload(text, "root"))

        def down():
            try:
                for t, d in bslvm.frames(ch):
                    if t == "o":
                        c.sendall(d)
            except (OSError, EOFError, ValueError):
                pass
            try:
                c.shutdown(so.SHUT_RDWR)
            except OSError:
                pass

        threading.Thread(target=down, daemon=True).start()
        try:
            while True:
                d = c.recv(65536)
                if not d:
                    break
                bslvm.send_frame(ch, "d", d)
        except OSError:
            pass
        # The client is gone: hang the command up, as VmPortForward does (proc.destroy()). A bare close() would leave
        # the channel open under down()'s blocked read, and the VM's sshd would keep the connection.
        hangup(ch)
        c.close()

    def accept(sock, text):
        while True:
            try:
                c, _ = sock.accept()
            except OSError:
                return
            threading.Thread(target=carry, args=(c, text), daemon=True).start()

    lst2 = so.socket(so.AF_INET, so.SOCK_STREAM)
    lst2.setsockopt(so.SOL_SOCKET, so.SO_REUSEADDR, 1)
    lst2.bind(("0.0.0.0", 12223))
    lst2.listen(8)
    threading.Thread(target=accept, args=(lst, fwd_owner), daemon=True).start()
    threading.Thread(target=accept, args=(lst2, fwd_other), daemon=True).start()
    o, _ = run("sshd -T 2>/dev/null | grep -i '^persourcepenaltyexemptlist' || echo none")
    check("parity: sshd exempts only the forward's fallback address (V18)", o.strip().lower() == "persourcepenaltyexemptlist 127.0.0.1",
          o.strip())
    if not me:
        check("parity: ssh login through the forward (V18)", False, "this container has no address for the VM to reach")
    else:
        ssh = ("timeout 40 ssh -p {port} -i {key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
               "-o BatchMode=yes -o LogLevel=ERROR -o IdentitiesOnly=yes tester@" + me[0] + " 'id -un; echo $SSH_CONNECTION'")
        o, st = run(ssh.format(port=12222, key="/tmp/bslk"))
        check("parity: ssh login through the forward (V18)", st == 0 and o.split()[:1] == ["tester"],
              o.strip().replace("\n", " | ")[-300:])
        # sshd sees the client's own loopback address, not 127.0.0.1 for everyone (OpenSSH's PerSourcePenalties).
        check("parity: sshd sees each client by an address of its own (V18)", o.split()[1:2] == ["127.168.1.20"],
              o.strip().replace("\n", " | ")[-300:])
        # A stranger is penalized by its own address: logins with a key that is not authorized, then connections that
        # never log in (sshd's "noauth", 1 s each; enforced from 15 s, OpenSSH's default). The owner's next login still
        # works, as under proot, where sshd sees every client's real address.
        run("rm -f /tmp/bslk2 /tmp/bslk2.pub; ssh-keygen -q -t ed25519 -N '' -f /tmp/bslk2")
        tries = []
        for _ in range(3):
            o, st = run(ssh.format(port=12223, key="/tmp/bslk2"))
            tries.append(f"{st}:{o.strip()[-80:]}")
        # From this container, the network side, as LAN clients reach Android's port.
        for _ in range(20):
            try:
                k = so.create_connection(("127.0.0.1", 12223), timeout=10)
                k.recv(64)
                k.close()
            except OSError:
                pass
        time.sleep(2)
        # The stranger's next connection, from this side too: sshd refuses it at once.
        sshd.take()
        t0 = time.time()
        try:
            k = so.create_connection(("127.0.0.1", 12223), timeout=10)
            got = k.recv(64)
            k.close()
        except OSError as e:
            got = repr(e).encode()
        took = time.time() - t0
        time.sleep(1)
        log = sshd.take().decode(errors="replace").strip().splitlines()
        said = [l for l in log if "127.168.1.21" in l and "penalty" in l]
        # sshd's own answer to a penalized address, at once, never a banner.
        refused = got.startswith(b"Not allowed at this time") and took < 8
        o = f"got {got[:40]!r} after {took:.1f} s | sshd: " + " ; ".join(said[-1:])
        if not refused:
            pen, _ = run("sshd -T 2>/dev/null | grep -i '^persourcepenalt'")
            o += " | tries: " + " ; ".join(tries) + " | " + pen.strip().replace("\n", " ; ") + " | sshd: " + " ; ".join(log[-20:])
        check("parity: a client that keeps failing is refused, by its own address (the check can fail) (V18)", refused,
              o.strip().replace("\n", " | ")[-1500:])
        o, st = run(ssh.format(port=12222, key="/tmp/bslk"))
        check("parity: another client's failed logins never lock the owner out (V18)", st == 0 and o.split()[:1] == ["tester"],
              f"status {st}: " + o.strip().replace("\n", " | ")[-300:])
    lst.close()
    lst2.close()
    hangup(sshd)
    time.sleep(2.5)
    o, _ = run("ss -ltn | grep -c ':2222 ' || true")
    check("parity: stopping SSH ends the VM's sshd (V18)", o.strip() == "0", o.strip())
    run("rm -f /tmp/bslk /tmp/bslk.pub /tmp/bslk2 /tmp/bslk2.pub")


def engine_test():
    """The engine marker (V8): /run/bsl/engine, written by the app's user step, and bsl-engine where the image has it."""
    o, st = run("cat /run/bsl/engine; command -v bsl-engine >/dev/null 2>&1 && bsl-engine || echo no-bsl-engine")
    w = o.split()
    check("parity: /run/bsl/engine says vm (V8)", w[:1] == ["vm"] and w[1:2] in (["vm"], ["no-bsl-engine"]), o.strip().replace("\n", " | "))


if os.environ.get("PARITY", "1") == "1":
    engine_test()
    settings_relay_test()
    mcp_test()
    ssh_test()


def stream_out(cmd, path):
    """An agent run as root whose output goes to [path] as it comes (a system's tar is too big to hold). Returns
    (exit status, bytes)."""
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


def stream_in(cmd, path):
    """An agent run as root with [path] as its stdin. Returns (exit status, output)."""
    out, st = b"", None
    with bslvm.connect(args, bslvm.AGENT_PORT) as s:
        bslvm.request(s, "r", bslvm.run_payload(cmd, "root"))
        done = threading.Event()

        def feed():
            with open(path, "rb") as f:
                for b in iter(lambda: f.read(65536), b""):
                    bslvm.send_frame(s, "d", b)
            bslvm.send_frame(s, "e")
            done.set()

        threading.Thread(target=feed, daemon=True).start()
        for t, d in bslvm.frames(s):
            if t == "o":
                out += d
            elif t == "x":
                st = struct.unpack("<i", d)[0]
    return st, out.decode(errors="replace")


def tabs_test():
    """Plan 5.14 V9: a Terminal tab in the VM is the user's tmux on the tab's own socket (Android
    VmCommands.tabCommand, copied in tab-command.sh): what runs in it survives the tab closing, and the next start of
    the tab attaches to the same session instead of making another."""
    cmd = open("/t/tab-command.sh").read().strip()
    o, st = run("command -v tmux")
    if st != 0:
        print("SKIP tabs (no tmux in this image)")
        return
    sock = "/tmp/.breadstick-tmux-1000-q1"
    t1 = Chan(cmd, user="tester", env=["BREADSTICK_TERMINAL=1", "TERM=xterm-256color"], pty=True)
    # Polled, not slept (round 10: a fixed 3 s lost the typed line under TCG, before tmux's client was attached and
    # the pane's shell was reading): the session attached and its shell at a prompt, then the line, then its file.
    run(f"n=0; until [ \"$(tmux -S {sock} list-sessions -F '#{{session_attached}}' 2>/dev/null)\" = 1 ] && "
        f"[ \"$(tmux -S {sock} list-panes -F '#{{pane_current_command}}' 2>/dev/null)\" = bash ] || [ $n -ge 120 ]; do sleep 0.5; n=$((n+1)); done; sleep 2",
        user="tester")
    t1.send(b"echo r9-pane-$$ > /tmp/r9-pane; sleep 600\r")
    run("n=0; until [ -s /tmp/r9-pane ] || [ $n -ge 120 ]; do sleep 0.5; n=$((n+1)); done", user="tester")
    time.sleep(1)
    t1.close()
    run(f"n=0; until [ \"$(tmux -S {sock} list-sessions -F '#{{session_attached}}' 2>/dev/null)\" = 0 ] || [ $n -ge 60 ]; do sleep 0.5; n=$((n+1)); done",
        user="tester")
    o, st = run(f"cat /tmp/r9-pane; tmux -S {sock} list-sessions -F '#{{session_name}} #{{session_attached}}'; "
                f"tmux -S {sock} list-panes -F '#{{pane_current_command}}'", user="tester")
    check("tabs (V9): the tab's shell keeps running after the tab closed (tmux)", "r9-pane-" in o and "main 0" in o and "sleep" in o,
          o.strip().replace("\n", " | "))
    t2 = Chan(cmd, user="tester", env=["BREADSTICK_TERMINAL=1", "TERM=xterm-256color"], pty=True)
    run(f"n=0; until [ \"$(tmux -S {sock} list-sessions -F '#{{session_attached}}' 2>/dev/null)\" = 1 ] || [ $n -ge 120 ]; do sleep 0.5; n=$((n+1)); done",
        user="tester")
    o, st = run(f"tmux -S {sock} list-sessions -F '#{{session_name}} #{{session_attached}}' | sort | tr '\\n' ' '; "
                f"tmux -S {sock} list-panes -a -F '#{{pane_current_command}}' | tr '\\n' ' '", user="tester")
    check("tabs (V9): the next start of the tab reattaches to the same session", o.split()[:2] == ["main", "1"] and o.count("main") == 1
          and "sleep" in o, o.strip())
    t2.close()
    run(f"tmux -S {sock} kill-server; rm -f /tmp/r9-pane", user="tester")


def file_backup_test():
    """Plan 5.14 V20: a file-level backup of the running VM (Android vm/VmFileBackup.TAR_SCRIPT, copied in
    file-backup.sh), checked as a tar (owners, setuid, links, an extended attribute), then restored into the same VM
    the way the app restores one (file-unpack-vm.sh into the stage, file-restore.sh over the system) and booted: the
    user's files come back with their owner and attribute, and sudo, the agent and networking still work. The app's
    own conversion to and from the backup format (metadata, end entry, compression) is VmFileBackupTest's, against GNU
    tar's output."""
    global q
    if os.environ.get("FILEBACKUP", "1") != "1":
        print("SKIP file backup (FILEBACKUP=0)")
        return
    o, st = run("printf 'kept by the backup\\n' > ~/r9-keep.txt && ln -sf r9-keep.txt ~/r9-link && "
                "python3 -c \"import os; os.setxattr(os.path.expanduser('~/r9-keep.txt'), 'user.breadstick', b'yes')\" && echo made",
                user="tester")
    check("file backup: the user's files to keep", "made" in o, o.strip())
    t0 = time.time()
    st, n = stream_out(open("/t/file-backup.sh").read(), "/w/vm-files.tar")
    check("file backup: the system streams out as one tar", st in (0, 1) and n > (50 << 20),
          f"tar exit {st}, {n >> 20} MiB in {time.time() - t0:.0f} s")
    import tarfile
    names, info = set(), {}
    try:
        with tarfile.open("/w/vm-files.tar", "r|") as tf:
            for m in tf:
                nm = m.name[2:] if m.name.startswith("./") else m.name
                names.add(nm)
                if nm in ("usr/bin/sudo", "home/tester/r9-keep.txt", "home/tester/r9-link", "home/tester", "proc", "tmp", "etc/shadow"):
                    info[nm] = m
        ok_tar = True
    except Exception as e:  # noqa: BLE001
        ok_tar = False
        print("tar error:", e)
    sudo = info.get("usr/bin/sudo")
    keep = info.get("home/tester/r9-keep.txt")
    link = info.get("home/tester/r9-link")
    check("file backup: a whole POSIX tar with owners, setuid, a link and the user's attribute",
          ok_tar and sudo is not None and sudo.mode & 0o4000 and keep is not None and keep.uid == 1000
          and keep.pax_headers.get("SCHILY.xattr.user.breadstick") == "yes" and link is not None and link.issym()
          and "etc/shadow" in info and "proc" in info and not any(x.startswith("proc/") for x in names)
          and not any(x.startswith("tmp/") for x in names),
          f"{len(names)} entries; sudo {oct(sudo.mode) if sudo else None}, keep uid {keep.uid if keep else None} "
          f"xattr {keep.pax_headers.get('SCHILY.xattr.user.breadstick') if keep else None}")
    run("rm -f ~/r9-keep.txt ~/r9-link; echo after > ~/r9-after.txt", user="tester")
    run("echo after > /etc/r9-after.conf; chmod 0700 /var/tmp")
    t0 = time.time()
    st, o = stream_in(open("/t/file-unpack-vm.sh").read(), "/w/vm-files.tar")
    check("file restore: unpacked into the stage", st == 0, f"exit {st} in {time.time() - t0:.0f} s {o.strip()[-200:]}")
    o, st = run(open("/t/file-restore.sh").read())
    check("file restore: laid over the system", st == 0 and "restored" in o, o.strip()[-300:])
    power_off(q, " (restored)")
    q = boot(" (after the restore)")
    o, st = run("cat ~/r9-keep.txt; stat -c %U ~/r9-keep.txt; readlink ~/r9-link; "
                "python3 -c \"import os; print(os.getxattr(os.path.expanduser('~/r9-keep.txt'), 'user.breadstick').decode())\"; "
                "sudo -n true && echo sudo-ok; test -e /var/lib/breadstick-vm/restore || echo no-stage", user="tester")
    check("file restore: the user's files back with owner, link and attribute; sudo; no stage left",
          "kept by the backup" in o and "tester" in o and "r9-keep.txt" in o and "yes" in o and "sudo-ok" in o and "no-stage" in o,
          o.strip().replace("\n", " | "))
    # Round 9 review: the restore replaces the system, as on proot: what came after the backup is gone, modes are back.
    o, st = run("test -e /home/tester/r9-after.txt || echo no-after; test -e /etc/r9-after.conf || echo no-etc; "
                "stat -c %a /var/tmp; test -e /var/lib/breadstick-vm/restore.work || echo no-work")
    check("file restore: what came after the backup is gone, /var/tmp's mode is back", o.split() == ["no-after", "no-etc", "1777", "no-work"],
          o.strip().replace("\n", " | "))
    o, st = run("systemctl --failed --no-legend --plain | cut -d' ' -f1 | tr '\\n' ' '; echo; systemctl is-system-running --wait; systemctl is-active bsl-vmnet bsl-x11-relay")
    check("file restore: systemd and the VM guest after the restore", ("running" in o or "degraded" in o) and o.split()[-2:] == ["active", "active"],
          o.strip().replace("\n", " | "))
    os.remove("/w/vm-files.tar")


tabs_test()
file_backup_test()

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
    if DISTRO == "debian":
        o, st = run("export DEBIAN_FRONTEND=noninteractive; a=$(dpkg --print-architecture); "
                    "c=$(apt-cache policy linux-image-$a | sed -n 's/ *Candidate: //p'); i=$(dpkg-query -W -f='${Version}' linux-image-$a); "
                    "if [ \"$c\" != \"$i\" ]; then pk=linux-image-$a; else pk=linux-image-rt-$a; fi; "
                    "apt-get -o DPkg::Lock::Timeout=180 install -y -q --no-install-recommends $pk >/tmp/kernel.log 2>&1 && echo \"installed $pk\"; "
                    "tail -n 3 /tmp/kernel.log")
    elif DISTRO == "fedora":
        # Another kernel the way Fedora installs one (kernel-core is install-only: kernel-install, then the image's
        # 95-breadstick-vm.install plugin). The newest in updates-testing when it is newer, else the release's own.
        o, st = run("D='dnf -y -q --disablerepo=breadstick --setopt=install_weak_deps=False'; "
                    "i=$(rpm -q --qf '%{VERSION}-%{RELEASE}\\n' kernel-core | sort -V | tail -n 1); "
                    "c=$($D --enablerepo=updates-testing repoquery --latest-limit 1 --qf '%{version}-%{release}\\n' kernel-core 2>/dev/null | sort -V | tail -n 1); "
                    "if [ -n \"$c\" ] && [ \"$(printf '%s\\n%s\\n' \"$i\" \"$c\" | sort -V | tail -n 1)\" = \"$c\" ] && [ \"$c\" != \"$i\" ]; then "
                    "$D --enablerepo=updates-testing install \"kernel-core-$c\" >/tmp/kernel.log 2>&1 && echo \"installed kernel-core-$c\"; "
                    "else echo \"no newer kernel than $i (updates-testing: ${c:-none})\"; exit 77; fi; tail -n 3 /tmp/kernel.log")
        if st == 77:
            print(f"SKIP kernel ({o.strip()})")
            return
    else:
        # Arch: the kernel before this one from Arch's own archive, through pacman -U: an Upgrade transaction of
        # 'linux', so pacman removes the running kernel's modules and the keep-modules hooks must put them back. A
        # module the running kernel has not loaded yet must still load after it (plan 5.14 V7).
        o, st = run("for x in loop sctp ip_gre btrfs; do grep -q \"^$x \" /proc/modules && continue; "
                    "modinfo -n $x 2>/dev/null | grep -q '\\.ko' && { echo $x; break; }; done")
        KERNEL["probe_module"] = o.strip()
        o, st = run(NO_BSL_PACMAN + "cur=$(pacman -Q linux | cut -d' ' -f2); "
                    "v=$(curl -fsS https://archive.archlinux.org/packages/l/linux/ | grep -o 'linux-[0-9][^\"]*-x86_64\\.pkg\\.tar\\.zst\"' "
                    "| tr -d '\"' | sed 's/^linux-//; s/-x86_64.pkg.tar.zst$//' | sort -uV | awk -v c=\"$cur\" '$0 != c' "
                    "| while read x; do [ \"$(printf '%s\\n%s\\n' \"$x\" \"$cur\" | sort -V | head -n 1)\" = \"$x\" ] && echo $x; done | tail -n 1); "
                    "[ -n \"$v\" ] || { echo no older linux; exit 1; }; "
                    "pacman --config /tmp/pc -U --noconfirm https://archive.archlinux.org/packages/l/linux/linux-$v-x86_64.pkg.tar.zst >/tmp/kernel.log 2>&1 "
                    "&& echo \"installed linux $v (was $cur)\"; tail -n 4 /tmp/kernel.log")
    check("kernel: a new kernel installs", st == 0 and "installed" in o, o.strip().replace("\n", " | ")[-300:])
    if DISTRO == "archlinux":
        m = KERNEL.get("probe_module")
        o, st = run(f"r=$(uname -r); ls /usr/lib/modules; cat /usr/lib/modules/$r/breadstick-kept 2>/dev/null | head -c 40; echo; "
                    f"test ! -e /usr/lib/modules/$r/pkgbase && echo no-pkgbase; {'modprobe ' + m + ' && echo loaded' if m else 'echo loaded'}")
        check("kernel: the running kernel kept its modules through the update (keep-modules)",
              "kept by Breadstick" in o and "no-pkgbase" in o and "loaded" in o, o.strip().replace("\n", " | "))
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
        check("kernel: the image's own pair still boots the upgraded disk (Debian and Fedora keep the old modules, Arch's keep-modules)", o.strip() == KERNEL["old"], o.strip())
        if DISTRO != "debian":
            # After the boot settles (under TCG bsl-vmnet was still queued and udev still loading modules, Arch 2026-11-15).
            o, _ = run("systemctl is-system-running --wait >/dev/null 2>&1; lsmod 2>/dev/null | grep -c -e '^nft_redir' -e '^dummy'; "
                       "systemctl is-active bsl-vmnet")
            check("kernel: the image's own pair has its modules and networking", o.split() == ["2", "active"], o.strip().replace("\n", " | "))
    power_off(q, " (grown disk)")

kernel_boots()


def proot_restore_test():
    """Plan 5.14 V20, the other way: a proot system (PROOT_IMAGE, decompressed by qemu-test.sh into /w/proot.tar, the
    files a proot backup of it holds) restored into the VM as the app does it (file-unpack-proot.sh: everything root's,
    homes to their accounts; file-restore.sh over the system), then booted: the VM's guest and kernel stay the image's,
    the system's own files are the proot system's, the app's user script makes its account again, and sudo works."""
    if not os.path.exists("/w/proot.tar"):
        return
    q = boot(" (for the proot restore)")
    # The units that fail in this VM before the restore (none, as a rule): the restore may add none (round 10, M6).
    failed_before, _ = run("systemctl is-system-running --wait >/dev/null; systemctl --failed --no-legend --plain | cut -d' ' -f1 | sort")
    # Made after the image's list and not in the backup: the restore takes it away (round 9 review).
    run("echo after > /etc/r9-after-image.conf")
    # The image's folder modes (Fedora's /root is 0550, Arch's 0750, Debian's 0700) and the VM's own machine id, which
    # the restore keeps (a proot system's is empty: laid over the VM's it made the next boot a first boot).
    image_modes, _ = run("stat -c %a /var/tmp /root")
    vm_id, _ = run("cat /etc/machine-id")
    st, o = stream_in(open("/t/file-unpack-proot.sh").read(), "/w/proot.tar")
    check("proot restore: unpacked into the stage, owners root's", st == 0, f"exit {st} {o.strip()[-200:]}")
    o, st = run(open("/t/file-restore-proot.sh").read())
    check("proot restore: laid over the system", st == 0 and "restored" in o, o.strip()[-300:])
    said = " | ".join(l for l in o.splitlines() if l.startswith(("package database", "systemd-sysusers")))
    power_off(q, " (proot restored)")
    q = boot(" (after the proot restore)")
    o, st = run(PREPARE_USER)
    check("proot restore: the account is made again, its bus up", st == 0 and "bus ok" in o, o.strip()[-200:])
    o, st = run("sudo -n true && echo sudo-ok; . /etc/os-release; echo \"$NAME|$ID\"; systemctl is-active bsl-vmagent bsl-vmnet; "
                "test -e /var/lib/breadstick-vm/restore || echo no-stage; stat -c '%U %a' /usr/bin/sudo", user="tester")
    check("proot restore: sudo, the system's identity, the VM guest, no stage", "sudo-ok" in o and "active\nactive" in o
          and "no-stage" in o and "root" in o and "unable to resolve" not in o, o.strip().replace("\n", " | "))
    # Round 9 review: the image's real programs in place of proot's stand-ins, the image's folder modes and owners,
    # the VM's hosts file, and nothing the backup does not have.
    o, st = run("head -c 4 /usr/bin/systemctl | od -An -c | tr -d ' '; for f in /usr/local/bin/systemctl /usr/local/bin/setpriv "
                "/usr/sbin/policy-rc.d /etc/r9-after-image.conf; do test -e $f && echo has:$f; done; stat -c %a /var/tmp /root; "
                "grep -c breadstick-vm /etc/hosts; cat /etc/machine-id")
    # /var/tmp and /root: the modes the image had before the restore (--no-overwrite-dir).
    want = image_modes.split()[:2]
    check("proot restore: the image's programs, folder modes and hosts; what came after the image is gone",
          o.split()[:1] == ["177ELF"] and "has:" not in o and len(want) == 2 and want[0] == "1777"
          and o.split()[1:4] == want + ["1"],
          o.strip().replace("\n", " | ") + f" (image: {' '.join(want)})")
    check("proot restore: the VM keeps its machine id", vm_id.strip() != "" and o.split()[4:5] == [vm_id.strip()],
          f"before {vm_id.strip()!r}, after {o.split()[4:5]}")
    o, st = run("systemctl is-system-running --wait; systemctl --failed --no-legend --plain | cut -d' ' -f1 | tr '\\n' ' '")
    check("proot restore: systemd after it", "running" in o or "degraded" in o, o.strip().replace("\n", " | "))
    new = sorted(set(o.split()[1:]) - set(failed_before.split()))
    check("proot restore: no unit fails that did not fail before it (round 10, M6)", o.split()[:1] == ["running"] or not new,
          f"{o.strip()} (before: {failed_before.strip() or 'none'})")
    # Round 10 (M6, the cross-engine restore row): the package database names the VM's own kernel and systemd, nothing
    # is listed twice, and the family's own database check is clean.
    owns = {"debian": "dpkg -S", "fedora": "rpm -qf", "archlinux": "pacman -Qo"}[DISTRO]
    kfile = "/boot/vmlinuz-$(uname -r)" if DISTRO == "debian" else "/usr/lib/modules/$(uname -r)/vmlinuz"
    pid1 = "$(readlink -f /proc/1/exe)"
    dups = {"debian": "dpkg-query -W -f='${Package}:${Architecture}\\n' | sort | uniq -d",
            "fedora": "rpm -qa --qf '%{NAME}.%{ARCH}\\n' | grep -v -e '^gpg-pubkey' -e '^kernel' | sort | uniq -d",
            "archlinux": "pacman -Qq | sort | uniq -d"}[DISTRO]
    audit = {"debian": "dpkg --audit", "fedora": "rpm -q --whatprovides /usr/bin/bash >/dev/null", "archlinux": "pacman -Dk >/dev/null"}[DISTRO]
    o, st = run(f"{owns} {kfile} >/dev/null 2>&1 && echo kernel-owned; p={pid1}; {owns} \"$p\" >/dev/null 2>&1 || "
                f"{owns} \"${{p#/usr}}\" >/dev/null 2>&1 && echo systemd-owned; echo dups=$({dups} | wc -l); "
                f"o=$({audit} 2>&1); r=$?; echo audit=$r $(printf '%s' \"$o\" | wc -l)")
    check("proot restore: the package database names the VM's own kernel and systemd, nothing twice, its check clean",
          "kernel-owned" in o and "systemd-owned" in o and "dups=0" in o and "audit=0 0" in o,
          o.strip().replace("\n", " | ") + f" (restore: {said})")
    power_off(q, " (proot restore done)")


proot_restore_test()

print(f"\n{len(fails)} failed: {fails}" if fails else "\nALL PASS")
sys.exit(1 if fails else 0)
