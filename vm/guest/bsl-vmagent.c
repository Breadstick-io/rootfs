/*
 * bsl-vmagent: the Breadstick VM guest agent (protocol BSA1, vm/PROTOCOL.md).
 *
 * Listens on AF_VSOCK port 5000 (or argv[1]) and serves the HOST only (peer CID 2): CID 1 is the
 * guest's own loopback, and serving it would give any guest process root exec. The app's vsock
 * fds allow only read, write, getattr and getopt (no shutdown(), no FIONREAD), so every message
 * is framed and the guest closes a channel when it is done.
 *
 * One process per connection (fork). A request is
 *     "BSA1" u8 op, u32le len, payload[len]
 * and every reply is a run of frames
 *     u8 type, u32le len, data[len]
 * ending with an 'x' frame (i32le status) after which the guest closes. Ops:
 *     p  ping        -> o "PONG <uptime> <agent version>\n", x 0
 *     i  info        -> o "key=value\n"..., x 0
 *     t  set time    payload u64le Unix ms -> x 0 | errno
 *     f  write file  payload path \0 octal mode \0 data -> x 0 | errno (atomic: tmp + rename)
 *     o  power       payload "poweroff" | "reboot" -> x 0, then systemd is asked
 *     r  run         payload "key=value\n"... "\n" command; then frames both ways:
 *                      host -> guest: d stdin data, e stdin EOF, w u16le cols u16le rows, k u8 signal
 *                      guest -> host: o output (stdout and stderr merged, or the pty), x status
 *                    keys: user=<name> (default root), pty=1, cols=, rows=, cwd=, env=K=V (repeat),
 *                    term=. An empty command with pty=1 is the user's login shell.
 *                    The host closing the channel before the command ends hangs it up: SIGHUP to
 *                    its process group, SIGKILL 2 s later.
 * Users are read from /etc/passwd and /etc/group directly (fgetpwent/fgetgrent), not through NSS.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <poll.h>
#include <pty.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <linux/vm_sockets.h>

#define AGENT_VERSION "1"
#define MAX_PAYLOAD (1u << 20)
#define MAX_PENDING (256 * 1024)

static int readn(int fd, void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, (char *)buf + got, n - got);
        if (r == 0) return -1;
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        got += (size_t)r;
    }
    return 0;
}

static int writen(int fd, const void *buf, size_t n) {
    size_t put = 0;
    while (put < n) {
        ssize_t w = write(fd, (const char *)buf + put, n - put);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        put += (size_t)w;
    }
    return 0;
}

static void le32(unsigned char *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static uint32_t rd32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

static int frame(int fd, char type, const void *data, uint32_t len) {
    unsigned char h[5];
    h[0] = (unsigned char)type;
    le32(h + 1, len);
    if (writen(fd, h, 5) < 0) return -1;
    return len ? writen(fd, data, len) : 0;
}

static int status_frame(int fd, int32_t st) {
    unsigned char b[4];
    le32(b, (uint32_t)st);
    return frame(fd, 'x', b, 4);
}

static int textf(int fd, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static int textf(int fd, const char *fmt, ...) {
    char buf[4096];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0) return -1;
    if ((size_t)n >= sizeof buf) n = sizeof buf - 1;
    return frame(fd, 'o', buf, (uint32_t)n);
}

/* ------------------------------------------------------------------------------------ users */

struct user { int found; uid_t uid; gid_t gid; char name[64], home[256], shell[128]; };

static void lookup_user(const char *name, struct user *u) {
    memset(u, 0, sizeof *u);
    FILE *f = fopen("/etc/passwd", "re");
    if (!f) return;
    struct passwd *pw;
    while ((pw = fgetpwent(f))) {
        if (strcmp(pw->pw_name, name) == 0) {
            u->found = 1; u->uid = pw->pw_uid; u->gid = pw->pw_gid;
            snprintf(u->name, sizeof u->name, "%s", pw->pw_name);
            snprintf(u->home, sizeof u->home, "%s", pw->pw_dir && *pw->pw_dir ? pw->pw_dir : "/");
            snprintf(u->shell, sizeof u->shell, "%s", pw->pw_shell && *pw->pw_shell ? pw->pw_shell : "/bin/sh");
            break;
        }
    }
    fclose(f);
}

