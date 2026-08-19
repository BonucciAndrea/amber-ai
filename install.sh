#!/usr/bin/env bash
# =============================================================================
# amber-ai installer  -  one command, no root, nothing system-wide.
#
#     ./install.sh /path/to/amber
#     ./install.sh                 # auto-detects the Amber installation
#
# What it does, in order:
#   1. locates your local Amber 1.9.5+ installation and checks its extension ABI
#   2. copies src/net.c, src/net.h and src/ai_ext.c into  <amber>/ext/
#   3. copies lib/ai.k into  <amber>/lib/  and registers it in <amber>/lib/ext.k
#   4. re-runs <amber>/build.sh, so the agent is compiled and linked INTO the
#      Amber binary you already had  (no shared object, no LD_PRELOAD, no PATH)
#   5. verifies the build: the `ai / `aio verbs, \ai, and Amber's own test suite
#   6. probes a local model backend on 127.0.0.1:11434 and reports what it found
#   7. prints the exact commands to start using it
#
# Not one line of Amber's src/ is modified; everything lands in ext/ and lib/,
# which Amber's build.sh and repl.k pick up by design (see <amber>/src/ext.h).
# ./uninstall.sh reverses all of it.
#
# Options:
#   --no-build        copy the files but do not rebuild (CI / packaging)
#   --no-test         skip the post-build verification
#   -y, --yes         never prompt (assumed when stdin is not a terminal)
#   -h, --help        this message
#
# amber-ai - GNU AGPLv3 - see LICENSE and NOTICE.
# =============================================================================
set -u

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
HERE="$(am_scriptdir "$0")"
AI_VERSION="2.0.0"
NEED_ABI=1
DEFAULT_URL="${AMBER_AI_URL:-http://127.0.0.1:11434/api/generate}"
DEFAULT_MODEL="${AMBER_AI_MODEL:-qwen2.5-coder:0.5b}"

DO_BUILD=1; DO_TEST=1; ASSUME_YES=0; TARGET=""

# ---- pretty ----------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; Z=""; fi
step(){ printf '%s==>%s %s\n' "$B" "$Z" "$*"; }
ok(){   printf '    %s✓%s %s\n' "$G" "$Z" "$*"; }
warn(){ printf '    %s!%s %s\n' "$Y" "$Z" "$*"; }
die(){  printf '%serror:%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
note(){ printf '    %s%s%s\n' "$D" "$*" "$Z"; }

usage(){ sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

for a in "$@"; do
  case "$a" in
    --no-build) DO_BUILD=0 ;;
    --no-test)  DO_TEST=0 ;;
    -y|--yes)   ASSUME_YES=1 ;;
    -h|--help)  usage ;;
    -*) die "unknown option: $a  (try --help)" ;;
    *)  TARGET="$a" ;;
  esac
done
[ -t 0 ] || ASSUME_YES=1

echo
printf '%samber-ai %s%s  -  local, offline AI co-pilot for Amber\n' "$B" "$AI_VERSION" "$Z"
echo

# =============================================================================
# 0. platform + toolchain
# =============================================================================
# The rebuild in step 4 invokes the C compiler, so a missing toolchain has to be
# caught HERE with an actionable message rather than surfacing as a wall of
# compiler noise after the files have already been copied.
step "checking your platform and toolchain"

UNAME=$(uname -s 2>/dev/null || echo unknown)
IS_WSL=0
case "$(uname -r 2>/dev/null)" in *[Mm]icrosoft*|*WSL*) IS_WSL=1 ;; esac
case "$UNAME" in
  Darwin) PLATFORM="macOS" ;;
  Linux)  PLATFORM=$([ "$IS_WSL" = 1 ] && echo "WSL2" || echo "Linux") ;;
  *)      PLATFORM="$UNAME" ;;
esac
ok "platform: $PLATFORM ($(uname -m 2>/dev/null || echo '?'))"

