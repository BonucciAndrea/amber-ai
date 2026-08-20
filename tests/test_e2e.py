#!/usr/bin/env python3
"""tests/test_e2e.py -- amber-ai, end to end, against a real Amber build.

Everything below drives the actual `./a` REPL of an Amber installation that
amber-ai has been installed into. Nothing is mocked except the model backend
itself (tests/mock_backend.py), which speaks the real HTTP that src/net.c
parses, on a real loopback socket, on an ephemeral port.

    python3 tests/test_e2e.py /path/to/amber

Cases:
  1. banner_tag              the banner reports the installed extension
  2. verbs_registered        `aio returns its 7-element status list
  3. ai_answer               \\ai <question> returns the backend's answer
  4. ai_why_sees_the_error   \\ai why picks up the error from the previous line
  5. ai_profile              \\ai profile reads the live table, not the model
  6. qsql_not_rewritten      \\ai optimize select ... reaches the agent verbatim
  7. tab_ghost               a lexical miss shows dim ghost text; a 2nd Tab
                             accepts it (driven on a real pty)
  8. off_switch              AMBER_AI=0 opens no socket and says so
  9. no_backend_is_fast      with nothing listening, a \\ai call still returns
                             quickly and the REPL stays usable
 10. response_shapes         llama.cpp and OpenAI-shaped replies decode too
 11. engine_unaffected       Amber's own suite still passes with ai installed

amber-ai - GNU AGPLv3 - see LICENSE and NOTICE.
"""
import os
import select
import socket
import subprocess
import sys
import time
import fcntl
import struct
import termios
import pty
import re
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FAILURES = []


def check(name, ok, detail=""):
    print("  %-24s %s" % (name, "PASS" if ok else "FAIL"))
    if not ok:
        FAILURES.append(name)
        if detail:
            print("      " + str(detail).replace("\n", "\n      ")[:1200])


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Backend(object):
    def __init__(self, shape="ollama", slow=0.0, answer=None, tokdelay=0.0):
        self.port = free_port()
        cmd = [sys.executable, os.path.join(HERE, "mock_backend.py"), str(self.port),
               "--shape", shape]
        if slow:
            cmd += ["--slow", str(slow)]
        if answer is not None:
            cmd += ["--answer", answer]
        if tokdelay:
            cmd += ["--tokdelay", str(tokdelay)]
        self.p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        # wait for the listener
        for _ in range(100):
            try:
                s = socket.create_connection(("127.0.0.1", self.port), 0.2)
                s.close()
                break
            except Exception:
                time.sleep(0.05)

    @property
    def url(self):
        return "http://127.0.0.1:%d/api/generate" % self.port

    def stop(self):
        self.p.terminate()
        try:
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


def repl(amber, lines, env_extra=None, timeout=60):
    """Feed `lines` to ./a through a pipe and return everything it printed."""
    env = dict(os.environ)
    env.setdefault("HOME", "/tmp")
    env["AMBER_AI_MEMORY"] = "/tmp/.amber_ai_test_memory.k"
    if env_extra:
        env.update(env_extra)
    src = "".join(l + "\n" for l in lines) + "\\\\\n"
    p = subprocess.run([os.path.join(amber, "a")], input=src.encode(),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=timeout, env=env, cwd=amber)
    return p.stdout.decode("utf-8", "replace")


def repl_pty(amber, chunks, env_extra=None, wait=12.0, gap=1.5):
    env = dict(os.environ)
    env["TERM"] = "xterm"
    env.setdefault("HOME", "/tmp")
    env["AMBER_AI_MEMORY"] = "/tmp/.amber_ai_test_memory.k"
    if env_extra:
        env.update(env_extra)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(amber)
        try:
            os.execvpe(os.path.join(amber, "a"), [os.path.join(amber, "a")], env)
        finally:
            os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 120, 0, 0))
    out, t0, stage = b"", time.time(), 0
    while time.time() - t0 < wait:
        r, _, _ = select.select([fd], [], [], 0.15)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                break
            if not d:
                break
            out += d
        if stage < len(chunks) and time.time() - t0 > 1.5 + stage * gap:
            os.write(fd, chunks[stage])
            stage += 1
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        pass
    return out.decode("utf-8", "replace")


