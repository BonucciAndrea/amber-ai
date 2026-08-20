/* ai_ext.c  -  amber-ai 2.0.0: the C half of the Amber AI co-pilot.
 *
 * This file is the ONLY thing that touches Amber's internals, and it does so
 * exclusively through the published extension seam in Amber 1.9.5's
 * src/ext.h.  Nothing in the engine is patched: install.sh copies this file,
 * src/net.c and src/net.h into <amber>/ext/, copies lib/ai.k into <amber>/lib/,
 * and re-runs <amber>/build.sh.  Uninstalling is deleting those files and
 * building again.
 *
 * The split is deliberate and total:
 *
 *   lib/ai.k   (Amber)  everything the agent DECIDES -- schema harvesting,
 *                       prompt construction, \ai sub-commands, diagnostics,
 *                       profiling, the persistent-memory format.
 *   src/net.c  (C99)    everything the agent TRANSPORTS -- a non-blocking
 *                       POSIX HTTP client under a hard millisecond deadline.
 *   src/ai_ext.c        this file: the joints, and nothing else.
 *
 * What it registers, all through src/ext.h:
 *
 *   `ai (system; prompt)             -> (rc; text)
 *   `ai (system; prompt; timeoutMs)  -> (rc; text)
 *   `ai (system; prompt; timeoutMs; maxTokens)
 *   `ai "prompt"                     -> (rc; text)   (default system + budget)
 *        rc 0 = ok; non-zero = an already-worded, friendly failure in `text`,
 *        so lib/ai.k never has to know what a socket is and the REPL never
 *        sees an exception just because no model server is running.
 *
 *   `aio 0 | 1        agent off / on        `aio 2 | 3   Tab assist off / on
 *   `aio 4            retry a dead endpoint now
 *   `aio (0;"http://host:port/path")        retarget the endpoint
 *   `aio (1;"model-name")                   switch model
 *   `aio (2;ms) | `aio (3;ms)                answer / Tab budgets
 *   `aio -1           query only
 *        -> (on; tabOn; url; model; qaMs; tabMs; lastMs)
 *   `aio 5            drain the last ACCEPTED Tab suggestion (feedback)
 *
 *   \ai ...           the REPL command, claimed ahead of the engine's
 *                     "unknown \cmd is a shell command" fallback
 *   am_ext_hint            inline ghost text from the model, inside a hard
 *                          millisecond budget, never inserted until accepted
 *   am_ext_complete        \ai and its sub-commands (before the engine's own
 *                          lexical sources -- `\ai pro` can mean nothing else)
 *   am_ext_complete_late   instant, network-free candidates mined from
 *                          ~/.amber_ai_memory.k, AFTER globals and columns so
 *                          a remembered line can never shadow a live name
 *
 * PRIVACY / SAFETY, in one paragraph: the only endpoint ever contacted is the
 * one in AMBER_AI_URL, which defaults to http://127.0.0.1:11434 -- a model
 * server on this machine.  There is no telemetry, no TLS stack, no third-party
 * host and no fallback to a hosted API: if nothing is listening on that port
 * the agent reports one friendly sentence and the REPL carries on.  Set
 * AMBER_AI=0 (or type \ai off) and not a single socket is opened.
 *
 * amber-ai - GNU AGPLv3 - see LICENSE and NOTICE.
 */
#include "a.h"
#include "ext.h"
#include "ln.h"
#include "net.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define AMBER_AI_VERSION "2.0.0"

/* Copy a K char vector (or symbol) into a fresh NUL-terminated C string. */
static char *cstr(A v) {
    char *s;
    U n;
    if (!v) return NULL;
    if (_ts(v)) {                       /* symbol atom */
        const char *p = su(_v(v));
        n = (U)strlen(p);
        s = (char *)malloc(n + 1);
        if (!s) return NULL;
        memcpy(s, p, n + 1);
        return s;
    }
    if (_t(v) != tC) return NULL;
    n = _n(v);
    s = (char *)malloc((size_t)n + 1);
    if (!s) return NULL;
    if (n) memcpy(s, _C(v), n);
    s[n] = 0;
    return s;
}

