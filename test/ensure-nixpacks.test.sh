#!/usr/bin/env bash
#
# Unit test for install.sh's ensure_nixpacks() — the bootstrap step that
# ensures the nixpacks binary is available on the host PATH. Environments in
# nixpacks mode depend on it for building and deploying; it's best-effort
# (returns 0 and warns if installation fails or if BOOTSTRAP=false).
#
# Test arms:
#   1. idempotent: when `nixpacks` is on PATH, no install is attempted
#   2. BOOTSTRAP=false + absent: warns and returns 0 (non-fatal)
#   3. BOOTSTRAP=true + absent + curl available: installs via curl
#   4. BOOTSTRAP=true + absent + no curl: warns and returns 0
#
# No bats in the repo; this sources just the function under test, stubs
# the presence probe (`command -v`) and the install commands, and asserts the arms.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

# Source only the ensure_nixpacks function from install.sh (test Linux path)
eval "$(sed -n '/^ensure_nixpacks()/,/^}/p' "$INSTALL_SH")"

# ── stubs ──────────────────────────────────────────────────────────────────
# Override `command` so we can simulate presence of nixpacks and curl.
# HAS_NIXPACKS / HAS_CURL default to present (1); a test flips them to 0.
# Everything else falls through to the real builtin.

CURL_MARKER=""
curl() { echo "called" >> "$CURL_MARKER"; return 0; }
nixpacks() { echo "nixpacks 1.0.0 (stub)"; }

command() {
  if [ "${1:-}" = "-v" ]; then
    case "${2:-}" in
      nixpacks) [ "${HAS_NIXPACKS:-0}" = 1 ] && { echo /usr/bin/nixpacks; return 0; } || return 1 ;;
      curl)     [ "${HAS_CURL:-1}" = 1 ] && { echo /usr/bin/curl; return 0; } || return 1 ;;
      *)        return 0 ;;
    esac
  fi
  builtin command "$@"
}

LOG_MSG=""; WARN_MSG=""; DIE_MSG=""
log()  { LOG_MSG="$LOG_MSG $*"; }
warn() { WARN_MSG="$WARN_MSG $*"; }
die()  { DIE_MSG="$*"; return 1; }

# ── assertions ───────────────────────────────────────────────────────────────
fails=0
assert_no_die() { # <label>
  [ -z "$DIE_MSG" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s (unexpected die: %s)\n' "$1" "$DIE_MSG"; fails=$((fails + 1)); }
}
assert_warns_with() { # <label> <substring>
  local label="$1" needle="$2"
  case "$WARN_MSG" in
    *"$needle"*) printf 'ok   %s\n' "$label" ;;
    *) printf 'FAIL %s\n       want substring: %s\n       got: %s\n' "$label" "$needle" "$WARN_MSG"; fails=$((fails + 1)) ;;
  esac
}
assert_logs_with() { # <label> <substring>
  local label="$1" needle="$2"
  case "$LOG_MSG" in
    *"$needle"*) printf 'ok   %s\n' "$label" ;;
    *) printf 'FAIL %s\n       want substring: %s\n       got: %s\n' "$label" "$needle" "$LOG_MSG"; fails=$((fails + 1)) ;;
  esac
}
assert_eq() { # <label> <got> <want>
  [ "$2" = "$3" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s\n       want: %s\n       got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); }
}
assert_curl_called() { # <label>
  [ -s "$CURL_MARKER" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s\n       curl was not called (marker file empty or absent)\n' "$1"; fails=$((fails + 1)); }
}
assert_curl_not_called() { # <label>
  [ ! -s "$CURL_MARKER" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s\n       curl was called but should not have been\n' "$1"; fails=$((fails + 1)); }
}

# ── Arm 1: nixpacks already present → idempotent, no curl call, logs "present" ──
HAS_NIXPACKS=1; HAS_CURL=1; BOOTSTRAP="true"
LOG_MSG=""; WARN_MSG=""; DIE_MSG=""
CURL_MARKER=$(mktemp)
ensure_nixpacks || true
assert_no_die "idempotent: already present does not die"
assert_curl_not_called "idempotent: curl not called"
assert_logs_with "idempotent: logs present" "present"
rm -f "$CURL_MARKER"

# ── Arm 2: BOOTSTRAP=false + nixpacks absent → warns, returns 0 ──
HAS_NIXPACKS=0; HAS_CURL=1; BOOTSTRAP="false"
LOG_MSG=""; WARN_MSG=""; DIE_MSG=""
CURL_MARKER=$(mktemp)
ensure_nixpacks
rc=$?
assert_eq     "no-bootstrap: returns 0" "$rc" "0"
assert_no_die "no-bootstrap: does not die"
assert_curl_not_called "no-bootstrap: curl not called"
assert_warns_with "no-bootstrap: warns about missing nixpacks" "missing"
rm -f "$CURL_MARKER"

# ── Arm 3: BOOTSTRAP=true + nixpacks absent + curl available → install via curl ──
HAS_NIXPACKS=0; HAS_CURL=1; BOOTSTRAP="true"
LOG_MSG=""; WARN_MSG=""; DIE_MSG=""
CURL_MARKER=$(mktemp)
ensure_nixpacks || true
# After the install attempt, nixpacks will still be "absent" because our stub
# doesn't actually install it, but we should see a curl call and an attempt message.
assert_no_die "bootstrap+curl: does not die"
assert_curl_called "bootstrap+curl: curl called"
assert_logs_with "bootstrap+curl: logs install attempt" "installing"
rm -f "$CURL_MARKER"

# ── Arm 4: BOOTSTRAP=true + nixpacks absent + no curl → warns, returns 0 ──
HAS_NIXPACKS=0; HAS_CURL=0; BOOTSTRAP="true"
LOG_MSG=""; WARN_MSG=""; DIE_MSG=""
CURL_MARKER=$(mktemp)
ensure_nixpacks
rc=$?
assert_eq     "bootstrap+no-curl: returns 0" "$rc" "0"
assert_no_die "bootstrap+no-curl: does not die"
assert_curl_not_called "bootstrap+no-curl: curl not called"
assert_warns_with "bootstrap+no-curl: warns curl unavailable" "curl unavailable"
rm -f "$CURL_MARKER"


# Print summary
if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
