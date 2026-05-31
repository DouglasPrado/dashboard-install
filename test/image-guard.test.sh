#!/usr/bin/env bash
#
# Unit test for ci/check-image-artifacts.sh — the CI guard that fails the build
# when the image leaks source/sourcemap artifacts (the MINIFY+STRIP invariant:
# the distribution image must ship only built JS, never .ts/.map/src/tsconfig).
#
# Pure text over a path listing (e.g. `docker export <cid> | tar -t`), so it is
# tested offline here, and shares ONE banned-artifact regex with release.yml via
# the script under test (no drift between CI and this test).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../ci/check-image-artifacts.sh"

[ -x "$CHECK" ] || { echo "FAIL: $CHECK not found or not executable"; exit 1; }

fails=0
assert_rejects() { # <label> <path>
  local label="$1" path="$2"
  if printf '%s\n' "$path" | "$CHECK" >/dev/null 2>&1; then
    printf 'FAIL %s (accepted, want reject): %s\n' "$label" "$path"
    fails=$((fails + 1))
  else
    printf 'ok   %s\n' "$label"
  fi
}
assert_accepts() { # <label> <path>
  local label="$1" path="$2"
  if printf '%s\n' "$path" | "$CHECK" >/dev/null 2>&1; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s (rejected, want accept): %s\n' "$label" "$path"
    fails=$((fails + 1))
  fi
}

# Banned — source, sourcemaps, build config, VCS, secrets.
assert_rejects "sourcemap .map"       "app/dist/index.js.map"
assert_rejects "TS source .ts"        "app/src/server.ts"
assert_rejects "TS source .tsx"       "app/src/App.tsx"
assert_rejects "/src/ dir leak"       "usr/src/app/foo.js"
assert_rejects "tsconfig.json"        "app/tsconfig.json"
assert_rejects "tsconfig.build.json"  "app/tsconfig.build.json"
assert_rejects ".git dir"             "app/.git/config"
assert_rejects ".env secret"          "app/.env"

# Accepted — built artifacts, dep type stubs, manifests, example env.
assert_accepts "built JS"             "app/dist/server.js"
assert_accepts "built HTML"           "app/dist/public/index.html"
assert_accepts "dep type stub .d.ts"  "app/node_modules/foo/index.d.ts"
assert_accepts "package.json"         "app/package.json"
assert_accepts ".env.example"         "app/.env.example"

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
