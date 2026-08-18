#!/usr/bin/env bash
# setup-ollama.sh  -  one-time setup of the LOCAL MODEL BACKEND for amber-ai.
#
# THIS IS THE ONE SCRIPT IN EITHER REPOSITORY THAT TOUCHES YOUR SYSTEM.
# ./install.sh, Amber's build.sh and ./a deliberately install nothing
# system-wide, and that promise is worth more than the convenience of folding a
# model installer into a compile step -- so this lives on its own, you run it
# knowingly, and it tells you exactly what it is about to do before doing it.
#
# You do NOT need this script. Installing ollama by hand (see INSTALL.md for
# WSL2 / macOS / Linux) is equally supported; this only automates it.
#
#   bash setup-ollama.sh            interactive: asks before each system change
#   bash setup-ollama.sh --check    report only; changes nothing, needs no root
#   bash setup-ollama.sh --yes      non-interactive (CI / provisioning)
#   bash setup-ollama.sh --model qwen2.5-coder:7b     pick a different model
#   bash setup-ollama.sh /path/to/amber   where Amber is, if not auto-detected
#
# After this, you do NOT run "ollama serve" every time: on a systemd host the
# installer registers ollama as a service that starts at boot.  On a host
# without systemd (some WSL setups, containers, macOS) use  \ai serve  inside
# the REPL, or start ollama however you normally start background services.
#
# amber-ai - GNU AGPLv3 - see LICENSE and NOTICE.
set -eu