if [ "$PLATFORM" = "macOS" ]; then
  # Homebrew lives at /opt/homebrew on Apple Silicon and /usr/local on Intel;
  # a shell that has never run `brew shellenv` has neither on PATH.
  if ! command -v brew >/dev/null 2>&1; then
    for bp in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [ -x "$bp" ] && { eval "$("$bp" shellenv)" 2>/dev/null || true; break; }
    done
  fi
  command -v brew >/dev/null 2>&1 && ok "homebrew: $(brew --prefix)" \
    || note "homebrew not found (only needed if you install ollama with it)"
fi

CC_FOUND=""
for c in "${CC:-}" cc gcc clang; do
  [ -n "$c" ] || continue
  command -v "$c" >/dev/null 2>&1 && { CC_FOUND="$c"; break; }
done
if [ -z "$CC_FOUND" ]; then
  case "$PLATFORM" in
    macOS) die "no C compiler found. Install Apple's Command Line Tools:

    xcode-select --install

Then re-run:  ./install.sh $*" ;;
    *) if command -v apt-get >/dev/null 2>&1; then
         die "no C compiler found:

    sudo apt-get update && sudo apt-get install -y build-essential

Then re-run:  ./install.sh $*"
       elif command -v dnf >/dev/null 2>&1; then
         die "no C compiler found:

    sudo dnf install -y gcc make

Then re-run:  ./install.sh $*"
       else
         die "no C compiler found. Install gcc or clang with your package manager, then re-run."
       fi ;;
  esac
fi
ok "compiler: $CC_FOUND"
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
  || note "neither curl nor wget found -- the backend probe will fall back to a raw TCP connect"

# =============================================================================
# 1. locate Amber
# =============================================================================
step "locating your Amber installation"

is_amber(){ [ -n "${1:-}" ] && [ -f "$1/src/a.h" ] && [ -f "$1/build.sh" ] && [ -f "$1/repl.k" ]; }

CANDIDATES=""
[ -n "$TARGET" ]              && CANDIDATES="$CANDIDATES $TARGET"
[ -n "${AMBER_HOME:-}" ]      && CANDIDATES="$CANDIDATES $AMBER_HOME"
CANDIDATES="$CANDIDATES $HERE/../amber $PWD/../amber $PWD/amber $HOME/amber $HOME/src/amber $HOME/code/amber $HOME/projects/amber"
# an `amber` already on PATH, or the target of an `a` alias
if command -v amber >/dev/null 2>&1; then
  CANDIDATES="$CANDIDATES $(am_scriptdir "$(command -v amber)")"
fi

AMBER=""
for c in $CANDIDATES; do
  [ -d "$c" ] || continue
  c="$(cd "$c" 2>/dev/null && pwd)" || continue
  if is_amber "$c"; then AMBER="$c"; break; fi
done

if [ -z "$AMBER" ]; then
  echo
  die "could not find an Amber installation.

Pass it explicitly:
    ./install.sh /path/to/amber

An Amber installation is the folder containing src/a.h, build.sh and repl.k.
If you do not have one yet:
    git clone https://github.com/bonucciandrea/amber.git
    cd amber && ./install.sh"
fi
ok "found $AMBER"

# ---- version + ABI ---------------------------------------------------------
V_MAJ=$(sed -n 's/^#define AMBER_VERSION_MAJOR \([0-9]*\).*/\1/p' "$AMBER/src/a.h" | head -1)
V_MIN=$(sed -n 's/^#define AMBER_VERSION_MINOR \([0-9]*\).*/\1/p' "$AMBER/src/a.h" | head -1)
V_PAT=$(sed -n 's/^#define AMBER_VERSION_PATCH \([0-9]*\).*/\1/p' "$AMBER/src/a.h" | head -1)
ok "amber version ${V_MAJ:-?}.${V_MIN:-?}.${V_PAT:-?}"

if [ ! -f "$AMBER/src/ext.h" ]; then
  die "that Amber has no extension seam (src/ext.h is missing).

