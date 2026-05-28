#!/usr/bin/env bash
#
# Regression test for compose.prod.yml — the mounts the dashboard relies on.
#
# Bug history: without /home/claude-bots/.claude mounted into /claude inside the
# container, the chat panel reads /claude/projects/*/*.jsonl and finds nothing,
# so the UI appears empty even after `claude /login`. Catch any future
# accidental removal of the bind here, plus the data/license/SSH key mount.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$SCRIPT_DIR/../compose.prod.yml"

[ -f "$COMPOSE" ] || { echo "FAIL: $COMPOSE not found"; exit 1; }

fails=0
assert_grep() { # <label> <pattern>
  local label="$1" pat="$2"
  if grep -qE "$pat" "$COMPOSE"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n       pattern: %s\n' "$label" "$pat"
    fails=$((fails + 1))
  fi
}

# server/license/runtime.ts defaults to /data/license.key and ssh-exec.ts to
# /data/ssh/id_ed25519 — both live under the same ./data bind.
assert_grep "./data mounted at /data" '^\s*-\s*\./data:/data(\s|$)'

# server/claude.ts reads ~/.claude under /claude/* (projects, plans, sessions,
# history, settings). The executor home is owned by claude-bots.
assert_grep "executor /home/claude-bots/.claude mounted at /claude" \
  '^\s*-\s*/home/claude-bots/\.claude:/claude(\s|$)'

# server/clone-project.ts and the workspace executor share /workspace on the host.
assert_grep "/root/workspace mounted at /workspace" \
  '^\s*-\s*/root/workspace:/workspace(\s|$)'

# host-gateway is required for SSH back to the host executor (claude-bots).
assert_grep "host.docker.internal mapped to host-gateway" \
  'host\.docker\.internal:host-gateway'

# License file path pinned under /data (matches ./data:/data mount). Belt and
# suspenders for older images whose default still resolves via process.cwd().
assert_grep "LICENSE_FILE pinned to /data/license.key" \
  '^\s*-\s*LICENSE_FILE=/data/license\.key\s*$'

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
