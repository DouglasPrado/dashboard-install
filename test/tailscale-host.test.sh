#!/usr/bin/env bash
#
# Unit test for install.sh's tailnet-host helpers — the bit that makes a fresh
# install reachable from other networks over Tailscale without manual config.
#
# Why: the dashboard host is `dash.<ip>.nip.io`, and nip.io resolves to the IP
# embedded in the name. A LAN IP (192.168.x) isn't routable from another
# network, so a remote tailnet node 404s. The installer must also advertise the
# host's tailnet IP (100.x) as a Traefik Host so any tailnet peer can reach it.
#
# Covers the two pure functions: detect_tailscale_ip (first -4 addr, empty when
# the CLI is absent) and build_traefik_rule (one or more `Host(...)` joined with
# `||`, empty args skipped).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

eval "$(sed -n '/^detect_tailscale_ip()/,/^}/p; /^build_traefik_rule()/,/^}/p' "$INSTALL_SH")"

# Override `command -v` so we control whether the tailscale CLI "exists".
command() {
  if [ "${1:-}" = "-v" ]; then
    case "${2:-}" in
      tailscale) [ "${HAS_TS:-1}" = 1 ] && { echo /usr/bin/tailscale; return 0; } || return 1 ;;
      *) return 0 ;;
    esac
  fi
  builtin command "$@"
}
# Stub the CLI: `tailscale ip -4` prints whatever TS_OUT holds.
tailscale() { printf '%s\n' "${TS_OUT:-}"; }

fails=0
assert_eq() { # <label> <got> <want>
  [ "$2" = "$3" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$3" "$2"; fails=$((fails + 1)); }
}

# ── detect_tailscale_ip ──
HAS_TS=1; TS_OUT=$'100.108.156.85'
assert_eq "single tailnet ip" "$(detect_tailscale_ip)" "100.108.156.85"

HAS_TS=1; TS_OUT=$'100.108.156.85\nfd7a:115c::1'   # picks the first (-4) line
assert_eq "first ip wins"     "$(detect_tailscale_ip)" "100.108.156.85"

HAS_TS=0; TS_OUT=""
assert_eq "no tailscale CLI → empty" "$(detect_tailscale_ip)" ""

# ── build_traefik_rule ──
assert_eq "single host" "$(build_traefik_rule 'dash.192.168.3.139.nip.io')" \
  'Host(`dash.192.168.3.139.nip.io`)'
assert_eq "two hosts joined with ||" "$(build_traefik_rule 'dash.192.168.3.139.nip.io' 'dash.100.108.156.85.nip.io')" \
  'Host(`dash.192.168.3.139.nip.io`) || Host(`dash.100.108.156.85.nip.io`)'
assert_eq "empty alt skipped" "$(build_traefik_rule 'dash.192.168.3.139.nip.io' '')" \
  'Host(`dash.192.168.3.139.nip.io`)'

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