static A pair(int rc, const char *text) {
    A a[2];
    a[0] = ai(rc);
    a[1] = text ? aCn((S)text, (U)strlen(text)) : emp(tC);
    return aV(tA, 2, a);
}

/* ======================================================================== */
/* 1.  `ai  -- one round trip to the local model                            */
/* ======================================================================== */
static A aiC(A x) {
    char *sys = NULL, *usr = NULL, *out = NULL;
    size_t n = 0;
    int tmo = 0, rc, maxtok = 0;
    A r;

    if (_t(x) == tC) {
        usr = cstr(x);
    } else if (_t(x) == tA && _n(x) >= 2) {
        A *v = _A(x);
        sys = cstr(v[0]);
        usr = cstr(v[1]);
        if (_n(x) >= 3 && _tz(v[2])) tmo = (int)gl_(v[2]);
        if (_n(x) >= 4 && _tz(v[3])) maxtok = (int)gl_(v[3]);
    } else {
        return x(et0());
    }
    mr(x);

    if (!usr) { free(sys); return pair(AMNET_EARG, am_net_strerror(AMNET_EARG)); }

    rc = am_net_generate(sys ? sys : "", usr, tmo, maxtok, &out, &n);
    free(sys);
    free(usr);

    if (rc != AMNET_OK) {
        free(out);
        r = pair(rc, am_net_strerror(rc));
    } else {
        A a[2];
        a[0] = ai(0);
        a[1] = aCn((S)out, (U)n);
        r = aV(tA, 2, a);
        free(out);
    }
    return r;
}

/* ======================================================================== */
/* ---------------------------------------------------------------------------
 * 1b.  `ais -- STREAMING ask, rendered live into a box that grows with it
 *
 *      `ais (system; prompt; idleMs; width)  ->  (rc; fullText)
 *
 * Why this is in C rather than lib/ai.k: the fragments arrive inside
 * am_net_generate_stream's poll loop, and calling back into the interpreter
 * from there would mean re-entering it mid-read. The k box renderer stays as
 * it is for everything that is NOT streamed (\ai warm, diagnostics).
 *
 * The box GROWS. A row already on screen cannot be widened in place, so the
 * text is buffered and the whole box is redrawn -- cursor up, clear, reprint --
 * whenever the layout changes. Throttled, because redrawing per token on a fast
 * backend is thousands of repaints a second for no visible benefit.
 *
 * If the box ever grows taller than the terminal it stops redrawing and simply
 * appends: once the top has scrolled off, "cursor up N" no longer addresses the
 * rows we drew, and repainting would corrupt the scrollback.
 * ------------------------------------------------------------------------- */

#define AI_BOX_MIN   24
#define AI_BOX_MS    40          /* redraw throttle */

typedef struct {
    char  *t;                    /* everything received so far */
    size_t n, cap;
    int    rows;                 /* rows of the box last drawn, borders included */
    int    inner;                /* inner width last drawn */
    int    maxw;                 /* terminal width - 4 */
    int    maxrows;              /* terminal height - 2 */
    int    drawn;
    int    frozen;               /* too tall to repaint: append-only from here */
    int    live;                 /* stdout is a terminal: repaint in place */
    size_t shown;                /* bytes already on screen */
    long long last;
} AiBox;

/* display columns: a UTF-8 continuation byte belongs to the previous character */
static int ai_dw(const char *s, size_t n) {
    size_t i; int w = 0;
    for (i = 0; i < n; i++) if ((s[i] & 0xC0) != 0x80) w++;
    return w;
}
/* longest byte-prefix of s[0..n) that fits in `cols` display columns */
static size_t ai_fit(const char *s, size_t n, int cols) {
    size_t i; int w = 0;
    for (i = 0; i < n; i++) {
        if ((s[i] & 0xC0) != 0x80) { if (w == cols) return i; w++; }
    }
    return n;
}
static void ai_put(const char *s, size_t n) { fwrite(s, 1, n, stdout); }

