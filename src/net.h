/* net.h  -  amber-ai 1.0.0 zero-dependency POSIX HTTP bridge.
 *
 * A small, strictly-timed HTTP/1.1 client used by the in-REPL AI agent
 * (lib/ai.k, the `\ai` commands and the editor hint hook in src/ai_ext.c).
 *
 * Design constraints, in order of importance:
 *
 *   1. NEVER block the REPL.  Every call carries an absolute deadline in
 *      milliseconds that covers DNS-free address setup, connect(), send() and
 *      the whole recv() loop.  The socket is non-blocking throughout and every
 *      wait goes through poll(2) with the remaining budget, so a hung or
 *      half-open backend costs exactly the budget and not one millisecond
 *      more.  Q&A uses AMBER_AI_TIMEOUT_MS (default 2000); Tab completion uses
 *      AMBER_AI_TAB_MS (default 100, and may be driven below 50 for a
 *      genuinely invisible keystroke cost).
 *
 *   2. NEVER crash.  There is no dynamic format string, no unbounded copy and
 *      no assumption that the peer speaks correct HTTP.  A missing backend is
 *      an ordinary return code, not a signal.  A failed connect also arms a
 *      short circuit-breaker (AM_NET_BACKOFF_MS) so a REPL whose model server
 *      is simply not running pays one failed connect, not one per keystroke.
 *
 *   3. C99 + POSIX only.  <sys/socket.h>, <netdb.h>, <arpa/inet.h>, <poll.h>,
 *      <fcntl.h>, <unistd.h>.  No third-party library, no TLS (plain http:// to
 *      a loopback model server is the supported transport).
 *
 * Amber - GNU AGPLv3 - see LICENSE and NOTICE.
 */
#ifndef AMBER_NET_H
#define AMBER_NET_H

#include <stddef.h>

/* ---- result codes -------------------------------------------------------- */
#define AMNET_OK        0   /* body delivered                                 */
#define AMNET_EOFF      1   /* AI disabled (`aio 0 / AMBER_AI=0)              */
#define AMNET_EURL      2   /* AMBER_AI_URL is not a usable http:// URL       */
#define AMNET_ECONN     3   /* no backend listening / connect refused         */
#define AMNET_ETIME     4   /* deadline hit                                   */
#define AMNET_EHTTP     5   /* backend answered with a non-2xx status         */
#define AMNET_EPROTO    6   /* malformed response, or no text field in it     */
#define AMNET_EMEM      7   /* allocation failed                              */
#define AMNET_EARG      8   /* bad argument from the caller                   */

/* Circuit breaker: after a refused/failed connect, suppress further attempts
 * for this long so Tab never stalls repeatedly against a dead endpoint. */
#define AM_NET_BACKOFF_MS 4000

/* ---- configuration (env-driven, resolved once, overridable at runtime) ---- */
/* AMBER_AI_URL          default http://127.0.0.1:11434/api/generate          */
/* AMBER_AI_MODEL        default qwen2.5-coder:0.5b                           */
/* AMBER_AI              0 disables the whole agent (default 1 = ON)          */
/* AMBER_AI_TAB          0 disables AI Tab completion only (default 1 = ON)   */
/* AMBER_AI_TIMEOUT_MS   default 2000                                          */
/* AMBER_AI_TAB_MS       default 100                                           */
void        am_net_init(void);              /* idempotent                     */
const char *am_net_url(void);
const char *am_net_model(void);
int         am_net_qa_ms(void);
int         am_net_tab_ms(void);
int         am_net_on(void);                /* master switch                  */
int         am_net_tab_on(void);            /* Tab-completion switch          */
void        am_net_set_on(int on);
int         am_net_set_url(const char *url);    /* 0 = accepted        */
int         am_net_set_model(const char *m);   /* 0 = accepted        */
void        am_net_set_qa_ms(int ms);
void        am_net_set_tab_ms(int ms);
void        am_net_set_tab_on(int on);
int         am_net_last_ms(void);           /* latency of the last request    */
void        am_net_clear_backoff(void);

/* ---- transport ----------------------------------------------------------- */
/* POST `body` as application/json to `url`.  On AMNET_OK the response body is
 * returned in *out (malloc'd, NUL-terminated, *out_len excludes the NUL) and
 * the caller owns it.  On any other return code *out is left NULL. */
int am_net_post(const char *url, const char *body, int timeout_ms,
                char **out, size_t *out_len);

/* ---- generation ---------------------------------------------------------- */
/* Build the JSON payload for `sys`+`user`, POST it, and extract the generated
 * text.  Understands the three response shapes a local backend can produce:
 *   Ollama         {"response":"..."}
 *   llama.cpp      {"content":"..."}
 *   OpenAI-compat  {"choices":[{"message":{"content":"..."}}]} / {"text":"..."}
 * `max_tokens` <= 0 means "let the backend decide".  On AMNET_OK the decoded
 * (JSON-unescaped) text is returned in *out, malloc'd and NUL-terminated. */
int am_net_generate(const char *sys, const char *user, int timeout_ms,
                    int max_tokens, char **out, size_t *out_len);

/* Human-readable, never NULL, never allocates. */
const char *am_net_strerror(int rc);

/* Milliseconds on a monotonic-ish clock; shared with src/ai_ext.c. */
long long am_net_now_ms(void);

#endif /* AMBER_NET_H */
