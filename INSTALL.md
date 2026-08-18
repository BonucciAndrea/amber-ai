# Installing `amber-ai` — per-OS guides

`amber-ai` has two halves, and they install separately:

1. **the extension** — three C files and one Amber file copied into an existing Amber
   installation, then one rebuild. Pure source, no root, nothing system-wide.
   This is `./install.sh` and it takes about twenty seconds.
2. **a local model backend** — Ollama (recommended), a `llama.cpp` server, or anything
   OpenAI-compatible listening on loopback. This is the part that differs per OS, and it is the
   part this document is mostly about.

You can do them in either order. Without a backend the extension installs cleanly and is simply a
no-op until one appears.

**Contents**

* [Common prerequisites](#common-prerequisites)
* [WSL2 (Windows Subsystem for Linux)](#wsl2)
* [macOS (Apple Silicon and Intel)](#macos)
* [Linux (Ubuntu / Debian)](#linux-ubuntu--debian)
* [Linux (RHEL / Fedora / Rocky / Alma)](#linux-rhel--fedora)
* [Alternative backends](#alternative-backends-llamacpp-openai-compatible)
* [Verifying the install](#verifying-the-install)
* [Uninstalling](#uninstalling)

---

<a name="common-prerequisites"></a>
## Common prerequisites

**Amber ≥ 1.9.5, built.** `amber-ai` plugs into the extension seam introduced in 1.9.5
(`src/ext.h`, ABI 1). Check:

```sh
cd /path/to/amber && ./amber --version      # amber 1.9.5  or newer
grep AMBER_EXT_ABI src/ext.h                # #define AMBER_EXT_ABI 1
```

If `src/ext.h` does not exist, your Amber predates the seam:

```sh
cd /path/to/amber && git pull && ./build.sh
```

**A C compiler.** The installer rebuilds Amber, so whatever built Amber will do.

**Disk and memory for the model.** `qwen2.5-coder:0.5b` is ~400 MB and runs on a laptop CPU;
`qwen2.5-coder:7b` is ~4.7 GB and wants a GPU or a lot of patience. Start with the small one —
for schema-shaped questions it is usually enough.

---

<a name="wsl2"></a>
## WSL2 (Windows Subsystem for Linux)

Everything below runs **inside** the WSL2 Linux distribution, not in PowerShell, unless a step
says otherwise. Amber, `amber-ai` and Ollama all live on the Linux side; that keeps the loopback
address, the filesystem and the compiler consistent.

### 1. Check your WSL2 setup

In **PowerShell**:

```powershell
wsl --status            # "Default Version: 2"  -- WSL1 will not work well here
wsl --update            # keeps the kernel and (for CUDA) the GPU shim current
wsl --list --verbose
```

If a distribution shows `VERSION 1`, convert it:

```powershell
wsl --set-version Ubuntu 2
wsl --set-default-version 2
```

### 2. Build tools, inside WSL

```sh
sudo apt-get update
sudo apt-get install -y build-essential git curl
```

### 3. Install Ollama, inside WSL

```sh
curl -fsSL https://ollama.com/install.sh | sh
```

The installer registers a systemd service **if** your WSL has systemd. Check:

```sh
ps -p 1 -o comm=          # "systemd" = you have it; "init"/"wsl-init" = you do not
```

**With systemd:**

```sh
sudo systemctl enable --now ollama
systemctl is-active ollama            # active
```

**Without systemd** — enable it once (recommended), then restart WSL:

```sh
printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
```

then in PowerShell: `wsl --shutdown`, and start your distribution again.

Or, if you would rather not enable systemd, start the server per session:

```sh
ollama serve >/tmp/ollama.log 2>&1 &
```

or, from inside the Amber REPL once `amber-ai` is installed: `\ai serve`.

### 4. Pull a model

```sh
ollama pull qwen2.5-coder:0.5b
ollama list
```

### 5. CUDA acceleration (optional, NVIDIA only)

WSL2 GPU passthrough needs **no** driver installed inside Linux — the Windows driver provides it.
Installing a Linux NVIDIA driver inside WSL will break it.

1. On **Windows**, install the current NVIDIA Game Ready or Studio driver (WSL support is built
   in from 470+).
2. In **PowerShell**: `wsl --update`.
3. Inside WSL, confirm the GPU is visible:

```sh
nvidia-smi                            # must list your GPU
```

4. Install the CUDA toolkit **for WSL** (not the generic Linux one), if you want to build
   GPU software yourself. Ollama ships its own CUDA runtime, so for `amber-ai` this is optional:

```sh
wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update && sudo apt-get install -y cuda-toolkit-12-4
```

5. Restart Ollama and confirm it picked the GPU up:

```sh
sudo systemctl restart ollama       # or kill and re-run: ollama serve
journalctl -u ollama -n 40 --no-pager | grep -i -e cuda -e gpu
ollama run qwen2.5-coder:0.5b "say hi"
nvidia-smi                           # ollama should appear while it generates
```

With a GPU, raise the budgets — the round trip gets much faster, so you can afford more:

```text
amber> \ai model qwen2.5-coder:7b
amber> \ai timeout 6000
```

### 6. Ports and `127.0.0.1` — the part that trips people up

`amber-ai` talks to `127.0.0.1:11434`. **Inside WSL2, Amber and Ollama are both in the same Linux
namespace, so loopback just works and there is nothing to forward.** You only need the rest of
this section if the two are on different sides of the boundary.

**Case A — everything inside WSL (the recommended layout).** Nothing to do.

**Case B — Ollama on Windows, Amber inside WSL.** WSL2 is a separate network namespace, so
Windows' `127.0.0.1` is not WSL's. Two options:

*Mirrored networking (Windows 11 22H2+, simplest).* Create `%UserProfile%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

then `wsl --shutdown` in PowerShell. Loopback is now shared and `127.0.0.1:11434` works from WSL.

*Otherwise, point Amber at the Windows host explicitly.* Bind Ollama on Windows to all
interfaces first (PowerShell, as administrator):

```powershell
setx OLLAMA_HOST "0.0.0.0:11434"
# restart Ollama, then allow it through the firewall:
New-NetFirewallRule -DisplayName "Ollama 11434" -Direction Inbound -LocalPort 11434 `
  -Protocol TCP -Action Allow
```

Then, inside WSL:

```sh
HOSTIP=$(ip route show default | awk '{print $3}')
export AMBER_AI_URL="http://$HOSTIP:11434/api/generate"
echo "export AMBER_AI_URL=\"http://\$(ip route show default | awk '{print \$3}'):11434/api/generate\"" >> ~/.bashrc
```

Note that this is no longer loopback: the request crosses the WSL↔Windows boundary. It is still
your own machine and still leaves no network, but the "127.0.0.1 only" guarantee becomes
"the host you configured only".

**Case C — Amber on Windows, Ollama in WSL.** Reach WSL from Windows at
`http://$(wsl hostname -I | cut -d' ' -f1):11434`, and set `OLLAMA_HOST=0.0.0.0:11434` inside WSL
so the server binds beyond loopback.

### 7. Install `amber-ai`

```sh
git clone https://github.com/bonucciandrea/amber-ai.git
cd amber-ai
./install.sh /path/to/amber
```

### 8. Use it

```sh
/path/to/amber/a
```

```text
amber> \ai status
amber> gentq 100000
amber> \ai average price per symbol
```

---

<a name="macos"></a>
## macOS (Apple Silicon and Intel)

### 1. Build tools

```sh
xcode-select --install          # Command Line Tools (clang); one-time
```

Homebrew, if you do not have it:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# Apple Silicon puts brew in /opt/homebrew; make sure it is on PATH:
eval "$(/opt/homebrew/bin/brew shellenv)"        # Intel: /usr/local/bin/brew
```

### 2. Install Ollama

**Either** the app (registers a login-item service that starts at boot and lives in the menu
bar):

```sh
brew install --cask ollama
open -a Ollama
```

**or** the CLI only, which you start yourself:

```sh
brew install ollama
brew services start ollama        # keeps it running across reboots
# or, for one session:  ollama serve &
```

Confirm:

```sh
curl -s http://127.0.0.1:11434/api/tags
```

### 3. Pull a model

```sh
ollama pull qwen2.5-coder:0.5b
```

On **Apple Silicon**, Ollama uses the Metal GPU automatically — there is nothing to configure and
no CUDA equivalent to install. An M-series laptop runs the 7B coder model comfortably:

```sh
ollama pull qwen2.5-coder:7b
```

```text
amber> \ai model qwen2.5-coder:7b
amber> \ai timeout 6000
```

On **Intel** Macs everything runs on the CPU; stay with the 0.5B model.

### 4. Build Amber (if you have not)

```sh
git clone https://github.com/bonucciandrea/amber.git
cd amber
chmod +x a build.sh install.sh
./build.sh
```

`build.sh` links without `-ldl` on macOS automatically. For NEON vector kernels on Apple Silicon:

```sh
AMBER_NATIVE=1 ./build.sh
```

### 5. Install `amber-ai`

```sh
git clone https://github.com/bonucciandrea/amber-ai.git
cd amber-ai
./install.sh /path/to/amber
```

If macOS Gatekeeper blocks the scripts after a download (rather than a `git clone`):

```sh
xattr -dr com.apple.quarantine .
chmod +x install.sh uninstall.sh setup-ollama.sh
```

### 6. Use it

```sh
/path/to/amber/a
```

---

<a name="linux-ubuntu--debian"></a>
## Linux (Ubuntu / Debian)

### 1. Build tools

```sh
sudo apt-get update
sudo apt-get install -y build-essential git curl
```

`build-essential` brings `gcc`, `make` and the C library headers. Amber needs nothing else —
no `libreadline`, no `ncurses`, no `rlwrap` (its REPL has its own line editor since 1.9.5).

### 2. Install Ollama and register the systemd service

```sh
curl -fsSL https://ollama.com/install.sh | sh
```

The installer creates an `ollama` system user and a unit. Enable it so it starts at boot:

```sh
sudo systemctl enable --now ollama
systemctl is-active ollama              # active
journalctl -u ollama -n 20 --no-pager
```

To change how it runs — bind address, model directory, keep-alive, GPU layers — use a drop-in
rather than editing the shipped unit:

```sh
sudo systemctl edit ollama
```

```ini
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_MODELS=/srv/ollama/models"
Environment="OLLAMA_KEEP_ALIVE=30m"
```

```sh
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

Keeping `OLLAMA_HOST` on `127.0.0.1` is the safe default: the model server has no
authentication, so binding it to `0.0.0.0` exposes it to your whole network.

**No systemd** (a container, a minimal image, some chroots)? Run it yourself:

```sh
ollama serve >/tmp/ollama.log 2>&1 &
```

or use `\ai serve` from inside the Amber REPL.

### 3. NVIDIA GPU (optional)

```sh
nvidia-smi                                    # driver present?
sudo apt-get install -y nvidia-driver-550     # if not; then reboot
sudo systemctl restart ollama
journalctl -u ollama -n 40 --no-pager | grep -i -e cuda -e gpu
```

Ollama ships its own CUDA runtime — you do not need the full CUDA toolkit unless you are
building GPU software yourself.

### 4. Pull a model

```sh
ollama pull qwen2.5-coder:0.5b
```

### 5. Install `amber-ai`

```sh
git clone https://github.com/bonucciandrea/amber-ai.git
cd amber-ai
./install.sh /path/to/amber
```

---

<a name="linux-rhel--fedora"></a>
## Linux (RHEL / Fedora / Rocky / Alma)

### 1. Build tools

```sh
sudo dnf install -y gcc make git curl          # Fedora / RHEL 9+
# older RHEL/CentOS:
sudo yum groupinstall -y "Development Tools"
```

If your distribution's GCC is very old, Amber's CI covers GCC 11 and newer; on RHEL 8 enable a
newer toolset:

```sh
sudo dnf install -y gcc-toolset-13
scl enable gcc-toolset-13 bash
```

### 2. Ollama + systemd

Identical to Ubuntu:

```sh
curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl enable --now ollama
systemctl is-active ollama
```

**SELinux.** On an enforcing system, a service reading models from a non-default directory is
denied. If you set `OLLAMA_MODELS`, relabel the directory:

```sh
sudo semanage fcontext -a -t var_lib_t "/srv/ollama(/.*)?"
sudo restorecon -Rv /srv/ollama
getenforce                                     # Enforcing
sudo ausearch -m avc -ts recent                # what was denied, if anything
```

**firewalld.** Loopback is never filtered, so a local-only setup needs nothing. Only if you
deliberately bind Ollama beyond loopback:

```sh
sudo firewall-cmd --add-port=11434/tcp --permanent && sudo firewall-cmd --reload
```

### 3. Pull a model, install `amber-ai`

```sh
ollama pull qwen2.5-coder:0.5b
git clone https://github.com/bonucciandrea/amber-ai.git
cd amber-ai && ./install.sh /path/to/amber
```

---

<a name="alternative-backends-llamacpp-openai-compatible"></a>
## Alternative backends (llama.cpp, OpenAI-compatible)

`src/net.c` decodes all three response shapes a local server can produce, so anything speaking
one of them works. Point `amber-ai` at it with `AMBER_AI_URL` or `\ai url`.

**llama.cpp server:**

```sh
llama-server -m ./qwen2.5-coder-0_5b-q4_k_m.gguf --port 8080
```

```text
amber> \ai url http://127.0.0.1:8080/completion
amber> \ai status
```

**Any OpenAI-compatible server** (vLLM, LM Studio, text-generation-webui, llama.cpp's `/v1`):

```text
amber> \ai url http://127.0.0.1:8000/v1/chat/completions
amber> \ai model my-local-model
```

Make it permanent:

```sh
export AMBER_AI_URL=http://127.0.0.1:8080/completion
export AMBER_AI_MODEL=qwen2.5-coder:0.5b
```

Only plain `http://` is supported. There is no TLS stack in this package, by design — a
loopback model server does not need one, and adding one would mean adding a dependency.

---

<a name="verifying-the-install"></a>
## Verifying the install

```sh
./setup-ollama.sh --check          # reports state, changes nothing, needs no root
```

```text
amber> \ai status
Amber AI agent v1.0.0
  agent      : on
  tab assist : on
  endpoint   : http://127.0.0.1:11434/api/generate
  model      : qwen2.5-coder:0.5b
  budgets    : 2000ms answer, 100ms tab   (last call 41ms)
  memory     : 12 records in /home/you/.amber_ai_memory.k
  workspace  : trades:table(time:P sym:S`g px:F size:I)[1000000 rows]
```

A real round trip:

```text
amber> \ai reply with exactly OK
OK
```

And the full suite, if you have a checkout:

```sh
tests/run_tests.sh /path/to/amber
```

If any of that misbehaves, **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** is organised by symptom.

---

<a name="uninstalling"></a>
## Uninstalling

```sh
./uninstall.sh /path/to/amber            # keeps ~/.amber_ai_memory.k
./uninstall.sh /path/to/amber --purge    # deletes it too
```

It removes `ext/net.c`, `ext/net.h`, `ext/ai_ext.c` and `lib/ai.k`, drops the loader line from
`lib/ext.k`, and rebuilds. Amber's `build.sh` prunes object files whose source has gone, so the
resulting binary is a stock one. Removing the model backend is separate and up to you:

```sh
sudo systemctl disable --now ollama      # linux / wsl2 with systemd
brew services stop ollama                # macOS
ollama rm qwen2.5-coder:0.5b             # reclaim the weights
```
