exec 2>/dev/null; command -v python3 >/dev/null || exit 3; exec python3 -Ic 'import json, os, pwd, re, select, shutil, socket, subprocess, sys, time
from urllib.parse import quote
SOCK = "/run/docker.sock"
LOCAL = ("", "0.0.0.0", "::", "127.0.0.1", "::1")
DOCKER = shutil.which("docker") or shutil.which("dockerd")
PODMAN = shutil.which("podman")
if not DOCKER and not PODMAN:
    sys.exit(3)
def clean(name):
    return re.sub("[^A-Za-z0-9_.-]", "", str(name).lstrip("/"))[:64]
def docker_up():
    try:
        pid = int(open("/run/docker.pid").read().strip() or 0)
        return pid > 0 and open("/proc/%d/comm" % pid).read().strip() == "dockerd"
    except (OSError, ValueError):
        return False
def docker_open(path):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(10)
    s.connect(SOCK)
    s.sendall(("GET %s HTTP/1.0\r\nHost: docker\r\n\r\n" % path).encode())
    return s
def docker_ports(found):
    s = docker_open("/containers/json")
    data = b""
    while True:
        b = s.recv(65536)
        if not b:
            break
        data += b
    s.close()
    for c in json.loads(data.split(b"\r\n\r\n", 1)[1]):
        name = clean((c.get("Names") or [""])[0])
        for p in c.get("Ports") or []:
            if p.get("Type") == "tcp" and p.get("PublicPort") and p.get("IP", "") in LOCAL:
                found.setdefault(int(p["PublicPort"]), ("d", name))
def podman_ports(found, pre):
    try:
        r = subprocess.run(pre + [PODMAN, "ps", "--format", "json"], capture_output=True, timeout=60, cwd="/")
        for c in json.loads(r.stdout or b"[]"):
            name = clean((c.get("Names") or [""])[0])
            for p in c.get("Ports") or []:
                if p.get("protocol", "tcp") == "tcp" and p.get("host_port") and p.get("host_ip", "") in LOCAL:
                    for i in range(min(int(p.get("range") or 1), 16)):
                        found.setdefault(int(p["host_port"]) + i, ("p", name))
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
def scan():
    found = {}
    if docker_up():
        try:
            docker_ports(found)
        except (OSError, ValueError, IndexError):
            pass
    global PODMAN
    PODMAN = PODMAN or shutil.which("podman")
    if PODMAN:
        podman_ports(found, [])
        for u in pwd.getpwall():
            run = "/run/user/%d" % u.pw_uid
            if 1000 <= u.pw_uid < 60000 and os.path.isdir(run + "/containers") and shutil.which("runuser"):
                podman_ports(found, ["runuser", "-u", u.pw_name, "--", "env", "HOME=" + u.pw_dir, "XDG_RUNTIME_DIR=" + run])
    return " ".join("%d,%s,%s" % (port, found[port][0], found[port][1]) for port in sorted(found))
journal = None
if shutil.which("journalctl"):
    journal = subprocess.Popen(["journalctl", "-f", "-n", "0", "-o", "cat", "PODMAN_EVENT=start", "PODMAN_EVENT=died",
        "PODMAN_EVENT=remove", "PODMAN_EVENT=cleanup", "+", "UNIT=docker.service"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    os.set_blocking(journal.stdout.fileno(), False)
events = None
last = None
while True:
    if events is None and docker_up():
        try:
            f = quote(json.dumps({"type": ["container"], "event": ["start", "die", "destroy"]}))
            events = docker_open("/events?filters=" + f)
            events.settimeout(None)
            events.setblocking(False)
        except OSError:
            events = None
    now = scan()
    if now != last:
        last = now
        sys.stdout.write(("P " + now).rstrip() + "\n")
        sys.stdout.flush()
    waits = ([journal.stdout] if journal else []) + ([events] if events else [])
    if not waits:
        break
    ready = select.select(waits, [], [])[0]
    time.sleep(0.5)
    if journal and journal.stdout in ready:
        try:
            while os.read(journal.stdout.fileno(), 65536):
                pass
        except BlockingIOError:
            pass
    if events:
        try:
            while True:
                if not events.recv(65536):
                    events.close()
                    events = None
                    break
        except BlockingIOError:
            pass
        except OSError:
            events = None
if journal:
    journal.terminate()'
