/* tests/test_net.c  -  amber-ai 2.0.0 unit tests for the POSIX HTTP bridge.
 *
 * Standalone, like tests/test_simd.c: it links ONLY src/net.c, provides its
 * own main(), and never touches the interpreter.
 *
 *   cc -std=c99 -Isrc -pthread -o test_net tests/test_net.c src/net.c
 *
 * A throwaway HTTP server is started on an ephemeral loopback port inside this
 * process, so every case below exercises the REAL socket path -- non-blocking
 * connect, poll deadlines, header parsing, chunked decoding, JSON extraction --
 * with no external dependency and no fixed port to collide with.
 *
 * Amber - GNU AGPLv3 - see LICENSE and NOTICE.
 */
/* ---- feature-test macros: MUST precede every system header in this TU ------
 * _POSIX_C_SOURCE is what makes -std=c99 see poll(2), fcntl(2) and pthreads.
 * On Darwin, though, asking for strict POSIX also switches the BSD extensions
 * OFF: <netinet/in.h> guards INADDR_LOOPBACK (and INADDR_ANY, and the whole
 * u_int32_t family) behind
 *     #if !defined(_POSIX_C_SOURCE) || defined(_DARWIN_C_SOURCE)
 * so defining the first without the second is exactly the `net / macos-latest /
 * clang` failure:
 *     tests/test_net.c:120:31: error: use of undeclared identifier
 *     'INADDR_LOOPBACK'
 * glibc keeps INADDR_LOOPBACK visible under plain _POSIX_C_SOURCE, which is why
 * both Linux legs stay green and only macOS breaks. The missing macro is the
 * bug, NOT a missing #include -- <netinet/in.h> and <arpa/inet.h> were already
 * here, and adding more headers cannot un-hide a guarded definition.
 *
 * src/net.c, which this file links against, already carries this exact pair;
 * the test that exercises it had drifted out of sync. _DARWIN_C_SOURCE is inert
 * on Linux (glibc has never defined it), so this is additive on every platform. */
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
#include <unistd.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static int failures = 0, checks = 0;

static void ck(int cond, const char *what) {
    checks++;
    if (!cond) { failures++; printf("  FAIL %s\n", what); }
}
static void ck_rc(int got, int want, const char *what) {
    checks++;
    if (got != want) {
        failures++;
        printf("  FAIL %s: rc=%d (%s) want rc=%d\n", what, got, am_net_strerror(got), want);
    }
}
static void ck_str(const char *got, const char *want, const char *what) {
    checks++;
    if (!got || strcmp(got, want)) {
        failures++;
        printf("  FAIL %s: got <%s> want <%s>\n", what, got ? got : "(null)", want);
    }
}

/* ---- a one-shot canned-response HTTP server ------------------------------ */

typedef struct {
    int   fd;             /* listening socket                                */
    int   port;
    const char *reply;    /* raw bytes to write back                          */
    int   delay_ms;       /* stall before replying (drives the timeout test)  */
    int   drop;           /* close without answering at all                   */
    char  request[8192];  /* what the client sent, for inspection             */
    int   reqlen;
} Server;

