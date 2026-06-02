#!/usr/bin/env bash
#
# Unit test for install.sh's ensure_tailscale() — makes the host a Tailscale
# subnet router for its LAN so --tailscale can serve the dashboard via Traefik
# from anywhere on the tailnet. Node auth is OAuth/browser unless --ts-authkey is
# given, so a non-interactive run without a key must fail loud, not hang.
#
# No bats: source just the function under test, define a `tailscale` shell
# function (so `command -v tailscale` resolves and we can script its behaviour),
# stub detect_lan_cidr + the system commands, and assert the arms:
#   A) --tailscale off            → no-op, never touches tailscale
#   B) present + already up        → advertises route via `tailscale set` (no up)
#   C) logged out + --ts-authkey   → `tailscale up --authkey <key> --advertise-routes=<cidr>`
#   D) logged out + no key + piped → die (can't OAuth non-interactively)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

eval "$(sed -n '/^ensure_tailscale()/,/^}/p' "$INSTALL_SH")"

detect_lan_cidr() { echo "10.0.0.0/24"; }
cat()       { echo 1; }
sysctl()    { return 0; }
systemctl() { return 1; }
curl()      { return 0; }

TS_STATUS_RC=0; TS_STATUS_OUT=""; TS_UP_ARGS="__unset__"; TS_SET_ARGS="__unset__"
tailscale() {
  case "${1:-}" in
    status) printf '%s\n' "$TS_STATUS_OUT"; return "$TS_STATUS_RC" ;;
    up)     shift; TS_UP_ARGS="$*"; return 0 ;;
    set)    shift; TS_SET_ARGS="$*"; return 0 ;;
    *)      return 0 ;;
  esac
}

DIE_MSG=""; WARN_MSG=""
log()  { :; }
warn() { WARN_MSG="$WARN_MSG $*"; }
die()  { DIE_MSG="$*"; return 1; }

reset() { TS_STATUS_RC=0; TS_STATUS_OUT=""; TS_UP_ARGS="__unset__"; TS_SET_ARGS="__unset__"; DIE_MSG=""; WARN_MSG=""; }

fails=0
assert_eq() { [ "$2" = "$3" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s\n       want: %s\n       got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); }; }
assert_nonempty() { [ -n "$2" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s (expected non-empty)\n' "$1"; fails=$((fails + 1)); }; }

reset; TAILSCALE="false"; BOOTSTRAP="true"; TS_AUTHKEY=""
ensure_tailscale </dev/null
assert_eq "off: never runs tailscale up"  "$TS_UP_ARGS"  "__unset__"
assert_eq "off: never runs tailscale set" "$TS_SET_ARGS" "__unset__"

reset; TAILSCALE="true"; BOOTSTRAP="true"; TS_AUTHKEY=""
TS_STATUS_RC=0; TS_STATUS_OUT="100.64.0.1 host ... active; relay"
ensure_tailscale </dev/null
assert_eq "already up: sets route, no up" "$TS_UP_ARGS"  "__unset__"
assert_eq "already up: advertises cidr"   "$TS_SET_ARGS" "--advertise-routes=10.0.0.0/24"

reset; TAILSCALE="true"; BOOTSTRAP="true"; TS_AUTHKEY="tskey-auth-abc123"
TS_STATUS_RC=1; TS_STATUS_OUT="Logged out."
ensure_tailscale </dev/null
assert_eq "authkey: up with key + route" "$TS_UP_ARGS" "--authkey tskey-auth-abc123 --advertise-routes=10.0.0.0/24"

reset; TAILSCALE="true"; BOOTSTRAP="true"; TS_AUTHKEY=""
TS_STATUS_RC=1; TS_STATUS_OUT="Logged out."
ensure_tailscale </dev/null
assert_eq "no key, piped: never blindly runs up" "$TS_UP_ARGS" "__unset__"
assert_nonempty "no key, piped: dies with guidance" "$DIE_MSG"

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
