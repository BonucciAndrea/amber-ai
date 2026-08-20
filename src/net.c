/* net.c  -  amber-ai 2.0.0 zero-dependency POSIX HTTP bridge.  See net.h.
 *
 * Everything here is plain C99 + POSIX.  The feature-test macro below is what
 * makes `cc -std=c99 -c src/net.c` see poll(2), getaddrinfo(3) and fcntl(2):
 * with -std=c99 alone glibc hides every POSIX-only declaration.
 *
 * Amber - GNU AGPLv3 - see LICENSE and NOTICE.
 */
#if !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif
#if !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE 1
#endif

#include "net.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The wasm build has no sockets at all (src/0.c stubs connect()/socket() to
 * -1), so the whole transport compiles out to "no backend here". Everything
 * above the transport -- lib/ai.k, the `\ai` parser, the memory file -- keeps
 * working and simply reports that the endpoint is unreachable. */
#if defined(wasm)

void am_net_init(void) {}
const char *am_net_url(void)   { return "http://127.0.0.1:11434/api/generate"; }
const char *am_net_model(void) { return "qwen2.5-coder:0.5b"; }
int  am_net_qa_ms(void)  { return 10000; }
int  am_net_tab_ms(void) { return 100; }
int  am_net_on(void)     { return 0; }
int  am_net_tab_on(void) { return 0; }
void am_net_set_on(int on)     { (void)on; }
int  am_net_set_url(const char *u)   { (void)u; return AMNET_EURL; }
int  am_net_set_model(const char *m) { (void)m; return AMNET_EARG; }
void am_net_set_qa_ms(int ms)  { (void)ms; }
void am_net_set_tab_ms(int ms) { (void)ms; }
void am_net_set_tab_on(int on) { (void)on; }
int  am_net_last_ms(void) { return 0; }
void am_net_clear_backoff(void) {}
long long am_net_now_ms(void) { return 0; }
int am_net_post(const char *u, const char *b, int t, char **o, size_t *n) {
    (void)u; (void)b; (void)t; if (o) *o = NULL; if (n) *n = 0; return AMNET_ECONN;
}
int am_net_generate(const char *s, const char *u, int t, int m, char **o, size_t *n) {
    (void)s; (void)u; (void)t; (void)m; if (o) *o = NULL; if (n) *n = 0; return AMNET_ECONN;
}

#else /* ---------------------------- native ------------------------------- */

#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/time.h>

#define AM_URL_MAX   512
#define AM_MODEL_MAX 128
#define AM_HOST_MAX  256
#define AM_PATH_MAX  256
/* Hard ceiling on a response body. A local model that streams megabytes back
 * is a misconfiguration, not something the REPL should try to absorb. */
#define AM_BODY_MAX  (1u << 20)

static int parse_url(const char *url, char *host, size_t hostcap,
                     char *port, size_t portcap, char *path, size_t pathcap);

/* ---- configuration ------------------------------------------------------- */

static int  g_init;
static char g_url[AM_URL_MAX]     = "http://127.0.0.1:11434/api/generate";
static char g_model[AM_MODEL_MAX] = "qwen2.5-coder:0.5b";
static int  g_on     = 1;   /* AI agent master switch: DEFAULT ON            */
static int  g_tab_on = 1;   /* AI Tab completion:      DEFAULT ON            */
static int  g_qa_ms  = 10000;  /* answer budget, ms -- see am_net_init */
static int  g_tab_ms = 100;
/* Generation bounds. Absent from the payload until now, which is what made a
 * local model feel slow: with no num_predict the server generates until it
 * decides to stop, and with no num_ctx it allocates its default KV cache
 * (2048+) however short the prompt actually is. Neither is a property of the
 * prompt, so no amount of prompt trimming could reach them. */
static int  g_num_ctx     = 512;
static int  g_num_predict = 128;
/* How long the backend should keep the model resident after a request.
 * Ollama unloads after 5 minutes idle by default, so on a 7B every question
 * asked more than five minutes after the last one pays the load again --
 * tens of seconds on CPU, inside the same deadline that has to cover the
 * generation. Sent per REQUEST, so it needs no OLLAMA_KEEP_ALIVE in the
 * server's environment and no restart of `ollama serve`. */
static char g_keep_alive[32] = "30m";
static int  g_last_ms;
static long long g_dead_until;   /* circuit breaker deadline (ms)            */

long long am_net_now_ms(void) {
    struct timeval tv;
    if (gettimeofday(&tv, NULL) != 0) return 0;
    return (long long)tv.tv_sec * 1000LL + (long long)tv.tv_usec / 1000LL;
}

static void copy_env(const char *name, char *dst, size_t cap) {
    const char *v = getenv(name);
    if (!v || !*v) return;
    if (strlen(v) >= cap) return;          /* silently keep the default */
    strcpy(dst, v);
}

