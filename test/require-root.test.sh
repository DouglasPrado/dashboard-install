#!/usr/bin/env bash
#
# Unit test for install.sh's require_root_for_bootstrap() — the preflight that
# stops the bootstrap path on a non-root invocation BEFORE it half-runs and
# leaves orphan files (the failure mode that caught us: ssh-keygen wrote
# data/id_ed25519 as the calling user, then useradd died with "Permission
# denied", and the next sudo re-run inherited a data/ dir owned by the wrong
# uid).
#
# Sources just the function under test, stubs id/die, and asserts the three
# arms: bootstrap+non-root dies; bootstrap+root no-ops; --no-bootstrap no-ops
# (no root needed on that path — it expects the executor pre-provisioned).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

# Source only the pure function under test (the rest runs main on load).
# Set the constants the function reads (install.sh declares them at top but
# we don't source that — keep the test hermetic).
EXECUTOR_USER="claude-bots"
eval "$(sed -n '/^require_root_for_bootstrap()/,/^}/p' "$INSTALL_SH")"

# die() in install.sh prints to stderr and exits non-zero. The test needs to
# survive the failure to inspect the message — stub it to record + return.
DIE_MSG=""
die() { DIE_MSG="$*"; return 1; }

fails=0
assert_dies_with() { # <label> <expected-substring>
  local label="$1" needle="$2"
  if [ -z "$DIE_MSG" ]; then
    printf 'FAIL %s (expected die, none)\n' "$label"
    fails=$((fails + 1)); return
  fi
  case "$DIE_MSG" in
    *"$needle"*) printf 'ok   %s\n' "$label" ;;
    *) printf 'FAIL %s\n       want substring: %s\n       got:            %s\n' "$label" "$needle" "$DIE_MSG"
       fails=$((fails + 1)) ;;
  esac
}
assert_no_die() { # <label>
  local label="$1"
  if [ -n "$DIE_MSG" ]; then
    printf 'FAIL %s (unexpected die: %s)\n' "$label" "$DIE_MSG"
    fails=$((fails + 1))
  else
    printf 'ok   %s\n' "$label"
  fi
}

# Arm 1: bootstrap + non-root → die with sudo + --no-bootstrap hint.
id() { echo 1000; }
BOOTSTRAP="true"; DIE_MSG=""
require_root_for_bootstrap || true
assert_dies_with "bootstrap as non-root dies with sudo hint" "sudo"
assert_dies_with "bootstrap as non-root mentions --no-bootstrap escape" "--no-bootstrap"

# Arm 2: bootstrap + root → no-op (no die, returns 0).
id() { echo 0; }
BOOTSTRAP="true"; DIE_MSG=""
require_root_for_bootstrap
assert_no_die "bootstrap as root is a no-op"

# Arm 3: --no-bootstrap + non-root → no-op (the OS-agnostic path doesn't need root).
id() { echo 1000; }
BOOTSTRAP="false"; DIE_MSG=""
require_root_for_bootstrap
assert_no_die "--no-bootstrap as non-root is a no-op"

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
