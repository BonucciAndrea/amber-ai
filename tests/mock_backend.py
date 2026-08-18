#!/usr/bin/env python3
"""tests/mock_backend.py -- a stand-in for a local Ollama / llama.cpp server.

The point of this file is that amber-ai's end-to-end tests must be runnable on
a laptop, in CI and inside a container with no GPU, no model weights and no
network -- while still exercising the real socket, the real HTTP framing and
the real JSON extraction in src/net.c. So this speaks exactly the subset of the
Ollama API that amber-ai uses, on loopback, and answers deterministically.

    python3 tests/mock_backend.py [port] [--shape ollama|llamacpp|openai]

Endpoints:
    GET  /api/tags       the model list, so install.sh's probe finds something
    POST /api/generate   a generation; the reply SHAPE is configurable, because
                         src/net.c must decode all three that a local backend
                         can produce, and a bug there is invisible against a
                         single shape

Answers:
    a prompt containing "Continuation:"  -> a Tab-completion continuation
    a prompt mentioning an error         -> a diagnosis line
    anything else                        -> a canned answer

Every reply is prefixed MOCK- so a test can never mistake it for a real model's
output, and --slow lets a test drive the deadline path in src/net.c.

amber-ai - GNU AGPLv3 - see LICENSE and NOTICE.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = {"models": [{"name": "qwen2.5-coder:0.5b"}, {"name": "llama3.2:1b"}]}

SHAPE = "ollama"
DELAY = 0.0

ANSWER_TAB = "select sym,px from trades"
ANSWER_WHY = "MOCK-DIAGNOSIS: that name is not defined in this workspace."
ANSWER_ANY = "MOCK-ANSWER: select last px by sym from trades"


def envelope(text, model):
    if SHAPE == "llamacpp":
        return {"content": text}
    if SHAPE == "openai":
        return {"choices": [{"message": {"content": text}}]}
    return {"model": model, "response": text, "done": True}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/api/tags"):
            self._send(MODELS)
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace")
        try:
            req = json.loads(raw)
        except Exception:
            req = {}
        prompt = req.get("prompt") or ""
        if DELAY:
            time.sleep(DELAY)
        if "Continuation:" in prompt:
            text = ANSWER_TAB
        elif "error" in prompt.lower() or "diagnos" in prompt.lower():
            text = ANSWER_WHY
        else:
            text = ANSWER_ANY
        self._send(envelope(text, req.get("model", "mock")))


def main():
    global SHAPE, DELAY
    port = 11434
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--shape":
            i += 1
            SHAPE = args[i]
        elif a.startswith("--shape="):
            SHAPE = a.split("=", 1)[1]
        elif a == "--slow":
            i += 1
            DELAY = float(args[i])
        elif a.startswith("--slow="):
            DELAY = float(a.split("=", 1)[1])
        else:
            port = int(a)
        i += 1
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write("mock_backend: 127.0.0.1:%d shape=%s\n" % (port, SHAPE))
    sys.stderr.flush()
    srv.serve_forever()


if __name__ == "__main__":
    main()
