<div align="center">

```
   █████╗ ███╗   ███╗██████╗ ███████╗██████╗       █████╗ ██╗
  ██╔══██╗████╗ ████║██╔══██╗██╔════╝██╔══██╗     ██╔══██╗██║
  ███████║██╔████╔██║██████╔╝█████╗  ██████╔╝     ███████║██║
  ██╔══██║██║╚██╔╝██║██╔══██╗██╔══╝  ██╔══██╗     ██╔══██║██║
  ██║  ██║██║ ╚═╝ ██║██████╔╝███████╗██║  ██║     ██║  ██║██║
  ╚═╝  ╚═╝╚═╝     ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝     ╚═╝  ╚═╝╚═╝
```

**A local, offline AI co-pilot for [Amber](https://github.com/bonucciandrea/amber).**

![version](https://img.shields.io/badge/version-2.0.0-orange)
![requires](https://img.shields.io/badge/requires-amber%20≥%201.9.5-blue)
![license](https://img.shields.io/badge/license-AGPLv3-blue)
![tests](https://img.shields.io/badge/tests-184%20passing-brightgreen)
![network](https://img.shields.io/badge/network-127.0.0.1%20only-informational)

</div>

## What this is

`amber-ai` adds a schema-aware assistant to an Amber REPL you already have. It reads
**your live tables** before it answers — their names, column types, attributes and row counts —
so its suggestions are about your session, not about a generic K tutorial.

```text
amber> trades:gentq 1000000

amber> \ai average price per symbol in the last hour
select avg px by sym from trades where time>.z.p-01:00
```

```text
amber> select last px by sym from trads
error[E0101]: Undefined variable `trads`

amber> \ai why
The name `trads` does not exist. This workspace has `trades`
(table: time:P sym:S`g px:F size:I, 1,000,000 rows) — you are one
character off. `sym` already carries the `g attribute, so the
grouped select will use the index.
```

Four things make it different from pasting your schema into a chat window:

| | |
|---|---|
| **Local only** | The one endpoint it ever contacts is `http://127.0.0.1:11434` — a model server on your machine. No account, no API key, no telemetry, no TLS stack, no hosted fallback. Your schema and your queries do not leave the box. |
| **It cannot hang your REPL** | Every request carries an absolute millisecond deadline that covers connect, send and the whole receive loop. Tab completion gets 100 ms; a failed connect arms a 4-second circuit breaker so a REPL with no backend pays **one** failed connect, not one per keystroke. |
| **It cannot break your REPL** | Every entry point is trapped. No backend, no model pulled, a malformed reply, a half-open socket — each is one friendly sentence, never an exception and never a stack trace. |
| **It does not patch Amber** | It installs through Amber 1.9.5's published extension seam (`src/ext.h`): three files into `ext/`, one into `lib/`, one rebuild. `./uninstall.sh` puts the engine back byte-for-byte. |

## Install

**One command.** You need an Amber 1.9.5+ installation and a C compiler.

```sh
git clone https://github.com/bonucciandrea/amber-ai.git
cd amber-ai
./install.sh /path/to/amber
```

The path is optional — `./install.sh` finds a sibling `../amber`, `$AMBER_HOME`, `~/amber`, or an
`amber` on your `PATH`. It then:

0. checks your platform and toolchain, and prints the exact package command for
   *your* system if a C compiler is missing (the rebuild in step 4 needs one);
1. checks the target's version and extension ABI, and refuses politely if they do not match;
2. copies `src/net.c`, `src/net.h`, `src/ai_ext.c` → `<amber>/ext/`;
3. copies `lib/ai.k` → `<amber>/lib/`, and registers it in `<amber>/lib/ext.k`;
4. runs `<amber>/build.sh`, linking the agent **into the binary you already had**;
5. verifies: the `` `ai`` / `` `aio`` verbs, `\ai`, and Amber's own 178-case suite;
6. repairs the executable bit on every script in **both** trees — a fresh clone can arrive mode
   `644`, in which case `./install.sh` answers with `Permission denied`;
7. probes `127.0.0.1:11434` and tells you exactly what it found — distinguishing *nothing
   listening*, *a live Ollama*, *a live Ollama with no models pulled*, and *something else
   squatting on the port*, each with its own fix. On **WSL2** it additionally probes the Windows
   host (`ip route show default`), because WSL2's `127.0.0.1` is not Windows' — see
   [INSTALL.md](INSTALL.md#wsl2);
8. prints the commands to start using it.

Nothing goes anywhere else. No root, no `PATH` change, no shared object, no `LD_PRELOAD`,
nothing system-wide. Reverse all of it with `./uninstall.sh /path/to/amber`.

**Then start a model.** Any local backend that speaks Ollama, llama.cpp or an OpenAI-compatible
`/v1` endpoint will do:

```sh
curl -fsSL https://ollama.com/install.sh | sh    # linux / wsl2  (macOS: brew install ollama)
ollama serve &
ollama pull qwen2.5-coder:0.5b                   # ~400 MB, runs on a laptop CPU
```

or run `./setup-ollama.sh`, which walks through the same thing and asks before every system
change. **[INSTALL.md](INSTALL.md)** has step-by-step guides for **WSL2** (including CUDA and
port forwarding), **macOS** (Apple Silicon and Intel) and **Linux** (Ubuntu/Debian and
RHEL/Fedora, with systemd). **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** covers port 11434
already being in use, terminal rendering, and custom endpoints.

Without a backend the agent is a **no-op**: it says so once, and the REPL is exactly Amber.

## Shell integration

`amber`'s own `install.sh` writes a managed block into your shell rc. Add the AI alias to it — or
let `amber/install.sh` write the whole block for you, which already includes this line:

```sh
# Where Amber lives. The launcher is $AMBER_HOME/a -- there is no bin/ directory
# and no separate `amber` wrapper on PATH unless you make one.
export AMBER_HOME="$HOME/amber"
export PATH="$AMBER_HOME:$PATH"

# amber -> the plain REPL. AMBER_THREADS sizes the peach worker pool; leave it
# unset to let the engine pick, or pin it on a shared box.
alias amber='AMBER_NATIVE=1 "$AMBER_HOME/a"'
alias amberx='"$AMBER_HOME/amber"'       # bare interpreter, for scripts and pipes

# amber-ai -> the full REPL with the local co-pilot pointed at your model server.
# lib/ai.k is loaded automatically by repl.k via lib/ext.k, so it must NOT be
# passed as a script argument. The 10000 ms budget is now the compiled-in
# default too; it is repeated here so the alias is self-documenting.
alias amber-ai='AMBER_NATIVE=1 AMBER_AI=1 AMBER_AI_URL="http://127.0.0.1:11434/api/generate" AMBER_AI_TIMEOUT_MS=10000 "$AMBER_HOME/a"'

# Agent off for one session, without editing anything:
alias amber-noai='AMBER_AI=0 "$AMBER_HOME/a"'
```

Three things that look like they should work and do not:

* **Do not pass `lib/ai.k` as an argument.** `amber $AMBER_HOME/lib/ai.k` runs the agent library
  as a *script* and exits. `repl.k` already loads it through `lib/ext.k` at startup; the alias only
  has to start the REPL.
* **Alias the launcher `a`, not the `amber` binary.** The bare binary has no stdlib and no
  `repl.k`, so `\ai` — which is dispatched by `repl.k` — does not exist there.
* **There is no `$AMBER_HOME/bin/`.** Amber builds in place: the binary is `$AMBER_HOME/amber` and
  the launcher beside it is `$AMBER_HOME/a`. Putting `$AMBER_HOME` itself on `PATH` is what makes
  `a` runnable from anywhere. There is likewise no `AMBER_MEM_MB`; the heap is sized by the engine,
  and the tunable that does exist is `AMBER_THREADS`.

### Big models: warm them once

A 7B on CPU generates a few tokens a second, so a 128-token answer can take 30s
while a 0.5B does it in 4 — and Ollama unloads an idle model after five minutes,
so the load is paid again and again inside the same deadline. Two things fix it:

```text
amber> \ai warm            # load the model now, on its own budget, and measure
```

`\ai warm` asks for a single token, so it returns as soon as the weights are
resident rather than when an answer is finished. It then times a short
generation and, if your measured tokens/sec cannot produce a full answer inside
the current budget, raises the budget and says so. It measures your machine
rather than guessing from the model's name.

Every request also carries `keep_alive`, so the backend holds the model for 30
minutes after each call. No `OLLAMA_KEEP_ALIVE` in the server environment, no
restart of `ollama serve`:

```sh
export AMBER_AI_KEEP_ALIVE=1h     # or "0" to unload at once, "-1" for forever
export AMBER_AI_NUM_PREDICT=48    # generation dominates; fewer tokens, faster
```

`AMBER_AI_NUM_PREDICT` is the biggest single lever after the load: the answer is
an expression plus two short lines, so 48 is usually plenty and cuts the wait by
more than half.

The answer budget defaults to 10000 ms. The *first* question after a cold start can still exceed
it while the backend loads weights, so raise it in any of three scopes:

```text
amber> \ai timeout 30000            # this session
```
```sh
export AMBER_AI_TIMEOUT_MS=30000     # every session (overrides the 10000 default)
```
```text
amber> `aio[(2;30000)]               # programmatic; key 2 is the answer budget
```

Leave the **Tab** budget small (`AMBER_AI_TAB_MS`, default 100 ms): it runs on the keystroke path,
so raising it makes typing feel laggy. `\ai status` shows both.

## Using it

### `\ai` commands

| command | what it does |
|---|---|
| `\ai <question>` | schema-aware code generation for **this** session |
| `\ai explain <expr>` | unpack a terse K expression, innermost first |
| `\ai why [error]` | diagnose the last (or a given) error against your real tables |
| `\ai profile <table>` | rows, column types, attributes, distinct counts + indexing advice |
| `\ai optimize <query>` | faster vector paths for a query |
| `\ai status` | endpoint, model, budgets, what it has learned, live workspace |
| `\ai memory` / `\ai learn` / `\ai forget` | inspect / extend / erase the persistent memory |
| `\ai on` \| `\ai off` | master switch (default **on**) |
| `\ai tab on` \| `\ai tab off` | inline Tab suggestions (default **on**) |
| `\ai model <name>` \| `\ai url <endpoint>` | switch model / endpoint for this session |
| `\ai timeout <ms>` \| `\ai tabtimeout <ms>` | answer / Tab budgets |
| `\ai retry` | forget a dead endpoint and try it again now |
| `\ai serve` | start a local ollama in the background (hosts without systemd) |
| `\ai help` | all of the above |

`\ai profile` and `\ai why` read your **actual** workspace first — the row counts, types and
attributes in their output are measured, not generated.

### Tab

Tab is layered so the network is the **last** resort, and usually never reached:

1. **lexical** — globals in your workspace, table column names, `\` commands, `\ai`
   sub-commands, the Amber/K vocabulary. Instant, offline. *(Amber's own, present without this
   package.)*
2. **memory** — whole lines you have actually run before, mined from `~/.amber_ai_memory.k`.
   Instant, offline, and what makes the REPL feel like it has learned your habits.
3. **model** — only when 1 and 2 find nothing, only when the agent is on, and only inside
   `AMBER_AI_TAB_MS` (default 100 ms).

A model suggestion is rendered as **dim ghost text after the cursor** and is *never* inserted
until you accept it with a second `Tab` (or `→`, or `Ctrl-F`). Any other keystroke discards it.
Accepted suggestions are recorded as feedback.

```text
amber> select avg px by sym from tr█ades where sym=`AAPL      <- dim = suggested, not typed
```

### Persistent memory

A local model cannot be fine-tuned while you type, so "learning" here means **persistent
few-shot context**. Every line that ran cleanly, every schema this workspace has held and every
accepted Tab suggestion is appended to `~/.amber_ai_memory.k`, one self-describing Amber
expression per line:

```k
ai.rec["q";1755512345;3;"select sym,px from trades";"trades quotes"]
/       kind  epoch-s  hits  text                    context
```

Loading it is simply evaluating it, so it stays human-readable and hand-editable. `\ai memory`
shows it, `\ai forget` erases it, `AMBER_AI_MEMORY=/path` moves it (per-project memories work),
and deleting the file is always safe.

### Environment

| variable | default | |
|---|---|---|
| `AMBER_AI` | `1` | `0` disables the agent entirely — no socket is ever opened |
| `AMBER_AI_TAB` | `1` | `0` disables model Tab suggestions only |
| `AMBER_AI_URL` | `http://127.0.0.1:11434/api/generate` | the only address ever contacted |
| `AMBER_AI_MODEL` | `qwen2.5-coder:0.5b` | any model your backend has |
| `AMBER_AI_TIMEOUT_MS` | `10000` | answer budget |
| `AMBER_AI_TAB_MS` | `100` | Tab budget; drop below 50 for an invisible keystroke cost |
| `AMBER_AI_KEEP_ALIVE` | `30m` | how long the backend keeps the model resident |
| `AMBER_AI_NUM_PREDICT` | `128` | max tokens generated per answer |
| `AMBER_AI_NUM_CTX` | `512` | context the backend allocates |
| `AMBER_AI_MEMORY` | `~/.amber_ai_memory.k` | where memory lives |

## Architecture

```
   YOUR MACHINE                                    (nothing leaves it)
   ┌──────────────────────────────────────────┐    ┌──────────────────┐
   │  amber (one binary, rebuilt with ext/)   │    │  ollama /        │
   │                                          │    │  llama.cpp       │
   │   repl.k ──► lib/ai.k                    │    │  127.0.0.1:11434 │
   │              │  decides everything:      │    └────────▲─────────┘
   │              │  schema, prompts, \ai,    │             │
   │              │  diagnostics, memory      │      plain HTTP/1.1
   │              ▼                           │      non-blocking,
   │   ext/ai_ext.c  ── the joints ───────────┼───►  hard deadline
   │              │   `ai `aio \ai hints      │             │
   │              ▼                           │             │
   │   ext/net.c     transports everything ───┼─────────────┘
   │                                          │
   │   src/ext.h     Amber's seam (unmodified)│
   └──────────────────────────────────────────┘
```

| file | |
|---|---|
| `lib/ai.k` | the agent, **written in Amber**: schema harvester, prompt builder, `\ai` command table, the `why` / `profile` / `optimize` engines, persistent memory. Everything that *decides*. |
| `src/net.c`, `src/net.h` | ~690 lines of C99 + POSIX: a non-blocking HTTP/1.1 client where every wait goes through `poll(2)` against a remaining budget. No third-party library, no TLS, no DNS. Decodes all three response shapes a local backend can produce. Everything that *transports*. |
| `src/ai_ext.c` | the joints, and nothing else: registers `` `ai``, `` `aio``, the `\ai` command, the editor hint and the memory-backed completion source through Amber's `src/ext.h`. The **only** file that knows Amber's internals. |
| `install.sh` / `uninstall.sh` | the one-command installer and its exact inverse |
| `setup-ollama.sh` | optional, interactive backend setup — the one script here that touches your system |
| `tests/` | see below |

**Why an extension and not a fork.** Amber 1.9.5 publishes a small, neutral seam (a runtime verb
registry, a `\`-command hook, editor hooks, a startup hook). `install.sh` drops files into `ext/`
and rebuilds; Amber's `build.sh` compiles them with the same flags into the same binary and its
`repl.k` loads `lib/ext.k` if it exists. **No file in Amber's `src/` is modified**, so pulling a
new Amber release can never conflict with this package, and an Amber user who does not install it
pays nothing — every hook is a null pointer.

## Tests

```sh
tests/run_tests.sh /path/to/amber     # everything
tests/run_tests.sh --quick            # the C transport tests only, no install needed
```

| suite | cases | what it proves |
|---|---|---|
| `tests/test_net.c` | 50 | the transport, linked against `src/net.c` **alone**, driving its own loopback server on an ephemeral port: connect deadlines, chunked decoding, JSON extraction from all three shapes, the circuit breaker. No backend, no fixed port. |
| `install.sh` into a copy | — | the installer is run for real, into a throwaway copy of an Amber tree (never yours) |
| `tests/test_ai.k` | 123 | the agent in Amber: switches, memory format/ranking/dedupe/cap, schema harvesting, prompt assembly, every `\ai` sub-command that needs no network, and the graceful-failure path (aimed at the closed discard port, so it cannot block) |
| `tests/test_e2e.py` | 11 | the whole thing through the **real REPL** against `tests/mock_backend.py`: answers, `\ai why` picking up the previous error, ghost text on a real **pty**, the off switch, all three response shapes, timing with no backend, and that Amber's own 178-case suite still passes |
| `./uninstall.sh` | — | the engine is stock again, with no trace left |

`tests/mock_backend.py` speaks the real HTTP that `src/net.c` parses, on a real socket, so the
whole suite runs on a laptop or in CI with **no GPU, no model weights and no network**.

## Privacy, in one paragraph

The only address ever contacted is `AMBER_AI_URL`, which defaults to loopback. There is no
telemetry, no crash reporting, no analytics, no third-party host, no TLS stack and no fallback to
a hosted API — grep `src/net.c` for `connect` and there is exactly one, to the address you
configured. `AMBER_AI=0`, or `\ai off`, and not a single socket is opened. Your schema, your
queries and your memory file stay on your machine.

## Requirements

* **Amber ≥ 1.9.5** (extension ABI 1) — [github.com/bonucciandrea/amber](https://github.com/bonucciandrea/amber)
* a C compiler (`gcc` or `clang`); POSIX (Linux, WSL2, macOS)
* optional, for answers: a local model backend — Ollama, `llama.cpp` server, or anything
  OpenAI-compatible on loopback

## Licence

GNU AGPLv3 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Amber's interpreter core derives from
[ngn/k](https://codeberg.org/ngn/k); that attribution is preserved in `NOTICE`, as the licence
requires.
