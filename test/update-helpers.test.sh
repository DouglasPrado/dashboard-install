#!/usr/bin/env bash
#
# Unit tests for update.sh's pure helpers. update.sh stops at the source guard
# when sourced (BASH_SOURCE != $0), so we can pull in its functions without
# running the live update. Covers:
#   * parse_install_dir — extract the compose working_dir from a docker inspect line
#   * pin_image_in_env  — rewrite/append the DASHBOARD_IMAGE pin (the override that
#                         a digest pin or an exported shell var would otherwise win)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../update.sh"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '     got=%q want=%q\n' "$2" "$3"; }; }

# ── parse_install_dir ──
eq "dir from inspect line"      "$(parse_install_dir '/srv/dash|/srv/dash/compose.prod.yml')" "/srv/dash"
eq "empty working_dir → empty"  "$(parse_install_dir '|/srv/dash/compose.prod.yml')"          ""
eq "no pipe → empty"            "$(parse_install_dir 'garbage')"                                ""
eq "blank → empty"              "$(parse_install_dir '')"                                       ""

# ── pin_image_in_env ──
REF="ghcr.io/douglasprado/dashboard-install:latest"

tmp="$(mktemp)"
printf 'DASHBOARD_HOST=x\nDASHBOARD_IMAGE=ghcr.io/o/r@sha256:deadbeef\nFOO=bar\n' > "$tmp"
pin_image_in_env "$tmp" "$REF"
eq "rewrites existing pin"        "$(grep '^DASHBOARD_IMAGE=' "$tmp")" "DASHBOARD_IMAGE=$REF"
eq "keeps other lines (count)"    "$(wc -l < "$tmp" | tr -d ' ')"     "3"
eq "preserves DASHBOARD_HOST"     "$(grep '^DASHBOARD_HOST=' "$tmp")" "DASHBOARD_HOST=x"
rm -f "$tmp"

tmp="$(mktemp)"
printf 'DASHBOARD_HOST=x\n' > "$tmp"
pin_image_in_env "$tmp" "$REF"
eq "appends when pin absent"      "$(grep '^DASHBOARD_IMAGE=' "$tmp")" "DASHBOARD_IMAGE=$REF"
rm -f "$tmp"

tmp="$(mktemp)"; rm -f "$tmp"   # nonexistent path
pin_image_in_env "$tmp" "$REF"
eq "creates env file when missing" "$(cat "$tmp" 2>/dev/null)" "DASHBOARD_IMAGE=$REF"
rm -f "$tmp"

# ── env_channel ── (default channel `./update.sh` follows when no --image/--tag)
tmp="$(mktemp)"
printf 'DASHBOARD_HOST=x\nDASHBOARD_CHANNEL=main\nFOO=bar\n' > "$tmp"
eq "reads DASHBOARD_CHANNEL"        "$(env_channel "$tmp")" "main"
printf 'DASHBOARD_HOST=x\n' > "$tmp"
eq "defaults to latest when absent" "$(env_channel "$tmp")" "latest"
printf 'DASHBOARD_CHANNEL=\n' > "$tmp"
eq "defaults to latest when blank"  "$(env_channel "$tmp")" "latest"
rm -f "$tmp"
eq "defaults to latest when no file" "$(env_channel /no/such/.env)" "latest"

tmpdir="$(mktemp -d)"
tmp="$tmpdir/.env"
printf 'DASHBOARD_HOST=x\nDASHBOARD_IMAGE=ghcr.io/o/r@sha256:deadbeef\n' > "$tmp"
chmod 600 "$tmp"
chmod 500 "$tmpdir"
pin_image_in_env "$tmp" "$REF"
eq "rewrites existing pin in a non-writable dir" "$(grep '^DASHBOARD_IMAGE=' "$tmp")" "DASHBOARD_IMAGE=$REF"
chmod 700 "$tmpdir"
rm -rf "$tmpdir"

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
