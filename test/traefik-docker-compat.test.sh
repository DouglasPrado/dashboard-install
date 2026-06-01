#!/usr/bin/env bash
#
# Regression test for the Traefik <-> Docker engine API compatibility.
#
# Bug history: stack.compose.yml pinned traefik:v3.5, whose embedded Docker
# client negotiates API v1.24. Docker engine 29 raised the minimum API version,
# so on any host that already had engine 29 the Traefik provider failed with
# "client version 1.24 is too old" — no routers registered, every route 404.
# The installer's DOCKER_VERSION="28.5" pin only ever applied to *fresh*
# installs (ensure_docker is a no-op when docker is already present), so a
# pre-existing engine 29 slipped straight past it.
#
# Fix: run a Traefik that speaks the modern engine API (>= v3.7) and stop
# pinning the engine down. These asserts lock that in.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$SCRIPT_DIR/../stack.compose.yml"
INSTALL="$SCRIPT_DIR/../install.sh"

[ -f "$STACK" ]   || { echo "FAIL: $STACK not found"; exit 1; }
[ -f "$INSTALL" ] || { echo "FAIL: $INSTALL not found"; exit 1; }

fails=0
assert_grep() { # <file> <label> <pattern>
  local file="$1" label="$2" pat="$3"
  if grep -qE "$pat" "$file"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n       pattern: %s\n' "$label" "$pat"
    fails=$((fails + 1))
  fi
}
refute_grep() { # <file> <label> <pattern>
  local file="$1" label="$2" pat="$3"
  if grep -qE "$pat" "$file"; then
    printf 'FAIL %s\n       must NOT match: %s\n' "$label" "$pat"
    fails=$((fails + 1))
  else
    printf 'ok   %s\n' "$label"
  fi
}

# Traefik must speak the modern engine API: v3.7 or newer (v3.7+, or any v3.1x,
# or v4+). v3.5/v3.6 are stuck on the old client and break against engine 29.
assert_grep "$STACK" "traefik image is >= v3.7" \
  '^\s*image:\s*traefik:v(3\.(7|8|9|[1-9][0-9])|[4-9])'
refute_grep "$STACK" "traefik image is not the broken v3.5/v3.6" \
  '^\s*image:\s*traefik:v3\.[56]([.:]|\s|$)'

# The installer must no longer pin the engine down to 28.x to protect a stale
# Traefik client — the forward-compatible Traefik removes that need.
refute_grep "$INSTALL" "no Docker engine pin to 28.x" \
  'DOCKER_VERSION="?28'
refute_grep "$INSTALL" "no --version 28 passed to get.docker.com" \
  'get\.docker\.com.*--version.*28'

[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "$fails check(s) failed"; exit 1; }
