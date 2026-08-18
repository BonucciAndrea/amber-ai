# Changelog

## 2.0.0 — cross-platform CI, hardened install, and the shell integration

No change to what the agent does; every change here is about it working on machines other than
the one it was written on.

### macOS and strict `-std=c99`

`src/net.c` already carried `_DARWIN_C_SOURCE`, so the extension itself was never the file that
broke — but it is rebuilt *into* Amber by `install.sh`, so an engine that would not compile on
Darwin meant an extension that would not install there either. Amber 1.9.5 now guards every
translation unit that puts itself into strict POSIX mode (`src/m.c`, `a.c`, `arena.c`, `trace.c`)
with `_GNU_SOURCE` / `_DEFAULT_SOURCE` / `_DARWIN_C_SOURCE` above the first `#include`, plus a
`MAP_ANON` → `MAP_ANONYMOUS` fallback. See Amber's own changelog for the full account; the short
version is that defining `_POSIX_C_SOURCE` *hides* BSD extensions on Darwin and does not on glibc,
which is why the failure was invisible on Linux.

### `readlink -f` removed from every script

GNU coreutils only; BSD readlink gained `-f` in macOS 12.3 (2022). `install.sh`, `uninstall.sh`,
`setup-ollama.sh` and `tests/run_tests.sh` all used it to find their own directory, so on an older
Mac they resolved to an empty path and operated on the wrong folder. All four now use an
`am_scriptdir` helper built on POSIX `readlink` plus `cd -P`, verified against a shim that rejects
`-f` exactly as BSD does.

### `install.sh`

* **Toolchain pre-check.** The rebuild needs a C compiler, so a missing one is now caught *before*
  any file is copied, with the exact package command for the platform (`xcode-select --install`,
  `apt-get`, `dnf`, ...) instead of a wall of compiler output after a half-finished install.
* **Homebrew prefix detection.** A shell that has never run `brew shellenv` has neither
  `/opt/homebrew/bin` (Apple Silicon) nor `/usr/local/bin` (Intel) on `PATH`; both are probed.
* **Executable bits.** Repaired across **both** trees before anything else runs.
* **A four-state backend probe.** *Nothing listening* / *live Ollama* / *live Ollama with no models
  pulled* / *port held by something that is not an Ollama* are now four distinct messages with
  four distinct fixes, rather than one "nothing is listening".
* **WSL2 networking.** On WSL2 the installer additionally probes the Windows host via
  `ip route show default`, because WSL2 runs in its own network namespace and Windows' `127.0.0.1`
  is not WSL's — the symptom of which was a "nothing is listening" message pointing at a perfectly
  healthy Ollama on the other side of the boundary. If it finds one it prints the exact
  `AMBER_AI_URL` to export (computed at runtime, since the host IP changes on reboot); if it does
  not, it prints the `OLLAMA_HOST=0.0.0.0` + firewall + `.wslconfig networkingMode=mirrored`
  options.
* **Model-list parsing fixed.** The probe's `sed` required `"name":"x"` with no whitespace, so any
  backend that pretty-prints its JSON produced an empty model list — reported as "no models
  pulled" when the backend was fully populated. It now tolerates whitespace around the colon, and
  `tests/mock_backend.py` emits compact JSON so CI validates the shape users actually see.

### CI

`.github/workflows/ci.yml` now runs on **`ubuntu-latest` and `macos-latest`**, with `gcc` and
`clang` on each (the macOS `gcc` leg installs a real Homebrew GCC and resolves its versioned name
at run time rather than pinning `gcc-14`). `actions/checkout@v4` and `actions/setup-python@v5`
pinned to 3.12.

Because a GitHub runner has no GPU and no Ollama daemon, the integration job starts
`tests/mock_backend.py` on 11434 before the suite. It waits for the listener rather than
`sleep 2` — a blind sleep is both slower than necessary and still racy on a loaded runner — and
fails the job with a clear annotation if the backend never comes up. The mock speaks the real
HTTP that `src/net.c` parses over a real loopback socket, so the transport, the deadlines and the
JSON extraction are genuinely exercised; only the model is fake.

A third `scripts` job runs shellcheck, greps for any reintroduction of `readlink -f`, and asserts
the **executable bit is committed** — every script in the published repository was mode `100644`,
so a fresh clone answered the README's first command with `Permission denied`.

### Documentation

`README.md` gains a Shell integration section, `INSTALL.md` a per-platform alias section that
names the four plausible-but-broken variants and why each fails, and `TROUBLESHOOTING.md` entries
for "the alias does nothing" and for a port that is open but not answering `/api/tags`.


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