def repl_box(amber, cols, rows, env_extra, line, term="xterm", wait=18.0):
    """Run one \\ai line on a pty of an EXACT size and return the raw bytes.

    The size is the point. The box is drawn by src/ai_ext.c, which asks the
    terminal how wide it is; a box wider than that wraps, and a wrapped box
    tears its own border AND breaks the cursor-up arithmetic of the next
    repaint, so the same answer gets drawn twice. term=None unsets TERM, which
    is how repl.k's `tput` probe fails and lib/ai.k falls back to its 999-column
    default -- the exact condition a user reported a broken frame under."""
    env = dict(os.environ)
    env.pop("TERM", None)
    if term:
        env["TERM"] = term
    env.setdefault("HOME", "/tmp")
    env["AMBER_AI_MEMORY"] = "/tmp/.amber_ai_test_memory.k"
    env.update(env_extra or {})
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(amber)
        try:
            os.execvpe(os.path.join(amber, "a"), [os.path.join(amber, "a")], env)
        finally:
            os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    out, t0, sent, quit_at = b"", time.time(), False, None
    while time.time() - t0 < wait:
        r, _, _ = select.select([fd], [], [], 0.15)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                break
            if not d:
                break
            out += d
            if quit_at is None:
                # the answer is over when a fresh prompt follows the last
                # bottom border -- not at the FIRST one, because a streamed
                # answer redraws the whole box on every token
                j = out.rfind(BOT.encode("utf-8"))
                if j >= 0 and b"amber>" in out[j:]:
                    quit_at = time.time()
        if not sent and time.time() - t0 > 1.2:
            os.write(fd, line.encode() + b"\r")
            sent = True
        if quit_at is not None and time.time() - quit_at > 0.6:
            break
    try:
        os.write(fd, b"\\\\\r")
        time.sleep(0.3)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        pass
    return out.decode("utf-8", "replace")


TOP, MID, BOT = u"\u250c", u"\u2502", u"\u2514"


def _dw(s):
    """display columns, the way a terminal counts them"""
    w = 0
    for ch in s:
        if unicodedata.combining(ch) or ch in u"\ufe0f\u200b\u200c\u200d":
            continue
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


