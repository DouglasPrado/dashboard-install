#!/usr/bin/env bash
#
# Regression test for install.sh's detect_ip helper on hosts without iproute2.
#
# detect_ip runs `ip -4 -o route get ... | awk | head`. On macOS (and any host
# missing the `ip` binary) the first stage exits 127; with `pipefail` the whole
# pipeline inherits 127. The caller assigns it under `set -e`
# (`HOST_IP="$(detect_ip)"`), so a non-zero detect_ip aborts the installer
# SILENTLY — before the friendly "bootstrap is Linux-only, use --no-bootstrap"
# guard can ever print. Symptom: `curl ... | bash` on macOS does nothing.
#
# Contract: detect_ip must ALWAYS exit 0 — emit the IP when found, empty string
# otherwise — so it never trips the caller's `set -e`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

# detect_ip is a one-liner, so extract just that line (a sed line-range never
# closes on a single-line function body).
eval "$(grep -E '^detect_ip\(\)' "$INSTALL_SH")"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

# Simulate a host with no `ip` binary (macOS, minimal images): shadow it with a
# function that fails the way "command not found" does — exit 127, no output.
ip() { return 127; }

set +e
out="$(detect_ip)"; rc=$?
set -e
# The load-bearing contract: detect_ip must exit 0 no matter what. If it does,
# the caller's `HOST_IP="$(detect_ip)"` can never trip `set -e` — independent of
# the bash version's (notoriously inconsistent) cmd-sub-in-assignment handling,
# which is the exact footgun macOS's bash 3.2 hits.
[ "$rc" -eq 0 ] && ok "exits 0 when \`ip\` is absent" \
  || bad "exits 0 when \`ip\` is absent (got rc=$rc)"
[ -z "$out" ] && ok "emits empty string when no IP found" \
  || bad "emits empty string when no IP found (got '$out')"

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
