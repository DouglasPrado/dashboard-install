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

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
