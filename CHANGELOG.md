# Changelog

## 1.0.0 — first release as a standalone package

`amber-ai` began life as the `\ai` agent inside Amber 2.0.0. This release takes it out of the
engine and makes it what it always should have been: **a separate repository that installs into
an existing Amber with one command, and uninstalls to nothing.**

### Why it was split out

Bundling the agent had three costs, and none of them were paid by the people who wanted it:

* Every Amber user carried an HTTP client, a JSON decoder and a socket in their build, whether or
  not they ever typed `\ai`. "Zero dependencies, zero network" stopped being literally true of
  the engine, and that claim is worth more than the convenience of one repository.
* The agent could not be updated without releasing a new interpreter, and a new interpreter could
  not be released without re-testing the agent.
* Anyone auditing Amber for a trading desk had to read the network code to convince themselves it
  was inert. Now there is no network code to read: `grep -r socket src/` in Amber finds only the
  IPC support that predates 1.9.

The split is total. Amber 1.9.5 is a pure C99 columnar engine with **no AI code and no outbound
network code**; this package adds all of it, through a published seam, without patching a single
line of `src/`.

### Installation: one command, and its exact inverse

```sh
./install.sh /path/to/amber
```

which locates Amber (argument, `$AMBER_HOME`, a sibling `../amber`, `~/amber`, or one on
`PATH`), checks its version and extension ABI, copies three C files into `<amber>/ext/` and
`lib/ai.k` into `<amber>/lib/`, registers the library in `<amber>/lib/ext.k`, re-runs
`<amber>/build.sh`, verifies the `` `ai`` / `` `aio`` verbs and the `\ai` command, re-runs
Amber's own 178-case suite to prove the engine is unaffected, probes `127.0.0.1:11434` and
reports what it found, and prints the exact commands to start using it.

`./uninstall.sh /path/to/amber` deletes the four files, drops the loader line, and rebuilds.
Amber's `build.sh` prunes objects whose source has gone, so the result is a stock binary. The
test suite asserts this: after uninstalling, `\ai` finds nothing and the banner is clean again.

### How it attaches: Amber 1.9.5's extension seam (ABI 1)

Everything registers from a constructor in `src/ai_ext.c` through `<amber>/src/ext.h`:

| seam | used for |
|---|---|
| `am_ext_verb("ai"/"aio", …)` | the two backtick verbs, registered at runtime — Amber's `sym1()` consults the registry before its own fixed table |
| `am_ext_bs` | `\ai …`, claimed ahead of the engine's "unknown `\cmd` is a shell command" fallback |
| `am_ext_hint` | inline ghost text, rendered dim and never inserted until accepted |
| `am_ext_complete` | `\ai` and its sub-commands, ahead of the engine's lexical sources |
| `am_ext_complete_late` | remembered lines, deliberately **after** globals and columns so a recalled line can never shadow a name that is in scope |
| `am_ext_startup` | `am_net_init()`, once, lazily |
| `am_ext_usage` / `am_ext_banner` | `--help` and the REPL banner |
| `ext.pre/post/err/raw/tag` (Amber-level) | per-line hooks in `repl.k`; `ext.raw` is what stops the qSQL rewriter from rewriting the *question* in `\ai optimize select …` before the agent sees it |

### Changes from the bundled 2.0.0 agent

* `src/agent.c` → `src/ai_ext.c`. The `` `rdl`` verb is **gone from this package**: the line
  editor belongs to Amber and ships with it (1.9.5), with or without the agent.
* Tab-completion sources that used to live in Amber's `src/ln.c` moved here: the
  `~/.amber_ai_memory.k` reader and the `\ai` sub-command list. Amber's own editor keeps the
  lexical sources and gained history-based completion in their place.
* The memory source is now registered as `am_ext_complete_late` rather than running before the
  engine's lexical sources — a remembered line no longer shadows a live variable name.
* `ai.BASE`, the "what was already here" snapshot that `ai.ctx[]` subtracts, is taken **after**
  the `ext.*` hooks are defined. Otherwise the agent described its own plumbing to the model as
  if it were the user's data.
* `setup-ai.sh` → `setup-ollama.sh`, and it now locates Amber rather than assuming it is running
  from inside the Amber folder.
* `User-Agent: amber/2.0.0` → `amber-ai/1.0.0`.
* Version reported by `\ai status` is the package's, not the interpreter's.

### Tests

184 assertions across four layers, all runnable with **no GPU, no model weights and no network**:

| suite | cases | |
|---|---|---|
| `tests/test_net.c` | 50 | the transport linked against `src/net.c` **alone**, driving its own loopback server on an ephemeral port: connect deadlines, chunked decoding, JSON extraction from all three response shapes, the circuit breaker |
| `tests/test_ai.k` | 123 | the agent in Amber: switches, memory format / ranking / dedupe / cap, schema harvesting, prompt assembly, every `\ai` sub-command that needs no network, and the graceful-failure path |
| `tests/test_e2e.py` | 11 | the whole package through the **real REPL** against `tests/mock_backend.py`: answers, `\ai why` picking up the previous line's error, ghost text driven on a real **pty**, the off switch, all three response shapes, latency with no backend, and Amber's own suite still passing |
| `tests/run_tests.sh` | — | runs `./install.sh` into a **throwaway copy** of an Amber tree, runs the above, then runs `./uninstall.sh` and asserts no trace is left |

### Guarantees this release commits to

* **One address.** `AMBER_AI_URL`, default `http://127.0.0.1:11434`. No telemetry, no analytics,
  no crash reporting, no third-party host, no hosted fallback, no TLS stack. `AMBER_AI=0` or
  `\ai off` opens no socket at all.
* **It cannot hang the REPL.** Every request carries an absolute deadline covering connect, send
  and the whole receive loop; every wait goes through `poll(2)` against the remaining budget. A
  failed connect arms a 4-second circuit breaker, so a REPL with no backend pays one failed
  connect, not one per keystroke.
* **It cannot break the REPL.** Every entry point is trapped with the rich diagnostic suppressed.
  A missing backend, an unpulled model, a malformed reply or a half-open socket is one friendly
  sentence — never an exception, never a stack trace.
* **It cannot surprise you.** A model suggestion is dim ghost text that a second keystroke
  accepts. Nothing is ever inserted into your line for you.

### Requirements

Amber ≥ 1.9.5 (extension ABI 1), a C compiler, POSIX. A local model backend is optional — without
one the package installs cleanly and is a no-op.
