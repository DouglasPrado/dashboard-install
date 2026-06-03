#!/usr/bin/env bash
#
# Unit test for ci/resolve-tags.sh's resolve_tags helper. The dashboard app
# reports its VERSION as a clean semver (package.json, no leading v) and the
# documented release contract is `ghcr.io/<repo>:X.Y.Z` (RELEASING.md). The
# release workflow used to publish only the v-prefixed tag (`:vX.Y.Z`), so the
# in-app update and `install.sh --image ...:X.Y.Z` both 404'd on the missing
# clean tag. This guards that a stable release publishes BOTH the v-prefixed and
# the clean tag (plus moves :latest), and that pre-release/edge/floating inputs
# keep their existing behaviour.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../ci/resolve-tags.sh"

IMG="ghcr.io/douglasprado/dashboard-install"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

# Assert resolve_tags emits exactly the given lines (order-independent).
assert_tags() {
  local name="$1" version="$2"; shift 2
  local got expected
  got="$(resolve_tags "$version" "$IMG" | sort)"
  expected="$(printf '%s\n' "$@" | sort)"
  if [ "$got" = "$expected" ]; then ok "$name"; else
    bad "$name"
    printf '     version=%s\n     got:\n%s\n     want:\n%s\n' "$version" "$got" "$expected"
  fi
}

assert_tags "stable release publishes v, clean, and latest" "v0.5.6" \
  "$IMG:v0.5.6" "$IMG:0.5.6" "$IMG:latest"

assert_tags "prerelease publishes v and clean, no latest" "v0.6.0-rc.1" \
  "$IMG:v0.6.0-rc.1" "$IMG:0.6.0-rc.1"

assert_tags "edge-<sha> publishes the immutable sha tag and moves :edge" "edge-abc1234" \
  "$IMG:edge-abc1234" "$IMG:edge"

assert_tags "bare edge input publishes only itself" "edge" \
  "$IMG:edge"

assert_tags "bare latest input publishes only itself" "latest" \
  "$IMG:latest"

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
