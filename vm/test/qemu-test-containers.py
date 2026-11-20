#!/usr/bin/env python3
"""Docker and Podman in a Breadstick VM image under QEMU (4.0, r14): runs inside bsl-vmtest:3
(qemu-test-containers.sh). Boots /w/{vmlinuz,initrd.img,root.img}, makes the user as the app does, runs the app's
installs and then real containers: the network through bsl-vmnet (DNS, HTTP, HTTPS, a pull), a published port, a bind
mount, a user network, a build, Compose, the user in the docker group, rootless Podman, and the main ones again after
a reboot. Then the published ports as the app finds and reaches them (published-ports.sh, port-forward.sh): found
when a container starts and gone when it ends, with no polling."""
import hashlib
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
CID = int(os.environ.get("CID", "81"))
KINDS = os.environ.get("KINDS", "docker podman").split()
RULES = os.environ.get("RULES", "app")
args = types.SimpleNamespace(unix=None, cid=CID)
fails = []
IMAGE = json.load(open("/w/image.json"))
DISTRO = IMAGE.get("distro") or "debian"
SLOW = 1 if ARCH == "arm64" else 12


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}", flush=True)
    if not ok:
        fails.append(name)


def run(cmd, user="root", **kw):
    out, st = bslvm.run(args, cmd, user, **kw)
    return out.decode(errors="replace"), st


def one(s):
    return " | ".join(l.strip() for l in s.strip().splitlines() if l.strip())[-600:]


def app_text(name):
    b = open(f"/t/{name}", "rb").read()
    print(f"SCRIPT {name} {hashlib.sha256(b).hexdigest()}", flush=True)
    return b.decode()


if ARCH == "arm64":
    qemu = ["qemu-system-aarch64", "-M", "virt", "-cpu", "host", "-accel", "kvm"]
    console = "console=ttyAMA0"
else:
    qemu = ["qemu-system-x86_64", "-M", "q35", "-cpu", "max", "-accel", "tcg"]
    console = "console=ttyS0"
cmdline = f"{console} root=/dev/vda rw panic=-1 bsl.vm=1"
OWN = ("console=", "root=", "rw", "panic=", "quiet", "8250.")
cmdline += "".join(" " + w for w in (IMAGE.get("cmdline") or "").split() if not w.startswith(OWN))
print(f"image: {IMAGE.get('name', '(no image.json)')}, distro {DISTRO}, kernel line: {cmdline}", flush=True)
print(f"containers: kinds {KINDS}, rules from the {RULES}", flush=True)


def boot(label=""):
    q = subprocess.Popen(qemu + [
        "-m", "3072", "-smp", "4", "-kernel", "/w/vmlinuz", "-initrd", "/w/initrd.img", "-append", cmdline,
        "-drive", "file=/w/root.img,if=virtio,format=raw,discard=unmap", "-device", f"vhost-vsock-pci,guest-cid={CID}",
        "-nic", "none", "-display", "none", "-serial", f"file:/w/console{label.replace(' ', '')}.log", "-monitor", "none",
    ])
    t0 = time.time()
    up = None
    while time.time() - t0 < 120 * SLOW:
        try:
            out, _ = bslvm.simple(args, "p")
            up = out.decode()
            break
        except OSError:
            time.sleep(0.5)
    check(f"agent answers{label}", up is not None and up.startswith("PONG"), f"{up!r} after {time.time() - t0:.1f}s")
    if up is None:
        print(open(f"/w/console{label.replace(' ', '')}.log", errors="replace").read()[-3000:])
        q.kill()
        sys.exit(1)
    run("systemctl is-system-running --wait >/dev/null 2>&1")
    return q


def power_off(q, label=""):
    bslvm.simple(args, "o", b"poweroff")
    try:
        q.wait(120 * SLOW)
        check(f"power off{label}", True, f"qemu exit {q.returncode}")
    except subprocess.TimeoutExpired:
        q.kill()
        check(f"power off{label}", False, "qemu still running")


# What a container must be able to do, as one shell line run in an alpine container.
IN_CONTAINER = ("nslookup deb.debian.org >/dev/null 2>&1 && echo dns-ok; "
                "wget -q -T 30 -O- http://deb.debian.org/debian/dists/trixie/Release | head -n 1; "
                "wget -q -T 30 -O /dev/null https://deb.debian.org/debian/dists/trixie/Release && echo https-ok")
