/*
 * bsl-vmnet: the guest half of networking through the app (protocol BSN1, vm/PROTOCOL.md).
 *
 * The VM has no network card. Its default route points at a dummy interface (bsl0), and an
 * nftables rule redirects every TCP connection routed there to this program on 127.0.0.1:15001
 * and [::1]:15001; SO_ORIGINAL_DST gives the address the program asked for. DNS goes to
 * 127.0.0.1:53 (resolv.conf), which this program also serves. Each connection and each query is
 * then carried to the APP over vsock, and the app opens the real socket, so Android's VPN, Data
 * Saver and per-app rules apply to the guest exactly as to the app.
 *
 * The app cannot listen on vsock, so it keeps a POOL of idle channels open to port 5100 (peers
 * other than the host, CID 2, are refused). A channel carries nothing until the guest uses it;
 * the guest speaks first:
 *     "BSN1" 'T' u8 family(4|6) addr[4|16] u16le port   -> host: u8 status (0 = connected),
 *                                                          then raw bytes both ways
 *     "BSN1" 'D' u16le len query[len]                   -> host: u16le len answer[len], closes
 * EOF from the program is passed on with shutdown(SHUT_WR); the host ends a channel by closing it.
 * UDP other than DNS, ICMP (ping) and inbound connections are not carried.
 *
 *   bsl-vmnet [vsock-port] [tcp-port] [dns-port]      (defaults 5100, 15001, 53)
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <linux/netfilter_ipv4.h>
#include <linux/vm_sockets.h>

#ifndef IP6T_SO_ORIGINAL_DST
#define IP6T_SO_ORIGINAL_DST 80
#endif
#define MAXQ 512
#define BUF (256 * 1024)

/* A request waiting for a host channel: a TCP client with its destination, or a DNS query. */
struct job {
    int kind;                    /* 'T' or 'D' */
    int fd;                      /* TCP client */
    unsigned char hdr[32];       /* the BSN1 header for 'T' */
    size_t hlen;
    unsigned char *q;            /* DNS query */
    size_t qlen;
    struct sockaddr_storage from; /* DNS client */
    socklen_t fromlen;
    int ch;                      /* the host channel, once paired */
};

static int idle[MAXQ], nidle;
static struct job *waiting[MAXQ];
static int nwait;
static int dns_fd = -1;

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

static void free_job(struct job *j) {
    if (j->kind == 'T' && j->fd >= 0) close(j->fd);
    if (j->ch >= 0) close(j->ch);
    free(j->q);
    free(j);
}

struct dir { int from, to; };

static void *copy(void *arg) {
    struct dir *d = arg;
    char *buf = malloc(BUF);
    for (;;) {
        ssize_t r = read(d->from, buf, BUF);
        if (r == 0) { shutdown(d->to, SHUT_WR); break; }
        if (r < 0) { if (errno == EINTR) continue; shutdown(d->to, SHUT_RDWR); shutdown(d->from, SHUT_RDWR); break; }
        if (writen(d->to, buf, (size_t)r) < 0) { shutdown(d->to, SHUT_RDWR); shutdown(d->from, SHUT_RDWR); break; }
    }
    free(buf);
    return NULL;
}

static void *serve_job(void *arg) {
    struct job *j = arg;
    if (j->kind == 'T') {
        unsigned char st = 0xff;
        if (writen(j->ch, j->hdr, j->hlen) < 0 || readn(j->ch, &st, 1) < 0 || st != 0) {
            /* Refused or unreachable: reset the program's connection so it sees an error at once. */
            struct linger lg = { 1, 0 };
            setsockopt(j->fd, SOL_SOCKET, SO_LINGER, &lg, sizeof lg);
            free_job(j);
            return NULL;
        }
        struct dir up = { j->fd, j->ch }, down = { j->ch, j->fd };
        pthread_t t;
        if (pthread_create(&t, NULL, copy, &down) == 0) {
            copy(&up);
            pthread_join(t, NULL);
        }
        free_job(j);
    } else {
        unsigned char h[7] = { 'B', 'S', 'N', '1', 'D', (unsigned char)j->qlen, (unsigned char)(j->qlen >> 8) };
        unsigned char lb[2];
        if (writen(j->ch, h, 7) == 0 && writen(j->ch, j->q, j->qlen) == 0 && readn(j->ch, lb, 2) == 0) {
            size_t n = lb[0] | (size_t)lb[1] << 8;
            unsigned char *a = malloc(n ? n : 1);
            if (a && n && readn(j->ch, a, n) == 0)
                sendto(dns_fd, a, n, 0, (struct sockaddr *)&j->from, j->fromlen);
            free(a);
        }
        free_job(j);
    }
    return NULL;
}

static void start_job(struct job *j, int ch) {
    j->ch = ch;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&a, 256 * 1024);
    pthread_t t;
    if (pthread_create(&t, &a, serve_job, j) != 0) free_job(j);
    pthread_attr_destroy(&a);
}

static void enqueue(struct job *j) {
    if (nwait < MAXQ) waiting[nwait++] = j;
    else free_job(j);
}

static int listen_tcp(int fam, unsigned port) {
    int s = socket(fam, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (s < 0) return -1;
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    int r;
    if (fam == AF_INET) {
        struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
        r = bind(s, (struct sockaddr *)&a, sizeof a);
    } else {
        setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one);
        struct sockaddr_in6 a = { .sin6_family = AF_INET6, .sin6_port = htons(port), .sin6_addr = IN6ADDR_LOOPBACK_INIT };
        r = bind(s, (struct sockaddr *)&a, sizeof a);
    }
    if (r < 0 || listen(s, 128) < 0) { close(s); return -1; }
    return s;
}

