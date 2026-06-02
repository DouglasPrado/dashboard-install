#!/usr/bin/env bash
#
# Unit test for install.sh's ensure_tailscale() — installs Tailscale and brings
# the node up so --tailscale can front the dashboard with `tailscale serve`
# (HTTPS on the tailnet, identity header injected, Funnel OFF). Node auth is
# OAuth/browser unless --ts-authkey is given, so a non-interactive run without a
# key must fail loud instead of hanging.
#
# No bats: source just the function under test, define a `tailscale` shell
# function (so `command -v tailscale` resolves and we can script its behaviour),
# stub systemctl/log/warn/die, and assert the arms:
#   A) --tailscale off            → no-op, never touches tailscale
#   B) present + already up        → does NOT re-run `tailscale up`
#   C) logged out + --ts-authkey   → runs `tailscale up --authkey <key>`
#   D) logged out + no key + piped → die (can't OAuth non-interactively)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

# Source only the function under test (the rest runs main on load).
eval "$(sed -n '/^ensure_tailscale()/,/^}/p' "$INSTALL_SH")"

# ── scriptable tailscale stub ────────────────────────────────────────────────
# TS_STATUS_RC drives `tailscale status` exit code; TS_STATUS_OUT its stdout.
# TS_UP_ARGS captures the args `tailscale up` was called with (empty = not run).
TS_STATUS_RC=0; TS_STATUS_OUT=""; TS_UP_ARGS="__unset__"; TS_SERVE_ARGS="__unset__"
tailscale() {
  case "${1:-}" in
    status) printf '%s\n' "$TS_STATUS_OUT"; return "$TS_STATUS_RC" ;;
    up)     shift; TS_UP_ARGS="$*"; return 0 ;;
    serve)  shift; TS_SERVE_ARGS="$*"; return 0 ;;
    *)      return 0 ;;
  esac
}
systemctl() { return 1; }   # pretend no systemd; ensure no real host is touched
curl()      { return 0; }   # install path must not run in these arms (present)

DIE_MSG=""; WARN_MSG=""
log()  { :; }
warn() { WARN_MSG="$WARN_MSG $*"; }
die()  { DIE_MSG="$*"; return 1; }

reset() { TS_STATUS_RC=0; TS_STATUS_OUT=""; TS_UP_ARGS="__unset__"; TS_SERVE_ARGS="__unset__"; DIE_MSG=""; WARN_MSG=""; }

# ── assertions ───────────────────────────────────────────────────────────────
fails=0
assert_eq() { # <label> <got> <want>
  [ "$2" = "$3" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s\n       want: %s\n       got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); }
}
assert_nonempty() { # <label> <got>
  [ -n "$2" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s (expected non-empty)\n' "$1"; fails=$((fails + 1)); }
}

# Arm A: --tailscale off → no-op.
reset; TAILSCALE="false"; BOOTSTRAP="true"; TS_AUTHKEY=""
ensure_tailscale </dev/null
assert_eq "off: never runs tailscale up" "$TS_UP_ARGS" "__unset__"

# Arm B: present + already up (status ok, not "logged out") → no re-up.
reset; TAILSCALE="true"; BOOTSTRAP="true"; TS_AUTHKEY=""
TS_STATUS_RC=0; TS_STATUS_OUT="100.101.102.103 host tagged ... active; relay"
ensure_tailscale </dev/null
assert_eq "already up: does not re-run up" "$TS_UP_ARGS" "__unset__"

# Arm C: logged out + auth key → tailscale up --authkey <key>.
reset; TAILSCALE="true"; BOOTSTRAP="true"; TS_AUTHKEY="tskey-auth-abc123"
TS_STATUS_RC=1; TS_STATUS_OUT="Logged out."
ensure_tailscale </dev/null
assert_eq "authkey: runs up with key" "$TS_UP_ARGS" "--authkey tskey-auth-abc123"

# Arm D: logged out + no key + non-interactive (stdin from /dev/null) → die.
reset; TAILSCALE="true"; BOOTSTRAP="true"; TS_AUTHKEY=""
TS_STATUS_RC=1; TS_STATUS_OUT="Logged out."
ensure_tailscale </dev/null
assert_eq "no key, piped: never blindly runs up" "$TS_UP_ARGS" "__unset__"
assert_nonempty "no key, piped: dies with guidance" "$DIE_MSG"

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
