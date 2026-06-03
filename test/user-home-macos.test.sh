#!/usr/bin/env bash
#
# Unit test for install-macos.sh's user_home — the macOS replacement for the
# Linux `getent passwd "$U" | cut -d: -f6` home-dir lookup. macOS has no
# getent / NSS; the directory service is queried with `dscl`. user_home must
# resolve a user's home from `dscl . -read /Users/<u> NFSHomeDirectory` and
# print just the path, so every getent call-site in the Linux installer maps to
# it 1:1.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install-macos.sh"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$INSTALL_SH" ] || { bad "install-macos.sh not found at $INSTALL_SH"; echo "FAILED: $fails"; exit 1; }

eval "$(sed -n '/^user_home()/,/^}/p' "$INSTALL_SH")"
command -v user_home >/dev/null 2>&1 || { bad "user_home not defined in install-macos.sh"; echo "FAILED: $fails"; exit 1; }

# `dscl . -read /Users/<u> NFSHomeDirectory` prints: "NFSHomeDirectory: /Users/<u>".
DSCL_HOME="/Users/douglas"
dscl() {
  # match: dscl . -read /Users/<u> NFSHomeDirectory
  [ -n "$DSCL_HOME" ] && printf 'NFSHomeDirectory: %s\n' "$DSCL_HOME" || return 1
}

# Arm 1: resolves the home path, nothing else.
DSCL_HOME="/Users/douglas"
set +e; out="$(user_home douglas)"; rc=$?; set -e
[ "$rc" -eq 0 ] && ok "resolves: exits 0" || bad "resolves: exits 0 (got rc=$rc)"
[ "$out" = "/Users/douglas" ] && ok "resolves: prints the home path" || bad "resolves: prints home (got '$out')"

# Arm 2: unknown user (dscl fails) → empty output, non-fatal (no crash).
DSCL_HOME=""
set +e; out="$(user_home nobody)"; set -e
[ -z "$out" ] && ok "unknown user: empty output" || bad "unknown user: empty (got '$out')"

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