static int env_int(const char *name, int dflt, int lo, int hi) {
    const char *v = getenv(name);
    long n;
    char *end;
    if (!v || !*v) return dflt;
    errno = 0;
    n = strtol(v, &end, 10);
    if (errno || end == v) return dflt;
    if (n < lo) n = lo;
    if (n > hi) n = hi;
    return (int)n;
}

void am_net_init(void) {
    if (g_init) return;
    g_init = 1;
    copy_env("AMBER_AI_URL",   g_url,   sizeof g_url);
    copy_env("AMBER_AI_MODEL", g_model, sizeof g_model);
    g_on     = env_int("AMBER_AI",            1, 0, 1);
    g_tab_on = env_int("AMBER_AI_TAB",        1, 0, 1);
    /* 10s, raised from 2s. Two reasons, one of them a CI failure:
     *   * a local model on a laptop CPU regularly needs more than 2s for a
     *     first token, so the documented alias in README.md/INSTALL.md already
     *     had to override this with AMBER_AI_TIMEOUT_MS=10000 -- the default
     *     was wrong often enough that the docs routed around it.
     *   * on a contended macos-latest runner the 2s budget expired before the
     *     mock backend answered, and test_e2e.py's ai_answer,
     *     ai_why_sees_the_error and response_shapes failed with
     *     "the model backend did not answer in time".
     * This is a DEADLINE, not a sleep: a backend that answers in 200ms still
     * costs 200ms, and a dead port still fails instantly on ECONNREFUSED. Only
     * a genuinely slow or black-holed endpoint waits longer than before. */
    g_qa_ms  = env_int("AMBER_AI_TIMEOUT_MS", 10000, 10, 120000);
    g_tab_ms = env_int("AMBER_AI_TAB_MS",     100,  10, 5000);
    /* 512 comfortably holds the ~230-token prompt this agent assembles plus
     * the reply. Raise it for a big workspace or a chattier task -- a prompt
     * longer than num_ctx is TRUNCATED by the server, and a truncated schema
     * produces confidently wrong column names rather than an error. */
    g_num_ctx     = env_int("AMBER_AI_NUM_CTX",     512, 128, 32768);
    g_num_predict = env_int("AMBER_AI_NUM_PREDICT", 128,   1,  4096);
    /* "30m", "1h", "0" to unload at once, "-1" to keep forever. */
    copy_env("AMBER_AI_KEEP_ALIVE", g_keep_alive, sizeof g_keep_alive);
}

const char *am_net_url(void)   { am_net_init(); return g_url; }
const char *am_net_model(void) { am_net_init(); return g_model; }
int  am_net_qa_ms(void)        { am_net_init(); return g_qa_ms; }
int  am_net_tab_ms(void)       { am_net_init(); return g_tab_ms; }
int  am_net_on(void)           { am_net_init(); return g_on; }
int  am_net_tab_on(void)       { am_net_init(); return g_on && g_tab_on; }
void am_net_set_on(int on)     { am_net_init(); g_on = !!on; if (on) g_dead_until = 0; }
int  am_net_set_url(const char *url) {
    char h[AM_HOST_MAX], p[16], q[AM_PATH_MAX];
    am_net_init();
    if (!url || !*url || strlen(url) >= sizeof g_url) return AMNET_EURL;
    if (parse_url(url, h, sizeof h, p, sizeof p, q, sizeof q) != AMNET_OK) return AMNET_EURL;
    strcpy(g_url, url);
    g_dead_until = 0;
    return AMNET_OK;
}
int  am_net_set_model(const char *m) {
    am_net_init();
    if (!m || !*m || strlen(m) >= sizeof g_model) return AMNET_EARG;
    strcpy(g_model, m);
    return AMNET_OK;
}
void am_net_set_qa_ms(int ms)  { am_net_init(); if (ms >= 10 && ms <= 120000) g_qa_ms = ms; }
void am_net_set_tab_ms(int ms) { am_net_init(); if (ms >= 10 && ms <= 5000)   g_tab_ms = ms; }
void am_net_set_tab_on(int on) { am_net_init(); g_tab_on = !!on; }
int  am_net_last_ms(void)      { return g_last_ms; }
void am_net_clear_backoff(void){ g_dead_until = 0; }


const char *am_net_strerror(int rc) {
    switch (rc) {
        case AMNET_OK:     return "ok";
        case AMNET_EOFF:   return "the AI agent is switched off (\\ai on to enable)";
        case AMNET_EURL:   return "AMBER_AI_URL is not a usable http:// URL";
        case AMNET_ECONN:  return "no model backend is listening (try: ollama serve)";
        case AMNET_ETIME:  return "the model backend did not answer in time";
        case AMNET_EHTTP:  return "the model backend returned an HTTP error";
        case AMNET_EPROTO: return "the model backend returned an unrecognised reply";
        case AMNET_EMEM:   return "out of memory";
        case AMNET_EARG:   return "bad argument";
        default:           return "unknown error";
    }
}