amber-ai needs Amber 1.9.5 or newer. Update it with:
    cd $AMBER && git pull && ./build.sh"
fi
ABI=$(sed -n 's/^#define AMBER_EXT_ABI \([0-9]*\).*/\1/p' "$AMBER/src/ext.h" | head -1)
[ -n "$ABI" ] || die "cannot read AMBER_EXT_ABI from $AMBER/src/ext.h"
if [ "$ABI" != "$NEED_ABI" ]; then
  die "extension ABI mismatch: this Amber offers ABI $ABI, amber-ai $AI_VERSION needs $NEED_ABI.
Update whichever of the two is older."
fi
ok "extension ABI $ABI"

if [ ! -w "$AMBER" ]; then
  die "$AMBER is not writable by $(id -un). Fix the permissions, or install Amber somewhere you own."
fi

# ---- confirm ---------------------------------------------------------------
echo
note "will copy    src/net.c  src/net.h  src/ai_ext.c   ->  $AMBER/ext/"
note "will copy    lib/ai.k                             ->  $AMBER/lib/"
note "will update  $AMBER/lib/ext.k"
note "will run     $AMBER/build.sh"
note "nothing in $AMBER/src/ is modified; nothing is installed system-wide"
echo
if [ "$ASSUME_YES" = 0 ]; then
  printf 'proceed? [Y/n] '
  read -r reply
  case "$reply" in [nN]*) echo "aborted."; exit 1 ;; esac
  echo
fi

