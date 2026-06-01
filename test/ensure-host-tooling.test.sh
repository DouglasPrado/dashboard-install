#!/usr/bin/env bash
#
# Unit test for install.sh's ensure_host_tooling() — the bootstrap step that
# installs the host-side tools the dashboard's clone/worktree/preview path runs
# AS THE EXECUTOR over SSH: git (clone-project.ts runs `git clone`, git-worktree.ts
# runs `git worktree` on the host; the preview mounts that worktree into /app) and
# Node.js (so agents can run project dev tooling directly against a host worktree).
#
# Bug history: install.sh ensured docker/stack/executor/agent-CLIs but never git
# or node. Dev hosts had both pre-installed system-wide, so it passed there; a
# fresh VM had neither, so clone failed and live preview never came up.
#
# No bats in the repo; this sources just the function under test, stubs the
# presence probe (`command -v`) and the package-manager calls, and asserts the
# arms: all-present no-ops; --no-bootstrap + missing dies; bootstrap + missing +
# no apt warns and returns 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

# Constants the function reads (install.sh declares them at top; keep hermetic).
NODE_MAJOR="22"

# Source only the function under test (the rest runs main on load).
eval "$(sed -n '/^ensure_host_tooling()/,/^}/p' "$INSTALL_SH")"

# ── stubs ──────────────────────────────────────────────────────────────────
# Override `command` so we can simulate which host tools are present. HAS_GIT /
# HAS_NODE / HAS_APT default to present (1); a test flips them to 0 to simulate
# absence. Everything else falls through to the real builtin.
command() {
  if [ "${1:-}" = "-v" ]; then
    case "${2:-}" in
      git)      [ "${HAS_GIT:-1}"  = 1 ] && { echo /usr/bin/git;     return 0; } || return 1 ;;
      node)     [ "${HAS_NODE:-1}" = 1 ] && { echo /usr/bin/node;    return 0; } || return 1 ;;
      apt-get)  [ "${HAS_APT:-1}"  = 1 ] && { echo /usr/bin/apt-get; return 0; } || return 1 ;;
      curl)     return 0 ;;
      corepack) return 1 ;;
      *)        return 0 ;;
    esac
  fi
  builtin command "$@"
}

APT_CALLS=0
apt-get() { APT_CALLS=$((APT_CALLS + 1)); return 0; }
curl()    { return 0; }
corepack(){ return 0; }
git()     { echo "git version 0 (stub)"; }
node()    { echo "v0 (stub)"; }

DIE_MSG=""; WARN_MSG=""
log()  { :; }
warn() { WARN_MSG="$WARN_MSG $*"; }
die()  { DIE_MSG="$*"; return 1; }

# ── assertions ───────────────────────────────────────────────────────────────
fails=0
assert_dies_with() { # <label> <substring>
  local label="$1" needle="$2"
  case "$DIE_MSG" in
    *"$needle"*) printf 'ok   %s\n' "$label" ;;
    *) printf 'FAIL %s\n       want substring: %s\n       got: %s\n' "$label" "$needle" "$DIE_MSG"; fails=$((fails + 1)) ;;
  esac
}
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
assert_eq() { # <label> <got> <want>
  [ "$2" = "$3" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s\n       want: %s\n       got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); }
}

# Arm 1: git + node already present → no-op, no package manager touched.
HAS_GIT=1; HAS_NODE=1; HAS_APT=1; BOOTSTRAP="true"
DIE_MSG=""; WARN_MSG=""; APT_CALLS=0
ensure_host_tooling || true
assert_no_die "all present: no die"
assert_eq    "all present: apt-get not called" "$APT_CALLS" "0"

# Arm 2: --no-bootstrap + git missing → die naming git (no install on that path).
HAS_GIT=0; HAS_NODE=1; HAS_APT=1; BOOTSTRAP="false"
DIE_MSG=""; WARN_MSG=""; APT_CALLS=0
ensure_host_tooling || true
assert_dies_with "no-bootstrap + missing git dies naming git" "git"
assert_eq        "no-bootstrap: apt-get not called" "$APT_CALLS" "0"

# Arm 3: bootstrap + missing node + no apt-get → warn, return 0 (best-effort).
HAS_GIT=1; HAS_NODE=0; HAS_APT=0; BOOTSTRAP="true"
DIE_MSG=""; WARN_MSG=""; APT_CALLS=0
ensure_host_tooling
rc=$?
assert_no_die "bootstrap + no apt: does not die"
assert_eq     "bootstrap + no apt: returns 0" "$rc" "0"
assert_warns_with "bootstrap + no apt: warns apt-get unavailable" "apt-get"

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
