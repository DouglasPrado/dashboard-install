#!/usr/bin/env bash
#
# Unit test for install.sh's image_is_pinned helper. The app container is a
# privileged host orchestrator (mounts the Docker socket), so the image it pulls
# should be digest-pinned (...@sha256:<digest>) — a floating tag (:latest, :v1)
# is mutable and a compromised/MITM'd registry can swap it. The installer warns
# loudly when the ref is not pinned; this guards the classifier behind that warn.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

eval "$(sed -n '/^image_is_pinned()/,/^}/p' "$INSTALL_SH")"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
assert_pinned()   { image_is_pinned "$2" && ok "$1" || bad "$1 (expected pinned: '$2')"; }
assert_unpinned() { image_is_pinned "$2" && bad "$1 (expected unpinned: '$2')" || ok "$1"; }

assert_pinned   "digest only"            "ghcr.io/x/dashboard-install@sha256:abc123"
assert_pinned   "tag + digest"           "ghcr.io/x/dashboard-install:v1@sha256:abc123"
assert_unpinned ":latest is mutable"     "ghcr.io/x/dashboard-install:latest"
assert_unpinned "version tag is mutable" "ghcr.io/x/dashboard-install:v0.1.0"
assert_unpinned "bare repo is mutable"   "ghcr.io/x/dashboard-install"

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