/* The user's supplementary groups from /etc/group, then setgid/setuid. -1 on any failure. */
static int become(const struct user *u) {
    gid_t groups[256];
    int n = 0;
    groups[n++] = u->gid;
    FILE *f = fopen("/etc/group", "re");
    if (f) {
        struct group *g;
        while ((g = fgetgrent(f)) && n < 256) {
            for (char **m = g->gr_mem; m && *m; m++)
                if (strcmp(*m, u->name) == 0 && g->gr_gid != u->gid) { groups[n++] = g->gr_gid; break; }
        }
        fclose(f);
    }
    if (setgroups((size_t)n, groups) < 0) return -1;
    if (setgid(u->gid) < 0) return -1;
    if (setuid(u->uid) < 0) return -1;
    return 0;
}

/* ----------------------------------------------------------------------------- run request */

struct req {
    char user[64];
    int pty;
    unsigned short cols, rows;
    char cwd[512];
    char term[64];
    char *env[128];
    int nenv;
    char *cmd;
};

static int parse_run(char *p, uint32_t len, struct req *r) {
    memset(r, 0, sizeof *r);
    snprintf(r->user, sizeof r->user, "root");
    r->cols = 80; r->rows = 24;
    snprintf(r->term, sizeof r->term, "xterm-256color");
    char *end = p + len;
    for (;;) {
        char *nl = memchr(p, '\n', (size_t)(end - p));
        if (!nl) return -1;
        *nl = 0;
        if (nl == p) { p = nl + 1; break; }
        char *eq = strchr(p, '=');
        if (eq) {
            *eq = 0;
            const char *k = p, *v = eq + 1;
            if (!strcmp(k, "user")) snprintf(r->user, sizeof r->user, "%s", v);
            else if (!strcmp(k, "pty")) r->pty = atoi(v) != 0;
            else if (!strcmp(k, "cols")) r->cols = (unsigned short)atoi(v);
            else if (!strcmp(k, "rows")) r->rows = (unsigned short)atoi(v);
            else if (!strcmp(k, "cwd")) snprintf(r->cwd, sizeof r->cwd, "%s", v);
            else if (!strcmp(k, "term")) snprintf(r->term, sizeof r->term, "%s", v);
            else if (!strcmp(k, "env") && r->nenv < 127 && strchr(v, '=')) r->env[r->nenv++] = eq + 1;
        }
        p = nl + 1;
    }
    size_t clen = (size_t)(end - p);
    r->cmd = malloc(clen + 1);
    if (!r->cmd) return -1;
    memcpy(r->cmd, p, clen);
    r->cmd[clen] = 0;
    return 0;
}

static int sigpipe_fds[2] = { -1, -1 };
static void on_sigchld(int s) { (void)s; int e = errno; if (write(sigpipe_fds[1], "c", 1) < 0) {} errno = e; }

static void child_exec(const struct req *r, const struct user *u) {
    /* The agent runs with OOMScoreAdjust=-1000 (it must outlive any program that runs Linux out of
     * memory), and oom_score_adj is inherited: put programs back to the ordinary 0, or nothing the
     * app launched could ever be chosen and an out-of-memory would hang the whole VM. Before the
     * user switch: raising it back needs no privilege, but do it while still root anyway. */
    int oom = open("/proc/self/oom_score_adj", O_WRONLY | O_CLOEXEC);
    if (oom >= 0) { if (write(oom, "0", 1) < 0) { /* best effort */ } close(oom); }
    for (int s = 1; s < NSIG; s++) signal(s, SIG_DFL);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    if (u->uid != 0 && u->uid != getuid() && become(u) < 0) { perror("bsl-vmagent: cannot switch user"); _exit(126); }
    clearenv();
    setenv("PATH", u->uid == 0 ? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                               : "/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games", 1);
    setenv("HOME", u->home, 1);
    setenv("USER", u->name, 1);
    setenv("LOGNAME", u->name, 1);
    setenv("SHELL", u->shell, 1);
    setenv("LANG", "C.UTF-8", 1);
    if (r->pty) setenv("TERM", r->term, 1);
    char rt[64], bus[96];
    snprintf(rt, sizeof rt, "/run/user/%u", (unsigned)u->uid);
    struct stat st;
    if (stat(rt, &st) == 0 && st.st_uid == u->uid) {
        setenv("XDG_RUNTIME_DIR", rt, 1);
        snprintf(bus, sizeof bus, "%s/bus", rt);
        if (stat(bus, &st) == 0) {
            char addr[128];
            snprintf(addr, sizeof addr, "unix:path=%s", bus);
            setenv("DBUS_SESSION_BUS_ADDRESS", addr, 1);
        }
    }
    for (int i = 0; i < r->nenv; i++) putenv(r->env[i]);
    if (chdir(*r->cwd ? r->cwd : u->home) < 0 && chdir("/") < 0) {}
    if (!*r->cmd && r->pty) {
        const char *base = strrchr(u->shell, '/');
        char argv0[160];
        snprintf(argv0, sizeof argv0, "-%s", base ? base + 1 : u->shell);
        execl(u->shell, argv0, (char *)NULL);
        execl("/bin/sh", "-sh", (char *)NULL);
    } else {
        execl("/bin/sh", "sh", "-c", r->cmd, (char *)NULL);
    }
    perror("bsl-vmagent: exec");
    _exit(127);
}

