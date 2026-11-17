"""4.0 round 12, the vmparC loop (Android docs/4.0/multi-distro.md 5.14): Emulated Display in the VM (V18), the Get apps
bundles and the MCP tools in each family's VM (V15, the MCP row), and V19's spike, the virgl vtest socket relayed into
the VM. Run by qemu-test.py inside its PARITY block (run_all(globals())), after the network relay is up. Every command is
the app's own text (app_text: rootfs vm/test/<name> = Android app/src/test/resources/vm/<name>, checked by
VmInboundTest + VmParityCTest), each check named "parity: ... (Vnn)" for AutoBuild's parity gate, and every check that a
broken text or guest would pass is paired with the case that shows it can fail.

  VMPARC=0                        skip all of it
  VMPARC_BREAK=session|bundle     run with the named app text broken on purpose (the checks must then FAIL)
  VIRGL_SOCK=<host socket>        V19's spike: a vtest server's socket in this container (qemu-test.sh VIRGL_DIR=)
"""
import os
import time

DISPLAY_N = 10
PORT = 5911


def run_all(g):
    if os.environ.get("VMPARC", "1") != "1":
        print("SKIP vmparc (VMPARC=0)", flush=True)
        return
    vd = emulated_display_test(g)
    try:
        if vd is not None:
            mcp_tools_test(g)
            gpu_spike(g)
    finally:
        if vd is not None:
            stop_display(g, vd)
    bundles_test(g)


# ----------------------------------------------------------------------------------------------- V18

def emulated_display_test(g):
    """VirtualDisplay's VM branch: TigerVNC installed by the VM's package manager when missing, the password file in root's
    0700 folder, the session script with BREADSTICK_HEADLESS=1 as root, Xvnc listening, a viewer carried in through the
    app's forward (VmPortForward's text) getting the RFB greeting, and the XFCE session drawing on the virtual display."""
    run, check, app_text, Chan, DISTRO = g["run"], g["check"], g["app_text"], g["Chan"], g["DISTRO"]
    o, st = run("grep -qs headless-v1 /usr/lib/breadstick/start-desktop-x11.sh || exit 77")
    if st == 77:
        print("SKIP emulated display (no headless-v1 breadstick-session in this image)", flush=True)
        return None
    # The app's own install text for the family. Arch's (an -Syu after the user's yes) syncs every repository
    # pacman.conf names, and [breadstick] serves nothing before the 4.0 publish: it is left out for the run, as the
    # bundle install below does, and put back after.
    if DISTRO == "archlinux":
        run("cp -p /etc/pacman.conf /etc/pacman.conf.r12vd; sed -i '/^\\[breadstick/,/^$/d' /etc/pacman.conf")
    o, st = run("command -v Xvnc >/dev/null && exit 0; " + app_text("vd-xvnc-install-" + DISTRO + ".sh"))
    if DISTRO == "archlinux":
        run("mv -f /etc/pacman.conf.r12vd /etc/pacman.conf")
    o2, st2 = run("command -v Xvnc")
    check(f"parity: Emulated Display: TigerVNC's Xvnc in the VM ({DISTRO}, V18)", st2 == 0, (o + " | " + o2).strip()[-300:])
    if st2 != 0:
        return None
    # 8 bytes on stdin, as VirtualDisplayRules.passwordFile writes them (the DES of the password).
    o, st = run(app_text("vd-password.sh"), stdin=bytes(range(8)))
    o, _ = run("id -gn; stat -c '%a %U %G' /run/bsl/headless /run/bsl/headless/passwd; head -c 8 /run/bsl/headless/passwd | od -An -tx1 | tr -d ' '; "
               "touch /run/bsl/headless/x 2>/dev/null && echo user-wrote", user="tester")
    w = o.split()
    check("parity: Emulated Display: the password file root's, the user's group may read it, the user cannot write there (V18)",
          st == 0 and len(w) == 8 and w[1:7] == ["750", "root", w[0], "640", "root", w[0]] and w[7] == "0001020304050607",
          o.strip().replace("\n", " | "))
    session_text = app_text("vd-session.sh")
    if os.environ.get("VMPARC_BREAK") == "session":
        print("NOTE vmparc: the session text broken on purpose (BREADSTICK_HEADLESS dropped)", flush=True)
        session_text = session_text.replace("BREADSTICK_HEADLESS=1 ", "")
    env = ["DISPLAY=:0", "NO_AT_BRIDGE=1", "LIBGL_KOPPER_DISABLE=1"]
    s = Chan(session_text, env=env)
    up = s.lines(150, lambda l: l.startswith("[BSL] virtual display: Xvnc on"))
    check("parity: Emulated Display: the session starts Xvnc on the virtual display (V18)",
          any(l.startswith(f"[BSL] virtual display: Xvnc on :{DISPLAY_N}, 1280x800, port {PORT}") for l in up), " | ".join(up[-5:])[-400:])
    ok = False
    for _ in range(40):
        _, st = run(app_text("vd-listen.sh"))
        if st == 0:
            ok = True
            break
        time.sleep(0.5)
    check("parity: Emulated Display: Xvnc listens in the VM (V18)", ok)
    fwd = Chan(app_text("vd-forward.sh"))
    greet = b""
    t0 = time.time()
    while time.time() - t0 < 15 and b"\n" not in greet:
        greet += fwd.take()
        time.sleep(0.1)
    check("parity: Emulated Display: a viewer through the app's forward gets the RFB greeting (V18)",
          greet.startswith(b"RFB 003.00"), repr(greet[:20]))
    g["hangup"](fwd)
    shown, dims = "", ""
    for _ in range(60):
        time.sleep(2)
        o, _ = run(f"xdpyinfo -display :{DISPLAY_N} 2>/dev/null | grep dimensions; "
                   f"xwininfo -display :{DISPLAY_N} -root -children 2>/dev/null | grep -c -E 'xfce4-panel|xfdesktop|Xfwm4'", user="tester")
        w = o.strip().splitlines()
        dims = w[0] if w else ""
        shown = w[-1].strip() if w else ""
        if "1280x800" in dims and shown not in ("", "0"):
            break
    check("parity: Emulated Display: XFCE draws on the virtual display at its size (V18)", "1280x800" in dims and shown not in ("", "0"),
          f"{dims.strip()}; {shown} shell windows")
    o, _ = run(f"for e in /proc/[0-9]*/environ; do tr '\\0' '\\n' 2>/dev/null < $e | grep -qx DISPLAY=:0 && echo x; done | wc -l")
    print(f"vmparc: programs on :0 while the virtual display runs: {o.strip()}", flush=True)
    return s