/* one wrapped row at a time; returns bytes consumed from s */
static size_t ai_row(const char *s, size_t n, int cols, size_t *outlen) {
    size_t take, i, brk;
    const char *nl = memchr(s, '\n', n);
    size_t seg = nl ? (size_t)(nl - s) : n;
    if (ai_dw(s, seg) <= cols) { *outlen = seg; return nl ? seg + 1 : seg; }
    take = ai_fit(s, seg, cols);
    brk = 0;
    for (i = 0; i < take; i++) if (s[i] == ' ') brk = i;
    if (brk == 0) { *outlen = take; return take; }        /* no space: hard break */
    *outlen = brk;
    return brk + 1;                                        /* swallow the space */
}
/* a line that is only a ``` fence is markdown scaffolding, not code */
static int ai_fence(const char *s, size_t len) {
    size_t i = 0;
    while (i < len && (s[i] == ' ' || s[i] == '\t')) i++;
    return len - i >= 3 && !strncmp(s + i, "```", 3);
}

static void ai_box_draw(AiBox *b, int final) {
    const char *p = b->t, *e = b->t + b->n;
    int want = AI_BOX_MIN, rows = 0, i;
    size_t adv, len;
    const char *q;

    /* widest natural line, capped at the terminal */
    for (q = p; q < e; ) {
        const char *nl = memchr(q, '\n', (size_t)(e - q));
        size_t seg = nl ? (size_t)(nl - q) : (size_t)(e - q);
        int w = ai_dw(q, seg);
        if (w > want) want = w;
        q = nl ? nl + 1 : e;
    }
    if (want > b->maxw) want = b->maxw;

    /* count the rows this layout needs */
    for (q = p; q < e; ) {
        adv = ai_row(q, (size_t)(e - q), want, &len);
        if (!ai_fence(q, len)) rows++;
        q += adv ? adv : 1;
    }
    if (rows == 0) rows = 1;

    if (b->drawn && !b->frozen) {
        if (b->rows + 2 > b->maxrows) { b->frozen = 1; }
        else printf("\033[%dA\033[J", b->rows);
    }
    if (b->frozen && b->drawn) return;      /* append-only: leave what is drawn */

    printf("\342\224\214");                                  /* top left */
    for (i = 0; i < want + 2; i++) printf("\342\224\200");
    printf("\342\224\220\n");
    for (q = p; q < e; ) {
        adv = ai_row(q, (size_t)(e - q), want, &len);
        if (!ai_fence(q, len)) {
            int pad = want - ai_dw(q, len);
            printf("\342\224\202 "); ai_put(q, len);
            for (i = 0; i < pad; i++) putchar(' ');
            printf(" \342\224\202\n");
        }
        q += adv ? adv : 1;
    }
    printf("\342\224\224");
    for (i = 0; i < want + 2; i++) printf("\342\224\200");
    printf("\342\224\230\n");
    fflush(stdout);
    b->rows  = rows + 2;
    b->inner = want;
    b->drawn = 1;
    b->shown = b->n;
    (void)final;
}

static int ai_sink(const char *frag, size_t n, int done, void *ud) {
    AiBox *b = (AiBox *)ud;
    long long now;
    if (frag && n) {
        if (b->n + n + 1 > b->cap) {
            size_t c = b->cap ? b->cap * 2 : 4096;
            char *q;
            while (c < b->n + n + 1) c *= 2;
            q = (char *)realloc(b->t, c);
            if (!q) return 1;
            b->t = q; b->cap = c;
        }
        memcpy(b->t + b->n, frag, n);
        b->n += n; b->t[b->n] = 0;
    }
    /* Repaint only on a terminal. Piped into a file or another program, the
     * cursor-up sequences are not control codes, they are CONTENT -- every
     * intermediate frame would land in the output and the escape bytes with it.
     * So off a tty the box is drawn exactly once, when the answer is complete,
     * which is also what a caller reading our stdout actually wants. */
    now = am_net_now_ms();
    if (!b->live) { if (done) ai_box_draw(b, 1); return 0; }
    if (b->drawn && b->shown == b->n) return 0;   /* nothing new to show */
    if (done || !b->drawn || now - b->last >= AI_BOX_MS) {
        ai_box_draw(b, done);
        b->last = now;
    }
    return 0;
}

