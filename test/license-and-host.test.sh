#!/usr/bin/env bash
#
# Unit test for install.sh's input/secret helpers:
#   valid_host   — rejects --host values outside the DNS charset before they
#                  land in the Traefik Host(`...`) label (backticks/quotes/$
#                  would corrupt the rule and silently break routing).
#   write_license — the license is the login credential; it must be written
#                  mode 600 (not world-readable), not the umask default.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

eval "$(sed -n '/^valid_host()/,/^}/p; /^write_license()/,/^}/p' "$INSTALL_SH")"

fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
assert_eq() { [ "$2" = "$3" ] && ok "$1" || { printf 'FAIL %s\n       want: %s\n       got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); }; }
assert_valid()   { valid_host "$2" && ok "$1" || bad "$1 (expected valid: '$2')"; }
assert_invalid() { valid_host "$2" && bad "$1 (expected invalid: '$2')" || ok "$1"; }

# ── valid_host ───────────────────────────────────────────────────────────────
assert_valid   "accepts nip.io host"      "dash.192.168.3.139.nip.io"
assert_valid   "accepts plain domain"     "dash.example.com"
assert_valid   "accepts hyphens"          "my-dash.example.com"
assert_invalid "rejects empty"            ""
assert_invalid "rejects backtick"         'dash\`.com'
assert_invalid "rejects space"            "dash .com"
assert_invalid "rejects dollar/brace"     'dash${x}.com'
assert_invalid "rejects single quote"     "dash'.com"

# ── write_license ────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
dest="$TMP/license.key"
# Pre-create world-readable so we prove write_license tightens it.
umask 022
write_license "SECRET-TOKEN-123" "$dest" "$(id -un)"
mode="$(stat -c '%a' "$dest" 2>/dev/null || stat -f '%Lp' "$dest")"
assert_eq "license.key is mode 600"     "$mode" "600"
got="$(cat "$dest")"
assert_eq "license.key holds the token" "$got" "SECRET-TOKEN-123"

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