def stop_display(g, s):
    """VirtualDisplay.stop in the VM: the channel hung up, then vd-stop.sh (the display's programs, its Xvnc, the password)."""
    run, check, app_text = g["run"], g["check"], g["app_text"]
    # Programs naming the display the other ways X clients do (the round 12 review's survivor was DISPLAY=:10.0), and
    # one on another display whose number starts with this one's, which Stop must leave alone.
    run(f"for d in :{DISPLAY_N}.0 unix:{DISPLAY_N} localhost:{DISPLAY_N}.0; do setsid env DISPLAY=$d sleep 600 >/dev/null 2>&1 & done; "
        f"setsid env DISPLAY=:{DISPLAY_N}9 BSL_VMPARC_OTHER=1 sleep 601 >/dev/null 2>&1 & true", user="tester")
    g["hangup"](s)
    o, st = run(app_text("vd-stop.sh"))
    time.sleep(3)
    o, _ = run(f"pgrep -x Xvnc || pgrep -x Xtigervnc || echo no-xvnc; test -e /run/bsl/headless/passwd && echo pw-left; "
               f"for e in /proc/[0-9]*/environ; do tr '\\0' '\\n' 2>/dev/null < $e | grep -Eqx 'DISPLAY=(unix|localhost)?:{DISPLAY_N}(\\.[0-9]+)?|BREADSTICK_HEADLESS=1' && {{ q=${{e%/environ}}; echo left:${{q#/proc/}}:$(cat $q/comm 2>/dev/null):$(stat -c %U $q 2>/dev/null):$(tr '\\0' ' ' < $q/cmdline 2>/dev/null | cut -c1-80 | tr ' ' _):$(tr '\\0' '\\n' < $e | grep ^DISPLAY=):ppid=$(awk '/^PPid/{{print $2}}' $q/status):$(pp=$(awk '/^PPid/{{print $2}}' $q/status); tr '\\0' ' ' < /proc/$pp/cmdline 2>/dev/null | cut -c1-120 | tr ' ' _); }}; done; "
               f"test -e /tmp/.X{DISPLAY_N}-lock && echo lock-left")
    check("parity: Emulated Display: Stop ends Xvnc, the session script and the display's programs (:N, :N.0, unix:N), the password file goes (V18)",
          st == 0 and o.split() == ["no-xvnc"], " | ".join(l[:240] for l in o.strip().splitlines()))
    o, _ = run("pgrep -x -f 'sleep 601' || echo gone; pkill -x -f 'sleep 601' || true")
    check("parity: Emulated Display: Stop leaves another display's programs running (V18)",
          o.split()[0].isdigit(), o.strip().replace("\n", " | "))


# --------------------------------------------------------------------------------------------- MCP row

