#!/usr/bin/env bash
#
# Regression guard for the "update-live: permission denied on docker.sock" bug.
# The dashboard runs `docker compose` on the HOST by SSHing in as the executor
# user (update-live, branch-switch restart). docker.sock is root:docker, so the
# executor must belong to the host docker group or every host-side compose call
# dies with "permission denied while trying to connect to the docker API at
# unix:///var/run/docker.sock". This is SEPARATE from the container's DOCKER_GID
# group_add (that only covers the in-process socket client inside the container).
# So ensure_executor MUST add the executor user to the host docker group,
# idempotently and gated on the group existing (no-op on rootless/podman hosts).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

# Extract a shell function body (from `name()` to the closing `}` at col 0).
fn_body() { sed -n "/^$1()/,/^}/p" "$INSTALL_SH"; }

body="$(fn_body ensure_executor)"
[ -n "$body" ] || { bad "ensure_executor not found in install.sh"; echo "FAILED: $fails"; exit 1; }

case "$body" in
  *'usermod -aG docker "$EXECUTOR_USER"'*)
    ok "ensure_executor adds the executor to the host docker group" ;;
  *)
    bad "ensure_executor does not 'usermod -aG docker \$EXECUTOR_USER' (host-side docker compose will hit EACCES on docker.sock)" ;;
esac

case "$body" in
  *'getent group docker'*)
    ok "docker group add is gated on the group existing" ;;
  *)
    bad "ensure_executor does not gate the usermod on 'getent group docker' (would fail on rootless/podman hosts)" ;;
esac

if [ "$fails" -eq 0 ]; then echo "PASS (all)"; exit 0; fi
echo "FAILED: $fails"; exit 1