/* ---- URL parsing --------------------------------------------------------- */

static int parse_url(const char *url, char *host, size_t hostcap,
                     char *port, size_t portcap, char *path, size_t pathcap) {
    const char *p = url, *hs, *he, *pe;
    size_t n;

    /* The scheme is REQUIRED and must be plain http: this client has no TLS, and
     * accepting a bare "host:port/path" would happily swallow typos ("not a
     * url") as a hostname and then fail much later, at connect time. */
    if (!url) return AMNET_EURL;
    if (strncmp(p, "http://", 7) != 0) return AMNET_EURL;
    p += 7;
    {   const char *c;
        for (c = p; *c; c++)
            if ((unsigned char)*c <= ' ' || (unsigned char)*c == 127) return AMNET_EURL;
    }

    hs = p;
    /* IPv6 literal in brackets */
    if (*hs == '[') {
        he = strchr(hs, ']');
        if (!he) return AMNET_EURL;
        he++;
    } else {
        he = hs;
        while (*he && *he != ':' && *he != '/') he++;
    }
    n = (size_t)(he - hs);
    if (!n || n >= hostcap) return AMNET_EURL;
    memcpy(host, hs, n);
    host[n] = 0;
    if (host[0] == '[') {                    /* strip the brackets */
        memmove(host, host + 1, n - 1);
        host[n - 2] = 0;
    }

    if (*he == ':') {
        pe = ++he;
        while (*pe && *pe != '/') pe++;
        n = (size_t)(pe - he);
        if (!n || n >= portcap) return AMNET_EURL;
        memcpy(port, he, n);
        port[n] = 0;
        he = pe;
    } else {
        if (portcap < 3) return AMNET_EURL;
        strcpy(port, "80");
    }

    if (!*he) {
        if (pathcap < 2) return AMNET_EURL;
        strcpy(path, "/");
    } else {
        n = strlen(he);
        if (n >= pathcap) return AMNET_EURL;
        memcpy(path, he, n + 1);
    }
    return AMNET_OK;
}

/* ---- non-blocking primitives --------------------------------------------- */

static int set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0) return -1;
    return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* Remaining budget, never negative; 0 means "the deadline is already gone". */
static int budget(long long deadline) {
    long long left = deadline - am_net_now_ms();
    if (left <= 0) return 0;
    if (left > 120000) left = 120000;
    return (int)left;
}

static int wait_io(int fd, short events, long long deadline) {
    struct pollfd pfd;
    int left, rc;
    for (;;) {
        left = budget(deadline);
        if (left <= 0) return AMNET_ETIME;
        pfd.fd = fd; pfd.events = events; pfd.revents = 0;
        rc = poll(&pfd, 1, left);
        if (rc > 0) return AMNET_OK;
        if (rc == 0) return AMNET_ETIME;
        if (errno == EINTR) continue;
        return AMNET_ECONN;
    }
}

static int dial(const char *host, const char *port, long long deadline, int *fdout) {
    struct addrinfo hints, *res = NULL, *ai;
    int rc, fd = -1, last = AMNET_ECONN;
    const int one = 1;

    memset(&hints, 0, sizeof hints);
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    /* AI_NUMERICSERV keeps getaddrinfo away from /etc/services; the default
     * loopback address also never hits a DNS resolver, which is what keeps the
     * common case comfortably inside a 100ms Tab budget. */
    hints.ai_flags    = AI_NUMERICSERV;

    if (getaddrinfo(host, port, &hints, &res) != 0 || !res) return AMNET_ECONN;

    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) { last = AMNET_ECONN; continue; }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (const void *)&one, sizeof one);
#ifdef SO_NOSIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, (const void *)&one, sizeof one);
#endif
        if (set_nonblock(fd) < 0) { close(fd); fd = -1; last = AMNET_ECONN; continue; }

        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) { last = AMNET_OK; break; }
        if (errno != EINPROGRESS && errno != EINTR) {
            close(fd); fd = -1; last = AMNET_ECONN; continue;
        }
        rc = wait_io(fd, POLLOUT, deadline);
        if (rc != AMNET_OK) { close(fd); fd = -1; last = rc; continue; }
        {
            int err = 0; socklen_t elen = sizeof err;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen) < 0 || err) {
                close(fd); fd = -1; last = AMNET_ECONN; continue;
            }
        }
        last = AMNET_OK;
        break;
    }
    freeaddrinfo(res);
    if (last != AMNET_OK) { if (fd >= 0) close(fd); return last; }
    *fdout = fd;
    return AMNET_OK;
}

