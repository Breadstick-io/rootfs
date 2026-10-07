#!/usr/bin/env python3
"""Reference HOST side of the Breadstick VM protocols (vm/PROTOCOL.md), for tests off the device.

The app's Kotlin code (Android: io.breadstick.vm.AgentProtocol, VmNetRelay) implements the same
bytes; this is what the guest programs are tested against in QEMU and over a unix socket.

  bslvm.py [--cid N | --unix PATH] ping|info|run CMD|pty|time|write PATH TEXT|poweroff
  bslvm.py --cid N net [--pool 8]        # serve the guest's network relay (vsock 5100) until ^C
"""
import argparse
import os
import select
import socket
import struct
import sys
import threading
import time

AGENT_PORT = 5000
NET_PORT = 5100


def connect(args, port):
    if args.unix:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(args.unix if port == AGENT_PORT else args.unix + f".{port}")
    else:
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.connect((args.cid, port))
    return s


def readn(s, n):
    b = b""
    while len(b) < n:
        k = s.recv(n - len(b))
        if not k:
            raise EOFError(f"EOF after {len(b)} of {n}")
        b += k
    return b


def request(s, op, payload=b""):
    s.sendall(b"BSA1" + op.encode() + struct.pack("<I", len(payload)) + payload)


def frames(s):
    while True:
        h = readn(s, 5)
        t, n = chr(h[0]), struct.unpack("<I", h[1:])[0]
        yield t, readn(s, n)
        if t == "x":
            return


def send_frame(s, t, data=b""):
    s.sendall(t.encode() + struct.pack("<I", len(data)) + data)


def simple(args, op, payload=b""):
    with connect(args, AGENT_PORT) as s:
        request(s, op, payload)
        out, st = b"", None
        for t, d in frames(s):
            if t == "o":
                out += d
            elif t == "x":
                st = struct.unpack("<i", d)[0]
        return out, st


def run_payload(cmd, user="root", pty=False, cols=80, rows=24, env=(), cwd=""):
    h = f"user={user}\npty={1 if pty else 0}\ncols={cols}\nrows={rows}\n"
    if cwd:
        h += f"cwd={cwd}\n"
    for e in env:
        h += f"env={e}\n"
    return (h + "\n").encode() + cmd.encode()


def run(args, cmd, user="root", stdin=None, pty=False, env=()):
    with connect(args, AGENT_PORT) as s:
        request(s, "r", run_payload(cmd, user, pty, env=env))
        if stdin is not None:
            send_frame(s, "d", stdin)
            send_frame(s, "e")
        out, st = b"", None
        for t, d in frames(s):
            if t == "o":
                out += d
            elif t == "x":
                st = struct.unpack("<i", d)[0]
        return out, st


def interactive(args, user):
    import termios
    import tty
    cols, rows = os.get_terminal_size()
    s = connect(args, AGENT_PORT)
    request(s, "r", run_payload("", user, True, cols, rows))
    old = termios.tcgetattr(0)
    tty.setraw(0)
    try:
        buf = b""
        while True:
            r, _, _ = select.select([0, s], [], [])
            if 0 in r:
                send_frame(s, "d", os.read(0, 4096))
            if s in r:
                k = s.recv(65536)
                if not k:
                    return
                buf += k
                while len(buf) >= 5:
                    n = struct.unpack("<I", buf[1:5])[0]
                    if len(buf) < 5 + n:
                        break
                    t, d, buf = chr(buf[0]), buf[5:5 + n], buf[5 + n:]
                    if t == "o":
                        os.write(1, d)
                    elif t == "x":
                        return
    finally:
        termios.tcsetattr(0, termios.TCSADRAIN, old)


# ----------------------------------------------------------------------------- network relay

def splice(a, b):
    try:
        while True:
            d = a.recv(262144)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass


