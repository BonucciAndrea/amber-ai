# Troubleshooting `amber-ai`

Organised by symptom. Every command here is safe to run and changes nothing unless it says so.

**Start here**

```sh
./setup-ollama.sh --check        # reports the whole picture; changes nothing, needs no root
```

```text
amber> \ai status                # what Amber itself believes
```

**Contents**

* [Port 11434: `bind: address already in use`](#port-in-use)
* [Nothing answers / `no backend` / `\ai` says it cannot connect](#no-backend)
* [Terminal and formatting problems](#terminal)
* [Custom endpoints with `AMBER_AI_URL`](#custom-endpoints)
* [Install and build problems](#install-problems)
* [Answer quality, latency and Tab behaviour](#quality)
* [Memory file problems](#memory)
* [Getting a clean report](#clean-report)

---

<a name="port-in-use"></a>
## Port 11434: `bind: address already in use`

```text
Error: listen tcp 127.0.0.1:11434: bind: address already in use
```

This almost always means **Ollama is already running** — as a systemd service, a macOS login
item, a Docker container, or a shell you forgot. It is not usually an error you need to fix; it
is a second copy failing to start. Find out what holds the port:

```sh
# linux / wsl2
sudo ss -lptn 'sport = :11434'
sudo lsof -iTCP:11434 -sTCP:LISTEN -P -n

# macos
lsof -iTCP:11434 -sTCP:LISTEN -P -n
```

### It is Ollama, and that is fine

```sh
curl -s http://127.0.0.1:11434/api/tags     # a JSON model list = it is healthy
```

You are done — do not start a second one. `\ai retry` in the REPL clears any circuit breaker.

### It is Ollama, but a stale or duplicated instance

```sh
# with systemd, prefer the service over a hand-started copy
sudo systemctl stop ollama
pgrep -af 'ollama serve'                     # any leftovers?
pkill -f 'ollama serve'                      # stop them
sudo systemctl start ollama
systemctl is-active ollama
```

macOS:

```sh
brew services restart ollama
# or, if you installed the app: quit it from the menu bar and reopen it
```

### It is something else entirely

Move Ollama, do not fight for the port:

```sh
OLLAMA_HOST=127.0.0.1:11500 ollama serve &
```

Permanently, with systemd:

```sh
sudo systemctl edit ollama
```

```ini
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11500"
```

```sh
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

Then tell Amber:

```text
amber> \ai url http://127.0.0.1:11500/api/generate
amber> \ai retry
amber> \ai status
```

or permanently:

```sh
export AMBER_AI_URL=http://127.0.0.1:11500/api/generate    # add to ~/.bashrc / ~/.zshrc
```

### A Docker container has the port

```sh
docker ps --filter publish=11434
docker stop <name>                 # or run it on another host port:
docker run -d -p 11500:11434 --name ollama ollama/ollama
```

Then `\ai url http://127.0.0.1:11500/api/generate`.

### WSL2: bound in the wrong namespace

WSL2 has its own loopback. Something bound on Windows' `127.0.0.1:11434` does **not** occupy
WSL's, and vice versa — so "in use" and "nothing there" can both be true at the same time,
depending on which side you look from. See
[INSTALL.md → WSL2 → Ports and 127.0.0.1](INSTALL.md#wsl2) for the three layouts and how to point
Amber at the right one.

---

<a name="no-backend"></a>
## Nothing answers

```text
amber> \ai hello
ai: no backend is listening on http://127.0.0.1:11434/api/generate
    ollama does not look installed. One-time setup, from the amber-ai folder:
      bash setup-ollama.sh      installs ollama, pulls the model, verifies
```

Work down this list; each step is one command.

**1. Is anything listening?**

```sh
curl -sv http://127.0.0.1:11434/api/tags 2>&1 | head -20
```

*Connection refused* → nothing is running. Start it:

```sh
sudo systemctl start ollama      # linux / wsl2 with systemd
brew services start ollama       # macos
ollama serve &                   # anywhere
```

or, from inside the REPL: `\ai serve`.

**2. Is the model pulled?** A running server with no weights answers HTTP but fails the
generation:

```sh
ollama list
ollama pull qwen2.5-coder:0.5b
```

If you use a different model, tell Amber: `\ai model <name>`.

**3. Is the agent switched off?**

```text
amber> \ai status
  agent      : off
amber> \ai on
```

Also check the environment — `AMBER_AI=0` disables it before anything else runs:

```sh
env | grep AMBER_AI
```

**4. Is the circuit breaker holding it back?** After a refused connect, `amber-ai` suppresses
further attempts for 4 seconds so Tab never stalls repeatedly against a dead endpoint. If you
just started the backend:

```text
amber> \ai retry
```

**5. Is the budget too tight for a cold model?** The first request after a pull loads weights
into RAM and can take many seconds; the default answer budget is 2000 ms.

```sh
ollama run qwen2.5-coder:0.5b "hi"      # warm it up outside Amber
```

```text
amber> \ai timeout 8000
amber> \ai hello
amber> \ai timeout 2000                 # put it back once warm
```

**6. Is the endpoint path right?** Ollama is `/api/generate`; llama.cpp is `/completion`;
OpenAI-compatible servers are `/v1/chat/completions`. `\ai status` shows what you are using.

**7. Is a proxy in the way?** `http_proxy` / `HTTP_PROXY` do not affect `src/net.c` (it connects
directly, with no proxy support at all), but they *do* affect `curl`, so a `curl` test can fail
while Amber succeeds — or the reverse, if your proxy intercepts loopback:

```sh
env | grep -i proxy
NO_PROXY=127.0.0.1,localhost curl -s http://127.0.0.1:11434/api/tags
```

---

<a name="terminal"></a>
## Terminal and formatting problems

### The prompt is garbled, or every error is followed by an `rlwrap` warning

```text
rlwrap: warning: rlwrap appears to do nothing for amber, which asks for
single keypresses all the time ...
```

**You are running Amber under `rlwrap`. Stop.** Since Amber 1.9.5 the REPL has its own line
editor and handles the terminal itself, which is exactly what `rlwrap` cannot wrap — so it prints
that warning across stdout and stderr, and then the two editors fight over one cursor.

```sh
grep -rn rlwrap ~/.bashrc ~/.zshrc ~/.profile ~/.aliases 2>/dev/null
alias | grep -i amber
```

Remove any `rlwrap` from the alias, wrapper script, `.desktop` entry or tmux command, and start
Amber with `./a`. If you genuinely need canonical-mode reads (a screen reader, a dumb terminal,
an editor subshell), `AMBER_NO_EDIT=1 ./a` turns the native editor off — and `./a` then invokes
`rlwrap -n -a` for you, which is silent.

### Ghost text shows as literal escape codes, or the suggestion will not go away

The dim suggestion uses `ESC [ 2 m`. A terminal that does not support it shows garbage.

```sh
echo $TERM                                    # xterm-256color, screen-256color, ... good
TERM=xterm-256color ./a
```

Or turn model suggestions off and keep the instant lexical ones:

```text
amber> \ai tab off
```

Any keystroke other than Tab / `→` / `Ctrl-F` discards a suggestion; `Ctrl-L` repaints the screen.

### Columns wrap wrongly, or the line jumps after a resize

The editor reads the width with `TIOCGWINSZ` on every refresh, so a resize is picked up on the
next keystroke. Over `ssh`, `screen` or `tmux` a stale size can persist:

```sh
stty size            # rows cols -- should match the window
resize >/dev/null    # xterm: re-query and export the real size
```

Inside `tmux`, make sure it is not forcing a smaller pane width than the client.

### Output is monochrome, or full of `[1;91m` sequences

Amber's colour comes from its own renderer, not from this package:

```text
amber> COLOR:0        / turn colour off
amber> COLOR:1        / and back on
```

If you are piping Amber's output to a file or a pager, `[1;91m` in the file is expected — pipe
through `sed -r 's/\x1b\[[0-9;]*m//g'`, or set `COLOR:0`.

### `\ai` output is wrapped oddly, or a table renders badly next to it

The agent prints plain lines; table rendering is Amber's:

```text
amber> \grid clean          / clean | rounded | sharp | heavy
amber> CROWS:20             / preview rows
amber> PREC:4               / float decimals
```

### Non-ASCII in an answer looks wrong

The editor is byte-oriented, so a multi-byte character is edited as its bytes. Answers print
through Amber's normal output path and are fine; only *editing* a line containing multi-byte
characters can move the cursor by a byte rather than a glyph. Ask the model for ASCII if it
matters:

```text
amber> \ai reply in plain ASCII: explain this expression +/!10
```

---

<a name="custom-endpoints"></a>
## Custom endpoints with `AMBER_AI_URL`

`AMBER_AI_URL` is the **only** address `amber-ai` ever contacts. It is read once at startup and
can be changed at any time from the REPL.

```sh
export AMBER_AI_URL=http://127.0.0.1:11434/api/generate     # ollama (default)
export AMBER_AI_URL=http://127.0.0.1:8080/completion        # llama.cpp server
export AMBER_AI_URL=http://127.0.0.1:8000/v1/chat/completions   # openai-compatible
export AMBER_AI_MODEL=qwen2.5-coder:7b
```

At runtime, for this session only:

```text
amber> \ai url http://127.0.0.1:8080/completion
amber> \ai model qwen2.5-coder:7b
amber> \ai retry
amber> \ai status
```

Rules and limits:

* **`http://` only.** There is no TLS stack in this package, deliberately — a loopback model
  server does not need one, and adding it would mean adding a dependency. An `https://` URL is
  rejected with `AMBER_AI_URL is not a usable http:// URL`.
* **Host and port are used literally**; there is no proxy support and no redirect following.
* **The path matters.** Sending Ollama's `/api/generate` body to llama.cpp's `/completion` gets
  you a non-2xx, reported as `the backend answered with a non-2xx status`.
* **Any response shape works**: `{"response":...}` (Ollama), `{"content":...}` (llama.cpp),
  `{"choices":[{"message":{"content":...}}]}` or `{"text":...}` (OpenAI-compatible).
* **A remote host is allowed but is no longer private.** Setting this to another machine means
  your schema and queries go to that machine. `\ai status` always shows the address in use, so
  you can check at a glance.

Per-project settings work well in a shell rc or a `direnv` file:

```sh
# .envrc
export AMBER_AI_URL=http://127.0.0.1:11500/api/generate
export AMBER_AI_MODEL=qwen2.5-coder:7b
export AMBER_AI_MEMORY=$PWD/.amber_ai_memory.k     # a memory scoped to this project
export AMBER_AI_TIMEOUT_MS=6000
```

---

<a name="install-problems"></a>
## Install and build problems

### `could not find an Amber installation`

Pass the path explicitly. An Amber installation is the folder containing `src/a.h`, `build.sh`
and `repl.k`:

```sh
./install.sh /path/to/amber
```

### `that Amber has no extension seam (src/ext.h is missing)`

Your Amber predates 1.9.5:

```sh
cd /path/to/amber && git pull && ./build.sh && ./amber --version
```

### `extension ABI mismatch`

The two repositories have drifted. Update whichever is older — `AMBER_EXT_ABI` in
`<amber>/src/ext.h` must equal the `NEED_ABI` in `install.sh`.

### The rebuild fails

```sh
sudo apt-get install -y build-essential      # debian / ubuntu / wsl2
xcode-select --install                       # macos
sudo dnf install -y gcc make                 # fedora / rhel
```

Then, for the real error:

```sh
cd /path/to/amber && ./build.sh
```

Nothing is left half-installed by a failed build — `./uninstall.sh /path/to/amber` removes the
copied files and rebuilds a stock engine.

### `\ai` runs a shell command instead of the agent

```text
amber> \ai status
sh: 1: ai: not found
```

The extension is not in the binary. Either the rebuild did not happen or `ext/ai_ext.c` is
missing:

```sh
ls /path/to/amber/ext/
cd /path/to/amber && ./build.sh              # look for "+ extensions: ai_ext net"
printf '#`aio[-1]\n\\\\\n' | ./a             # should print 7
```

### `\ai` answers `the agent could not run. If lib/ai.k is not loaded ...`

The C half linked but the Amber half did not load:

```sh
ls /path/to/amber/lib/ai.k /path/to/amber/lib/ext.k
cat /path/to/amber/lib/ext.k                 # must reference lib/ai.k by absolute path
```

Load it by hand to see the real error:

```text
amber> \l lib/ai.k
```

Re-running `./install.sh` rewrites both files.

### Amber's own tests fail after installing

They should not — `install.sh` and `tests/run_tests.sh` both check exactly this. Report it, and
meanwhile:

```sh
./uninstall.sh /path/to/amber
cd /path/to/amber && ./amber test.k          # confirm the engine alone is clean
```

---

<a name="quality"></a>
## Answer quality, latency and Tab behaviour

**Answers are vague or wrong.** A 0.5B model is small. Give it more to work with, or a bigger
model:

```text
amber> \ai learn                    / record the current schema into memory
amber> \ai profile trades           / measured facts, no model involved
amber> \ai model qwen2.5-coder:7b
amber> \ai timeout 6000
```

`\ai profile` and the row counts in `\ai status` are read from your live workspace, not
generated, so they are always correct regardless of the model.

**The first answer is slow, the rest are fast.** The backend loads weights on first use. Raise
`OLLAMA_KEEP_ALIVE` (e.g. `30m`) so it stops unloading between questions.

**Tab feels slow.** Only the third layer touches the model, inside `AMBER_AI_TAB_MS`
(default 100 ms). Lower it, or switch model suggestions off entirely:

```text
amber> \ai tabtimeout 40
amber> \ai tab off
```

**Tab suggests nothing.** That is the design: the model is only asked when the lexical sources
and your history find nothing, the cursor is at end of line, and the line is at least three
characters and not a `\` command.

**A suggestion was inserted that I did not want.** Nothing is inserted until you press Tab, `→`
or `Ctrl-F` a second time; any other key discards it. `Ctrl-W` removes the last word,
`Ctrl-U` the whole line.

---

<a name="memory"></a>
## Memory file problems

`~/.amber_ai_memory.k` is plain text, one Amber expression per line, and is always safe to
inspect, edit or delete.

```text
amber> \ai memory        / what it has learned
amber> \ai forget        / erase it
```

```sh
wc -l ~/.amber_ai_memory.k
tail -5 ~/.amber_ai_memory.k
rm ~/.amber_ai_memory.k          # equally fine
```

**It contains something I do not want kept.** Delete the line, or the file. Records are capped at
400 and the file is only ever read locally — but a question you asked *was* sent to your
configured endpoint at the time you asked it.

**Per-project memory:** `export AMBER_AI_MEMORY=$PWD/.amber_ai_memory.k`.

**Two REPLs at once:** each writes its own view on exit, so the last one to close wins. Use
separate `AMBER_AI_MEMORY` paths if that matters.

---

<a name="clean-report"></a>
## Getting a clean report

If you need to open an issue, this is the useful set:

```sh
cd /path/to/amber && ./amber --version
grep AMBER_EXT_ABI src/ext.h
ls ext/ lib/
uname -a
cc --version | head -1
env | grep AMBER
```

```text
amber> \ai status
```

```sh
cd /path/to/amber-ai && ./setup-ollama.sh --check
tests/run_tests.sh /path/to/amber 2>&1 | tail -40
```

Please include what you expected, what happened, and whether `./uninstall.sh` restores normal
behaviour — that last one separates an engine problem from an extension problem immediately.