static void run(int c, char *payload, uint32_t len) {
    struct req r;
    if (parse_run(payload, len, &r) < 0) { textf(c, "bad run request\n"); status_frame(c, 125); return; }
    struct user u;
    lookup_user(r.user, &u);
    if (!u.found) { textf(c, "bsl-vmagent: no user %s\n", r.user); status_frame(c, 125); return; }

    if (pipe2(sigpipe_fds, O_CLOEXEC | O_NONBLOCK) < 0) { status_frame(c, 125); return; }
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sigchld;
    sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
    sigaction(SIGCHLD, &sa, NULL);

    int infd = -1, outfd = -1;
    pid_t pid;
    if (r.pty) {
        int m, s;
        struct winsize ws = { .ws_row = r.rows ? r.rows : 24, .ws_col = r.cols ? r.cols : 80 };
        if (openpty(&m, &s, NULL, NULL, &ws) < 0) { textf(c, "openpty: %s\n", strerror(errno)); status_frame(c, 125); return; }
        pid = fork();
        if (pid == 0) {
            close(c); close(m);
            setsid();
            ioctl(s, TIOCSCTTY, 0);
            dup2(s, 0); dup2(s, 1); dup2(s, 2);
            if (s > 2) close(s);
            child_exec(&r, &u);
        }
        close(s);
        infd = outfd = m;
    } else {
        int in[2], out[2];
        if (pipe2(in, O_CLOEXEC) < 0 || pipe2(out, O_CLOEXEC) < 0) { status_frame(c, 125); return; }
        pid = fork();
        if (pid == 0) {
            close(c);
            setsid();
            dup2(in[0], 0); dup2(out[1], 1); dup2(out[1], 2);
            child_exec(&r, &u);
        }
        close(in[0]); close(out[1]);
        infd = in[1]; outfd = out[0];
    }
    if (pid < 0) { status_frame(c, 125); return; }
    fcntl(infd, F_SETFL, fcntl(infd, F_GETFL) | O_NONBLOCK);
    fcntl(outfd, F_SETFL, fcntl(outfd, F_GETFL) | O_NONBLOCK);

    char *pend = malloc(MAX_PENDING);
    size_t npend = 0;
    int in_open = 1, out_open = 1, exited = 0, status = 0, host_gone = 0, eof_after_pending = 0, drain_rounds = 0;
    char buf[65536];
    while (!exited || out_open) {
        struct pollfd pf[4];
        int n = 0, ic = -1, io = -1, ii = -1, is = -1;
        if (!host_gone && npend < MAX_PENDING - 65536) { ic = n; pf[n++] = (struct pollfd){ .fd = c, .events = POLLIN }; }
        if (out_open) { io = n; pf[n++] = (struct pollfd){ .fd = outfd, .events = POLLIN }; }
        if (in_open && npend) { ii = n; pf[n++] = (struct pollfd){ .fd = infd, .events = POLLOUT }; }
        is = n; pf[n++] = (struct pollfd){ .fd = sigpipe_fds[0], .events = POLLIN };
        /* After the command ended, only drain what is already buffered. */
        int timeout = exited ? 50 : -1;
        int pr = poll(pf, (nfds_t)n, timeout);
        if (pr < 0) { if (errno == EINTR) continue; break; }
        if (pr == 0 && exited) break;
        if (pf[is].revents) {
            char t[64];
            while (read(sigpipe_fds[0], t, sizeof t) > 0) {}
            int st;
            pid_t w;
            while ((w = waitpid(-1, &st, WNOHANG)) > 0)
                if (w == pid) { exited = 1; status = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st); }
        }
        if (io >= 0 && pf[io].revents) {
            ssize_t k = read(outfd, buf, sizeof buf);
            if (k > 0) { if (frame(c, 'o', buf, (uint32_t)k) < 0) host_gone = 1; }
            else if (k == 0 || (errno != EAGAIN && errno != EINTR)) out_open = 0; /* EIO: pty closed */
        }
        if (ii >= 0 && (pf[ii].revents & (POLLOUT | POLLERR | POLLHUP))) {
            ssize_t k = write(infd, pend, npend);
            if (k > 0) { memmove(pend, pend + k, npend - (size_t)k); npend -= (size_t)k; }
            else if (k < 0 && errno != EAGAIN && errno != EINTR) { in_open = 0; npend = 0; }
            if (!npend && eof_after_pending && !r.pty) { close(infd); in_open = 0; }
        }
        if (ic >= 0 && pf[ic].revents) {
            unsigned char h[5];
            if (readn(c, h, 5) < 0) { host_gone = 1; }
            else {
                uint32_t fl = rd32(h + 1);
                if (fl > 65536) { host_gone = 1; }
                else if (readn(c, buf, fl) < 0) { host_gone = 1; }
                else if (h[0] == 'd') {
                    if (in_open && npend + fl <= MAX_PENDING) { memcpy(pend + npend, buf, fl); npend += fl; }
                } else if (h[0] == 'e') {
                    if (r.pty) { if (in_open && npend < MAX_PENDING) pend[npend++] = 4; }
                    else if (npend) eof_after_pending = 1;
                    else if (in_open) { close(infd); in_open = 0; }
                } else if (h[0] == 'w' && fl >= 4 && r.pty) {
                    struct winsize ws = { .ws_col = (unsigned short)((buf[0] & 0xff) | (buf[1] & 0xff) << 8),
                                          .ws_row = (unsigned short)((buf[2] & 0xff) | (buf[3] & 0xff) << 8) };
                    ioctl(outfd, TIOCSWINSZ, &ws); /* the kernel sends SIGWINCH to the foreground group */
                } else if (h[0] == 'k' && fl >= 1) {
                    kill(-pid, (unsigned char)buf[0]);
                }
            }
        }
        if (host_gone) break;
        if (exited && ++drain_rounds > 10) break; /* background jobs may keep a pty busy */
    }
    free(pend);
    if (host_gone && !exited) {
        /* The host hung up: so does the command, then it is killed. */
        kill(-pid, SIGHUP);
        kill(-pid, SIGCONT);
        for (int i = 0; i < 20 && !exited; i++) {
            int st;
            if (waitpid(pid, &st, WNOHANG) == pid) exited = 1;
            else usleep(100 * 1000);
        }
        if (!exited) { kill(-pid, SIGKILL); waitpid(pid, NULL, 0); }
        return;
    }
    if (!host_gone) status_frame(c, status);
}

