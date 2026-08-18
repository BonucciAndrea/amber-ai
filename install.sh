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

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
AI_VERSION="1.0.0"
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
  CANDIDATES="$CANDIDATES $(dirname "$(readlink -f "$(command -v amber)")")"
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

  # (a) the verbs exist. `aio -1 returns a 7-element status list.
  out=$(printf '#`aio[-1]\n\\\\\n' | AMBER_AI=0 "$AMBER/a" 2>/dev/null | tr -d '\r')
  case "$out" in *7*) ok "\`aio verb registered" ;;
                 *)   die "the \`aio verb did not register -- the extension did not link.
Check that $AMBER/ext/ai_ext.c exists and re-run $AMBER/build.sh by hand." ;; esac

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
  MODELS=$(curl -fsS --max-time 2 "http://$HOST:$PORT/api/tags" 2>/dev/null \
           | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | tr '\n' ' ')
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
  fi
else
  warn "nothing is listening on $HOST:$PORT -- that is fine, install is complete"
  note "the agent is a no-op until a backend is running; it never blocks the REPL"
  note "and it never contacts anything but this address."
  echo
  note "to start one (all local, no account, no telemetry):"
  note "    curl -fsSL https://ollama.com/install.sh | sh     # linux / wsl2"
  note "    brew install ollama                              # macos"
  note "    ollama serve &"
  note "    ollama pull $DEFAULT_MODEL"
  note "or run  ./setup-ollama.sh  from this folder, which walks you through it."
  note "See INSTALL.md for per-OS instructions and TROUBLESHOOTING.md if the"
  note "port is already in use."
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