static A aisC(A x) {
    char *sys = NULL, *usr = NULL;
    AiBox b;
    int idle = 0, width = 84, height = 1000, rc;
    A r;

    memset(&b, 0, sizeof b);
    if (_t(x) == tA && _n(x) >= 2) {
        A *v = _A(x);
        sys = cstr(v[0]);
        usr = cstr(v[1]);
        if (_n(x) >= 3 && _tz(v[2])) idle   = (int)gl_(v[2]);
        if (_n(x) >= 4 && _tz(v[3])) width  = (int)gl_(v[3]);
        if (_n(x) >= 5 && _tz(v[4])) height = (int)gl_(v[4]);
    } else {
        return x(et0());
    }
    mr(x);
    if (!usr) { free(sys); return pair(AMNET_EARG, am_net_strerror(AMNET_EARG)); }

    if (width  < AI_BOX_MIN + 4) width  = AI_BOX_MIN + 4;
    if (height < 6)              height = 6;
    b.maxw    = width - 4;
    b.maxrows = height - 2;
    b.live    = isatty(1) ? 1 : 0;

    rc = am_net_generate_stream(sys ? sys : "", usr, idle, ai_sink, &b);
    free(sys); free(usr);

    if (rc != AMNET_OK && !b.drawn) { free(b.t); return pair(rc, am_net_strerror(rc)); }
    {   A a[2];
        a[0] = ai(0);
        a[1] = aCn((S)(b.t ? b.t : ""), (U)b.n);
        r = aV(tA, 2, a);
    }
    free(b.t);
    return r;
}

/* 2.  `aio -- switches, runtime reconfiguration, status                    */
/* ======================================================================== */
static A aioC(A x) {
    A a[7];

    if (!_tP(x) && _n(x) == 2 && (_t(x) == tA || _tZ(x))) {
        /* `aio (key; value) -- runtime reconfiguration.
         *   0 url(string)  1 model(string)  2 qaMs(int)  3 tabMs(int)
         * ii() is used rather than _A(x)[i] because a pair of two integers --
         * `aio (2;1500) -- is an INT VECTOR in this dialect, not a general
         * list, and both spellings have to work. */
        A k0 = ii(x, 0), v0 = ii(x, 1);
        if (_tz(k0)) {
            int key = (int)gl_(k0);
            if (key == 0 || key == 1) {
                char *t = cstr(v0);
                if (t) { if (key) am_net_set_model(t); else am_net_set_url(t); free(t); }
            } else if (key == 2 && _tz(v0)) am_net_set_qa_ms((int)gl_(v0));
            else if (key == 3 && _tz(v0)) am_net_set_tab_ms((int)gl_(v0));
        }
        mr(k0); mr(v0);
    } else if (_tz(x)) {
        switch ((int)gl_(x)) {
            case 0: am_net_set_on(0);     break;
            case 1: am_net_set_on(1);     break;
            case 2: am_net_set_tab_on(0); break;
            case 3: am_net_set_tab_on(1); break;
            case 4: am_net_clear_backoff(); break;
            case 5: {                     /* drain the accepted Tab suggestion */
                const char *acc = am_repl_take_accepted();
                return x(aCn((S)acc, (U)strlen(acc)));
            }
            default: break;               /* anything else = query only */
        }
    }
    mr(x);
    a[0] = ai(am_net_on());
    a[1] = ai(am_net_tab_on());
    a[2] = aCz(am_net_url());
    a[3] = aCz(am_net_model());
    a[4] = ai(am_net_qa_ms());
    a[5] = ai(am_net_tab_ms());
    a[6] = ai(am_net_last_ms());
    return aV(tA, 7, a);
}

