#!/usr/bin/env bash
# =============================================================================
# amber-ai uninstaller.
#
#     ./uninstall.sh /path/to/amber
#     ./uninstall.sh                  # same auto-detection as install.sh
#
# Removes ext/net.c, ext/net.h, ext/ai_ext.c and lib/ai.k, drops amber-ai's
# loader line from lib/ext.k, and rebuilds. Amber's build.sh prunes object files
# whose source has gone, so the resulting binary is byte-for-byte a stock one.
#
# Your persistent memory (~/.amber_ai_memory.k) is NOT deleted -- it is your
# data. Pass --purge to delete it too.
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
PURGE=0; TARGET=""
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) TARGET="$a" ;;
  esac
done

is_amber(){ [ -n "${1:-}" ] && [ -f "$1/src/a.h" ] && [ -f "$1/build.sh" ]; }
AMBER=""
for c in $TARGET ${AMBER_HOME:-} "$HERE/../amber" "$PWD/../amber" "$HOME/amber"; do
  [ -d "$c" ] || continue
  c="$(cd "$c" && pwd)"
  if is_amber "$c"; then AMBER="$c"; break; fi
done
[ -n "$AMBER" ] || { echo "error: could not find an Amber installation; pass the path" >&2; exit 1; }

echo "==> removing amber-ai from $AMBER"
for f in ext/net.c ext/net.h ext/ai_ext.c lib/ai.k; do
  if [ -e "$AMBER/$f" ]; then rm -f "$AMBER/$f" && echo "    removed $f"; fi
done

EXTK="$AMBER/lib/ext.k"
if [ -f "$EXTK" ]; then
  # drop amber-ai's marker line, its loader line, and the blank line before it
  tmp="$EXTK.tmp.$$"
  grep -v '^/ amber-ai ' "$EXTK" | grep -v 'lib/ai\.k' > "$tmp" && mv "$tmp" "$EXTK"
  echo "    cleaned lib/ext.k"
  # if nothing but the header comment is left, remove the file entirely
  if ! grep -qv '^\s*\(/.*\)\?$' "$EXTK"; then rm -f "$EXTK"; echo "    removed lib/ext.k (empty)"; fi
fi

echo "==> rebuilding stock amber"
( cd "$AMBER" && bash build.sh ) || { echo "error: rebuild failed" >&2; exit 1; }

if [ "$PURGE" = 1 ]; then
  m="${AMBER_AI_MEMORY:-$HOME/.amber_ai_memory.k}"
  [ -e "$m" ] && rm -f "$m" && echo "    purged $m"
else
  echo "    kept ${AMBER_AI_MEMORY:-$HOME/.amber_ai_memory.k} (pass --purge to delete it)"
fi

echo
echo "amber-ai removed. $AMBER is stock again."
