#!/usr/bin/env bash
#
# Unit test for install.sh's image_tag helper. The installer derives the update
# channel (DASHBOARD_CHANNEL) from an explicit --image's tag, so a host pinned to
# repo:main is recorded as tracking `main`, not the default `latest`. The tag
# lives only in the final path segment, so a registry:port must not be mistaken
# for a tag and a @sha256 digest must be dropped first.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

eval "$(sed -n '/^image_tag()/,/^}/p' "$INSTALL_SH")"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected '$2', got '$3')"; }

eq "plain tag"            "main"   "$(image_tag ghcr.io/x/di:main)"
eq "version tag"          "v0.5.6" "$(image_tag ghcr.io/x/di:v0.5.6)"
eq "latest"               "latest" "$(image_tag ghcr.io/x/di:latest)"
eq "no tag → empty"       ""       "$(image_tag ghcr.io/x/di)"
eq "digest only → empty"  ""       "$(image_tag ghcr.io/x/di@sha256:abc123)"
eq "tag + digest → tag"   "v1"     "$(image_tag ghcr.io/x/di:v1@sha256:abc123)"
eq "registry port, notag" ""       "$(image_tag localhost:5000/di)"
eq "registry port + tag"  "main"   "$(image_tag localhost:5000/di:main)"

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
