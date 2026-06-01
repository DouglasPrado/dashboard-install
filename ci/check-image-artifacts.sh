#!/usr/bin/env bash
#
# CI guard: fail the build when the distribution image leaks source or
# protection-regression artifacts. The image must ship only minified, bundled
# JS (the MINIFY+STRIP invariant) — never original TypeScript, sourcemaps, the
# src tree, build config, a .git dir, or a baked .env secret. A determined
# root-on-host operator can still extract the bundle; this only stops us from
# accidentally handing over the *source*.
#
# Reads a path listing on stdin (e.g. `docker export <cid> | tar -t`).
# Single source of truth for the banned-artifact contract — unit-tested by
# test/image-guard.test.sh and invoked from .github/workflows/release.yml.
#
# Scope: OUR source only. Third-party deps are not our IP, and the runtime stage
# copies prod node_modules wholesale (the server is esbuild-bundled with
# --packages=external), so node_modules legitimately carries thousands of dep
# .map/.ts/tsconfig files. Excluding node_modules avoids false positives while
# still catching a leak of our dist/dist-server/src/server source.
set -euo pipefail

banned='(\.map$)|(\.tsx?$)|(/src/)|((^|/)tsconfig[^/]*\.json$)|((^|/)\.git/)|((^|/)\.env$)'

# Ignore third-party deps; *.d.ts type stubs are harmless and never source.
matches="$(grep -vE '(^|/)node_modules/' - | grep -E "$banned" | grep -vE '\.d\.ts$' || true)"

if [ -n "$matches" ]; then
  echo "::error::protection regression — banned source/sourcemap artifacts in image:" >&2
  printf '%s\n' "$matches" | sed 's/^/  /' >&2
  exit 1
fi

echo "ok: no banned source/sourcemap/tsconfig/.git/.env artifacts in image"