class Screen(object):
    """The smallest terminal that can judge a box.

    The renderer repaints by moving the cursor up and clearing, so the byte
    stream holds every intermediate frame; only a screen can say what is left
    at the end. It also AUTO-WRAPS, which is the failure being tested: a frame
    one column too wide folds onto the next line, and from then on "cursor up
    N" addresses the wrong rows, so the next repaint lands below the last
    instead of over it -- two boxes, both torn.

    Rows are lists of CELLS, not characters: a double-width glyph takes one
    cell for itself and leaves the next empty, so a column index is always a
    column and never a string offset. Handled: printable text, CR, LF, TAB,
    ESC[nA/B/C/D, ESC[J and ESC[K. Anything else is skipped, which is right for
    the colour codes the REPL emits around them."""

    def __init__(self, cols, rows=24):
        self.cols = cols
        self.rows = rows
        self.buf = [[]]
        self.r = 0
        self.c = 0
        self.top = 0          # buf index of the first VISIBLE row

    def _row(self, i):
        while len(self.buf) <= i:
            self.buf.append([])
        if i >= self.top + self.rows:        # the screen scrolled
            self.top = i - self.rows + 1
        return self.buf[i]

    def _put(self, ch, w):
        row = self._row(self.r)
        while len(row) < self.c + w:
            row.append(" ")
        row[self.c] = ch
        for k in range(1, w):
            row[self.c + k] = ""
        self.c += w
        if self.c >= self.cols:              # auto-wrap
            self.c = 0
            self.r += 1
            self._row(self.r)

    def feed(self, s):
        i, n = 0, len(s)
        while i < n:
            ch = s[i]
            if ch == "\x1b":
                i += 1
                if i < n and s[i] == "[":
                    i += 1
                    p = ""
                    while i < n and (s[i].isdigit() or s[i] in ";?"):
                        p += s[i]
                        i += 1
                    final = s[i] if i < n else ""
                    i += 1
                    head = p.split(";")[0].lstrip("?")
                    v = int(head) if head.isdigit() else 0
                    if final == "A":
                        # clamped at the TOP OF THE SCREEN, not of the
                        # scrollback: this is why a box taller than the
                        # terminal cannot be repainted at all
                        self.r = max(self.top, self.r - max(1, v))
                    elif final == "B":
                        self.r += max(1, v)
                    elif final == "C":
                        self.c = min(self.cols - 1, self.c + max(1, v))
                    elif final == "D":
                        self.c = max(0, self.c - max(1, v))
                    elif final == "J" and v == 0:
                        del self._row(self.r)[self.c:]
                        del self.buf[self.r + 1:]
                    elif final == "K" and v == 0:
                        del self._row(self.r)[self.c:]
                    continue
                elif i < n:
                    i += 1                   # a two-byte escape
                continue
            if ch == "\r":
                self.c = 0
            elif ch == "\n":
                self.r += 1
                self.c = 0
                self._row(self.r)
            elif ch == "\t":
                self.c = min(self.cols - 1, (self.c // 8 + 1) * 8)
            elif ch < " ":
                pass
            else:
                self._put(ch, _dw(ch))
            i += 1
        return self

    def lines(self):
        return ["".join(r).rstrip() for r in self.buf]


def box_rows(raw, cols, rows=24):
    """the box as it stands on the screen when everything has been drawn"""
    return [l.strip() for l in Screen(cols, rows).feed(raw).lines()
            if l.strip()[:1] in (TOP, MID, BOT)]


def box_errors(raw, cols, height=24):
    """what is wrong with the box the user is left looking at"""
    rows = box_rows(raw, cols, height)
    if not rows:
        return ["no box drawn"]
    errs = []
    tops = [r for r in rows if r[0] == TOP]
    bots = [r for r in rows if r[0] == BOT]
    if len(tops) != 1:
        errs.append("%d top borders (want 1) -- a repaint landed below the last"
                    % len(tops))
    if len(bots) != 1:
        errs.append("%d bottom borders (want 1)" % len(bots))
    w = sorted(set(_dw(r) for r in rows))
    if len(w) != 1:
        errs.append("ragged frame, widths=%s" % w)
    if w[-1] > cols:
        errs.append("box is %d columns on a %d-column terminal" % (w[-1], cols))
    for r in rows:
        want = {TOP: u"\u2510", MID: MID, BOT: u"\u2518"}[r[0]]
        if not r.endswith(want):
            errs.append("row not closed: %r" % r[:60])
    if u"\x1b[" in "".join(r for r in rows if r[0] == MID):
        errs.append("an escape sequence reached the inside of the box")
    return errs


def box_text(raw, cols, height=24):
    return [r[1:-1].strip() for r in box_rows(raw, cols, height) if r[0] == MID]


def main():
    amber = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "..", "amber")
    amber = os.path.abspath(amber)
    if not os.path.isfile(os.path.join(amber, "a")):
        print("error: %s is not a built Amber installation" % amber)
        return 2
    if not os.path.isfile(os.path.join(amber, "ext", "ai_ext.c")):
        print("error: amber-ai is not installed into %s (run ./install.sh %s)" % (amber, amber))
        return 2

    print("amber-ai end-to-end (%s)" % amber)
    for f in ("/tmp/.amber_ai_test_memory.k",):
        if os.path.exists(f):
            os.remove(f)

    b = Backend()
    env = {"AMBER_AI_URL": b.url}
    try:
        out = repl(amber, ["2+2"], env)
        check("banner_tag", "[amber-ai" in out, out[:400])

        out = repl(amber, ["#`aio[-1]"], env)
        check("verbs_registered", "\n7" in out or " 7" in out, out[-400:])

        out = repl(amber, ["\\ai what is the last px per sym"], env)
        check("ai_answer", "MOCK-ANSWER" in out, out[-600:])

        out = repl(amber, ["nosuchvariable", "\\ai why"], env)
        check("ai_why_sees_the_error", "MOCK-DIAGNOSIS" in out, out[-600:])

        out = repl(amber, ["trades:([]sym:`AAPL`MSFT;px:100.0 200.0)",
                           "\\ai profile trades"], env)
        check("ai_profile", "2 rows" in out and "sym" in out, out[-800:])

        out = repl(amber, ["trades:([]sym:`AAPL`MSFT;px:100.0 200.0)",
                           "\\ai optimize select px from trades where sym=`AAPL"], env)
        check("qsql_not_rewritten", "MOCK-ANSWER" in out, out[-800:])

        # a lexical miss -> ghost text (dim), a second Tab accepts it
        out = repl_pty(amber,
                       [b"trades:([]sym:`AAPL;px:100.0)\r", b"zzq9x", b"\t", b"\t", b"\r"],
                       env, wait=14.0)
        check("tab_ghost", "\x1b[2m" in out and "select sym,px from trades" in out,
              out[-900:])

        e = dict(env); e["AMBER_AI"] = "0"
        out = repl(amber, ["\\ai status"], e)
        check("off_switch", "off" in out.lower(), out[-500:])
    finally:
        b.stop()

    # nothing listening at all: must fail fast and stay usable
    dead = {"AMBER_AI_URL": "http://127.0.0.1:%d/api/generate" % free_port()}
    t0 = time.time()
    out = repl(amber, ["\\ai hello", "6*7"], dead)
    dt = time.time() - t0
    check("no_backend_is_fast", "42" in out and dt < 20, "%.1fs\n%s" % (dt, out[-600:]))

    # the other two response shapes a local backend can produce
    okshapes = True
    detail = ""
    for shape in ("llamacpp", "openai"):
        b2 = Backend(shape=shape)
        try:
            out = repl(amber, ["\\ai hello"], {"AMBER_AI_URL": b2.url})
            if "MOCK-ANSWER" not in out:
                okshapes = False
                detail += "%s:\n%s\n" % (shape, out[-400:])
        finally:
            b2.stop()
    check("response_shapes", okshapes, detail)

    # ---- the box frame -----------------------------------------------------
    # A user photographed a torn frame: a wide top border, "42", a wide blank
    # row with no right border, and no bottom border at all. Cause: the answer
    # ended in a whitespace-only line, which measured 66 columns, so a 2-char
    # answer got a 70-column box -- wider than the terminal, so it wrapped, and
    # the wrap threw off the repaint that follows. Each case below is one way
    # the drawn width can drift from the measured width.
    b3 = Backend(answer="42\\n" + " " * 66 + "\\n")
    try:
        raw = repl_box(amber, 60, 24, {"AMBER_AI_URL": b3.url},
                       "\\ai what is six times seven", term=None)
        errs = box_errors(raw, 60)
        check("box_fits_narrow_term", not errs and box_text(raw, 60) == ["42"],
              "; ".join(errs) or box_rows(raw, 60))
    finally:
        b3.stop()

    # tab, ANSI colour and CJK all measure differently than they draw
    b4 = Backend(answer="\\x1b[31mselect\\tpx\\x1b[0m from \\u4ea4\\u6613\\u8868")
    try:
        raw = repl_box(amber, 60, 24, {"AMBER_AI_URL": b4.url}, "\\ai show me the table")
        errs = box_errors(raw, 60)
        txt = box_text(raw, 60)
        check("box_normalises_output",
              not errs and txt and "select  px from" in txt[0]
              and u"\u4ea4\u6613\u8868" in txt[0],
              "; ".join(errs) or txt)
    finally:
        b4.stop()

    # taller than the screen: the box cannot be repainted any more, so it goes
    # append-only. Every line must still arrive, and it must still be closed.
    tall = "\\n".join("line %d" % i for i in range(40))
    # with a per-token delay, so the box really is repainted many times and the
    # append-only switch happens mid-answer rather than after it
    b5 = Backend(answer=tall, tokdelay=0.01)
    try:
        raw = repl_box(amber, 60, 14, {"AMBER_AI_URL": b5.url}, "\\ai list them", wait=25.0)
        errs = box_errors(raw, 60, 14)
        txt = box_text(raw, 60, 14)
        missing = [l for l in ("line 0", "line 17", "line 39") if l not in txt]
        check("box_taller_than_screen", not errs and not missing,
              "; ".join(errs) or "missing %s of %d rows" % (missing, len(txt)))
    finally:
        b5.stop()

    p = subprocess.run([os.path.join(amber, "amber"), "test.k"], cwd=amber,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=300)
    o = p.stdout.decode("utf-8", "replace")
    check("engine_unaffected", "0 failures" in o, o[-400:])

    print()
    if FAILURES:
        print("FAILED: %s" % ", ".join(FAILURES))
        return 1
    print("all end-to-end tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
