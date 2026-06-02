#!/usr/bin/env bash
#
# CI guard: fail the build when the distribution image is MISSING a runtime
# artifact the app needs at boot. Complements check-image-artifacts.sh — that
# guard bans *extra* source leaks; this one bans *missing* essentials.
#
# Motivating regression: the ask_human MCP bridge (mcp-askhuman-server.mjs) is a
# SEPARATE process the dashboard provisions onto the host at boot. It is NOT part
# of the esbuild index.js bundle — it has its own `build:server` esbuild step.
# Drop that step and the image still boots, but silently cannot provision the
# bridge, so the claude-code runtime aborts on every clean install
# ("Invalid MCP configuration: MCP config file not found") and the chat "won't
# send". This guard turns that silent break into a red release.
#
# Reads a path listing on stdin (e.g. `docker export <cid> | tar -t`).
# Single source of truth for the required-artifact contract — unit-tested by
# test/required-artifacts.test.sh and invoked from .github/workflows/release.yml.
set -euo pipefail

required=(
  'dist-server/index.js'
  'dist-server/mcp-askhuman-server.mjs'
)

listing="$(cat)"
missing=()
for r in "${required[@]}"; do
  # Match the artifact at the end of any path component chain (tar -t emits
  # paths like `app/dist-server/index.js`, no leading slash).
  grep -qE "(^|/)${r}\$" <<<"$listing" || missing+=("$r")
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "::error::missing required runtime artifact(s) in image:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

echo "ok: all required runtime artifacts present in image"
