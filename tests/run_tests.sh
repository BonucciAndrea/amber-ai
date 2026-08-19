#!/usr/bin/env bash
# tests/run_tests.sh  -  every amber-ai test suite.
#
#   tests/run_tests.sh [/path/to/amber]
#   tests/run_tests.sh --quick [/path/to/amber]   C unit tests only, no install
#
# What runs, and why each layer exists:
#
#   1. tests/test_net.c   the HTTP transport, linked against src/net.c ALONE and
#                         nothing else. It starts its own loopback server on an
#                         ephemeral port, so it exercises connect deadlines,
#                         chunked decoding, JSON extraction and the circuit
#                         breaker with no model backend and no fixed port.
#   2. install            a real ./install.sh run into a THROWAWAY COPY of your
#                         Amber tree (never your own), because "does the
#                         installer work" is the single most user-visible thing
#                         in this repository.
#   3. tests/test_ai.k    123 Amber-level assertions on the agent: switches,
#                         memory format and ranking, schema harvesting, prompt
#                         assembly, every \ai sub-command that needs no network,
#                         and the graceful-failure path (the endpoint is aimed
#                         at the closed discard port, so it cannot block).
#   4. tests/test_e2e.py  the whole thing driven through the real REPL against
#                         tests/mock_backend.py: answers, \ai why, ghost text on
#                         a pty, the off switch, all three response shapes, and
#                         a check that Amber's own suite is unaffected.
#
# Exit status 0 iff everything passed.
#
# amber-ai - GNU AGPLv3 - see LICENSE and NOTICE.
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
cd "$(am_scriptdir "$0")/.."
REPO="$PWD"
QUICK=0; TARGET=""
for a in "$@"; do case "$a" in --quick) QUICK=1 ;; *) TARGET="$a" ;; esac; done

fail=0
say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
res(){ if [ "$1" = 0 ]; then echo "  -> PASS ($2)"; else echo "  -> FAIL ($2)"; fail=1; fi; }

CC="${CC:-cc}"
mkdir -p o

