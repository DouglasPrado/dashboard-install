#!/usr/bin/env bash
#
# Unit test for install.sh's install_subagents() — provisions the canonical
# Claude Code subagents (currently just test-writer) into the executor user's
# ~/.claude/agents so the dashboard's agents can delegate test work via the Task
# tool (subagent_type) in ANY project they run in, not only repos that happen to
# ship their own .claude/agents dir. User-level resolves regardless of run cwd.
#
# No bats in the repo; this sources just the function under test, stubs the
# passwd lookup (getent) to point at a temp home, stubs chown, and asserts the
# arms: --no-bootstrap no-ops; bootstrap + absent writes a valid subagent file;
# bootstrap + present is idempotent (does not clobber a local edit).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

EXECUTOR_USER="claude-bots"

# Source only the function under test (the rest runs main on load).
eval "$(sed -n '/^install_subagents()/,/^}/p' "$INSTALL_SH")"

# ── stubs ──────────────────────────────────────────────────────────────────
TEST_HOME=""
getent() { echo "claude-bots:x:1000:1000::$TEST_HOME:/bin/bash"; }
chown()  { return 0; }

DIE_MSG=""; WARN_MSG=""
log()  { :; }
warn() { WARN_MSG="$WARN_MSG $*"; }
die()  { DIE_MSG="$*"; return 1; }

# ── assertions ───────────────────────────────────────────────────────────────
fails=0
assert_eq() { # <label> <got> <want>
  [ "$2" = "$3" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s\n       want: %s\n       got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); }
}
assert_file_contains() { # <label> <file> <substring>
  if [ -f "$2" ] && grep -q -- "$3" "$2"; then printf 'ok   %s\n' "$1"; else
    printf 'FAIL %s (file %s missing or lacks %q)\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}
assert_no_file() { # <label> <file>
  [ ! -f "$2" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s (unexpected file %s)\n' "$1" "$2"; fails=$((fails + 1)); }
}

mk_home() { TEST_HOME="$(mktemp -d)"; }

# Arm 1: --no-bootstrap → no-op, nothing written.
mk_home; BOOTSTRAP="false"
install_subagents
assert_no_file "no-bootstrap: writes nothing" "$TEST_HOME/.claude/agents/test-writer.md"
rm -rf "$TEST_HOME"

# Arm 2: bootstrap + absent → writes a valid haiku-pinned test-writer subagent.
mk_home; BOOTSTRAP="true"
install_subagents
f="$TEST_HOME/.claude/agents/test-writer.md"
assert_file_contains "bootstrap: name frontmatter"  "$f" "name: test-writer"
assert_file_contains "bootstrap: pinned to haiku"   "$f" "model: haiku"
# Safety constraint: subagent must not commit/push — parent owns git.
assert_file_contains "bootstrap: defers git"        "$f" "Do NOT commit"
rm -rf "$TEST_HOME"

# Arm 3: bootstrap + present → idempotent, does not clobber a local edit.
mk_home; BOOTSTRAP="true"
mkdir -p "$TEST_HOME/.claude/agents"
echo "LOCAL EDIT — keep me" > "$TEST_HOME/.claude/agents/test-writer.md"
install_subagents
got="$(cat "$TEST_HOME/.claude/agents/test-writer.md")"
assert_eq "present: local edit preserved" "$got" "LOCAL EDIT — keep me"
rm -rf "$TEST_HOME"

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