WAIT = "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do curl -fsS -m 5 {url} 2>/dev/null && break; sleep 2; done"


def net_ok(o):
    return "dns-ok" in o and "Origin: Debian" in o and "https-ok" in o


q = boot()
threading.Thread(target=bslvm.net_serve, args=(args, 16), daemon=True).start()
time.sleep(1)
o, st = run(open("/t/prepare-user.sh").read())
check("prepare user", st == 0 and "bus ok" in o, one(o))
o, st = run("df -B1M --output=size,avail / | tail -n 1; uname -r; echo localnet=$(cat /proc/sys/net/ipv4/conf/all/route_localnet); "
            "nft list table inet breadstick_vm_containers >/dev/null 2>&1 && echo rules-loaded || echo no-rules; "
            "[ -f /usr/lib/breadstick-vm/vmnet-containers.nft ] && echo image-has-rules || echo image-has-none; "
            "echo \"newuidmap in the image: $(ls -l /usr/bin/newuidmap 2>/dev/null | cut -c1-10) $(getcap /usr/bin/newuidmap 2>/dev/null)\"")
print(f"NOTE disk (MiB size, free), kernel, route_localnet, rules: {one(o)}", flush=True)
image_rules = "image-has-rules" in o
if RULES == "image":
    check("the image loads the container rules itself at boot (vmnet-setup)",
          image_rules and "rules-loaded" in o and "localnet=1" in o, one(o))
if DISTRO == "archlinux":
    # [breadstick] serves nothing before the 4.0 publish; Arch's install is -Syu, so it is left out for the run.
    run("cp -p /etc/pacman.conf /etc/pacman.conf.r14; sed -i '/^\\[breadstick/,/^$/d' /etc/pacman.conf")

# The app's script refuses anywhere but in a Breadstick VM: here with the folder it looks for swapped for one that
# is not there.
o, st = run("d=$(mktemp -d) && sed 's#! -d /usr/lib/breadstick-vm \\]#! -d '\"$d\"'/none ]#' > \"$d/s.sh\"; sh \"$d/s.sh\"; r=$?; "
            "rm -f \"$d/s.sh\"; rmdir \"$d\"; exit $r", stdin=open(f"/t/containers-docker-{DISTRO}.sh", "rb").read())
check("the install refuses outside a Breadstick VM, nothing installed",
      st == 1 and "needs the virtual machine engine" in o and "[1/3]" not in o, one(o))


def docker_checks(label):
    o, st = run("docker info --format '{{.Driver}} {{.CgroupDriver}} cgroup{{.CgroupVersion}} {{.ServerVersion}}'; "
                "systemctl is-active docker; systemctl is-enabled docker")
    check(f"docker{label}: the daemon runs under systemd (overlay storage, cgroup v2)",
          st == 0 and "overlay" in o and "cgroup2" in o and "active" in o and "enabled" in o, one(o))
    o, st = run("docker run --rm hello-world 2>&1 | grep -c 'Hello from Docker'")
    check(f"docker{label}: hello-world (a pull through the relay, a container run)", o.strip() == "1", one(o))
    o, st = run(f"docker run --rm alpine sh -c '{IN_CONTAINER}' 2>&1")
    check(f"docker{label}: a container reaches the network (DNS, HTTP, HTTPS)", net_ok(o), one(o))
    o, st = run("mkdir -p /srv/r14 && echo 'from the bind mount' > /srv/r14/index.html; docker rm -f r14web >/dev/null 2>&1; "
                "docker run -d --name r14web -p 8080:80 -v /srv/r14:/usr/share/nginx/html:ro nginx:alpine >/dev/null 2>&1; "
                + WAIT.format(url="http://127.0.0.1:8080/") + "; docker rm -f r14web >/dev/null 2>&1")
    check(f"docker{label}: a published port serves a bind-mounted file", "from the bind mount" in o, one(o))
    o, st = run("docker network create r14net >/dev/null && docker run -d --name r14a --network r14net nginx:alpine >/dev/null && "
                f"docker run --rm --network r14net alpine sh -c 'sleep 2; wget -q -T 20 -O- http://r14a/ | grep -c nginx; {IN_CONTAINER}' 2>&1; "
                "docker rm -f r14a >/dev/null 2>&1; docker network rm r14net >/dev/null 2>&1")
    check(f"docker{label}: a user network (container names resolve, and the network beyond)",
          net_ok(o) and o.strip()[:1] in tuple("123456789"), one(o))
    o, st = run("docker ps >/dev/null 2>&1 && echo user-ok; id -Gn", user="tester")
    check(f"docker{label}: the user runs docker without sudo (the docker group)", "user-ok" in o and "docker" in o.split(), one(o))


