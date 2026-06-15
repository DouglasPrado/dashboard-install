#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SH="$SCRIPT_DIR/../update.sh"

source "$UPDATE_SH"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

assert_eq() {
  local label="$1" got="$2" want="$3"
  [ "$got" = "$want" ] && ok "$label" || {
    printf '       want: %s\n       got: %s\n' "$want" "$got"
    bad "$label"
  }
}

assert_grep() {
  local label="$1" pattern="$2" file="$3"
  grep -Eq "$pattern" "$file" && ok "$label" || bad "$label"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ENV_FILE="$TMP/.env"
cat > "$ENV_FILE" <<'EOF'
DASHBOARD_IMAGE=ghcr.io/x/old:latest
OTHER=value
EOF
pin_image_in_env "$ENV_FILE" "ghcr.io/x/new:latest"
assert_grep "pin_image_in_env rewrites the existing image pin" '^DASHBOARD_IMAGE=ghcr\.io/x/new:latest$' "$ENV_FILE"
assert_grep "pin_image_in_env preserves unrelated lines" '^OTHER=value$' "$ENV_FILE"

pin_env_value "$ENV_FILE" DASHBOARD_PLATFORM "linux/amd64"
assert_grep "pin_env_value appends missing keys portably" '^DASHBOARD_PLATFORM=linux/amd64$' "$ENV_FILE"
assert_grep "install.sh hands .env to the executor for host-side updates" 'chown "\$EXECUTOR_USER:\$EXECUTOR_USER" "\$ENV_FILE"' "$SCRIPT_DIR/../install.sh"

uname() { echo Darwin; }
assert_eq "dashboard_platform forces amd64 on macOS" "$(dashboard_platform)" "linux/amd64"
uname() { echo Linux; }
assert_eq "dashboard_platform is empty on Linux/WSL" "$(dashboard_platform)" ""

if grep -Eq '[[:space:]]sed -i[[:space:]]' "$UPDATE_SH"; then
  bad "update.sh no longer relies on sed -i"
else
  ok "update.sh no longer relies on sed -i"
fi

if [ "$fails" -eq 0 ]; then
  echo "PASS (all)"
  exit 0
fi
echo "FAILED: $fails"
exit 1
