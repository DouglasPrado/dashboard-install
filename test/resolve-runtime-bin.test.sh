#!/usr/bin/env bash
#
# Unit test for install.sh's resolve_runtime_bin() — the function that locates
# where each native runtime installer dropped its binary so it can be symlinked
# onto /usr/local/bin (the only PATH the dashboard's non-interactive ssh sees).
#
# No bats in the repo; this sources just the function under test, stubs the
# login-shell lookup (runuser) so the deterministic dir-search path is exercised,
# and asserts against fixture dirs that mirror each installer's real layout.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

# Force the dir-search branch: make the login-shell lookup find nothing.
EXECUTOR_USER="test-user"
runuser() { return 1; }

# Source only the pure functions under test (the rest runs main on load).
eval "$(sed -n '/^resolve_runtime_bin()/,/^}/p; /^runtime_login_spec()/,/^}/p; /^runtime_authed()/,/^}/p' "$INSTALL_SH")"

fails=0
assert_resolves() { # <label> <binary> <home> <expected-path>
  local label="$1" bin="$2" home="$3" want="$4" got
  got="$(resolve_runtime_bin "$bin" "$home")" || got="<not found>"
  if [ "$got" = "$want" ]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n       want: %s\n       got:  %s\n' "$label" "$want" "$got"
    fails=$((fails + 1))
  fi
}

H="$(mktemp -d)"
trap 'rm -rf "$H"' EXIT
mkbin() { mkdir -p "$(dirname "$1")"; : > "$1"; chmod +x "$1"; }

# opencode: ~/.opencode/bin/<bin> (control — already covered today)
mkbin "$H/.opencode/bin/opencode"
assert_resolves "opencode in ~/.opencode/bin" opencode "$H" "$H/.opencode/bin/opencode"

# codex: standalone installer drops it under packages/standalone/current/bin
mkbin "$H/.codex/packages/standalone/current/bin/codex"
assert_resolves "codex in standalone/current/bin" codex "$H" "$H/.codex/packages/standalone/current/bin/codex"

# cursor: versioned dir under ~/.local/share/cursor-agent/versions/<ver>/
mkbin "$H/.local/share/cursor-agent/versions/2026.05.24-abc/cursor-agent"
assert_resolves "cursor-agent in versions/<ver>" cursor-agent "$H" \
  "$H/.local/share/cursor-agent/versions/2026.05.24-abc/cursor-agent"

# cursor: newest version wins when several are present
mkbin "$H/.local/share/cursor-agent/versions/2026.06.01-def/cursor-agent"
assert_resolves "cursor-agent newest version wins" cursor-agent "$H" \
  "$H/.local/share/cursor-agent/versions/2026.06.01-def/cursor-agent"

assert_authed() {   # <label> <runtime-id> <home>
  local label="$1" rt="$2" home="$3"
  if runtime_authed "$rt" "$home"; then printf 'ok   %s\n' "$label"
  else printf 'FAIL %s (expected authed)\n' "$label"; fails=$((fails + 1)); fi
}
assert_not_authed() { # <label> <runtime-id> <home>
  local label="$1" rt="$2" home="$3"
  if runtime_authed "$rt" "$home"; then printf 'FAIL %s (expected NOT authed)\n' "$label"; fails=$((fails + 1))
  else printf 'ok   %s\n' "$label"; fi
}

# runtime_authed: probe file present → authed
mkdir -p "$H/.claude"; : > "$H/.claude/.credentials.json"
assert_authed "claude-code authed when creds present" claude-code "$H"
# probe file absent → not authed
assert_not_authed "codex not authed without auth.json" codex "$H"
# empty probe (cursor) → always not authed (status unknown)
assert_not_authed "cursor not authed (no probe)" cursor "$H"

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