def docker_extra():
    o, st = run("mkdir -p /tmp/r14b && printf 'FROM alpine\\nRUN apk add --no-cache curl >/dev/null && curl -sI https://deb.debian.org/ | head -n 1 > /out\\n"
                "CMD cat /out\\n' > /tmp/r14b/Dockerfile && docker build -q -t r14b /tmp/r14b >/dev/null 2>&1 && docker run --rm r14b; "
                "docker rmi -f r14b >/dev/null 2>&1")
    check("docker: a build whose RUN step uses the network", "HTTP/" in o and " 200" in o, one(o))
    compose = ("services:\n  web:\n    image: nginx:alpine\n    ports: [\"8081:80\"]\n    volumes: [\"/srv/r14:/usr/share/nginx/html:ro\"]\n"
               "  probe:\n    image: alpine\n    depends_on: [web]\n    command: sh -c \"sleep 3; wget -q -O- http://web/\"\n")
    run("mkdir -p /tmp/r14c")
    bslvm.simple(args, "f", b"/tmp/r14c/compose.yaml\0" + b"644\0" + compose.encode())
    o, st = run("cd /tmp/r14c && docker compose version --short 2>&1 | head -n 1 && docker compose up -d >/dev/null 2>&1; "
                + WAIT.format(url="http://127.0.0.1:8081/") + "; sleep 6; docker compose logs probe 2>&1 | tail -n 1; "
                "docker compose down >/dev/null 2>&1")
    check("docker: Compose (two services, a published port, one reaching the other by name)", o.count("from the bind mount") >= 2, one(o))
    # The guard: route_localnet lets the rules hand a container's packets to bsl-vmnet on 127.0.0.1, and must not let
    # a container that sends to 127.0.0.0/8 through its gateway reach this machine's own loopback services. A web
    # server on the VM's 127.0.0.1:8099 stands in for one; the container drops its own loopback address and routes
    # 127.0.0.0/8 at the VM. First with the guard chain deleted, to see that the test can fail (the page arrives), then
    # with the rules loaded again from their file.
    probe = ("docker run --rm --cap-add NET_ADMIN --sysctl net.ipv4.conf.all.route_localnet=1 alpine sh -c '"
             "ip addr del 127.0.0.1/8 dev lo; ip route add 127.0.0.0/8 via 172.17.0.1; "
             "wget -q -T 5 -O- http://127.0.0.1:8099/ 2>/dev/null | head -n 1; echo probe-done' 2>&1")
    rules = "$(ls /usr/lib/breadstick-vm/vmnet-containers.nft /etc/breadstick-vm/vmnet-containers.nft 2>/dev/null | head -n 1)"
    o, st = run("cd /srv/r14 && (python3 -m http.server 8099 --bind 127.0.0.1 >/dev/null 2>&1 & echo $! > /tmp/r14-http.pid); sleep 2; "
                "nft delete chain inet breadstick_vm_containers guard && echo \"open: $(" + probe.replace('"', '\\"') + " | tr '\\n' ' ')\"; "
                f"nft -f {rules} && echo \"guarded: $(" + probe.replace('"', '\\"') + " | tr '\\n' ' ')\"; "
                "kill $(cat /tmp/r14-http.pid) 2>/dev/null; rm -f /tmp/r14-http.pid")
    lines = {l.split(":", 1)[0]: l for l in o.splitlines() if ":" in l}
    check("docker: a container cannot reach the VM's loopback services (the guard; reachable with the guard deleted)",
          "from the bind mount" in lines.get("open", "") and "probe-done" in lines.get("guarded", "")
          and "from the bind mount" not in lines.get("guarded", ""), one(o))


