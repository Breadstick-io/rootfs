/*
 * bsl-x11-relay: guest half of the W0 X11-over-vsock relay (branch vm-spike only).
 *
 * Only the host may open vsock channels (the app cannot listen on vsock), so the pairing works
 * like this:
 *   - The host keeps a small POOL of idle channels open to this relay's vsock port (6000). They
 *     carry nothing until they are used. Peers other than the host (CID 2) are refused.
 *   - X clients connect to /tmp/.X11-unix/X0 as usual (DISPLAY=:0). Each accepted client is
 *     paired with the oldest idle channel (a client waits when none is idle; the host tops the
 *     pool up as soon as it sees a channel carry data, because an X client always speaks first).
 *   - The pair is spliced both ways by two threads, bytes as they come (no framing). EOF is
 *     passed on with shutdown(SHUT_WR) (the guest may shut down; the host may not, so the host
 *     ends a channel by closing it); a write error shuts both sockets down.
 *   - An idle channel the host closes (relay stopped, VM stopping) is dropped.
 * No header: the design's {magic, version, pid, uid} first frame is left out of the spike.
 * MIT-SHM and DRI3 fds cannot cross: a byte relay drops SCM_RIGHTS.
 *
 *   bsl-x11-relay [vsock-port] [unix-path]      (defaults 6000, /tmp/.X11-unix/X0)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <linux/vm_sockets.h>

#define MAXQ 256
#define BUF (256 * 1024)

static int idle[MAXQ], nidle;       /* host channels waiting for a client, oldest first */
static int waiting[MAXQ], nwait;    /* X clients waiting for a channel, oldest first */
static unsigned long npairs;

static void qpush(int *q, int *n, int fd) { if (*n < MAXQ) q[(*n)++] = fd; else close(fd); }
static int qpop(int *q, int *n) { int fd = q[0]; memmove(q, q + 1, (size_t)(--*n) * sizeof *q); return fd; }
static void qdel(int *q, int *n, int i) { memmove(q + i, q + i + 1, (size_t)(*n - i - 1) * sizeof *q); (*n)--; }

struct dir { int from, to; unsigned long long bytes; };
struct pair { int x, v; unsigned long id; };

static void *copy(void *arg) {
    struct dir *d = arg;
    char *buf = malloc(BUF);
    for (;;) {
        ssize_t r = read(d->from, buf, BUF);
        if (r == 0) { shutdown(d->to, SHUT_WR); break; }
        if (r < 0) { if (errno == EINTR) continue; shutdown(d->to, SHUT_RDWR); shutdown(d->from, SHUT_RDWR); break; }
        ssize_t off = 0;
        while (off < r) {
            ssize_t w = write(d->to, buf + off, (size_t)(r - off));
            if (w < 0) { if (errno == EINTR) continue; goto fail; }
            off += w;
        }
        d->bytes += (unsigned long long)r;
    }
    free(buf);
    return NULL;
fail:
    shutdown(d->to, SHUT_RDWR);
    shutdown(d->from, SHUT_RDWR);
    free(buf);
    return NULL;
}

static void *run_pair(void *arg) {
    struct pair *p = arg;
    struct dir up = { p->x, p->v, 0 }, down = { p->v, p->x, 0 };
    pthread_t t;
    if (pthread_create(&t, NULL, copy, &down) != 0) { close(p->x); close(p->v); free(p); return NULL; }
    copy(&up);
    pthread_join(t, NULL);
    close(p->x);
    close(p->v);
    fprintf(stderr, "bsl-x11-relay: pair %lu done: client->host %llu B, host->client %llu B\n", p->id, up.bytes, down.bytes);
    free(p);
    return NULL;
}

static void start_pair(int x, int v) {
    struct pair *p = malloc(sizeof *p);
    p->x = x; p->v = v; p->id = ++npairs;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    pthread_t t;
    if (pthread_create(&t, &a, run_pair, p) != 0) { close(x); close(v); free(p); }
    pthread_attr_destroy(&a);
}

int main(int argc, char **argv) {
    unsigned port = argc > 1 ? (unsigned)atoi(argv[1]) : 6000;
    const char *path = argc > 2 ? argv[2] : "/tmp/.X11-unix/X0";
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stderr, NULL, _IOLBF, 0);

