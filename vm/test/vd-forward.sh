exec 2>/dev/null; command -v python3 >/dev/null && exec python3 -Ic 'import os, socket, sys, threading
s = socket.socket()
try:
    s.bind((sys.argv[1], 0))
except OSError:
    pass
try:
    s.connect(("127.0.0.1", int(sys.argv[2])))
except OSError:
    sys.exit(7)
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
def up():
    try:
        while True:
            b = os.read(0, 65536)
            if not b:
                break
            s.sendall(b)
        s.shutdown(socket.SHUT_WR)
    except OSError:
        pass
threading.Thread(target=up, daemon=True).start()
o = sys.stdout.buffer
try:
    while True:
        b = s.recv(65536)
        if not b:
            break
        o.write(b)
        o.flush()
except OSError:
    pass
sys.exit(0)' 127.168.1.20 5911; exec bash -c 'exec 4<&0; { exec 3<>/dev/tcp/127.0.0.1/5911; } || exit 7; cat <&4 >&3 & c=$!; cat <&3; kill $c; exit 0'