def podman_checks(label):
    o, st = run(f"podman run --rm docker.io/library/alpine sh -c '{IN_CONTAINER}' 2>&1")
    check(f"podman{label}: a container run as root reaches the network", net_ok(o), one(o))
    o, st = run("podman info --format '{{.Host.Security.Rootless}} {{.Store.GraphDriverName}} {{.Host.CgroupsVersion}} {{.Host.RootlessNetworkCmd}}' 2>&1", user="tester")
    check(f"podman{label}: rootless for the user (overlay, cgroup v2)", st == 0 and o.split()[:3] == ["true", "overlay", "v2"], one(o))
    o, st = run(f"podman run --rm docker.io/library/alpine sh -c 'id -u; {IN_CONTAINER}' 2>&1", user="tester")
    check(f"podman{label}: a rootless container reaches the network", net_ok(o), one(o))
    o, st = run("mkdir -p ~/r14 && echo 'rootless bind mount' > ~/r14/index.html; podman rm -f r14w >/dev/null 2>&1; "
                "podman run -d --name r14w -p 8090:80 -v ~/r14:/usr/share/nginx/html:ro docker.io/library/nginx:alpine >/dev/null 2>&1; "
                + WAIT.format(url="http://127.0.0.1:8090/") + "; podman rm -f r14w >/dev/null 2>&1", user="tester")
    check(f"podman{label}: a rootless published port serves a bind-mounted file", "rootless bind mount" in o, one(o))


# ---- Published ports on Android (4.0, Android vm/VmPorts.kt): the watcher the app holds in the VM, and the app's own
# forward command against what containers publish.
PORTS_TEXT = None


class Watcher:
    """published-ports.sh (the app's VmPorts.WATCH_SCRIPT) held on an agent channel as the app holds it: its lines as
    they arrive, its exit status if it ends, and the hangup the app's stop is."""

    def __init__(self):
        self.lines, self.status = [], None
        self.s = bslvm.connect(args, bslvm.AGENT_PORT)
        bslvm.request(self.s, "r", bslvm.run_payload(PORTS_TEXT, "root"))
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        buf = b""
        try:
            for t, d in bslvm.frames(self.s):
                if t == "o":
                    buf += d
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        self.lines.append(line.decode(errors="replace"))
                elif t == "x":
                    self.status = int.from_bytes(d[:4], "little", signed=True)
        except OSError:
            pass

    def wait(self, pred, secs=40):
        """Seconds until the newest line satisfies pred, or None."""
        t0 = time.time()
        while time.time() - t0 < secs * SLOW:
            if self.lines and pred(self.lines[-1]):
                return time.time() - t0
            time.sleep(0.2)
        return None

    def ended(self, secs=20):
        t0 = time.time()
        while self.status is None and time.time() - t0 < secs * SLOW:
            time.sleep(0.2)
        return self.status

    def close(self):
        # shutdown() first: close() alone leaves the channel open while the reader thread sits in recv().
        try:
            import socket
            self.s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.s.close()
        except OSError:
            pass


def words(line):
    return set((line or "").split()[1:])