#ifdef TEST_HOST_PATH
    /* Off-device test build only: a unix socket stands in for the vsock listener. */
    int vs = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un ta;
    memset(&ta, 0, sizeof ta);
    ta.sun_family = AF_UNIX;
    snprintf(ta.sun_path, sizeof ta.sun_path, "%s", TEST_HOST_PATH);
    unlink(TEST_HOST_PATH);
    if (vs < 0 || bind(vs, (struct sockaddr *)&ta, sizeof ta) < 0 || listen(vs, 64) < 0) { perror("test listen"); return 1; }
#else
    int vs = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (vs < 0) { perror("bsl-x11-relay: socket(AF_VSOCK)"); return 1; }
    struct sockaddr_vm va;
    memset(&va, 0, sizeof va);
    va.svm_family = AF_VSOCK;
    va.svm_cid = VMADDR_CID_ANY;
    va.svm_port = port;
    if (bind(vs, (struct sockaddr *)&va, sizeof va) < 0 || listen(vs, 64) < 0) { perror("bsl-x11-relay: vsock bind/listen"); return 1; }
#endif

    char dir[sizeof ((struct sockaddr_un *)0)->sun_path];
    snprintf(dir, sizeof dir, "%s", path);
    char *slash = strrchr(dir, '/');
    if (slash && slash != dir) { *slash = 0; mkdir(dir, 01777); chmod(dir, 01777); }
    unlink(path);
    int us = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un ua;
    memset(&ua, 0, sizeof ua);
    ua.sun_family = AF_UNIX;
    snprintf(ua.sun_path, sizeof ua.sun_path, "%s", path);
    if (us < 0 || bind(us, (struct sockaddr *)&ua, sizeof ua) < 0 || listen(us, 64) < 0) { perror("bsl-x11-relay: unix bind/listen"); return 1; }
    chmod(path, 0777);
    fprintf(stderr, "bsl-x11-relay: vsock port %u <-> %s\n", port, path);

    for (;;) {
        struct pollfd pf[2 + 2 * MAXQ];
        int n = 0;
        pf[n++] = (struct pollfd){ .fd = vs, .events = POLLIN };
        pf[n++] = (struct pollfd){ .fd = us, .events = POLLIN };
        for (int i = 0; i < nidle; i++) pf[n++] = (struct pollfd){ .fd = idle[i], .events = POLLIN };
        for (int i = 0; i < nwait; i++) pf[n++] = (struct pollfd){ .fd = waiting[i], .events = 0 };
        if (poll(pf, (nfds_t)n, -1) < 0) { if (errno == EINTR) continue; perror("poll"); return 1; }

        int ni = nidle, nw = nwait;
        /* An idle channel that became readable was closed by the host (it never sends first). */
        for (int i = ni - 1; i >= 0; i--)
            if (pf[2 + i].revents) { close(idle[i]); qdel(idle, &nidle, i); }
        /* A waiting client that hung up is dropped. */
        for (int i = nw - 1; i >= 0; i--)
            if (pf[2 + ni + i].revents & (POLLHUP | POLLERR)) { close(waiting[i]); qdel(waiting, &nwait, i); }
        if (pf[0].revents & POLLIN) {
#ifdef TEST_HOST_PATH
            int c = accept4(vs, NULL, NULL, SOCK_CLOEXEC);
            if (c >= 0) qpush(idle, &nidle, c);
#else
            struct sockaddr_vm peer;
            socklen_t pl = sizeof peer;
            int c = accept4(vs, (struct sockaddr *)&peer, &pl, SOCK_CLOEXEC);
            if (c >= 0) {
                if (peer.svm_cid != VMADDR_CID_HOST) { fprintf(stderr, "bsl-x11-relay: refused cid %u\n", peer.svm_cid); close(c); }
                else qpush(idle, &nidle, c);
            }
#endif
        }
        if (pf[1].revents & POLLIN) {
            int c = accept4(us, NULL, NULL, SOCK_CLOEXEC);
            if (c >= 0) qpush(waiting, &nwait, c);
        }
        while (nidle > 0 && nwait > 0) start_pair(qpop(waiting, &nwait), qpop(idle, &nidle));
    }
}
