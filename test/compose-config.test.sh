#!/usr/bin/env bash
#
# Semantic check for compose.prod.yml: it must parse AND keep the hardening keys
# after YAML rendering. A grep test alone misses indentation typos that put a
# key under the wrong node; `docker compose config` resolves the real document.
# Skips cleanly where docker (compose v2) is unavailable, matching the repo's
# "stay green without the dependency" convention.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$SCRIPT_DIR/../compose.prod.yml"

[ -f "$COMPOSE" ] || { echo "FAIL: $COMPOSE not found"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "SKIP: docker absent"; exit 0; }
docker compose version >/dev/null 2>&1 || { echo "SKIP: docker compose v2 absent"; exit 0; }

# Render in a throwaway dir with an empty .env so the `env_file: - .env`
# directive resolves without the installer-written file (and without touching
# the repo). `config` only renders — it does not validate that mounts exist.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$COMPOSE" "$TMP/compose.prod.yml"
: > "$TMP/.env"

# EXECUTOR_UID/GID are now mandatory (${VAR:?}) — the docker.sock-mounted
# container must never silently fall back to root. install.sh writes them to
# .env; supply them here so the render resolves.
out="$(DASHBOARD_HOST=test.example DASHBOARD_IMAGE=img:test \
      EXECUTOR_UID=1000 EXECUTOR_GID=1000 \
      docker compose -f "$TMP/compose.prod.yml" config 2>&1)" || {
  echo "FAIL: compose config did not parse"
  echo "$out"
  exit 1
}

fails=0

# Fail-closed identity: omitting EXECUTOR_UID must make `config` abort, not
# render a uid-0 container. Proves the ${VAR:?} guard, not a :-0 fallback.
if DASHBOARD_HOST=test.example DASHBOARD_IMAGE=img:test \
     docker compose -f "$TMP/compose.prod.yml" config >/dev/null 2>&1; then
  echo "FAIL: compose config resolved without EXECUTOR_UID (should fail closed)"
  fails=1
else
  echo "ok   config fails closed when EXECUTOR_UID is unset"
fi
assert_rendered() { # <label> <pattern>
  local label="$1" pat="$2"
  if grep -qE "$pat" <<<"$out"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s (missing from rendered config)\n       pattern: %s\n' "$label" "$pat"
    fails=$((fails + 1))
  fi
}

assert_rendered "read_only rendered" 'read_only:\s*true'
assert_rendered "pids_limit rendered" 'pids_limit:'
assert_rendered "cap_drop ALL rendered" '^\s*-\s*ALL\s*$'
assert_rendered "healthcheck rendered" 'healthcheck:'
assert_rendered "healthcheck test rendered" '/api/health'
# Port published to the host loopback only — lets a host-side reverse proxy
# (Tailscale Serve, nginx) reach the app without exposing it on a public NIC.
# `docker compose config` renders ports in long form (host_ip/target/published).
assert_rendered "port published to loopback" 'host_ip:\s*127\.0\.0\.1'
assert_rendered "port target is 3001" 'target:\s*3001'

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
