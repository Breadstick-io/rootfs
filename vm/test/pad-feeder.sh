modprobe uinput 2>/dev/null; exec python3 -I -c 'import fcntl, os, struct, sys
def ioc(d, nr, size): return (d << 30) | (size << 16) | (ord('\''U'\'') << 8) | nr
UI_DEV_CREATE, UI_DEV_DESTROY = ioc(0, 1, 0), ioc(0, 2, 0)
UI_DEV_SETUP, UI_ABS_SETUP = ioc(1, 3, 92), ioc(1, 4, 28)
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT = ioc(1, 100, 4), ioc(1, 101, 4), ioc(1, 103, 4)
KEYS = [0x130, 0x131, 0x133, 0x134, 0x136, 0x137, 0x13a, 0x13b, 0x13c, 0x13d, 0x13e]
AXES = [0, 1, 2, 3, 4, 5, 0x10, 0x11]
INFO = [(-32768, 32767, 16, 128), (-32768, 32767, 16, 128), (0, 255, 0, 0), (-32768, 32767, 16, 128),
        (-32768, 32767, 16, 128), (0, 255, 0, 0), (-1, 1, 0, 0), (-1, 1, 0, 0)]
pads = {}
def make(name):
    fd = os.open('\''/dev/uinput'\'', os.O_WRONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    for ev in (1, 3):
        fcntl.ioctl(fd, UI_SET_EVBIT, ev)
    for k in KEYS:
        fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    for a, (lo, hi, fuzz, flat) in zip(AXES, INFO):
        fcntl.ioctl(fd, UI_SET_ABSBIT, a)
        fcntl.ioctl(fd, UI_ABS_SETUP, struct.pack('\''HH6i'\'', a, 0, 0, lo, hi, fuzz, flat, 0))
    nm = name.encode('\''utf-8'\'', '\''replace'\'')[:79]
    fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack('\''4H80sI'\'', 3, 0x045e, 0x028e, 0x0114, nm, 0))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return [fd, 0, [0] * 8]
def emit(fd, t, c, v):
    os.write(fd, struct.pack('\''llHHi'\'', 0, 0, t, c, v))
def drop(slot):
    p = pads.pop(slot, None)
    if p:
        try:
            fcntl.ioctl(p[0], UI_DEV_DESTROY)
        finally:
            os.close(p[0])
for line in sys.stdin:
    w = line.rstrip('\''\n'\'').split('\'' '\'', 11)
    try:
        slot = int(w[1])
        if w[0] == '\''R'\'' or slot < 0 or slot > 3:
            drop(slot)
            continue
        if w[0] != '\''S'\'' or len(w) < 11:
            continue
        buttons = int(w[2])
        axes = [int(x) for x in w[3:11]]
        p = pads.get(slot)
        if p is None:
            p = pads[slot] = make(w[11] if len(w) > 11 else '\''Controller'\'')
        fd, old, olda = p
        for i, k in enumerate(KEYS):
            if (buttons ^ old) >> i & 1:
                emit(fd, 1, k, buttons >> i & 1)
        for i, a in enumerate(AXES):
            if axes[i] != olda[i]:
                emit(fd, 3, a, axes[i])
        emit(fd, 0, 0, 0)
        p[1], p[2] = buttons, axes
        print('\''ok'\'', slot, flush=True)
    except Exception as e:
        print('\''error'\'', repr(e)[:200], flush=True)
for s in list(pads):
    drop(s)
'