/* ------------------------------------------------------------------------------- other ops */

static void write_file(int c, char *p, uint32_t len) {
    char *end = p + len;
    char *path = p;
    char *z = memchr(path, 0, (size_t)(end - path));
    if (!z || path[0] != '/') { status_frame(c, EINVAL); return; }
    char *mode_s = z + 1;
    char *z2 = memchr(mode_s, 0, (size_t)(end - mode_s));
    if (!z2) { status_frame(c, EINVAL); return; }
    char *data = z2 + 1;
    mode_t mode = (mode_t)strtoul(mode_s, NULL, 8);
    char tmp[4200];
    snprintf(tmp, sizeof tmp, "%s.bsl-tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, mode ? mode : 0644);
    if (fd < 0) { status_frame(c, errno); return; }
    int e = 0;
    if (writen(fd, data, (size_t)(end - data)) < 0) e = errno;
    if (!e && fchmod(fd, mode ? mode : 0644) < 0) e = errno;
    close(fd);
    if (!e && rename(tmp, path) < 0) e = errno;
    if (e) unlink(tmp);
    status_frame(c, e);
}

static void set_time(int c, const unsigned char *p, uint32_t len) {
    if (len < 8) { status_frame(c, EINVAL); return; }
    uint64_t ms = 0;
    for (int i = 7; i >= 0; i--) ms = ms << 8 | p[i];
    struct timespec ts = { .tv_sec = (time_t)(ms / 1000), .tv_nsec = (long)(ms % 1000) * 1000000L };
    status_frame(c, clock_settime(CLOCK_REALTIME, &ts) < 0 ? errno : 0);
}

static void info(int c) {
    struct utsname un;
    uname(&un);
    char up[64] = "?";
    FILE *f = fopen("/proc/uptime", "re");
    if (f) { if (!fgets(up, sizeof up, f)) strcpy(up, "?"); fclose(f); up[strcspn(up, " \n")] = 0; }
    char osr[128] = "";
    f = fopen("/etc/debian_version", "re");
    if (f) { if (!fgets(osr, sizeof osr, f)) osr[0] = 0; fclose(f); osr[strcspn(osr, "\n")] = 0; }
    textf(c, "agent=%s\nkernel=%s\nmachine=%s\nhostname=%s\nuptime=%s\ndebian=%s\nsystemd=%d\n",
          AGENT_VERSION, un.release, un.machine, un.nodename, up, osr, access("/run/systemd/system", F_OK) == 0);
    status_frame(c, 0);
}

static void power(int c, const char *what) {
    int rb = strcmp(what, "reboot") == 0;
    status_frame(c, 0);
    close(c);
    sync();
    if (access("/run/systemd/system", F_OK) == 0) {
        execl("/bin/systemctl", "systemctl", rb ? "reboot" : "poweroff", (char *)NULL);
    }
    reboot(rb ? RB_AUTOBOOT : RB_POWER_OFF);
    _exit(0);
}

static void serve(int c) {
    unsigned char h[9];
    if (readn(c, h, 9) < 0 || memcmp(h, "BSA1", 4) != 0) return;
    uint32_t len = rd32(h + 5);
    if (len > MAX_PAYLOAD) return;
    char *p = malloc(len + 1);
    if (!p || (len && readn(c, p, len) < 0)) return;
    p[len] = 0;
    switch (h[4]) {
    case 'p': {
        char up[64] = "?";
        FILE *f = fopen("/proc/uptime", "re");
        if (f) { if (!fgets(up, sizeof up, f)) strcpy(up, "?"); fclose(f); up[strcspn(up, " \n")] = 0; }
        textf(c, "PONG %s %s\n", up, AGENT_VERSION);
        status_frame(c, 0);
        break;
    }
    case 'i': info(c); break;
    case 't': set_time(c, (unsigned char *)p, len); break;
    case 'f': write_file(c, p, len); break;
    case 'o': power(c, p); break;
    case 'r': run(c, p, len); break;
    default: status_frame(c, 125); break;
    }
}

int main(int argc, char **argv) {
    unsigned port = argc > 1 ? (unsigned)atoi(argv[1]) : 5000;
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN); /* connection handlers are reaped by the kernel */
    setvbuf(stderr, NULL, _IOLBF, 0);
    int s = -1;
#ifdef TEST_HOST_PATH
    s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un ta = { .sun_family = AF_UNIX };
    snprintf(ta.sun_path, sizeof ta.sun_path, "%s", TEST_HOST_PATH);
    unlink(TEST_HOST_PATH);
    if (bind(s, (struct sockaddr *)&ta, sizeof ta) < 0 || listen(s, 16) < 0) { perror("test listen"); return 1; }
#else
    /* The vsock transport can be a module that udev loads a moment after this starts. */
    for (int tries = 0;; tries++) {
        s = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (s >= 0) {
            struct sockaddr_vm a = { .svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_ANY, .svm_port = port };
            if (bind(s, (struct sockaddr *)&a, sizeof a) == 0 && listen(s, 16) == 0) break;
            close(s);
        }
        if (tries == 0) perror("bsl-vmagent: vsock not ready, retrying");
        if (tries > 600) return 1;
        usleep(100 * 1000);
    }
#endif
    fprintf(stderr, "bsl-vmagent %s: listening on vsock port %u\n", AGENT_VERSION, port);
    for (;;) {
#ifdef TEST_HOST_PATH
        int c = accept4(s, NULL, NULL, SOCK_CLOEXEC);
        if (c < 0) { if (errno == EINTR) continue; sleep(1); continue; }
#else
        struct sockaddr_vm peer;
        socklen_t pl = sizeof peer;
        int c = accept4(s, (struct sockaddr *)&peer, &pl, SOCK_CLOEXEC);
        if (c < 0) { if (errno == EINTR) continue; perror("bsl-vmagent: accept"); sleep(1); continue; }
        if (peer.svm_cid != VMADDR_CID_HOST) {
            fprintf(stderr, "bsl-vmagent: refused peer cid %u\n", peer.svm_cid);
            close(c);
            continue;
        }
#endif
        pid_t p = fork();
        if (p == 0) {
            close(s);
            signal(SIGCHLD, SIG_DFL);
            serve(c);
            _exit(0);
        }
        close(c);
    }
}