static void msleep(int ms) {
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

static void *serve(void *arg) {
    Server *s = (Server *)arg;
    int c = accept(s->fd, NULL, NULL);
    if (c < 0) return NULL;
    /* Read until the request body has arrived, not merely until the first
     * segment has: a POST's headers and body routinely land in separate TCP
     * segments, and a single recv() then makes "payload is sent verbatim"
     * fail for reasons that have nothing to do with the client. */
    {   size_t got = 0;
        for (;;) {
            ssize_t k = recv(c, s->request + got, sizeof s->request - 1 - got, 0);
            if (k <= 0) break;
            got += (size_t)k;
            s->request[got] = 0;
            {   char *hdr_end = strstr(s->request, "\r\n\r\n"), *cl;
                size_t want;
                if (!hdr_end) continue;
                cl = strstr(s->request, "Content-Length:");
                want = cl ? (size_t)strtoul(cl + 15, NULL, 10) : 0;
                if (got >= (size_t)(hdr_end - s->request) + 4 + want) break;
            }
        }
        s->reqlen = (int)got;
    }
    if (s->delay_ms) msleep(s->delay_ms);
    if (!s->drop) {
        size_t n = strlen(s->reply), off = 0;
        while (off < n) {
            ssize_t k = send(c, s->reply + off, n - off, 0);
            if (k <= 0) break;
            off += (size_t)k;
        }
    }
    close(c);
    return NULL;
}

static int server_start(Server *s, const char *reply, int delay_ms, int drop) {
    struct sockaddr_in a;
    socklen_t alen = sizeof a;
    pthread_t th;
    const int one = 1;

    memset(s, 0, sizeof *s);
    s->reply = reply; s->delay_ms = delay_ms; s->drop = drop;
    s->fd = socket(AF_INET, SOCK_STREAM, 0);
    if (s->fd < 0) return -1;
    setsockopt(s->fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;                                  /* ephemeral */
    if (bind(s->fd, (struct sockaddr *)&a, sizeof a) < 0) return -1;
    if (listen(s->fd, 1) < 0) return -1;
    if (getsockname(s->fd, (struct sockaddr *)&a, &alen) < 0) return -1;
    s->port = ntohs(a.sin_port);
    if (pthread_create(&th, NULL, serve, s) != 0) return -1;
    pthread_detach(th);
    return 0;
}

static void server_url(Server *s, char *out, size_t cap) {
    snprintf(out, cap, "http://127.0.0.1:%d/api/generate", s->port);
}

/* ---- canned replies ------------------------------------------------------ */

/* Content-Length values below are exact; the client stops reading the moment
 * they are satisfied rather than waiting for the peer's FIN, and that is what
 * keeps a 100ms Tab budget realistic, so getting them wrong here would quietly
 * stop testing the thing worth testing. (R_OK is taken by <unistd.h>.) */
#define RSP_OK \
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 32\r\n\r\n" \
    "{\"response\":\"select sym from t\"}"

/* 25-byte body split 15 + 10 across two chunks, plus the terminating 0-chunk */
#define RSP_CHUNKED \
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
    "Transfer-Encoding: chunked\r\n\r\n" \
    "f\r\n{\"response\":\"ch\r\n" \
    "a\r\nunked ok\"}\r\n" \
    "0\r\n\r\n"

#define RSP_LLAMACPP \
    "HTTP/1.1 200 OK\r\nContent-Length: 24\r\n\r\n" \
    "{\"content\":\"from llama\"}"

#define RSP_OPENAI \
    "HTTP/1.1 200 OK\r\nContent-Length: 62\r\n\r\n" \
    "{\"choices\":[{\"message\":{\"content\":\"openai shaped\"}}],\"id\":\"x\"}"

#define RSP_ESCAPES \
    "HTTP/1.1 200 OK\r\nContent-Length: 34\r\n\r\n" \
    "{\"response\":\"a\\\"b\\\\c\\nd\\te\\u00e9\"}"

#define RSP_500 \
    "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 18\r\n\r\n" \
    "{\"error\":\"kaboom\"}"

#define RSP_GARBAGE "not http at all, not even close\n"

#define RSP_NOFIELD \
    "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"done\":true}"

int main(void) {
    char url[128];
    char *out = NULL;
    size_t n = 0;
    int rc;

    printf("test_net: amber-ai 2.0.0 POSIX HTTP bridge\n");

    /* ---- 1. URL validation ------------------------------------------------ */
    ck(am_net_set_url("http://127.0.0.1:11434/api/generate") == AMNET_OK, "accepts a plain http URL");
    ck(am_net_set_url("http://host:8080/x") == AMNET_OK,                  "accepts host:port/path");
    ck(am_net_set_url("https://host/x")     != AMNET_OK,                  "rejects https (no TLS here)");
    ck(am_net_set_url("not a url")          != AMNET_OK,                  "rejects a non-URL");
    ck(am_net_set_url("")                   != AMNET_OK,                  "rejects the empty string");
    ck(am_net_set_url(NULL)                 != AMNET_OK,                  "rejects NULL");
    ck(am_net_set_model("qwen2.5-coder:0.5b") == AMNET_OK,                "accepts a model name");
    ck(am_net_set_model("")                 != AMNET_OK,                  "rejects an empty model name");
    ck_str(am_net_model(), "qwen2.5-coder:0.5b",                          "model is readable back");

    /* ---- 2. switches ------------------------------------------------------ */
    am_net_set_on(0);
    ck(am_net_on() == 0,     "master switch turns off");
    ck(am_net_tab_on() == 0, "Tab assist follows the master switch");
    am_net_set_on(1);
    ck(am_net_on() == 1,     "master switch turns back on");
    am_net_set_tab_on(0);
    ck(am_net_tab_on() == 0, "Tab assist turns off on its own");
    am_net_set_tab_on(1);
    ck(am_net_tab_on() == 1, "Tab assist turns back on");
    am_net_set_qa_ms(1234);
    ck(am_net_qa_ms() == 1234, "Q&A budget is settable");
    am_net_set_qa_ms(0);
    ck(am_net_qa_ms() == 1234, "an out-of-range budget is ignored");

    /* ---- 3. a plain 200 with Content-Length ------------------------------- */
    {   Server s;
        ck(server_start(&s, RSP_OK, 0, 0) == 0, "test server starts");
        server_url(&s, url, sizeof url);
        am_net_clear_backoff();
        rc = am_net_post(url, "{\"prompt\":\"hi\"}", 3000, &out, &n);
        ck(rc == AMNET_OK, "POST succeeds");
        ck(out && strstr(out, "select sym from t") != NULL, "body is delivered");
        ck(n == 32, "body length is exact");
        ck(strstr(s.request, "POST /api/generate HTTP/1.1") != NULL, "request line is well formed");
        ck(strstr(s.request, "Content-Type: application/json") != NULL, "content type is set");
        ck(strstr(s.request, "Content-Length: 15") != NULL, "content length matches the payload");
        ck(strstr(s.request, "{\"prompt\":\"hi\"}") != NULL, "payload is sent verbatim");
        free(out); out = NULL;
        close(s.fd);
    }

    /* ---- 4. chunked transfer encoding ------------------------------------- */
    {   Server s;
        server_start(&s, RSP_CHUNKED, 0, 0);
        server_url(&s, url, sizeof url);
        am_net_clear_backoff();
        am_net_set_url(url);
        rc = am_net_generate("sys", "user", 3000, 16, &out, &n);
        ck(rc == AMNET_OK, "chunked reply is accepted");
        ck_str(out, "chunked ok", "chunked body is reassembled");
        free(out); out = NULL;
        close(s.fd);
    }

    /* ---- 5. the three backend response shapes ----------------------------- */
    {   Server s;
        server_start(&s, RSP_LLAMACPP, 0, 0);
        server_url(&s, url, sizeof url); am_net_set_url(url); am_net_clear_backoff();
        rc = am_net_generate("s", "u", 3000, 0, &out, &n);
        ck(rc == AMNET_OK, "llama.cpp shape: request ok");
        ck_str(out, "from llama", "llama.cpp shape: \"content\" is extracted");
        free(out); out = NULL; close(s.fd);
    }
    {   Server s;
        server_start(&s, RSP_OPENAI, 0, 0);
        server_url(&s, url, sizeof url); am_net_set_url(url); am_net_clear_backoff();
        rc = am_net_generate("s", "u", 3000, 0, &out, &n);
        ck(rc == AMNET_OK, "OpenAI shape: request ok");
        ck_str(out, "openai shaped", "OpenAI shape: nested content is extracted");
        free(out); out = NULL; close(s.fd);
    }

    /* ---- 6. JSON unescaping ----------------------------------------------- */
    {   Server s;
        server_start(&s, RSP_ESCAPES, 0, 0);
        server_url(&s, url, sizeof url); am_net_set_url(url); am_net_clear_backoff();
        rc = am_net_generate("s", "u", 3000, 0, &out, &n);
        ck(rc == AMNET_OK, "escaped reply is accepted");
        ck_str(out, "a\"b\\c\nd\te\xc3\xa9", "\\\" \\\\ \\n \\t and \\uXXXX all decode");
        free(out); out = NULL; close(s.fd);
    }

    /* ---- 7. failure paths, none of which may hang or crash ---------------- */
    {   Server s;
        server_start(&s, RSP_500, 0, 0);
        server_url(&s, url, sizeof url); am_net_clear_backoff();
        rc = am_net_post(url, "{}", 3000, &out, &n);
        ck(rc == AMNET_EHTTP, "a 500 is reported as an HTTP error");
        ck(out == NULL, "no body is handed back on failure");
        close(s.fd);
    }
    {   Server s;
        server_start(&s, RSP_GARBAGE, 0, 0);
        server_url(&s, url, sizeof url); am_net_clear_backoff();
        rc = am_net_post(url, "{}", 3000, &out, &n);
        ck_rc(rc, AMNET_EPROTO, "a non-HTTP reply is a protocol error");
        ck(out == NULL, "no body on a protocol error");
        close(s.fd);
    }
    {   Server s;
        server_start(&s, RSP_NOFIELD, 0, 0);
        server_url(&s, url, sizeof url); am_net_set_url(url); am_net_clear_backoff();
        rc = am_net_generate("s", "u", 3000, 0, &out, &n);
        ck(rc == AMNET_EPROTO, "a reply with no text field is a protocol error");
        close(s.fd);
    }
    {   /* the deadline is honoured, and honoured tightly */
        Server s;
        long long t0, dt;
        server_start(&s, RSP_OK, 1500, 0);
        server_url(&s, url, sizeof url); am_net_clear_backoff();
        t0 = am_net_now_ms();
        rc = am_net_post(url, "{}", 200, &out, &n);
        dt = am_net_now_ms() - t0;
        ck(rc == AMNET_ETIME, "a stalled backend times out");
        ck(dt < 900, "the timeout is respected, not merely eventual");
        ck(out == NULL, "no body after a timeout");
        close(s.fd);
    }
    {   /* nothing listening at all: the everyday "ollama is not running" case */
        am_net_clear_backoff();
        rc = am_net_post("http://127.0.0.1:9/api/generate", "{}", 500, &out, &n);
        ck(rc == AMNET_ECONN, "a closed port is a connect error");
        ck(out == NULL, "no body from a closed port");
        /* and the circuit breaker makes the SECOND attempt instant */
        {   long long t0 = am_net_now_ms();
            rc = am_net_post("http://127.0.0.1:9/api/generate", "{}", 500, &out, &n);
            ck(rc == AMNET_ECONN, "the retry still reports a connect error");
            ck(am_net_now_ms() - t0 < 50, "the circuit breaker short-circuits the retry");
        }
        am_net_clear_backoff();
    }
    {   /* switched off: no socket is opened at all */
        am_net_set_on(0);
        rc = am_net_generate("s", "u", 1000, 0, &out, &n);
        ck(rc == AMNET_EOFF, "generate refuses while the agent is off");
        am_net_set_on(1);
    }
    /* argument hygiene */
    ck(am_net_post(NULL, "{}", 100, &out, &n) == AMNET_EARG, "NULL url is rejected");
    ck(am_net_post("http://127.0.0.1:9/", NULL, 100, &out, &n) == AMNET_EARG, "NULL body is rejected");
    ck(am_net_post("http://127.0.0.1:9/", "{}", 100, NULL, NULL) == AMNET_EARG, "NULL out is rejected");
    ck(am_net_strerror(AMNET_ECONN) != NULL, "every code has a message");
    ck(am_net_strerror(9999) != NULL, "an unknown code still has a message");

    printf("test_net: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
