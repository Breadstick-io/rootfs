"""4.0, Flatpak in the virtual machine (the r14 trial; Android linux/FlatpakSetup.kt): Get apps > Flatpak's own script in
the image's family, an app from Flathub installed by the user, listed for the Apps page with its icon, and opened with
the app's own launch text until its window is on the display. Run by qemu-test.py after the network and display relays
are up (run_all(globals())). Every command the VM runs for the app is the app's own text (app_text: rootfs
vm/test/<name> = Android app/src/test/resources/vm/<name>, checked by VmInboundTest + FlatpakSetupTest), and each check
that a broken text or guest would pass is paired with the case that shows it can fail.

  FLATPAK=1 vm/test/qemu-test.sh ...        run it after the other display checks (off by default: it downloads an
                                             app and its runtime from Flathub, about 1 GB, 2.5 GB on the disk)
  ONLY_FLATPAK=1 vm/test/qemu-test.sh ...   boot, the user, the network, the display, then these checks alone, and off
  FLATPAK_APP=org.gnome.Calculator FLATPAK_WINDOW=Calculator   the app and a word of its window's title
"""
import os
import time

APP = os.environ.get("FLATPAK_APP", "org.gnome.Calculator")
WINDOW = os.environ.get("FLATPAK_WINDOW", "Calculator")
PORTAL = ("gdbus call --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop "
          "--method org.freedesktop.portal.Settings.Read org.freedesktop.appearance color-scheme")


