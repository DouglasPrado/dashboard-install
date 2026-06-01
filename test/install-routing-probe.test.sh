#!/usr/bin/env bash
#
# Regression test for the post-up routing probe in install.sh.
#
# Bug history: `docker compose up -d` can succeed while no request ever reaches
# the dashboard — Traefik may have registered no routers (engine/API mismatch),
# or the host iptables for stack_web get desynced (common on WSL2 after a daemon
# restart) so FORWARD drops container traffic and requests hang ~20s (HTTP 499).
# The installer used to print "done" regardless, so a fully-broken deploy looked
# successful. It must instead probe end-to-end through Traefik and, on failure,
# print actionable host-networking remediation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$SCRIPT_DIR/../install.sh"

[ -f "$INSTALL" ] || { echo "FAIL: $INSTALL not found"; exit 1; }

fails=0
assert_grep() { # <label> <pattern>
  local label="$1" pat="$2"
  if grep -qE "$pat" "$INSTALL"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n       pattern: %s\n' "$label" "$pat"
    fails=$((fails + 1))
  fi
}

# Probes /api/health *through Traefik* (http://$HOST), with a bounded timeout so
# a desynced-iptables hang does not stall the installer for 20s per attempt.
assert_grep "curls /api/health through \$HOST" \
  'curl\s+.*--max-time\s+[0-9].*http://\$HOST/api/health'

# On failure, surface the two known host-networking fixes.
assert_grep "remediation: restart docker (reprograms iptables)" \
  'systemctl restart docker'
assert_grep "remediation: recreate the stack_web network" \
  'docker network rm stack_web'

[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "$fails check(s) failed"; exit 1; }
