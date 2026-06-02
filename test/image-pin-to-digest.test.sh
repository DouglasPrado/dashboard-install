#!/usr/bin/env bash
#
# Unit test for install.sh's pin_to_digest helper. After pulling a (possibly
# floating) tag, the installer pins DASHBOARD_IMAGE to the immutable digest of
# the exact bytes it pulled, so the socket-mounted orchestrator runs known bytes
# on every `compose up`. The rewrite must: replace an existing digest, strip a
# :tag, preserve a registry:port, and be idempotent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

eval "$(sed -n '/^pin_to_digest()/,/^}/p' "$INSTALL_SH")"
# Re-use the existing classifier to assert the result is genuinely pinned.
eval "$(sed -n '/^image_is_pinned()/,/^}/p' "$INSTALL_SH")"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
eq()  { # <name> <expected> <actual>
  [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected '$2', got '$3')"
}

D="sha256:abc123"
eq "tag stripped"        "ghcr.io/x/di@$D"        "$(pin_to_digest ghcr.io/x/di:latest "$D")"
eq "no tag"              "ghcr.io/x/di@$D"        "$(pin_to_digest ghcr.io/x/di "$D")"
eq "version tag"         "ghcr.io/x/di@$D"        "$(pin_to_digest ghcr.io/x/di:v0.1.0 "$D")"
eq "edge sha tag"        "ghcr.io/x/di@$D"        "$(pin_to_digest ghcr.io/x/di:edge-9f2a1c "$D")"
eq "re-pin replaces"     "ghcr.io/x/di@$D"        "$(pin_to_digest ghcr.io/x/di@sha256:old "$D")"
eq "tag + digest re-pin" "ghcr.io/x/di@$D"        "$(pin_to_digest ghcr.io/x/di:v1@sha256:old "$D")"
eq "registry port kept"  "localhost:5000/di@$D"   "$(pin_to_digest localhost:5000/di:tag "$D")"
eq "registry port notag" "localhost:5000/di@$D"   "$(pin_to_digest localhost:5000/di "$D")"

# Idempotent: pinning an already-pinned ref to the same digest is a no-op.
eq "idempotent" "ghcr.io/x/di@$D" "$(pin_to_digest "$(pin_to_digest ghcr.io/x/di:latest "$D")" "$D")"

# Every result must pass the pinned classifier.
for ref in ghcr.io/x/di:latest ghcr.io/x/di localhost:5000/di:tag; do
  image_is_pinned "$(pin_to_digest "$ref" "$D")" && ok "result pinned: $ref" \
    || bad "result NOT classified pinned: $ref"
done

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