/* ======================================================================== */
/* 3.  \ai -- the REPL command                                              */
/* ======================================================================== */
/*
 * Handed the text after the backslash, e.g. "ai why".  Everything the command
 * does lives in lib/ai.k; this only routes.  Routed through .[;;] so a session
 * in which lib/ai.k was never loaded gets one clear sentence instead of a
 * 'value error, and so an agent-side error can never take the REPL down with
 * it.  The rich stderr diagnostic is switched off around the call (`diag
 * returns the previous setting) because the handler ALREADY prints the full
 * error text -- leaving it on painted a report about the internals of this
 * very dispatch lambda, which tells the user nothing.
 */
static unsigned long long ai_bs(const char *line) {
    if (strncmp(line, "ai", 2)) return 0;
    if (line[2] && line[2] != ' ') return 0;          /* \aim, \air, ... : not ours */
    {
        const char *rest = line + 2 + (line[2] == ' ');
        return (unsigned long long)K1(
            "{p:`diag 0;.[{ai.cmd x};,x;{`1:\"ai: \",(*\"\\n\"\\$[`C~@x;x;`k x]),\"\\n\";"
            "`1:\"    the agent could not run. If lib/ai.k is not loaded:  \\\\l lib/ai.k"
            "   (or start the REPL with ./a)\\n\";}];`diag p;}",
            aCz((S)rest));
    }
}

/* ======================================================================== */
/* 4.  the editor: ghost text from the model, inside a hard budget          */
/* ======================================================================== */
/*
 * Called by src/ln.c ONLY when the cursor is at end of line and every lexical
 * completion source (globals, columns, \ commands, vocabulary, this session's
 * history, and the memory-file source below) has already come up empty.  The
 * result is rendered as dim ghost text and is NEVER inserted until the user
 * presses Tab, Right or Ctrl-F again.
 *
 * Every wait inside am_net_generate() is bounded by AMBER_AI_TAB_MS (default
 * 100ms), and a refused connect arms a 4-second circuit breaker, so a REPL
 * whose model server is not running pays one failed connect -- not one per
 * keystroke.
 */
static int ai_hint(const char *line, size_t len, char *dst, size_t cap) {
    char sys[512];
    char user[3072];
    char schema[1024];
    char *txt = NULL;
    size_t tn = 0, i, j;
    int rc;

    if (!am_net_tab_on()) return 0;

    am_schema_brief(schema, sizeof schema);

    strcpy(sys,
        "You complete a single line of Amber (a K/q dialect) at the cursor. "
        "Reply with ONLY the characters that continue the line. "
        "No prose, no backticks, no newline, no repetition of what is typed. "
        "If unsure, reply with nothing.");

    if ((size_t)snprintf(user, sizeof user,
                 "Workspace: %s\nLine so far: %s\nContinuation:",
                 schema, line) >= sizeof user)
        return 0;

    rc = am_net_generate(sys, user, am_net_tab_ms(), 24, &txt, &tn);
    if (rc != AMNET_OK || !txt) { free(txt); return 0; }

    /* Sanitise.  Leading BLANK LINES are noise and get skipped, but a leading
     * SPACE is not: for a continuation it is usually the separator the user
     * has not typed yet.  Only the first line is ever offered. */
    j = 0;
    while (txt[j] == '\n' || txt[j] == '\r') j++;
    for (i = j; txt[i] && txt[i] != '\n' && txt[i] != '\r'; i++) { }
    txt[i] = 0;
    while (i > j && (txt[i - 1] == ' ' || txt[i - 1] == '\t')) txt[--i] = 0;
    if (!txt[j]) { free(txt); return 0; }
    /* A model that echoes the line back is offering nothing: drop the echo. */
    if (!strncmp(txt + j, line, len)) j += len;
    if (!txt[j]) { free(txt); return 0; }

    strncpy(dst, txt + j, cap - 1);
    dst[cap - 1] = 0;
    free(txt);
    return dst[0] != 0;
}