def run_all(g):
    run, check, app_text, Chan, DISTRO, bslvm, args = g["run"], g["check"], g["app_text"], g["Chan"], g["DISTRO"], g["bslvm"], g["args"]
    hangup = g["hangup"]
    if DISTRO not in ("debian", "fedora", "archlinux"):
        print(f"SKIP flatpak (no card for {DISTRO})", flush=True)
        return
    setup = app_text(f"flatpak-setup-{DISTRO}.sh")

    # The Standard engine's word first: the script must say so and install nothing (the app's row never offers it there).
    o, _ = run("cat /run/bsl/engine 2>/dev/null")
    word = o.strip() or "vm"
    bslvm.simple(args, "f", b"/run/bsl/engine\x00" + b"644\x00" + b"proot\n")
    o, st = run(setup)
    o2, _ = run("command -v flatpak || echo none")
    bslvm.simple(args, "f", b"/run/bsl/engine\x00" + b"644\x00" + word.encode() + b"\n")
    check("flatpak: on the Standard engine the card's script refuses and installs nothing",
          st == 3 and "needs the virtual machine engine" in o and "none" in o2, f"exit {st}: {o.strip()[-120:]} | {o2.strip()}")

    # Arch's [breadstick] repository serves nothing before the 4.0 publish: left out for the run, as vmparc.py does.
    if DISTRO == "archlinux":
        run("cp -p /etc/pacman.conf /etc/pacman.conf.r14fp; sed -i '/^\\[breadstick/,/^$/d' /etc/pacman.conf")
    t0 = time.time()
    o, st = run(setup)
    if DISTRO == "archlinux":
        run("mv -f /etc/pacman.conf.r14fp /etc/pacman.conf")
    o2, _ = run("flatpak --version; flatpak remotes --columns=name,options; systemctl is-active bsl-flatpak-apps.path; "
                "systemctl is-enabled flatpak-add-fedora-repos.service 2>/dev/null; ls /etc/polkit-1/rules.d/49-breadstick-flatpak.rules")
    check(f"flatpak: Get apps > Flatpak sets it up with Flathub alone ({DISTRO})",
          st == 0 and "Done." in o and "Flatpak " in o2 and o2.count("flathub") == 1 and "fedora" not in o2.replace("flatpak-add-fedora", "")
          and "\nactive" in o2 and "\nenabled" not in o2 and "49-breadstick-flatpak.rules" in o2,
          f"exit {st} in {time.time() - t0:.0f}s: {' | '.join(o.strip().splitlines()[-2:])} || {o2.strip()}".replace("\n", " | "))
    if st != 0:
        return
    o, st = run(setup + "\n")
    check("flatpak: a second run changes nothing and ends well", st == 0 and "Done." in o, f"exit {st}")

    # The Floating session, as the app starts it in the VM (bridges_test's line): its bus, its sound, its runtime folder.
    session = Chan("export BREADSTICK_WAYLAND=0 BREADSTICK_COMPOSITOR=0 BREADSTICK_DARK=0 BREADSTICK_LOCALE=en_US.UTF-8 "
                   "BREADSTICK_DPI=96 BREADSTICK_GPU=0; export BREADSTICK_VOLUMES=''; "
                   "F=/usr/lib/breadstick/start-desktop-x11.sh; sh \"$F\" 0 tester 1",
                   env=["DISPLAY=:0", "NO_AT_BRIDGE=1", "LIBGL_KOPPER_DISABLE=1", "BREADSTICK_ROOTLESS=1"])
    up = session.lines(90, lambda l: "rootless mode" in l)
    check("flatpak: session up (Floating)", any("rootless mode" in l for l in up), " | ".join(up[-4:]))
    time.sleep(3)

    # What the app gives a launch (VmCommands.displayEnv at 150% for "tester", scale-env.txt being its scale lines).
    env = ["DISPLAY=:0", "ADW_DISABLE_PORTAL=1", "PULSE_SERVER=unix:/tmp/runtime-tester/pulse/native", "NO_AT_BRIDGE=1",
           "QT_X11_NO_MITSHM=1", "LIBGL_KOPPER_DISABLE=1", "MESA_VK_WSI_DEBUG=noshm", "BREADSTICK_ROOTLESS=1"]
    env += [l for l in app_text("scale-env.txt").splitlines() if l]
    bslvm.simple(args, "f", b"/tmp/bsl-xres-144\x00" + b"644\x00" + app_text("xres-144.txt").encode())

    # The user installs, with no password and no root (the polkit rule): as from a Terminal tab.
    df0, _ = run("df -m --output=used / | tail -1")
    t0 = time.time()
    o, st = run(f"flatpak install -y --noninteractive flathub {APP} 2>&1 | tail -4", user="tester", env=env)
    o2, st2 = run(f"flatpak info {APP} >/dev/null 2>&1 && echo installed; flatpak list --app --columns=application,installation", user="tester")
    df1, _ = run("df -m --output=used / | tail -1")
    took = time.time() - t0
    check(f"flatpak: the user installs {APP} from Flathub (no root)", "installed" in o2 and "system" in o2,
          f"{took:.0f}s, {int(df1) - int(df0)} MiB on the disk: {o.strip()[-200:]} || {o2.strip()}".replace("\n", " | "))
    if "installed" not in o2:
        hangup(session)
        return

    # The Apps page: the session package's lister (the text the app feeds the VM) finds it, icon and all.
    line = ""
    for _ in range(20):
        o, _ = run("BREADSTICK_ROOTLESS=1 sh /usr/lib/breadstick/list-apps.sh", user="tester")
        line = next((l for l in o.splitlines() if l.split("\t")[3:4] == [APP + ".desktop"]), "")
        if line:
            break
        time.sleep(1)
    f = line.split("\t")
    icon = f[2] if len(f) > 2 else ""
    o, _ = run(f"[ -f '{icon}' ] && head -c 512 '{icon}' | grep -c -a -E 'svg|PNG'") if icon.startswith("/") else ("0", 1)
    check("flatpak: the app is in the Apps page's list with its launch line and an icon file",
          len(f) >= 4 and f[1].startswith("/usr/bin/flatpak run ") and APP in f[1] and icon.startswith("/var/lib/flatpak/exports/") and o.strip() not in ("", "0"),
          line.replace("\t", " | ")[:300])

    # Opened as the app opens it (flatpak-launch.sh = VmCommands.launch for `flatpak run <app>` at 150%).
    wins = "xwininfo -root -tree 2>/dev/null | grep -F '\"' | grep -v 'has no name'"
    o, _ = run(wins, user="tester", env=["DISPLAY=:0"])
    before = set(o.splitlines())
    launch = app_text("flatpak-launch.sh")
    if APP != "org.gnome.Calculator":
        launch = launch.replace("org.gnome.Calculator", APP)
    t0 = time.time()
    app = Chan(launch, user="tester", env=env)
    got = ""
    while time.time() - t0 < 90 and not got:
        time.sleep(0.5)
        o, _ = run(wins, user="tester", env=["DISPLAY=:0"])
        got = next((l.strip() for l in o.splitlines() if l not in before and WINDOW.lower() in l.lower() and " 1x1+" not in l), "")
    check(f"flatpak: {APP} opens a window on the display", bool(got), f"{time.time() - t0:.1f}s: {got[:160]}")
    time.sleep(3)
    o, _ = run("flatpak ps --columns=application,pid", user="tester", env=["XDG_RUNTIME_DIR=/tmp/runtime-tester"])
    pid = next((l.split()[1] for l in o.splitlines() if l.split()[:1] == [APP] and len(l.split()) > 1), "")
    # The sandbox as it was started: the scale's resource file inside it (root reads the sandbox's own /tmp).
    o, _ = run(f"for p in $(pgrep -P {pid} 2>/dev/null) {pid}; do cat /proc/$p/root/tmp/bsl-xres-144 2>/dev/null && break; done") if pid else ("", 1)
    check("flatpak: the running app's sandbox has the scale's resource file (150%)",
          "Xft.dpi: 144" in o.replace("\t", " ") or "Xft.dpi:144" in o.replace(" ", "").replace("\t", ""),
          o.strip().replace("\n", " | ")[:200] or f"no instance ({pid!r})")

    # The portals answer a sandbox started in the session's runtime folder, and refuse one in the agent's (the pair).
    sess = env + ["XDG_RUNTIME_DIR=/tmp/runtime-tester", "DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/runtime-tester/bus"]
    o, st = run(f"flatpak run --command=sh {APP} -c '{PORTAL}' 2>&1", user="tester", env=sess)
    check("flatpak: a portal answers the sandbox (the session's runtime folder)", "uint32" in o and "AccessDenied" not in o, o.strip()[:160])
    o, st = run(f"flatpak run --command=sh {APP} -c '{PORTAL}' 2>&1", user="tester", env=env + ["DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/runtime-tester/bus"])
    check("flatpak: with the agent's runtime folder the portal refuses (the check can fail)", "AccessDenied" in o, o.strip()[:160])
    o, st = run(f"flatpak run --socket=pulseaudio --command=pactl {APP} info 2>&1 | grep -E 'Server Name|Default Sink'", user="tester", env=sess)
    check("flatpak: the session's sound server from inside a sandbox", "pulseaudio" in o and "breadstick" in o, o.strip().replace("\n", " | "))

    run(f"flatpak kill {APP}", user="tester", env=sess)
    hangup(app)
    # Uninstalled: its entry leaves the Apps page's folder by itself (the path unit).
    o, st = run(f"flatpak uninstall -y --noninteractive {APP} 2>&1 | tail -1", user="tester", env=sess)
    left = "there"
    for _ in range(20):
        o2, _ = run(f"[ -e /usr/local/share/applications/{APP}.desktop ] && echo there || echo gone")
        left = o2.strip()
        if left == "gone":
            break
        time.sleep(1)
    check("flatpak: an uninstalled app leaves the Apps page", left == "gone", f"{o.strip()[-100:]} | {left}")
    hangup(session)
    time.sleep(2)