# =============================================================================
# 2. copy the C half into ext/
# =============================================================================
# A clone or a zip can arrive with mode 644 on every script, in which case the
# very first line of the README answers with "Permission denied". Fix both trees
# rather than assuming either is right.
step "fixing permissions"
PFIX=0
for f in "$HERE"/*.sh "$HERE"/tests/*.sh "$HERE"/tests/*.py \
         "$AMBER/a" "$AMBER/build.sh" "$AMBER/install.sh" "$AMBER"/tests/*.sh "$AMBER"/tests/*.py; do
  [ -f "$f" ] || continue
  [ -x "$f" ] || { chmod +x "$f" 2>/dev/null && PFIX=$((PFIX+1)); }
done
[ "$PFIX" -gt 0 ] && ok "made $PFIX script(s) executable" || ok "all scripts already executable"

step "installing the transport + glue into $AMBER/ext/"
mkdir -p "$AMBER/ext" || die "cannot create $AMBER/ext"
for f in net.c net.h ai_ext.c; do
  [ -f "$HERE/src/$f" ] || die "missing $HERE/src/$f (broken checkout?)"
  cp -f "$HERE/src/$f" "$AMBER/ext/$f" || die "cannot write $AMBER/ext/$f"
  ok "ext/$f"
done

# =============================================================================
# 3. copy the Amber half into lib/ and register it
# =============================================================================
step "installing the agent library into $AMBER/lib/"
mkdir -p "$AMBER/lib" || die "cannot create $AMBER/lib"
cp -f "$HERE/lib/ai.k" "$AMBER/lib/ai.k" || die "cannot write $AMBER/lib/ai.k"
ok "lib/ai.k"
# The shipped few-shot corpus. Read-only at run time and kept apart from the
# user's own ~/.amber_ai_memory.k, so `\ai forget` never destroys it and it is
# never written back into personal memory. Absent = the agent simply starts with
# no examples, so this is not fatal.
if [ -f "$HERE/lib/amber_ai_memory.k" ]; then
  cp -f "$HERE/lib/amber_ai_memory.k" "$AMBER/lib/amber_ai_memory.k" \
    || die "cannot write $AMBER/lib/amber_ai_memory.k"
  ok "lib/amber_ai_memory.k ($(grep -c '^ai.seed\[' "$HERE/lib/amber_ai_memory.k") examples)"
else
  warn "lib/amber_ai_memory.k is missing -- the agent will start with no seed examples"
fi

# repl.k loads lib/ext.k whole-file at startup (trapped, diagnostics off) and
# nothing else. Registering means appending one trapped loader line -- appending,
# not overwriting, so a second extension can register alongside this one.
EXTK="$AMBER/lib/ext.k"
MARK="/ amber-ai $AI_VERSION"
if [ ! -f "$EXTK" ]; then
  {
    echo "/ lib/ext.k -- extension loader, read whole-file by repl.k at startup."
    echo "/ Generated by installers; safe to edit or delete. Each line loads one"
    echo "/ extension library, trapped, so a broken extension cannot break the REPL."
  } > "$EXTK" || die "cannot write $EXTK"
fi
if grep -qF "$MARK" "$EXTK" 2>/dev/null; then
  ok "lib/ext.k already registers amber-ai"
else
  {
    echo ""
    echo "$MARK"
    echo ".[{. \`c\$1:x};,\"$AMBER/lib/ai.k\";0]"
  } >> "$EXTK" || die "cannot append to $EXTK"
  ok "lib/ext.k registers lib/ai.k"
fi

# =============================================================================
# 4. rebuild
# =============================================================================
if [ "$DO_BUILD" = 1 ]; then
  step "rebuilding amber with the agent linked in"
  ( cd "$AMBER" && chmod +x build.sh a 2>/dev/null; bash build.sh ) \
    || die "build failed.

Nothing was left half-installed -- run ./uninstall.sh $AMBER to remove the
files again. The usual causes are a missing C compiler or a read-only folder:
    Debian/Ubuntu/WSL:  sudo apt-get install -y build-essential
    macOS:              xcode-select --install
    RHEL/Fedora:        sudo dnf install -y gcc make"
  ok "built $AMBER/amber"
else
  warn "--no-build: skipping the rebuild (run $AMBER/build.sh yourself)"
fi

# =============================================================================
# 5. verify
# =============================================================================
if [ "$DO_BUILD" = 1 ] && [ "$DO_TEST" = 1 ]; then
  step "verifying"

  # The rebuild above just produced these; assert they are runnable before the
  # probes below try to run them. Without it, a launcher left at mode 644 makes
  # every probe produce EMPTY output, and the first one reports that as "the
  # extension did not link" -- sending the reader into ext/ to hunt a bug that
  # is really a lost file mode.
  chmod +x "$AMBER/a" "$AMBER/amber" "$AMBER/build.sh" 2>/dev/null || true

  # (a) the verbs exist. `aio -1 returns a 7-element status list.
  # stderr is CAPTURED rather than discarded: it is the only place a permission
  # error, a missing loader or a REPL diagnostic can announce itself, and
  # throwing it away is what let this check misreport its own cause.
  VLOG="$AMBER/.amber-ai-verify.log"
  out=$(printf '#`aio[-1]\n\\\\\n' | AMBER_AI=0 "$AMBER/a" 2>"$VLOG" | tr -d '\r')
  case "$out" in *7*) ok "\`aio verb registered"; rm -f "$VLOG" ;;
                 *)   VERR=$(sed -n '1,5p' "$VLOG" 2>/dev/null | tr '\n' ' '); rm -f "$VLOG"
                      die "the \`aio verb did not register -- the extension did not link.
Check that $AMBER/ext/ai_ext.c exists and re-run $AMBER/build.sh by hand.

  the launcher printed : ${out:-(nothing)}
  the launcher's stderr: ${VERR:-(empty)}
  ls -l \$AMBER/a       : $(ls -l "$AMBER/a" 2>&1)
  ls -l \$AMBER/ext     : $(ls "$AMBER/ext" 2>&1 | tr '\n' ' ')" ;; esac

  # (b) \ai reaches lib/ai.k. Offline on purpose: the agent is switched off, so
  #     this tests the dispatch path and nothing else.
  out=$(printf '\\ai status\n\\\\\n' | AMBER_AI=0 "$AMBER/a" 2>/dev/null | tr -d '\r')
  case "$out" in *"endpoint"*|*"agent"*) ok "\\ai reaches lib/ai.k" ;;
                 *) warn "\\ai did not answer as expected; try '\\ai help' in the REPL" ;; esac

  # (c) the engine itself must be untouched by our presence.  test.k resolves
  #     its sibling modules relative to the cwd, so run it from there.
  out=$( cd "$AMBER" && ./amber test.k 2>/dev/null | tail -3 )
  case "$out" in *"0 failures"*) ok "amber's own test suite still passes" ;;
                 *) warn "amber's test suite did not report 0 failures -- see: (cd $AMBER && ./amber test.k)" ;; esac
fi

# =============================================================================
# 6. probe the local model backend
# =============================================================================
step "checking for a local model backend"
HOSTPORT=$(printf '%s' "$DEFAULT_URL" | sed -e 's|^http://||' -e 's|/.*$||')
HOST=${HOSTPORT%%:*}; PORT=${HOSTPORT##*:}
[ "$PORT" = "$HOST" ] && PORT=80

BACKEND=0
if command -v curl >/dev/null 2>&1; then
  curl -fsS --max-time 2 "http://$HOST:$PORT/api/tags" >/dev/null 2>&1 && BACKEND=1
fi
if [ "$BACKEND" = 0 ]; then
  # no curl (or no /api/tags): fall back to a plain TCP connect
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$HOST" "$PORT" <<'PY' >/dev/null 2>&1 && BACKEND=2
import socket, sys
s = socket.socket(); s.settimeout(2)
try: s.connect((sys.argv[1], int(sys.argv[2])))
except Exception: sys.exit(1)
finally: s.close()
PY
  elif command -v nc >/dev/null 2>&1; then
    nc -z -w2 "$HOST" "$PORT" >/dev/null 2>&1 && BACKEND=2
  fi
fi

MODELS=""
if [ "$BACKEND" = 1 ] && command -v curl >/dev/null 2>&1; then
  # Tolerate whitespace after the colon: ollama emits compact JSON, but a proxy
  # or a pretty-printing stand-in emits `"name": "x"`, and the strict pattern
  # silently produced an EMPTY model list against those -- which read as "no
  # models pulled" when the backend was in fact fully populated.
  MODELS=$(curl -fsS --max-time 2 "http://$HOST:$PORT/api/tags" 2>/dev/null \
           | tr ',' '\n' | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
           | tr '\n' ' ')
fi

if [ "$BACKEND" != 0 ]; then
  ok "something is listening on $HOST:$PORT"
  if [ -n "$MODELS" ]; then
    ok "models available: $MODELS"
    case " $MODELS " in
      *" $DEFAULT_MODEL "*) ok "the default model ($DEFAULT_MODEL) is pulled" ;;
      *) warn "the default model is not pulled yet:   ollama pull $DEFAULT_MODEL"
         note "or point Amber at one you have:   \\ai model <name>" ;;
    esac
  elif [ "$BACKEND" = 1 ]; then
    # /api/tags answered but listed nothing: an ollama with no models pulled.
    warn "the backend answered but has no models pulled yet"
    note "    ollama pull $DEFAULT_MODEL"
  elif [ "$BACKEND" = 2 ]; then
    # Something holds the port but did not answer /api/tags. That is either a
    # non-ollama backend (llama.cpp, an OpenAI-compatible server) -- fine -- or
    # an unrelated process squatting on 11434, which is the single most common
    # "why does nothing work" report.
    warn "the port is open but did not answer ollama's /api/tags"
    note "that is expected for llama.cpp or an OpenAI-compatible server."
    note "if you did NOT start one, something else is squatting on the port:"
    note "    sudo ss -lptn 'sport = :$PORT'      # linux / wsl2"
    note "    lsof -iTCP:$PORT -sTCP:LISTEN -P -n  # macos"
    note "move ollama instead of fighting for it:  OLLAMA_HOST=127.0.0.1:11500 ollama serve"
    note "then:  \\ai url http://127.0.0.1:11500/api/generate"
  fi
else
  warn "nothing is listening on $HOST:$PORT -- that is fine, the install is complete"
  note "the agent is a no-op until a backend is running; it never blocks the REPL"
  note "and it never contacts anything but this address."

  # ---- WSL2: the loopback that is not the loopback you think it is ----------
  # WSL2 runs in its own network namespace, so Windows' 127.0.0.1 is NOT WSL's.
  # An Ollama installed on the Windows side is invisible from here unless
  # mirrored networking is on -- and the symptom is exactly this message, which
  # sends people hunting for a broken install that is working perfectly.
  if [ "$IS_WSL" = 1 ]; then
    echo
    warn "you are on WSL2, where 127.0.0.1 is WSL's loopback, NOT Windows'."
    WINHOST=""
    if command -v ip >/dev/null 2>&1; then
      WINHOST=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    fi
    if [ -n "$WINHOST" ]; then
      WBACK=0
      if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 2 "http://$WINHOST:$PORT/api/tags" >/dev/null 2>&1 && WBACK=1
      fi
      if [ "$WBACK" = 1 ]; then
        ok "FOUND an Ollama on the WINDOWS host at $WINHOST:$PORT"
        note "point Amber at it -- add this to your shell rc:"
        note "    export AMBER_AI_URL=\"http://\$(ip route show default | awk '/default/{print \$3}'):$PORT/api/generate\""
        note "(the host IP changes on reboot, so compute it rather than hard-coding it)"
      else
        note "nothing on the Windows host either ($WINHOST:$PORT)."
        note "if your Ollama runs on WINDOWS, do BOTH of these:"
        note "  1. on Windows:  setx OLLAMA_HOST \"0.0.0.0:$PORT\"   (then restart Ollama)"
        note "  2. allow it through the firewall, in an admin PowerShell:"
        note "     New-NetFirewallRule -DisplayName 'Ollama $PORT' -Direction Inbound \\"
        note "       -LocalPort $PORT -Protocol TCP -Action Allow"
        note "  3. back in WSL:  export AMBER_AI_URL=\"http://$WINHOST:$PORT/api/generate\""
        note "simplest alternative: install ollama INSIDE wsl2, and none of this applies."
        note "or, on Windows 11 22H2+, put this in %UserProfile%\\.wslconfig and run"
        note "\`wsl --shutdown\`:   [wsl2]  networkingMode=mirrored"
      fi
    fi
  fi

  echo
  note "to start a backend (all local, no account, no telemetry):"
  case "$PLATFORM" in
    macOS) note "    brew install ollama && brew services start ollama" ;;
    *)     note "    curl -fsSL https://ollama.com/install.sh | sh"
           note "    sudo systemctl enable --now ollama    # or: ollama serve &" ;;
  esac
  note "    ollama pull $DEFAULT_MODEL"
  note "or run  ./setup-ollama.sh  from this folder, which walks you through it"
  note "and asks before every system change."
  note "See INSTALL.md for per-OS steps and TROUBLESHOOTING.md for port conflicts."
fi

# =============================================================================
# 7. done
# =============================================================================
echo
printf '%samber-ai %s installed into %s%s\n' "$B" "$AI_VERSION" "$AMBER" "$Z"
echo
echo "start it:"
echo "    $AMBER/a"
echo
echo "then, in the REPL:"
echo "    \\ai help              every command"
echo "    \\ai status            endpoint, model, budgets, what it has learned"
echo "    \\ai why               diagnose the last error against your real tables"
echo "    \\ai profile trades    rows, types, attributes + indexing advice"
echo "    \\ai select the last trade per sym"
echo "    <Tab>                 completions; a dim suggestion needs a 2nd Tab"
echo
echo "switches:"
echo "    AMBER_AI=0            disable the agent entirely for a session"
echo "    AMBER_AI_URL=...      point at a different local endpoint"
echo "    AMBER_AI_MODEL=...    use a different local model"
echo
echo "uninstall:   $HERE/uninstall.sh $AMBER"
echo
