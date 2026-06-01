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

out="$(DASHBOARD_HOST=test.example DASHBOARD_IMAGE=img:test \
      docker compose -f "$TMP/compose.prod.yml" config 2>&1)" || {
  echo "FAIL: compose config did not parse"
  echo "$out"
  exit 1
}

fails=0
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

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