# Restore the executable bit on everything this harness EXECUTES rather than
# sources. ./install.sh and ./uninstall.sh are invoked as commands below, so at
# mode 644 the run dies with "./install.sh: Permission denied" and every later
# stage fails as a CONSEQUENCE -- including "the \`aio verb did not register",
# which then blames the extension seam for a lost file mode. The bits are
# committed (the "shell hygiene" job enforces 100755), but a zip export, a tar
# restore or a copy across a non-POSIX filesystem drops them.
chmod +x install.sh uninstall.sh setup-ollama.sh tests/*.sh tests/*.py 2>/dev/null || true

# --------------------------------------------------------------- 1. transport
say "tests/test_net.c (src/net.c standalone)"
if $CC -w -O2 -std=c99 -Isrc -pthread -o o/test_net tests/test_net.c src/net.c -lm 2>o/net.log; then
  o/test_net; res $? "tests/test_net.c"
else
  echo "  -> FAIL (did not compile)"; sed -n '1,20p' o/net.log; fail=1
fi

if [ "$QUICK" = 1 ]; then
  say "result"; [ "$fail" = 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
  exit $fail
fi

# ------------------------------------------------------- 2. locate + copy amber
is_amber(){ [ -n "${1:-}" ] && [ -f "$1/src/a.h" ] && [ -f "$1/build.sh" ] && [ -f "$1/repl.k" ]; }
SRC_AMBER=""
for c in $TARGET ${AMBER_HOME:-} "$REPO/../amber" "$PWD/../amber" "$HOME/amber"; do
  [ -d "$c" ] || continue
  c="$(cd "$c" 2>/dev/null && pwd)" || continue
  if is_amber "$c"; then SRC_AMBER="$c"; break; fi
done
if [ -z "$SRC_AMBER" ]; then
  echo
  echo "no Amber installation found -- the transport tests above are all that can run."
  echo "Pass one:   tests/run_tests.sh /path/to/amber"
  say "result"; [ "$fail" = 0 ] && echo "ALL RUNNABLE SUITES PASSED" || echo "SOME SUITES FAILED"
  exit $fail
fi

# A throwaway copy, so a test run can never disturb the user's own installation.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/amber-ai-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT
say "staging a throwaway copy of $SRC_AMBER"
mkdir -p "$WORK/amber"
( cd "$SRC_AMBER" && tar cf - --exclude=./o --exclude=./.git --exclude=./amber . ) \
  | ( cd "$WORK/amber" && tar xf - ) || { echo "  -> FAIL (copy)"; exit 1; }
# start from a stock tree: drop anything a previous install left behind
rm -f "$WORK/amber/ext/net.c" "$WORK/amber/ext/net.h" "$WORK/amber/ext/ai_ext.c" \
      "$WORK/amber/lib/ai.k" "$WORK/amber/lib/amber_ai_memory.k" "$WORK/amber/lib/ext.k"
# `tar` faithfully reproduces the SOURCE tree's modes, so a stock `git clone` of
# Amber whose ./a is 644 yields a copy whose ./a is 644 too. install.sh's own
# verification pipes into "$AMBER/a" with stderr discarded, so the resulting
# "Permission denied" is swallowed and the empty output is reported as
#   error: the `aio verb did not register -- the extension did not link.
# i.e. a file mode is misdiagnosed as a broken extension seam. Set the bits on
# the copy explicitly; it is a throwaway, so this can disturb nothing.
chmod +x "$WORK/amber/a" "$WORK/amber/build.sh" 2>/dev/null || true
chmod +x "$WORK/amber"/tests/*.sh "$WORK/amber"/tests/*.py 2>/dev/null || true
echo "  -> staged $WORK/amber"

# ------------------------------------------------------------- 3. the installer
say "./install.sh (into the copy)"
./install.sh "$WORK/amber" --yes > "$WORK/install.log" 2>&1
rc=$?
if [ "$rc" != 0 ]; then sed -n '1,60p' "$WORK/install.log"; fi
res $rc "install.sh"
grep -q 'aio verb registered' "$WORK/install.log"; res $? "installer self-verification"

# --------------------------------------------------------- 4. the agent suite
# test_ai.k resolves ../amber.k, ../lib/ai.k and harness.k relative to itself,
# so it runs from inside the target tree's tests/ directory.
say "tests/test_ai.k"
cp tests/test_ai.k "$WORK/amber/tests/test_ai.k"
out=$( cd "$WORK/amber" && ./amber tests/test_ai.k 2>&1 )
echo "$out" | tail -4
echo "$out" | grep -q '0 failures'; res $? "tests/test_ai.k"

# ------------------------------------------------- 4b. the shipped seed corpus
# Every example in lib/amber_ai_memory.k is replayed to the model as a few-shot
# example AND offered back as a Tab candidate, so one that no longer parses is
# worse than none: it teaches a wrong idiom and completes the user into an
# error. Run them all, through the same qsql.k rewriter the REPL uses.
say "tests/verify_memory.k (shipped few-shot corpus)"
cp tests/verify_memory.k "$WORK/amber/tests/verify_memory.k"
out=$( cd "$WORK/amber" && ./amber tests/verify_memory.k 2>&1 )
echo "$out" | tail -3
echo "$out" | grep -q '0 failures'; res $? "tests/verify_memory.k"

# ------------------------------------------------------------- 5. end to end
say "tests/test_e2e.py (real REPL + mock backend)"
if command -v python3 >/dev/null 2>&1; then
  python3 tests/test_e2e.py "$WORK/amber"; res $? "tests/test_e2e.py"
else
  echo "  -> SKIP (no python3)"
fi

# ------------------------------------------------------------- 6. uninstall
say "./uninstall.sh (must leave a stock engine)"
./uninstall.sh "$WORK/amber" > "$WORK/uninstall.log" 2>&1
rc=$?; res $rc "uninstall.sh"
left=$(ls "$WORK/amber/ext"/*.c 2>/dev/null | wc -l)
[ "$left" = 0 ]; res $? "ext/ is empty again"
out=$(printf '\\ai status\n\\\\\n' | "$WORK/amber/a" 2>&1)
case "$out" in *"amber-ai"*) res 1 "no trace of amber-ai after uninstall" ;;
               *)             res 0 "no trace of amber-ai after uninstall" ;; esac

say "result"
[ "$fail" = 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit $fail
