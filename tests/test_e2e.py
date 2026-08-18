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
    def __init__(self, shape="ollama", slow=0.0):
        self.port = free_port()
        cmd = [sys.executable, os.path.join(HERE, "mock_backend.py"), str(self.port),
               "--shape", shape]
        if slow:
            cmd += ["--slow", str(slow)]
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