def net_channel(ch, stats, became_busy):
    """One pooled channel: wait for the guest's request, then serve it (vm/PROTOCOL.md, BSN1)."""
    try:
        hdr = readn(ch, 5)
    except (EOFError, OSError):
        became_busy()
        ch.close()
        return
    became_busy()
    stats["used"] += 1
    if hdr[:4] != b"BSN1":
        ch.close()
        return
    kind = chr(hdr[4])
    if kind == "T":
        fam = readn(ch, 1)[0]
        addr = readn(ch, 4 if fam == 4 else 16)
        port = struct.unpack("<H", readn(ch, 2))[0]
        host = socket.inet_ntop(socket.AF_INET if fam == 4 else socket.AF_INET6, addr)
        try:
            r = socket.create_connection((host, port), timeout=15)
            r.settimeout(None)
        except OSError as e:
            ch.sendall(bytes([2]))
            ch.close()
            stats["tcp_fail"] += 1
            print(f"net: connect {host}:{port} failed: {e}", file=sys.stderr)
            return
        stats["tcp"] += 1
        ch.sendall(bytes([0]))
        t = threading.Thread(target=lambda: (splice(r, ch), ch.close()), daemon=True)
        t.start()
        splice(ch, r)  # guest EOF -> shut the remote's write side, keep reading it
        try:
            r.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        t.join(30)
        r.close()
        ch.close()
    elif kind == "D":
        n = struct.unpack("<H", readn(ch, 2))[0]
        q = readn(ch, n)
        ans = b""
        try:
            # The host's resolver, as a plain UDP forward (Android uses DnsResolver.rawQuery).
            u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            u.settimeout(5)
            ns = os.environ.get("BSL_DNS", "1.1.1.1")
            u.sendto(q, (ns, 53))
            ans = u.recv(65535)
        except OSError as e:
            print(f"net: dns failed: {e}", file=sys.stderr)
        stats["dns"] += 1
        ch.sendall(struct.pack("<H", len(ans)) + ans)
        ch.close()
    else:
        ch.close()


def net_serve(args, pool):
    stats = {"used": 0, "tcp": 0, "tcp_fail": 0, "dns": 0}
    idle = [0]
    lock = threading.Lock()

    def busy():
        with lock:
            idle[0] -= 1

    last = time.time()
    while True:
        with lock:
            n = idle[0]
        if n < pool:
            try:
                c = connect(args, NET_PORT)
            except OSError as e:
                print(f"net: connect failed: {e}", file=sys.stderr)
                time.sleep(0.5)
                continue
            with lock:
                idle[0] += 1
            threading.Thread(target=net_channel, args=(c, stats, busy), daemon=True).start()
        else:
            time.sleep(0.02)
        if time.time() - last > 10:
            last = time.time()
            print(f"net: {stats}", file=sys.stderr, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cid", type=int, default=3)
    ap.add_argument("--unix")
    ap.add_argument("--user", default="root")
    ap.add_argument("--pool", type=int, default=8)
    ap.add_argument("op")
    ap.add_argument("rest", nargs="*")
    a = ap.parse_args()
    if a.op == "ping":
        out, st = simple(a, "p")
    elif a.op == "info":
        out, st = simple(a, "i")
    elif a.op == "time":
        out, st = simple(a, "t", struct.pack("<Q", int(time.time() * 1000)))
    elif a.op == "write":
        out, st = simple(a, "f", a.rest[0].encode() + b"\0" + b"644\0" + a.rest[1].encode())
    elif a.op == "poweroff":
        out, st = simple(a, "o", b"poweroff")
    elif a.op == "run":
        out, st = run(a, " ".join(a.rest), a.user)
    elif a.op == "pty":
        interactive(a, a.user)
        return
    elif a.op == "net":
        net_serve(a, a.pool)
        return
    else:
        ap.error("unknown op")
    sys.stdout.buffer.write(out)
    print(f"[status {st}]", file=sys.stderr)
    sys.exit(0 if st == 0 else 1)


if __name__ == "__main__":
    main()