/* ======================================================================== */
/* 5.  the editor: instant candidates from ~/.amber_ai_memory.k             */
/* ======================================================================== */
/*
 * lib/ai.k OWNS that file; this only READS it, and only to mine past lines as
 * completion candidates.  The format is one Amber expression per line:
 *
 *      ai.rec["q";1755512345;3;"select sym,px from trades";"trades quotes"]
 *              kind  epoch-s  hits  text                    context
 *
 * so the SECOND double-quoted field of an `ai.rec[` line is the text.  A file
 * that cannot be parsed simply yields no candidates; it is never an error.
 * This source is instant and entirely offline -- it is what makes the REPL
 * feel like it has learned this user's table names and query habits, with no
 * model involved at all.
 */
#define AI_MEM_MAX    400          /* recalled lines kept in memory        */
#define AI_MEM_BYTES  (256u*1024u) /* cap on the file we are willing to read */
#define AI_SUB_CAND   4096

static char *g_mem[AI_MEM_MAX];
static int   g_mem_n;
static long  g_mem_mtime = -1;
static char  g_mem_path[512];

static const char *mem_path(void) {
    const char *h;
    if (g_mem_path[0]) return g_mem_path;
    h = getenv("AMBER_AI_MEMORY");
    if (h && *h && strlen(h) < sizeof g_mem_path) { strcpy(g_mem_path, h); return g_mem_path; }
    h = getenv("HOME");
    if (!h || !*h) h = ".";
    if (strlen(h) + 24 >= sizeof g_mem_path) return NULL;
    sprintf(g_mem_path, "%s/.amber_ai_memory.k", h);
    return g_mem_path;
}

/* Decode one K string literal starting at the opening quote; advances *pp. */
static char *k_string(const char **pp) {
    const char *p = *pp;
    char *out;
    size_t n = 0, cap = 64;
    if (*p != '"') return NULL;
    p++;
    out = (char *)malloc(cap);
    if (!out) return NULL;
    while (*p && *p != '"') {
        char c = *p++;
        if (c == '\\' && *p) {
            char e = *p++;
            c = (e == 'n') ? '\n' : (e == 't') ? '\t' : (e == 'r') ? '\r' : e;
        }
        if (n + 2 > cap) {
            char *q = (char *)realloc(out, cap *= 2);
            if (!q) { free(out); return NULL; }
            out = q;
        }
        out[n++] = c;
    }
    if (*p == '"') p++;
    out[n] = 0;
    *pp = p;
    return out;
}

static void mem_clear(void) {
    int i;
    for (i = 0; i < g_mem_n; i++) free(g_mem[i]);
    g_mem_n = 0;
}

static void mem_reload(void) {
    const char *path = mem_path();
    struct stat st;
    FILE *f;
    char line[2048];
    size_t total = 0;

    if (!path) return;
    if (stat(path, &st) != 0) { mem_clear(); g_mem_mtime = -1; return; }
    if ((long)st.st_mtime == g_mem_mtime) return;
    g_mem_mtime = (long)st.st_mtime;
    mem_clear();

    f = fopen(path, "r");
    if (!f) return;
    while (fgets(line, (int)sizeof line, f) && g_mem_n < AI_MEM_MAX) {
        const char *p = line;
        char *kind, *text;
        total += strlen(line);
        if (total > AI_MEM_BYTES) break;
        if (strncmp(p, "ai.rec[", 7)) continue;
        p += 7;
        while (*p && *p != '"') p++;
        kind = k_string(&p);
        if (!kind) continue;
        while (*p && *p != '"') p++;
        text = k_string(&p);
        free(kind);
        if (!text) continue;
        if (!*text) { free(text); continue; }
        g_mem[g_mem_n++] = text;
    }
    fclose(f);
}

/* \ai sub-commands, so `\ai pro<Tab>` completes.  Kept here rather than in the
 * engine: the engine has no idea this command exists. */
static const char *const AI_SUBS[] = {
    "explain ", "why ", "profile ", "optimize ", "on", "off", "status",
    "memory", "forget", "learn", "model ", "url ", "timeout ", "tabtimeout ",
    "retry", "serve", "tab on", "tab off", "help", NULL
};