/* Accept one redirected connection and build its 'T' job (its original destination). */
static struct job *accept_tcp(int ls, int fam) {
    int c = accept4(ls, NULL, NULL, SOCK_CLOEXEC);
    if (c < 0) return NULL;
    struct job *j = calloc(1, sizeof *j);
    j->kind = 'T'; j->fd = c; j->ch = -1;
    memcpy(j->hdr, "BSN1T", 5);
    if (fam == AF_INET) {
        struct sockaddr_in o;
        socklen_t ol = sizeof o;
        if (getsockopt(c, SOL_IP, SO_ORIGINAL_DST, &o, &ol) < 0) { free_job(j); return NULL; }
        j->hdr[5] = 4;
        memcpy(j->hdr + 6, &o.sin_addr, 4);
        uint16_t p = ntohs(o.sin_port);
        j->hdr[10] = (unsigned char)p; j->hdr[11] = (unsigned char)(p >> 8);
        j->hlen = 12;
    } else {
        struct sockaddr_in6 o;
        socklen_t ol = sizeof o;
        if (getsockopt(c, SOL_IPV6, IP6T_SO_ORIGINAL_DST, &o, &ol) < 0) { free_job(j); return NULL; }
        j->hdr[5] = 6;
        memcpy(j->hdr + 6, &o.sin6_addr, 16);
        uint16_t p = ntohs(o.sin6_port);
        j->hdr[22] = (unsigned char)p; j->hdr[23] = (unsigned char)(p >> 8);
        j->hlen = 24;
    }
    return j;
}

int main(int argc, char **argv) {
    unsigned vport = argc > 1 ? (unsigned)atoi(argv[1]) : 5100;
    unsigned tport = argc > 2 ? (unsigned)atoi(argv[2]) : 15001;
    unsigned dport = argc > 3 ? (unsigned)atoi(argv[3]) : 53;
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stderr, NULL, _IOLBF, 0);

    int vs = -1;
    for (int tries = 0;; tries++) {
        vs = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (vs >= 0) {
            struct sockaddr_vm va = { .svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_ANY, .svm_port = vport };
            if (bind(vs, (struct sockaddr *)&va, sizeof va) == 0 && listen(vs, 128) == 0) break;
            close(vs);
        }
        if (tries > 600) { perror("bsl-vmnet: vsock"); return 1; }
        usleep(100 * 1000);
    }
    int t4 = listen_tcp(AF_INET, tport), t6 = listen_tcp(AF_INET6, tport);
    if (t4 < 0) { perror("bsl-vmnet: tcp listen"); return 1; }
    dns_fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    struct sockaddr_in da = { .sin_family = AF_INET, .sin_port = htons(dport), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (dns_fd < 0 || bind(dns_fd, (struct sockaddr *)&da, sizeof da) < 0) { perror("bsl-vmnet: dns bind"); return 1; }
    fprintf(stderr, "bsl-vmnet: vsock %u, tcp 127.0.0.1/::1:%u, dns 127.0.0.1:%u\n", vport, tport, dport);

    for (;;) {
        struct pollfd pf[4 + MAXQ];
        int n = 0;
        pf[n++] = (struct pollfd){ .fd = vs, .events = POLLIN };
        pf[n++] = (struct pollfd){ .fd = t4, .events = POLLIN };
        pf[n++] = (struct pollfd){ .fd = t6, .events = t6 >= 0 ? POLLIN : 0 };
        pf[n++] = (struct pollfd){ .fd = dns_fd, .events = POLLIN };
        for (int i = 0; i < nidle; i++) pf[n++] = (struct pollfd){ .fd = idle[i], .events = POLLIN };
        if (poll(pf, (nfds_t)n, -1) < 0) { if (errno == EINTR) continue; perror("poll"); return 1; }

        /* An idle channel that became readable was closed by the host (it never sends first). */
        int ni = nidle;
        for (int i = ni - 1; i >= 0; i--)
            if (pf[4 + i].revents) {
                close(idle[i]);
                memmove(idle + i, idle + i + 1, (size_t)(nidle - i - 1) * sizeof *idle);
                nidle--;
            }
        if (pf[0].revents & POLLIN) {
            struct sockaddr_vm peer;
            socklen_t pl = sizeof peer;
            int c = accept4(vs, (struct sockaddr *)&peer, &pl, SOCK_CLOEXEC);
            if (c >= 0) {
                if (peer.svm_cid != VMADDR_CID_HOST || nidle >= MAXQ) close(c);
                else idle[nidle++] = c;
            }
        }
        if (pf[1].revents & POLLIN) { struct job *j = accept_tcp(t4, AF_INET); if (j) enqueue(j); }
        if (t6 >= 0 && (pf[2].revents & POLLIN)) { struct job *j = accept_tcp(t6, AF_INET6); if (j) enqueue(j); }
        if (pf[3].revents & POLLIN) {
            unsigned char q[4096];
            struct job *j = calloc(1, sizeof *j);
            j->fromlen = sizeof j->from;
            ssize_t k = recvfrom(dns_fd, q, sizeof q, 0, (struct sockaddr *)&j->from, &j->fromlen);
            if (k > 0) {
                j->kind = 'D'; j->fd = -1; j->ch = -1;
                j->q = malloc((size_t)k); memcpy(j->q, q, (size_t)k); j->qlen = (size_t)k;
                enqueue(j);
            } else {
                free(j);
            }
        }
        while (nidle > 0 && nwait > 0) {
            struct job *j = waiting[0];
            memmove(waiting, waiting + 1, (size_t)(--nwait) * sizeof *waiting);
            int ch = idle[0];
            memmove(idle, idle + 1, (size_t)(--nidle) * sizeof *idle);
            start_job(j, ch);
        }
    }
}