# ---- portable script-directory resolution ---------------------------------
# `readlink -f` is GNU coreutils. BSD/macOS readlink gained -f only in macOS
# 12.3 (2022), so on any older Mac every script that used it resolved to an
# empty path and cd'd to the wrong place -- or silently to $HOME. This uses
# only POSIX readlink (no -f) plus `cd -P`, which behaves identically on macOS,
# Linux, WSL2 and BusyBox, and still follows a chain of symlinks.
am_scriptdir() {
  am__p=$1
  while [ -h "$am__p" ]; do
    am__d=$(CDPATH='' cd -- "$(dirname -- "$am__p")" && pwd -P) || return 1
    am__l=$(readlink -- "$am__p")
    case $am__l in /*) am__p=$am__l ;; *) am__p=$am__d/$am__l ;; esac
  done
  CDPATH='' cd -- "$(dirname -- "$am__p")" || return 1
  pwd -P
}
here="$(am_scriptdir "$0")"
cd "$here"

AMBER_DIR="${AMBER_HOME:-}"
MODEL="${AMBER_AI_MODEL:-qwen2.5-coder:0.5b}"
URL="${AMBER_AI_URL:-http://127.0.0.1:11434/api/generate}"
ASSUME_YES=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=1 ;;
    --check|-n) CHECK_ONLY=1 ;;
    --model)    shift; MODEL="${1:-$MODEL}" ;;
    --model=*)  MODEL="${1#--model=}" ;;
    -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "setup-ollama.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
    *)  AMBER_DIR="$1" ;;
  esac
  shift
done

BOLD=$(tput bold 2>/dev/null || true)
DIM=$(tput dim 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
note() { printf '%s    %s%s\n' "$DIM" "$*" "$RESET"; }

ask() { # ask "question" -> 0 = yes
  [ "$ASSUME_YES" = 1 ] && return 0
  [ ! -t 0 ] && { say "    (not a terminal, and --yes was not given -- skipping)"; return 1; }
  printf '    %s [y/N] ' "$1"
  read -r reply </dev/tty || return 1
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Endpoint host:port, derived from URL so --check follows AMBER_AI_URL.
hostport="$(printf '%s' "$URL" | sed -e 's|^https\{0,1\}://||' -e 's|/.*$||')"
[ "$hostport" = "$(printf '%s' "$hostport" | sed 's/:.*//')" ] && hostport="$hostport:11434"
base="http://$hostport"

alive() { # is anything accepting connections on the endpoint?
  # A bare TCP connect, NOT a GET on /api/tags: llama.cpp and OpenAI-compatible
  # servers have no /api/tags, and probing an ollama-only path would declare a
  # perfectly good backend dead. Step 5 verifies the endpoint properly, with a
  # real generation round trip through Amber itself.
  local h="${hostport%%:*}" p="${hostport##*:}"
  if (exec 3<>"/dev/tcp/$h/$p") >/dev/null 2>&1; then return 0; fi
  # /dev/tcp can be compiled out of bash; fall back to curl/wget, accepting ANY
  # HTTP status (a 404 still proves something is listening).
  if command -v curl >/dev/null 2>&1; then
    curl -sS -m 3 -o /dev/null "$base/" >/dev/null 2>&1 && return 0
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 3 -O /dev/null "$base/" >/dev/null 2>&1 && return 0
  fi
  return 1
}

has_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

# ---- locate Amber (only needed for the end-to-end check in step 5) ---------
is_amber() { [ -n "${1:-}" ] && [ -f "$1/src/a.h" ] && [ -f "$1/build.sh" ]; }
AMBER=""
for c in ${AMBER_DIR:-} "$here/../amber" "$PWD/../amber" "$PWD/amber" "$HOME/amber"; do
  [ -d "$c" ] || continue
  c="$(cd "$c" 2>/dev/null && pwd)" || continue
  if is_amber "$c"; then AMBER="$c"; break; fi
done

# ---------------------------------------------------------------- 1. report
step "1. current state"
say "    amber folder : ${AMBER:-<not found>}"
say "    endpoint     : $URL"
say "    model wanted : $MODEL"
if command -v ollama >/dev/null 2>&1; then
  say "    ollama       : installed ($(command -v ollama))"
  OLLAMA=1
else
  say "    ollama       : NOT installed"
  OLLAMA=0
fi
if alive; then say "    backend      : answering on $base"; ALIVE=1
else            say "    backend      : nothing answering on $base"; ALIVE=0; fi
if has_systemd; then
  say "    systemd      : present ($(systemctl is-active ollama 2>/dev/null || echo 'ollama service not active'))"
else
  say "    systemd      : not running here -- use  \\ai serve  in the REPL, or start ollama yourself"
fi

if [ "$CHECK_ONLY" = 1 ]; then
  step "check only -- nothing was changed"
  exit 0
fi

# --------------------------------------------------------------- 2. install
if [ "$OLLAMA" = 0 ]; then
  step "2. install ollama"
  say "    Amber needs a local model server. The official installer is:"
  say ""
  say "        curl -fsSL https://ollama.com/install.sh | sh"
  say ""
  note "It downloads and runs a shell script as root, installs /usr/local/bin/ollama,"
  note "creates an 'ollama' user, and (on a systemd host) registers a service that"
  note "starts at boot. Nothing in Amber requires this -- \\ai simply stays offline"
  note "without it, and the rest of the interpreter is unaffected."
  if ! command -v curl >/dev/null 2>&1; then
    say "    curl is not installed; install it first (sudo apt-get install -y curl)." >&2
    exit 1
  fi
  if ask "Run the official ollama installer now?"; then
    curl -fsSL https://ollama.com/install.sh | sh
    OLLAMA=1
  else
    say "    Skipped. Install it yourself when you like, then re-run this script."
    exit 0
  fi
else
  step "2. install ollama -- already present, skipping"
fi

# ----------------------------------------------------------------- 3. serve
step "3. make sure it is running"
if alive; then
  say "    already answering on $base"
else
  if has_systemd; then
    say "    starting the ollama service (and enabling it, so it survives reboots)"
    if ask "Run: sudo systemctl enable --now ollama ?"; then
      sudo systemctl enable --now ollama || true
    fi
  fi
  if ! alive; then
    say "    starting 'ollama serve' in the background for this session"
    # setsid detaches it from this terminal's session, so closing the terminal
    # (or this script exiting) does not take the server down with it.
    if command -v setsid >/dev/null 2>&1; then
      setsid ollama serve >/dev/null 2>&1 </dev/null &
    else
      ( ollama serve >/dev/null 2>&1 </dev/null & )
    fi
  fi
  n=0
  while [ $n -lt 15 ] && ! alive; do sleep 1; n=$((n+1)); done
  if alive; then say "    up after ${n}s"
  else
    say "    still not answering on $base." >&2
    say "    Run 'ollama serve' in another terminal to see the error." >&2
    exit 1
  fi
fi

# ----------------------------------------------------------------- 4. model
step "4. pull the model ($MODEL)"
if ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$MODEL"; then
  say "    already downloaded"
else
  say "    downloading -- a 0.5b coder model is a few hundred MB and is plenty for"
  say "    schema-shaped questions; pass --model for something larger."
  ollama pull "$MODEL"
fi

# ----------------------------------------------------------------- 5. verify
step "5. verify end to end through Amber"
if [ -z "${AMBER:-}" ]; then
  say "    no Amber installation found -- skipping the end-to-end check."
  say "    (pass the path:  bash setup-ollama.sh /path/to/amber)"
  step "done"
  exit 0
fi
[ -x "$AMBER/amber" ] || bash "$AMBER/build.sh"
cat > "$AMBER/.setup-ai-probe.k" <<'PROBE'
/ `0: already terminates the line; a bare `0:"\n" would be a char ATOM and raise 'type.
r:`ai[("You answer with one short line.";"Reply with exactly: AMBER-AI-OK";8000;16)]
`0:$[0=r 0;"OK   ",r 1;"FAIL rc=",($r 0)," ",r 1]
PROBE
out="$(AMBER_AI_MODEL="$MODEL" AMBER_AI_URL="$URL" "$AMBER/amber" "$AMBER/.setup-ai-probe.k" 2>&1 || true)"
rm -f "$AMBER/.setup-ai-probe.k"
say "    $out"
case "$out" in
  OK*) ;;
  *)   say ""; say "    The round trip failed. 'bash setup-ollama.sh --check' reports the state." >&2; exit 1 ;;
esac

step "done"
say "Start Amber and ask it something:"
say ""
say "    $AMBER/a"
say "    amber> \\ai status"
say "    amber> gentq 100000"
say "    amber> \\ai average price per symbol in the last hour"
say ""
if has_systemd; then
  note "ollama is a systemd service now -- it starts at boot, so you never need"
  note "'ollama serve' again. Stop it with: sudo systemctl disable --now ollama"
else
  note "No systemd here, so nothing starts ollama for you at boot. Use  \\ai serve"
  note "inside the REPL, or run 'ollama serve' from your shell profile."
fi
note "Turn the agent off entirely at any time with  \\ai off  or AMBER_AI=0."