/* EARLY source: syntax the engine cannot know about.  Runs before globals and
 * the vocabulary, and short-circuits them when it matches -- which is right,
 * because `\ai pro` can only ever mean an \ai sub-command. */
static void ai_complete(const char *buf, void *lcv) {
    amCompletions *lc = (amCompletions *)lcv;
    size_t len = strlen(buf);
    int i;

    /* (a) the \ai command itself */
    if (buf[0] == '\\' && !strchr(buf, ' ')) {
        if (!strncmp("\\ai ", buf, len) && strcmp("\\ai ", buf))
            am_ln_add_completion(lc, "\\ai ");
        if (lc->len) return;
    }

    /* (b) its sub-commands */
    if (!strncmp(buf, "\\ai ", 4)) {
        const char *rest = buf + 4;
        if (!strchr(rest, ' ') || !strncmp(rest, "tab", 3)) {
            char cand[AI_SUB_CAND];
            for (i = 0; AI_SUBS[i]; i++) {
                if (strncmp(AI_SUBS[i], rest, strlen(rest))) continue;
                if (!strcmp(AI_SUBS[i], rest)) continue;
                if (4 + strlen(AI_SUBS[i]) + 1 >= sizeof cand) continue;
                memcpy(cand, buf, 4);
                strcpy(cand + 4, AI_SUBS[i]);
                am_ln_add_completion(lc, cand);
            }
            if (lc->len) return;
        }
    }

}

/* LATE source: whole lines this user has actually run before, across sessions.
 * Registered as am_ext_complete_late precisely so it runs only after globals,
 * columns, vocabulary and this session's history have all come up empty -- a
 * remembered line must never shadow the name of a table that is in scope right
 * now.  Still instant and still entirely offline: no model is involved. */
static void ai_complete_late(const char *buf, void *lcv) {
    amCompletions *lc = (amCompletions *)lcv;
    size_t len = strlen(buf);
    int m;

    if (len < 2 || buf[0] == '\\') return;
    mem_reload();
    for (m = 0; m < g_mem_n; m++)
        if (!strncmp(g_mem[m], buf, len) && strcmp(g_mem[m], buf))
            am_ln_add_completion(lc, g_mem[m]);
}

/* ======================================================================== */
/* 6.  registration                                                         */
/* ======================================================================== */

static void ai_startup(void) { am_net_init(); }

static const char AI_USAGE[] =
  "\n"
  "amber-ai " AMBER_AI_VERSION " (local model only; AMBER_AI=0 disables it):\n"
  "  \\ai QUESTION       schema-aware code generation for the live session\n"
  "  \\ai explain EXPR   plain-English walk through a terse K expression\n"
  "  \\ai why [ERROR]    diagnose the last error against the actual tables\n"
  "  \\ai profile TABLE  rows, types, attributes, distinct counts + advice\n"
  "  \\ai optimize QUERY faster vector paths\n"
  "  \\ai status         endpoint, model, budgets, learned memory\n"
  "  Tab completes globals, columns, commands and your own past lines; only\n"
  "  when nothing matches does it ask the model, inside a millisecond budget.\n"
  "  Backend:  ollama serve  &  ollama pull qwen2.5-coder:0.5b\n"
  "  Env: AMBER_AI AMBER_AI_TAB AMBER_AI_URL AMBER_AI_MODEL\n"
  "       AMBER_AI_TIMEOUT_MS AMBER_AI_TAB_MS AMBER_AI_MEMORY\n";

__attribute__((constructor))
static void ai_register(void) {
    am_ext_verb("ai",  (void *)aiC);
    am_ext_verb("ais", (void *)aisC);
    am_ext_verb("aio", (void *)aioC);
    am_ext_bs       = ai_bs;
    am_ext_hint     = ai_hint;
    am_ext_complete      = ai_complete;
    am_ext_complete_late = ai_complete_late;
    am_ext_startup  = ai_startup;
    am_ext_usage    = AI_USAGE;
    am_ext_banner   = " [amber-ai " AMBER_AI_VERSION "]";
}
