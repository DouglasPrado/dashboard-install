#!/usr/bin/env bash
#
# Unit test for ci/check-required-artifacts.sh — the CI guard that fails the
# build when the image is MISSING a runtime artifact the app needs at boot.
# Complements image-guard.test.sh (which guards against *extra* source leaks);
# this guards against *missing* essentials, the ask_human MCP bridge above all.
#
# Pure text over a path listing (e.g. `docker export <cid> | tar -t`), tested
# offline here and sharing ONE required-artifact list with release.yml via the
# script under test (no drift between CI and this test).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../ci/check-required-artifacts.sh"

[ -x "$CHECK" ] || { echo "FAIL: $CHECK not found or not executable"; exit 1; }

# A complete, valid image listing (what `docker export | tar -t` would emit).
complete() {
  cat <<'EOF'
app/package.json
app/dist/index.html
app/dist-server/index.js
app/dist-server/mcp-askhuman-server.mjs
app/node_modules/foo/index.js
EOF
}

fails=0
assert_accepts() { # <label> <stdin-listing>
  local label="$1"
  if "$CHECK" >/dev/null 2>&1; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s (rejected, want accept)\n' "$label"
    fails=$((fails + 1))
  fi
}
assert_rejects() { # <label> <stdin-listing>
  local label="$1"
  if "$CHECK" >/dev/null 2>&1; then
    printf 'FAIL %s (accepted, want reject)\n' "$label"
    fails=$((fails + 1))
  else
    printf 'ok   %s\n' "$label"
  fi
}

assert_accepts "complete image"             < <(complete)
# Drop the bridge mjs — the exact clean-install regression we guard against.
assert_rejects "missing askhuman bridge"    < <(complete | grep -v 'mcp-askhuman-server.mjs')
assert_rejects "missing server bundle"      < <(complete | grep -v 'dist-server/index.js')
assert_rejects "empty listing"              < <(true)

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
