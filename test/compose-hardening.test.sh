#!/usr/bin/env bash
#
# Regression test for runtime least-privilege in compose.prod.yml.
#
# These keys limit blast radius if the dashboard process is compromised
# (dependency RCE, an agent escaping its sandbox, prompt-injection escalation).
# They do NOT stop a root-on-host operator from `docker export`ing the image —
# that is not the threat they address. Catch accidental removal here, and guard
# that hardening did not drop the load-bearing mounts the dashboard needs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$SCRIPT_DIR/../compose.prod.yml"

[ -f "$COMPOSE" ] || { echo "FAIL: $COMPOSE not found"; exit 1; }

fails=0
assert_grep() { # <label> <pattern>
  local label="$1" pat="$2"
  if grep -qE "$pat" "$COMPOSE"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n       pattern: %s\n' "$label" "$pat"
    fails=$((fails + 1))
  fi
}

# Least-privilege keys.
assert_grep "read-only rootfs"        '^\s*read_only:\s*true\s*$'
assert_grep "tmpfs for /tmp"          '^\s*-\s*/tmp\s*$'
assert_grep "cap_drop ALL"            '^\s*-\s*ALL\s*$'
assert_grep "pids_limit set"          '^\s*pids_limit:\s*[0-9]+\s*$'
assert_grep "no-new-privileges kept"  'no-new-privileges:true'

# Healthcheck: unattended remote installs need the container's liveness to be
# observable (the dashboard's own container panel reads it via docker.ts's
# /(unhealthy)/ probe). Hits the ungated /api/health route with node's global
# fetch, so it needs no extra binary under read_only + cap_drop:ALL.
assert_grep "healthcheck defined"     '^\s*healthcheck:\s*$'
assert_grep "healthcheck hits health" '/api/health'

# Hardening must not drop the load-bearing bind/host-gateway (see
# compose-mounts.test.sh for the full mount contract). read_only rootfs is only
# safe because the app writes solely under /data (a bind) and /tmp (tmpfs).
assert_grep "./data write mount kept" '^\s*-\s*\./data:/data(\s|$)'
assert_grep "host-gateway kept"       'host\.docker\.internal:host-gateway'

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
