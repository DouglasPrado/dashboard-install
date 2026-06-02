#!/usr/bin/env bash
#
# Unit test for uninstall.sh's cleanup steps.
#
#   remove_runtimes — removes the /usr/local/bin symlinks install.sh created
#   (claude/opencode/codex/cursor-agent AND rtk). Two regressions guarded:
#     1. `((removed++))` returned exit 1 when removed was 0, which under the
#        script's `set -euo pipefail` aborted uninstall on the FIRST symlink
#        found. The counter must not kill the run.
#     2. rtk was symlinked by install_rtk but never cleaned up — left orphaned.
#
#   remove_stack — the shared Traefik stack is never torn down on a default
#   ("all") uninstall (other projects route through it); only on an explicit
#   --components stack.
#
# No bats: source just the functions under test, stub log/warn, inject BIN_DIR.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALL_SH="$SCRIPT_DIR/../uninstall.sh"

EXECUTOR_USER="claude-bots"

eval "$(sed -n '/^has_component()/,/^}/p; /^remove_runtimes()/,/^}/p; /^remove_stack()/,/^}/p' "$UNINSTALL_SH")"

DIE_MSG=""; WARN_MSG=""; LOG_MSG=""
log()  { LOG_MSG="$LOG_MSG $*"; }
warn() { WARN_MSG="$WARN_MSG $*"; }
die()  { DIE_MSG="$*"; return 1; }

fails=0
assert_eq() { [ "$2" = "$3" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s\n       want: %s\n       got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); }; }
assert_no_file() { [ ! -e "$2" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s (still exists: %s)\n' "$1" "$2"; fails=$((fails + 1)); }; }
assert_contains() { case "$2" in *"$3"*) printf 'ok   %s\n' "$1" ;; *) printf 'FAIL %s (want substring %q in %q)\n' "$1" "$3" "$2"; fails=$((fails + 1)) ;; esac; }

# ── remove_runtimes ──────────────────────────────────────────────────────────
BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$BIN_DIR"' EXIT
: > "$BIN_DIR/_target"
for b in claude opencode codex cursor-agent rtk; do ln -sf "$BIN_DIR/_target" "$BIN_DIR/$b"; done

# Run under `set -e` exactly like uninstall.sh's top-level — the old
# `((removed++))` aborted here on the first symlink. The fix must survive.
COMPONENTS="all"; CHECK_ONLY="false"
( set -e; remove_runtimes ); rc=$?
assert_eq "remove_runtimes survives set -e (counter bug)" "$rc" "0"
assert_no_file "removes claude symlink"       "$BIN_DIR/claude"
assert_no_file "removes rtk symlink (was orphaned)" "$BIN_DIR/rtk"
assert_no_file "removes cursor-agent symlink" "$BIN_DIR/cursor-agent"

# ── remove_stack: default "all" leaves the shared stack alone ────────────────
docker() { echo "DOCKER CALLED: $*" >&2; return 0; }   # must NOT be called
LOG_MSG=""; COMPONENTS="all"; CHECK_ONLY="false"
remove_stack; rc=$?
assert_eq "remove_stack returns 0 on all" "$rc" "0"
assert_contains "remove_stack leaves shared stack on all" "$LOG_MSG" "leaving shared stack"

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