def through_the_app(port, source="127.0.0.1"):
    """An HTTP request through the app's own command for one connection (port-forward.sh, VmPortForward's, here for
    [port] and leaving from [source]: 127.0.0.1 itself is what the app uses for these ports, VmPorts.SOURCE)."""
    text = open("/t/port-forward.sh").read().replace("2222", str(port)).replace("127.168.1.20", source)
    assert f" {source} {port};" in text
    o, st = run(text, stdin=b"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
    return o, st


WATCHER_TICKS = ("exec 2>/dev/null; j=$(for p in /proc/[0-9]*; do tr '\\0' ' ' < $p/cmdline | grep -q '^journalctl -f -n 0 -o cat PODMAN_EVENT=start' && echo ${p#/proc/}; done | head -n 1); "
                 "[ -n \"$j\" ] || { echo none; exit 0; }; w=$(awk '{print $4}' /proc/$j/stat); "
                 "echo \"$(awk '{print $14+$15}' /proc/$w/stat) $(awk '{print $14+$15}' /proc/$j/stat) $(cat /proc/$w/comm)\"")


def ports_before_any_install():
    w = Watcher()
    st = w.ended()
    check("ports: with neither Docker nor Podman the watcher ends at once and says nothing",
          st == 3 and w.lines == [], f"status {st}, lines {w.lines}")
    w.close()


def ports_checks(label, kept=None):
    w = Watcher()
    first = w.wait(lambda l: l.startswith("P"), 30)
    want = {kept} if kept else set()
    check(f"ports{label}: the watcher's first line is what is published now",
          first is not None and (want <= words(w.lines[-1]) if want else w.lines[-1] == "P"), f"{w.lines[-1:]} after {first}")
    if "docker" in KINDS:
        run("docker rm -f r14pub >/dev/null 2>&1; docker run -d --name r14pub -p 8085:80 -p 127.0.0.1:8086:80 "
            "-v /srv/r14:/usr/share/nginx/html:ro nginx:alpine >/dev/null 2>&1")
        t = w.wait(lambda l: {"8085,d,r14pub", "8086,d,r14pub"} <= words(l))
        check(f"ports{label}: a Docker container's published ports are found when it starts (every address, and loopback)",
              t is not None, f"{w.lines[-1:]} after {t and round(t, 1)}s")
        o, st = run(WAIT.format(url="http://127.0.0.1:8085/") + " >/dev/null; echo up")
        o, st = through_the_app(8085)
        check(f"ports{label}: the app's forward command reaches the Docker container's port", "from the bind mount" in o and "200 OK" in o, one(o))
        o, st = through_the_app(8086)
        check(f"ports{label}: and the one published on the VM's loopback only", "from the bind mount" in o, one(o))
        # Nothing happens for a while: the watcher and its journalctl use no processor time at all.
        a, _ = run(WATCHER_TICKS)
        time.sleep(20)
        b, _ = run(WATCHER_TICKS)
        check(f"ports{label}: while nothing changes the watcher uses no processor time (20 s; it waits, never polls)",
              a.strip() == b.strip() and a.strip() not in ("", "none"), f"ticks before {a.strip()!r}, after {b.strip()!r}")
        # The daemon restarted under it: the event stream is opened again, and a later container is still found.
        run("docker rm -f r14pub >/dev/null 2>&1; systemctl restart docker")
        t0 = w.wait(lambda l: not ({"8085,d,r14pub"} & words(l)))
        run("docker run -d --name r14pub2 -p 8088:80 nginx:alpine >/dev/null 2>&1")
        t = w.wait(lambda l: "8088,d,r14pub2" in words(l))
        check(f"ports{label}: found again after the Docker daemon restarted", t0 is not None and t is not None, f"{w.lines[-3:]}")
        run("docker rm -f r14pub2 >/dev/null 2>&1")
        t = w.wait(lambda l: not any(",d,r14pub" in x for x in words(l)))
        check(f"ports{label}: a removed container's port is gone", t is not None, f"{w.lines[-1:]} after {t and round(t, 1)}s")
    if "podman" in KINDS:
        run("mkdir -p ~/r14 && echo 'rootless bind mount' > ~/r14/index.html; podman rm -f r14pp >/dev/null 2>&1; "
            "podman run -d --name r14pp -p 8091:80 -v ~/r14:/usr/share/nginx/html:ro docker.io/library/nginx:alpine >/dev/null 2>&1", user="tester")
        t = w.wait(lambda l: "8091,p,r14pp" in words(l))
        check(f"ports{label}: a rootless Podman container's published port is found (the journal's event, the user's own podman)",
              t is not None, f"{w.lines[-1:]} after {t and round(t, 1)}s")
        run(WAIT.format(url="http://127.0.0.1:8091/") + " >/dev/null; echo up")
        o, st = through_the_app(8091)
        check(f"ports{label}: the app's forward command reaches the rootless Podman container's port", "rootless bind mount" in o, one(o))
        run("podman rm -f r14pr >/dev/null 2>&1; podman run -d --name r14pr -p 8092:80 -v /srv/r14:/usr/share/nginx/html:ro "
            "docker.io/library/nginx:alpine >/dev/null 2>&1")
        t = w.wait(lambda l: "8092,p,r14pr" in words(l))
        check(f"ports{label}: a Podman container run as root is found too", t is not None, f"{w.lines[-1:]} after {t and round(t, 1)}s")
        run(WAIT.format(url="http://127.0.0.1:8092/") + " >/dev/null; echo up")
        o, st = through_the_app(8092)
        check(f"ports{label}: the app's forward command reaches the root Podman container's port", "from the bind mount" in o, one(o))
        # Why the app's forwards leave from 127.0.0.1 itself: from a client's own loopback address, as SSH's leave,
        # Podman's rules for root's containers (netavark) let nothing back in (exit 7 after the connect times out).
        o, st = through_the_app(8092, "127.168.1.20")
        print(f"NOTE the root Podman container's port from 127.168.1.20: exit {st}, {len(o)} bytes", flush=True)
        run("podman rm -f r14pp >/dev/null 2>&1", user="tester")
        run("podman rm -f r14pr >/dev/null 2>&1")
        t = w.wait(lambda l: not any(",p,r14p" in x for x in words(l)))
        check(f"ports{label}: removed Podman containers' ports are gone", t is not None, f"{w.lines[-1:]} after {t and round(t, 1)}s")
    check(f"ports{label}: the watcher is still running, and every line it printed is a P line",
          w.status is None and all(l == "P" or l.startswith("P ") for l in w.lines), f"status {w.status}, {len(w.lines)} lines")
    # The app's stop is a hangup: the watcher and its journalctl are gone.
    w.close()
    time.sleep(4)
    o, st = run(WATCHER_TICKS)
    check(f"ports{label}: the hangup ends the watcher and its journalctl", o.strip() == "none", one(o))


PORTS_TEXT = app_text("published-ports.sh")
ports_before_any_install()

if "docker" in KINDS:
    text = app_text(f"containers-docker-{DISTRO}.sh")
    t0 = time.time()
    o, st = run(text)
    check(f"docker: the app's install ({DISTRO})", st == 0 and o.strip().endswith("Docker is ready."), f"{time.time() - t0:.0f}s: {one(o)[-300:]}")
    o, st = run("nft list table inet breadstick_vm_containers 2>/dev/null | grep -c dnat; cat /proc/sys/net/ipv4/conf/all/route_localnet; "
                "systemctl is-enabled bsl-vmnet-containers.service 2>/dev/null || echo no-unit")
    check("docker: the container rules are loaded" + (" (the image's own, no unit written)" if image_rules else " (the app's unit: an image without them)"),
          o.split()[:2] == ["2", "1"] and (("enabled" in o) != image_rules), one(o))
    docker_checks("")
    docker_extra()

if "podman" in KINDS:
    text = app_text(f"containers-podman-{DISTRO}.sh")
    t0 = time.time()
    o, st = run(text)
    check(f"podman: the app's install ({DISTRO})", st == 0 and o.strip().endswith("Podman is ready."), f"{time.time() - t0:.0f}s: {one(o)[-300:]}")
    o, st = run("ls -l /usr/bin/newuidmap | cut -c1-10; getcap /usr/bin/newuidmap /usr/bin/newgidmap 2>/dev/null")
    check("podman: newuidmap can map ids (setuid, or its file capability)", "rws" in o or o.count("cap_set") == 2, one(o))
    podman_checks("")

ports_checks("")

o, st = run("df -B1M --output=used / | tail -n 1")
print(f"NOTE disk used after the installs and tests: {o.strip()} MiB", flush=True)

# Again after a reboot: the daemon starts by itself, the rules are there before it, a container set to restart is back.
if "docker" in KINDS:
    run("docker run -d --restart unless-stopped --name r14keep -p 8082:80 -v /srv/r14:/usr/share/nginx/html:ro nginx:alpine >/dev/null 2>&1")
power_off(q)
q = boot(" (second boot)")
threading.Thread(target=bslvm.net_serve, args=(args, 16), daemon=True).start()
time.sleep(1)
if "docker" in KINDS:
    o, st = run(WAIT.format(url="http://127.0.0.1:8082/"))
    check("docker (second boot): a container set to restart is serving again", "from the bind mount" in o, one(o))
    # A watcher started after the boot, as the app starts it, says at once what is already published.
    w2 = Watcher()
    t = w2.wait(lambda l: "8082,d,r14keep" in words(l), 30)
    check("ports (second boot): a container already serving is in the watcher's first line", t is not None and len(w2.lines) == 1, f"{w2.lines}")
    w2.close()
    run("docker rm -f r14keep >/dev/null 2>&1")
    docker_checks(" (second boot)")
if "podman" in KINDS:
    podman_checks(" (second boot)")
o, st = run("systemctl --failed --no-legend --plain | cut -d' ' -f1 | tr '\\n' ' '")
check("no failed units", o.strip() == "", one(o))
power_off(q, " (second boot)")

print("all passed" if not fails else f"{len(fails)} failed: {', '.join(fails)}", flush=True)
sys.exit(1 if fails else 0)
