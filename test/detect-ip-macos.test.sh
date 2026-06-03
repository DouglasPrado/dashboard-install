#!/usr/bin/env bash
#
# Unit test for install-macos.sh's detect_ip — the macOS-native primary-IP probe.
#
# Linux's detect_ip uses `ip` (iproute2), which doesn't exist on macOS. The mac
# variant resolves the default-route interface with `route -n get` and then its
# address with `ipconfig getifaddr`. It MUST honour the same load-bearing
# contract as the Linux one: ALWAYS exit 0 (emit the IP when found, empty string
# otherwise), because the caller assigns it under `set -e`
# (`HOST="dash.$(detect_ip).nip.io"`). A non-zero detect_ip would abort the
# installer SILENTLY — the exact "curl | bash does nothing on macOS" footgun.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install-macos.sh"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$INSTALL_SH" ] || { bad "install-macos.sh not found at $INSTALL_SH"; echo "FAILED: $fails"; exit 1; }

# detect_ip may span multiple lines on macOS (iface lookup + getifaddr), so
# extract the whole function body, not a single line.
eval "$(sed -n '/^detect_ip()/,/^}/p' "$INSTALL_SH")"
command -v detect_ip >/dev/null 2>&1 || { bad "detect_ip not defined in install-macos.sh"; echo "FAILED: $fails"; exit 1; }

# ── stubs: simulate the two macOS network tools ──────────────────────────────
# `route -n get 1.1.1.1` prints a block including "   interface: en0".
# `ipconfig getifaddr en0` prints the address bound to that interface.
ROUTE_IFACE="en0"
IPCONFIG_ADDR="192.168.3.42"
route()    { [ -n "$ROUTE_IFACE" ] && printf '   interface: %s\n' "$ROUTE_IFACE" || return 1; }
ipconfig() { [ "${1:-}" = "getifaddr" ] && [ -n "$IPCONFIG_ADDR" ] && printf '%s\n' "$IPCONFIG_ADDR" || return 1; }

# Arm 1: happy path → emits the address, exits 0.
ROUTE_IFACE="en0"; IPCONFIG_ADDR="192.168.3.42"
set +e; out="$(detect_ip)"; rc=$?; set -e
[ "$rc" -eq 0 ] && ok "happy: exits 0" || bad "happy: exits 0 (got rc=$rc)"
[ "$out" = "192.168.3.42" ] && ok "happy: emits the interface address" || bad "happy: emits address (got '$out')"

# Arm 2: no default route → empty interface, must still exit 0 with empty output.
ROUTE_IFACE=""; IPCONFIG_ADDR="192.168.3.42"
set +e; out="$(detect_ip)"; rc=$?; set -e
[ "$rc" -eq 0 ] && ok "no-route: exits 0" || bad "no-route: exits 0 (got rc=$rc)"
[ -z "$out" ] && ok "no-route: emits empty string" || bad "no-route: emits empty (got '$out')"

# Arm 3: interface found but ipconfig has no address (interface down) → exit 0.
ROUTE_IFACE="en0"; IPCONFIG_ADDR=""
set +e; out="$(detect_ip)"; rc=$?; set -e
[ "$rc" -eq 0 ] && ok "no-addr: exits 0" || bad "no-addr: exits 0 (got rc=$rc)"
[ -z "$out" ] && ok "no-addr: emits empty string" || bad "no-addr: emits empty (got '$out')"

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