def mcp_tools_test(g):
    """The MCP tools' Linux text (McpVmScripts) as McpAndroidBackend runs it in the VM: as the Linux user through the agent."""
    run, check, app_text = g["run"], g["check"], g["app_text"]
    import base64
    o, st = run(app_text("mcp-command.sh"), user="tester")
    check("parity: MCP run_command in the VM: its folder and the Linux user", st == 0 and o.split()[:2] == ["/tmp", "tester"], o.strip())
    data = b"written by an MCP client\n"
    o, st = run(app_text("mcp-write.sh"), user="tester", stdin=data)
    check("parity: MCP write_file in the VM: the folder made, the real path back", st == 0 and o.strip().endswith("/home/tester/r12/mcp.txt"), o.strip())
    o, st = run(app_text("mcp-read.sh"), user="tester")
    w = o.split("\n")
    got = base64.b64decode(w[2].strip()) if len(w) > 2 and st == 0 else b""
    check("parity: MCP read_file in the VM: the same bytes and size", got == data and w[1].strip() == str(len(data)), o.strip()[-200:])
    o, st = run("stat -c %U /home/tester/r12/mcp.txt")
    check("parity: MCP files in the VM are the Linux user's", o.strip() == "tester", o.strip())
    run(f"printf 'from the clipboard' | timeout 10 xclip -display :{DISPLAY_N} -quiet -selection clipboard >/dev/null 2>&1 &", user="tester")
    time.sleep(1.5)
    o, st = run(app_text("mcp-clipboard.sh"), user="tester", env=[f"DISPLAY=:{DISPLAY_N}"])
    check("parity: MCP clipboard_get in the VM reads Linux's clipboard", o == "from the clipboard", repr(o[:80]))
    o, st = run(app_text("mcp-read.sh").replace("/r12/mcp.txt", "/r12"), user="tester")
    check("parity: MCP read_file refuses what is not a file (the check can fail)", st == 2, f"exit {st}: {o.strip()[:120]}")
    run("rm -rf /home/tester/r12")


# ------------------------------------------------------------------------------------------------- V15

def bundles_test(g):
    """Get apps in the VM (MainViewModel.runInstallScript: InstallScripts.vmBundle, the family's marker around the
    bundle's own script): every bundle's packages resolve to packages of this distribution through the VM's own name
    table (bsl_pkg_names), and the Media bundle installs, its programs there, no package-run marker left."""
    run, check, app_text, DISTRO = g["run"], g["check"], g["app_text"], g["DISTRO"]
    if DISTRO not in ("fedora", "archlinux"):
        print(f"SKIP bundles ({DISTRO}: its bundles are 3.x's, device-checked in the VM)", flush=True)
        return
    o, st = run("[ -r /usr/lib/breadstick/bsl-os.sh ] || exit 77")
    if st == 77:
        print("SKIP bundles (no breadstick-session in this image)", flush=True)
        return
    names = app_text(f"bundle-names-{DISTRO}.txt").strip().splitlines()
    avail = ("dnf -q -y --disablerepo='breadstick*' repoquery --available --qf '%{name}\\n' \"$p\" 2>/dev/null | grep -qx \"$p\""
             if DISTRO == "fedora" else g["NO_BSL_PACMAN"] + "pacman --config /tmp/pc -Si \"$p\" >/dev/null 2>&1")
    if DISTRO == "archlinux":
        run(g["NO_BSL_PACMAN"] + "pacman --config /tmp/pc -Sy >/dev/null 2>&1")
    missing = []
    for line in names:
        bid, pk = line.split(" ", 1)
        o, st = run(f". /usr/lib/breadstick/bsl-os.sh; for p in $(bsl_pkg_names {pk}); do {avail} || echo \"missing $p\"; done; "
                    f"bsl_pkg_names {pk} | tr '\\n' ' '")
        if "missing" in o or not o.strip():
            missing.append(f"{bid}: {o.strip()}")
        else:
            print(f"vmparc: bundle {bid} -> {o.strip()}", flush=True)
    check(f"parity: every Get apps bundle's packages resolve in the VM ({DISTRO}, V15)", not missing, "; ".join(missing)[-400:])
    o, st = run(f". /usr/lib/breadstick/bsl-os.sh; for p in $(bsl_pkg_names bsl-no-such-package-r12); do {avail} || echo \"missing $p\"; done")
    check("parity: a bundle name with no package is found missing (the check can fail)", "missing" in o, o.strip())
    heavy = os.environ.get("HEAVY") or ("1" if g["ARCH"] == "arm64" else "0")
    if heavy != "1":
        print("SKIP the Media bundle's install (HEAVY=0)", flush=True)
        return
    text = app_text(f"bundle-media-{DISTRO}.sh")
    if os.environ.get("VMPARC_BREAK") == "bundle":
        print("NOTE vmparc: the bundle text broken on purpose (apt-get in place of the family's install)", flush=True)
        text = text.replace("bsl_pkg_install mpv audacity", "apt-get install -y mpv audacity")
    if DISTRO == "archlinux":
        # [breadstick] serves nothing before the 4.0 publish; Arch's install is -Syu, so it is left out for the run.
        run("cp -p /etc/pacman.conf /etc/pacman.conf.r12; sed -i '/^\\[breadstick/,/^$/d' /etc/pacman.conf")
    o, st = run(text)
    if DISTRO == "archlinux":
        run("mv -f /etc/pacman.conf.r12 /etc/pacman.conf")
    o2, _ = run("command -v mpv audacity | wc -l; test -e /var/lib/breadstick/package-run && echo marker-left; "
                "test -e /var/lib/breadstick/package-run.cut && echo cut-left")
    check(f"parity: the Media bundle installs in the VM under the marker ({DISTRO}, V15)",
          st == 0 and "Installed." in o and o2.split() == ["2"], f"exit {st}: {' | '.join(o.strip().splitlines()[-3:])} | {o2.strip()}")
    o, _ = run("ls /var/log/breadstick/ 2>/dev/null | tr '\\n' ' '; grep -h 'install' /var/lib/breadstick/package-run.log 2>/dev/null | tail -2")
    print(f"vmparc: package-run records after the bundle: {o.strip()}", flush=True)