static int send_all(int fd, const char *buf, size_t len, long long deadline) {
    size_t off = 0;
    while (off < len) {
        ssize_t k;
        int rc = wait_io(fd, POLLOUT, deadline);
        if (rc != AMNET_OK) return rc;
#ifdef MSG_NOSIGNAL
        k = send(fd, buf + off, len - off, MSG_NOSIGNAL);
#else
        k = send(fd, buf + off, len - off, 0);
#endif
        if (k > 0) { off += (size_t)k; continue; }
        if (k < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        return AMNET_ECONN;
    }
    return AMNET_OK;
}

/* Growable byte buffer -- the only allocation policy in this file. */
typedef struct { char *p; size_t n, cap; } Buf;

static int buf_need(Buf *b, size_t extra) {
    size_t want = b->n + extra + 1;
    char *q;
    if (want <= b->cap) return 0;
    if (want > AM_BODY_MAX + 64) return -1;
    while (b->cap < want) b->cap = b->cap ? b->cap * 2 : 4096;
    q = (char *)realloc(b->p, b->cap);
    if (!q) return -1;
    b->p = q;
    return 0;
}

static int buf_add(Buf *b, const char *s, size_t n) {
    if (buf_need(b, n) < 0) return -1;
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = 0;
    return 0;
}

static int buf_str(Buf *b, const char *s) { return buf_add(b, s, strlen(s)); }

/* ---- HTTP ---------------------------------------------------------------- */

static const char *ci_find(const char *hay, size_t hn, const char *needle) {
    size_t nn = strlen(needle), i, j;
    if (nn > hn) return NULL;
    for (i = 0; i + nn <= hn; i++) {
        for (j = 0; j < nn; j++) {
            char a = hay[i + j], c = needle[j];
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
            if (a != c) break;
        }
        if (j == nn) return hay + i;
    }
    return NULL;
}

/* De-chunk in place. Returns the new length, or (size_t)-1 on malformed input. */
static size_t dechunk(char *body, size_t len) {
    size_t in = 0, out = 0;
    while (in < len) {
        size_t sz = 0;
        int digits = 0;
        while (in < len) {
            char c = body[in];
            int v;
            if (c >= '0' && c <= '9') v = c - '0';
            else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
            else break;
            sz = sz * 16 + (size_t)v;
            digits++;
            in++;
            if (sz > AM_BODY_MAX) return (size_t)-1;
        }
        if (!digits) return (size_t)-1;
        while (in < len && body[in] != '\n') in++;   /* skip chunk extensions */
        if (in < len) in++;
        if (sz == 0) break;
        if (in + sz > len) return (size_t)-1;
        memmove(body + out, body + in, sz);
        out += sz;
        in += sz;
        if (in < len && body[in] == '\r') in++;
        if (in < len && body[in] == '\n') in++;
    }
    body[out] = 0;
    return out;
}

int am_net_post(const char *url, const char *body, int timeout_ms,
                char **out, size_t *out_len) {
    char host[AM_HOST_MAX], port[16], path[AM_PATH_MAX];
    char head[AM_HOST_MAX + AM_PATH_MAX + 256];
    Buf resp;
    long long deadline, started;
    int fd = -1, rc, status = 0;
    size_t hdrlen = 0, blen, want = 0;
    char *sep, *hdr;

    if (out) *out = NULL;
    if (out_len) *out_len = 0;
    if (!url || !body || !out) return AMNET_EARG;

    am_net_init();
    started = am_net_now_ms();

    /* circuit breaker: a dead endpoint costs nothing until it is retried */
    if (g_dead_until && started < g_dead_until) return AMNET_ECONN;

    rc = parse_url(url, host, sizeof host, port, sizeof port, path, sizeof path);
    if (rc != AMNET_OK) return rc;

    if (timeout_ms <= 0) timeout_ms = g_qa_ms;
    deadline = started + timeout_ms;

    rc = dial(host, port, deadline, &fd);
    if (rc != AMNET_OK) {
        if (rc == AMNET_ECONN) g_dead_until = am_net_now_ms() + AM_NET_BACKOFF_MS;
        g_last_ms = (int)(am_net_now_ms() - started);
        return rc;
    }
    g_dead_until = 0;

    blen = strlen(body);
    if (snprintf(head, sizeof head,
                 "POST %s HTTP/1.1\r\n"
                 "Host: %s:%s\r\n"
                 "User-Agent: amber-ai/2.0.0\r\n"
                 "Content-Type: application/json\r\n"
                 "Accept: application/json\r\n"
                 "Connection: close\r\n"
                 "Content-Length: %lu\r\n\r\n",
                 path, host, port, (unsigned long)blen) >= (int)sizeof head) {
        close(fd);
        return AMNET_EURL;
    }

    rc = send_all(fd, head, strlen(head), deadline);
    if (rc == AMNET_OK) rc = send_all(fd, body, blen, deadline);
    if (rc != AMNET_OK) { close(fd); g_last_ms = (int)(am_net_now_ms() - started); return rc; }

    resp.p = NULL; resp.n = 0; resp.cap = 0;
    for (;;) {
        char tmp[4096];
        ssize_t k;
        rc = wait_io(fd, POLLIN, deadline);
        if (rc != AMNET_OK) break;
        k = recv(fd, tmp, sizeof tmp, 0);
        if (k == 0) { rc = AMNET_OK; break; }              /* peer closed */
        if (k < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            rc = AMNET_ECONN; break;
        }
        if (buf_add(&resp, tmp, (size_t)k) < 0) { rc = AMNET_EMEM; break; }
        /* Stop as soon as Content-Length is satisfied rather than waiting for
         * the peer's FIN -- that is what keeps a 100ms Tab budget realistic. */
        if (!hdrlen) {
            sep = resp.p ? strstr(resp.p, "\r\n\r\n") : NULL;
            if (sep) {
                hdrlen = (size_t)(sep - resp.p) + 4;
                hdr = resp.p;
                if (resp.n >= 12 && !strncmp(hdr, "HTTP/1.", 7))
                    status = atoi(hdr + 9);
                {
                    const char *cl = ci_find(hdr, hdrlen, "\r\ncontent-length:");
                    if (cl) want = (size_t)strtoul(cl + 17, NULL, 10);
                }
            }
        }
        if (hdrlen && want && resp.n - hdrlen >= want) { rc = AMNET_OK; break; }
    }
    close(fd);
    g_last_ms = (int)(am_net_now_ms() - started);

    if (rc != AMNET_OK) { free(resp.p); return rc; }
    if (!resp.p || !hdrlen) { free(resp.p); return AMNET_EPROTO; }

    {
        int chunked = ci_find(resp.p, hdrlen, "\r\ntransfer-encoding:") &&
                      ci_find(resp.p, hdrlen, "chunked") != NULL;
        size_t bodylen = resp.n - hdrlen;
        char *b = resp.p + hdrlen;
        memmove(resp.p, b, bodylen);
        resp.p[bodylen] = 0;
        if (chunked) {
            size_t d = dechunk(resp.p, bodylen);
            if (d == (size_t)-1) { free(resp.p); return AMNET_EPROTO; }
            bodylen = d;
        }
        if (status && (status < 200 || status > 299)) { free(resp.p); return AMNET_EHTTP; }
        *out = resp.p;
        if (out_len) *out_len = bodylen;
    }
    return AMNET_OK;
}

/* ---- minimal JSON in / out ----------------------------------------------- */

/* Append `s` to `b` as the *inside* of a JSON string (no surrounding quotes). */
static int json_escape(Buf *b, const char *s) {
    unsigned char c;
    char esc[8];
    if (!s) return 0;
    for (; (c = (unsigned char)*s) != 0; s++) {
        switch (c) {
            case '"':  if (buf_str(b, "\\\"") < 0) return -1; break;
            case '\\': if (buf_str(b, "\\\\") < 0) return -1; break;
            case '\n': if (buf_str(b, "\\n")  < 0) return -1; break;
            case '\r': if (buf_str(b, "\\r")  < 0) return -1; break;
            case '\t': if (buf_str(b, "\\t")  < 0) return -1; break;
            case '\b': if (buf_str(b, "\\b")  < 0) return -1; break;
            case '\f': if (buf_str(b, "\\f")  < 0) return -1; break;
            default:
                if (c < 0x20) {
                    sprintf(esc, "\\u%04x", (unsigned)c);
                    if (buf_str(b, esc) < 0) return -1;
                } else {
                    if (buf_add(b, (const char *)&c, 1) < 0) return -1;
                }
        }
    }
    return 0;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Decode the JSON string starting at `*p` (which must point at the opening
 * quote). Returns a malloc'd NUL-terminated UTF-8 string, or NULL. */
static char *json_unescape(const char *p, size_t *lenout) {
    Buf b; b.p = NULL; b.n = 0; b.cap = 0;
    if (*p != '"') return NULL;
    p++;
    while (*p && *p != '"') {
        if (*p != '\\') {
            if (buf_add(&b, p, 1) < 0) { free(b.p); return NULL; }
            p++;
            continue;
        }
        p++;
        switch (*p) {
            case 'n': buf_add(&b, "\n", 1); p++; break;
            case 't': buf_add(&b, "\t", 1); p++; break;
            case 'r': buf_add(&b, "\r", 1); p++; break;
            case 'b': buf_add(&b, "\b", 1); p++; break;
            case 'f': buf_add(&b, "\f", 1); p++; break;
            case '/': buf_add(&b, "/",  1); p++; break;
            case '"': buf_add(&b, "\"", 1); p++; break;
            case '\\':buf_add(&b, "\\", 1); p++; break;
            case 'u': {
                int h0 = hexval(p[1]), h1 = hexval(p[2]), h2 = hexval(p[3]), h3 = hexval(p[4]);
                unsigned cp;
                if (h0 < 0 || h1 < 0 || h2 < 0 || h3 < 0) { free(b.p); return NULL; }
                cp = (unsigned)((h0 << 12) | (h1 << 8) | (h2 << 4) | h3);
                p += 5;
                /* surrogate pair */
                if (cp >= 0xD800 && cp <= 0xDBFF && p[0] == '\\' && p[1] == 'u') {
                    int k0 = hexval(p[2]), k1 = hexval(p[3]), k2 = hexval(p[4]), k3 = hexval(p[5]);
                    if (k0 >= 0 && k1 >= 0 && k2 >= 0 && k3 >= 0) {
                        unsigned lo = (unsigned)((k0 << 12) | (k1 << 8) | (k2 << 4) | k3);
                        if (lo >= 0xDC00 && lo <= 0xDFFF) {
                            cp = 0x10000u + ((cp - 0xD800u) << 10) + (lo - 0xDC00u);
                            p += 6;
                        }
                    }
                }
                {   /* UTF-8 encode */
                    char u[4];
                    int n = 0;
                    if (cp < 0x80) { u[0] = (char)cp; n = 1; }
                    else if (cp < 0x800) {
                        u[0] = (char)(0xC0 | (cp >> 6)); u[1] = (char)(0x80 | (cp & 0x3F)); n = 2;
                    } else if (cp < 0x10000) {
                        u[0] = (char)(0xE0 | (cp >> 12));
                        u[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
                        u[2] = (char)(0x80 | (cp & 0x3F)); n = 3;
                    } else {
                        u[0] = (char)(0xF0 | (cp >> 18));
                        u[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
                        u[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
                        u[3] = (char)(0x80 | (cp & 0x3F)); n = 4;
                    }
                    buf_add(&b, u, (size_t)n);
                }
                break;
            }
            default:
                if (!*p) { free(b.p); return NULL; }
                buf_add(&b, p, 1); p++;
        }
    }
    if (!b.p) { b.p = (char *)calloc(1, 1); if (!b.p) return NULL; }
    if (lenout) *lenout = b.n;
    return b.p;
}

/* Find "<key>" : "<string>" at any depth and decode it. First match wins. */
static char *json_find_str(const char *doc, const char *key, size_t *lenout) {
    size_t klen = strlen(key);
    const char *p = doc;
    while ((p = strstr(p, key)) != NULL) {
        const char *q;
        if (p == doc || p[-1] != '"') { p += klen; continue; }
        q = p + klen;
        if (*q != '"') { p += klen; continue; }
        q++;
        while (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r') q++;
        if (*q != ':') { p += klen; continue; }
        q++;
        while (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r') q++;
        if (*q != '"') { p += klen; continue; }
        return json_unescape(q, lenout);
    }
    return NULL;
}

/* Build the request body. Shared by the blocking and the streaming paths so
 * they cannot drift: a field added for one is sent by both.
 * max_tokens < 0 means UNCAPPED -- generate until the model stops. That is only
 * safe alongside streaming, where the deadline is an IDLE timeout: an answer
 * that is still arriving is not a hang, and one that stops arriving is. */
static int build_payload(Buf *req, const char *sys, const char *user,
                         int max_tokens, int stream) {
    char num[128];
    int np = max_tokens > 0 ? max_tokens : (max_tokens < 0 ? -1 : g_num_predict);
    if (buf_str(req, "{\"model\":\"") < 0) return -1;
    if (json_escape(req, g_model) < 0) return -1;
    if (buf_str(req, "\",\"system\":\"") < 0) return -1;
    if (json_escape(req, sys ? sys : "") < 0) return -1;
    if (buf_str(req, "\",\"prompt\":\"") < 0) return -1;
    if (json_escape(req, user ? user : "") < 0) return -1;
    if (buf_str(req, stream ? "\",\"stream\":true,\"temperature\":0.0"
                            : "\",\"stream\":false,\"temperature\":0.0") < 0) return -1;
    sprintf(num, ",\"max_tokens\":%d,\"n_predict\":%d", np, np);
    if (buf_str(req, num) < 0) return -1;
    sprintf(num, ",\"options\":{\"temperature\":0.0,\"num_ctx\":%d,\"num_predict\":%d}",
            g_num_ctx, np);
    if (buf_str(req, num) < 0) return -1;
    if (g_keep_alive[0]) {
        if (buf_str(req, ",\"keep_alive\":\"") < 0) return -1;
        if (json_escape(req, g_keep_alive) < 0) return -1;
        if (buf_str(req, "\"") < 0) return -1;
    }
    return buf_str(req, "}");
}

/* Find the next COMPLETE "key":"value" at or after *off.
 * Returns 1 and hands back the unescaped value, 0 when the record has not
 * fully arrived yet (the closing quote is still in flight -- a token split
 * across two TCP reads), -1 on allocation failure. Scanning for whole records
 * rather than decoding the chunked framing is what lets this read a chunked
 * NDJSON stream without an incremental de-chunker: chunk-size lines simply are
 * not "response":"..." and are skipped as noise. */
static int next_field(const char *buf, size_t n, size_t *off, const char *key,
                      char **out, size_t *outlen) {
    size_t klen = strlen(key);
    const char *base = buf, *p = buf + *off, *end = buf + n, *q;
    while ((p = strstr(p, key)) != NULL) {
        if (p > base && p[-1] == '"') {
            q = p + klen;
            if (*q == '"') {
                q++;
                while (*q == ' ' || *q == '\t') q++;
                if (*q == ':') {
                    q++;
                    while (*q == ' ' || *q == '\t') q++;
                    if (*q == '"') {
                        const char *r = q + 1;      /* find the closing quote */
                        while (r < end && *r) {
                            if (*r == '\\') { r += 2; continue; }
                            if (*r == '"') break;
                            r++;
                        }
                        if (r >= end || *r != '"') return 0;   /* still in flight */
                        *out = json_unescape(q, outlen);
                        if (!*out) return -1;
                        *off = (size_t)(r + 1 - base);
                        return 1;
                    }
                }
            }
        }
        p += klen;
    }
    *off = n > klen ? n - klen : *off;   /* keep a little overlap for a split key */
    return 0;
}

int am_net_generate(const char *sys, const char *user, int timeout_ms,
                    int max_tokens, char **out, size_t *out_len) {
    Buf req;
    char *body = NULL, *text;
    size_t blen = 0;
    int rc;

    if (out) *out = NULL;
    if (out_len) *out_len = 0;
    if (!out) return AMNET_EARG;

    am_net_init();
    if (!g_on) return AMNET_EOFF;

    req.p = NULL; req.n = 0; req.cap = 0;
    /* One payload that every supported backend understands: Ollama reads
     * model/prompt/system/stream/options, llama.cpp's server reads
     * prompt/n_predict/temperature, OpenAI-compatible servers read
     * model/prompt/max_tokens. Unknown keys are ignored by all three.
     * Built by build_payload so the streaming path cannot drift from this one. */
    if (build_payload(&req, sys, user, max_tokens, 0) < 0) goto oom;

    rc = am_net_post(g_url, req.p, timeout_ms, &body, &blen);
    free(req.p);
    if (rc != AMNET_OK) return rc;

    /* Ollama -> "response"; llama.cpp -> "content"; OpenAI-compat -> "content"
     * inside choices[].message, or "text" for the legacy completions shape. */
    text = json_find_str(body, "response", out_len);
    if (!text) text = json_find_str(body, "content", out_len);
    if (!text) text = json_find_str(body, "text",    out_len);
    if (!text) {
        char *e = json_find_str(body, "error", NULL);
        free(body);
        if (e) { free(e); return AMNET_EHTTP; }
        return AMNET_EPROTO;
    }
    free(body);
    *out = text;
    return AMNET_OK;

oom:
    free(req.p);
    return AMNET_EMEM;
}

/* ---- streaming generation -------------------------------------------------
 * The blocking path above waits for the whole answer, then hands it over. That
 * is why a long answer feels like a hang: nothing is on screen until the last
 * token is written. Here the body is consumed as it arrives and each fragment
 * is handed to `sink` immediately.
 *
 * Two things make this safe to leave UNCAPPED (num_predict -1):
 *
 *   1. The deadline is an IDLE timeout, reset on every byte received. An answer
 *      that is still arriving is not a hang; one that stops arriving is. A
 *      total-response deadline would kill exactly the long answers streaming
 *      exists to make bearable.
 *   2. AM_BODY_MAX still bounds the total, so a runaway backend cannot exhaust
 *      memory.
 *
 * Ollama streams NDJSON under chunked transfer-encoding. Rather than decode the
 * chunk framing incrementally, next_field() scans for COMPLETE "response":"..."
 * records: chunk-size lines are not that shape, so they are skipped as noise,
 * and a record split across two reads is simply left until the rest arrives.
 */
int am_net_generate_stream(const char *sys, const char *user, int idle_ms,
                           am_net_sink sink, void *ud) {
    char host[AM_HOST_MAX], port[16], path[AM_PATH_MAX];
    char head[AM_HOST_MAX + AM_PATH_MAX + 256];
    Buf req, resp;
    long long started, deadline;
    size_t hdrlen = 0, off = 0, blen;
    const char *key = NULL;
    int fd = -1, rc, status = 0, done = 0, emitted = 0;

    if (!sink) return AMNET_EARG;
    am_net_init();
    if (!g_on) return AMNET_EOFF;

    started = am_net_now_ms();
    if (g_dead_until && started < g_dead_until) return AMNET_ECONN;

    rc = parse_url(g_url, host, sizeof host, port, sizeof port, path, sizeof path);
    if (rc != AMNET_OK) return rc;

    if (idle_ms <= 0) idle_ms = g_qa_ms;
    deadline = started + idle_ms;

    rc = dial(host, port, deadline, &fd);
    if (rc != AMNET_OK) {
        if (rc == AMNET_ECONN) g_dead_until = am_net_now_ms() + AM_NET_BACKOFF_MS;
        g_last_ms = (int)(am_net_now_ms() - started);
        return rc;
    }
    g_dead_until = 0;

    req.p = NULL; req.n = 0; req.cap = 0;
    if (build_payload(&req, sys, user, -1, 1) < 0) {
        close(fd); free(req.p); return AMNET_EMEM;
    }
    blen = req.n;
    if (snprintf(head, sizeof head,
                 "POST %s HTTP/1.1\r\n"
                 "Host: %s:%s\r\n"
                 "User-Agent: amber-ai/2.0.0\r\n"
                 "Content-Type: application/json\r\n"
                 "Accept: application/x-ndjson\r\n"
                 "Connection: close\r\n"
                 "Content-Length: %lu\r\n\r\n",
                 path, host, port, (unsigned long)blen) >= (int)sizeof head) {
        close(fd); free(req.p); return AMNET_EURL;
    }
    rc = send_all(fd, head, strlen(head), deadline);
    if (rc == AMNET_OK) rc = send_all(fd, req.p, blen, deadline);
    free(req.p);
    if (rc != AMNET_OK) {
        close(fd); g_last_ms = (int)(am_net_now_ms() - started); return rc;
    }

    resp.p = NULL; resp.n = 0; resp.cap = 0;
    for (;;) {
        char tmp[4096];
        ssize_t k;
        rc = wait_io(fd, POLLIN, deadline);
        if (rc != AMNET_OK) break;
        k = recv(fd, tmp, sizeof tmp, 0);
        if (k == 0) { rc = AMNET_OK; break; }
        if (k < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            rc = AMNET_ECONN; break;
        }
        if (buf_add(&resp, tmp, (size_t)k) < 0) { rc = AMNET_EMEM; break; }
        deadline = am_net_now_ms() + idle_ms;      /* idle, not total */

        if (!hdrlen) {
            char *sep = strstr(resp.p, "\r\n\r\n");
            if (sep) {
                hdrlen = (size_t)(sep - resp.p) + 4;
                if (resp.n >= 12 && !strncmp(resp.p, "HTTP/1.", 7))
                    status = atoi(resp.p + 9);
                off = hdrlen;
            }
        }
        if (hdrlen) {
            if (!key) {
                if (strstr(resp.p + hdrlen, "\"response\"")) key = "response";
                else if (strstr(resp.p + hdrlen, "\"content\"")) key = "content";
            }
            while (key) {
                char *frag = NULL; size_t fl = 0;
                int r = next_field(resp.p, resp.n, &off, key, &frag, &fl);
                if (r < 0) { rc = AMNET_EMEM; goto stop; }
                if (r == 0) break;
                if (fl) { emitted = 1; if (sink(frag, fl, 0, ud) != 0) { free(frag); done = 1; break; } }
                free(frag);
            }
            if (strstr(resp.p + hdrlen, "\"done\":true")) done = 1;
        }
        if (done) { rc = AMNET_OK; break; }
        if (resp.n > AM_BODY_MAX) { rc = AMNET_EPROTO; break; }
    }
stop:
    close(fd);
    g_last_ms = (int)(am_net_now_ms() - started);
    free(resp.p);
    if (rc != AMNET_OK) return rc;
    if (status && (status < 200 || status > 299)) return AMNET_EHTTP;
    if (!emitted) return AMNET_EPROTO;
    sink(NULL, 0, 1, ud);                /* let the sink close its box */
    return AMNET_OK;
}


#endif /* wasm */
