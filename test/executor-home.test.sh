#!/usr/bin/env bash
#
# Regression guard for the "/root leak" bug: the per-user installers
# (install_caveman, install_rtk, install_runtime) run under
# `runuser -u "$EXECUTOR_USER"`, which sets the uid but KEEPS the caller's
# HOME (/root) and cwd (/root). Tools they shell out to resolve paths from
# $HOME/cwd, so left unpinned they failed with EACCES (skills → /root/.agents)
# or registered at the wrong scope (MCP → [project: /root]) and codex's installer
# could not write cwd-relative state. Each of these functions MUST pin HOME and
# cd into the executor home inside its runuser block.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

# Extract a shell function body (from `name()` to the closing `}` at col 0).
fn_body() { sed -n "/^$1()/,/^}/p" "$INSTALL_SH"; }

assert_pins_home() { # <function-name>
  local body; body="$(fn_body "$1")"
  [ -n "$body" ] || { bad "$1 not found in install.sh"; return; }
  case "$body" in
    *'runuser -u "$EXECUTOR_USER"'*) ;;
    *) bad "$1 has no runuser block to guard"; return ;;
  esac
  case "$body" in
    *"export HOME='\$home'"*) ok "$1 pins HOME to executor home" ;;
    *) bad "$1 does not 'export HOME=\$home' (would inherit caller /root)" ;;
  esac
  case "$body" in
    *"cd '\$home'"*) ok "$1 cd's into executor home" ;;
    *) bad "$1 does not 'cd \$home' (would run with cwd=/root)" ;;
  esac
}

assert_pins_home install_caveman
assert_pins_home install_rtk
assert_pins_home install_runtime

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