# ------------------------------------------------------------------------------------------------- V19

def gpu_spike(g):
    """V19: Mesa's virgl in the VM against a real vtest server through the app's socket relay (VmCommands.socketRelayScript
    on vsock 6104, the host end a pool like VmSocketRelay's). vsock carries no file descriptors, and the vtest protocol
    hands one over (SCM_RIGHTS) for every resource's shared memory (vtest_create_resource_internal) and for blobs and sync
    files: this records how far a GL program gets, for the plan. Not a parity check (no "parity:" name)."""
    sock = os.environ.get("VIRGL_SOCK")
    run = g["run"]
    if not sock or not os.path.exists(sock):
        print("SKIP gpu spike (no VIRGL_SOCK)", flush=True)
        return
    stop = g["relay_pool"](6104, sock)
    relay = g["Chan"](g["app_text"]("gpu-relay.sh"))
    time.sleep(2)
    probe = ("import ctypes,sys; X=ctypes.CDLL('libX11.so.6'); GL=ctypes.CDLL('libGL.so.1'); X.XOpenDisplay.restype=ctypes.c_void_p; "
             "X.XOpenDisplay.argtypes=[ctypes.c_char_p]; d=X.XOpenDisplay(None); X.XDefaultScreen.argtypes=[ctypes.c_void_p]; s=X.XDefaultScreen(d); "
             "GL.glXChooseVisual.restype=ctypes.c_void_p; GL.glXChooseVisual.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.POINTER(ctypes.c_int)]; "
             "v=GL.glXChooseVisual(d,s,(ctypes.c_int*7)(4,12,1,5,0,0,0)); GL.glXCreateContext.restype=ctypes.c_void_p; "
             "GL.glXCreateContext.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int]; c=GL.glXCreateContext(d,v,None,1); "
             "X.XRootWindow.restype=ctypes.c_ulong; X.XRootWindow.argtypes=[ctypes.c_void_p,ctypes.c_int]; r=X.XRootWindow(d,s); "
             "GL.glXMakeCurrent.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_void_p]; print('current', GL.glXMakeCurrent(d,r,c), flush=True); "
             "GL.glGetString.restype=ctypes.c_char_p; GL.glGetString.argtypes=[ctypes.c_uint]; print('renderer', GL.glGetString(0x1F01), flush=True); "
             "GL.glClearColor.argtypes=[ctypes.c_float]*4; GL.glClearColor(1,0,0,1); GL.glClear(0x4000); b=(ctypes.c_ubyte*4)(); "
             "GL.glReadPixels.argtypes=[ctypes.c_int]*4+[ctypes.c_uint,ctypes.c_uint,ctypes.c_void_p]; GL.glReadPixels(0,0,1,1,0x1908,0x1401,b); "
             "print('pixel', list(b), flush=True)")
    o, st = run(f"test -S /run/bsl/virgl.sock && echo relayed; GALLIUM_DRIVER=virpipe VTEST_SOCKET_NAME=/run/bsl/virgl.sock "
                f"MESA_DEBUG=1 timeout 40 python3 -c \"{probe}\" 2>&1 | tail -n 12; echo rc=$?", user="tester", env=[f"DISPLAY=:{DISPLAY_N}"])
    print("GPU-SPIKE " + o.strip().replace("\n", " | ")[-900:], flush=True)
    g["hangup"](relay)
    stop[0] = True
