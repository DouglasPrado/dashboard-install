#!/usr/bin/env bash
#
# Dashboard installer — distribution mode (published Docker image).
#
# Pulls the published image (no source on this host), provisions per-host
# secrets locally (nothing is embedded in the distribution), installs the
# license, and brings the stack up via compose.prod.yml.
#
# Usage:
#   ./install.sh --host dash.example.ts.net --license <key> [options]
#
# Options:
#   --host <domain>      Host the dashboard is served at (required).
#   --license <key>      License token, or a path to a file containing it.
#   --image <ref>        Image to pull (default: ghcr.io/douglasprado/dashboard:latest).
#                        Prefer a digest pin: ...@sha256:<digest>.
#   --password <pw>      Enable basic auth with this password.
#   --trust-proxy        Trust the Tailscale Serve identity header (instead of a password).
#   --dir <path>         Install directory (default: current directory).
#   --check              Validate prerequisites and inputs, then exit (no changes).
#   -h, --help           Show this help.
#
set -euo pipefail

IMAGE_DEFAULT="ghcr.io/douglasprado/dashboard:latest"

HOST=""
LICENSE=""
IMAGE="$IMAGE_DEFAULT"
PASSWORD=""
TRUST_PROXY="false"
DIR="$PWD"
CHECK_ONLY="false"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
sha256() { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }

# Public bootstrap repo hosting install.sh + compose.prod.yml. When the installer
# runs piped (curl ... | bash) there is no compose.prod.yml on disk, so it is
# fetched from here. Override with BOOTSTRAP_BASE for a fork or a pinned ref.
BOOTSTRAP_BASE="${BOOTSTRAP_BASE:-https://raw.githubusercontent.com/DouglasPrado/dashboard-install/main}"

usage() { sed -n '2,/^set -euo/{/^set -euo/!p}' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)        HOST="${2:-}"; shift 2 ;;
    --license)     LICENSE="${2:-}"; shift 2 ;;
    --image)       IMAGE="${2:-}"; shift 2 ;;
    --password)    PASSWORD="${2:-}"; shift 2 ;;
    --trust-proxy) TRUST_PROXY="true"; shift ;;
    --dir)         DIR="${2:-}"; shift 2 ;;
    --check)       CHECK_ONLY="true"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown argument: $1 (see --help)" ;;
  esac
done

# ── prerequisites ──
command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not available"
command -v curl >/dev/null 2>&1 || die "curl not found in PATH"
[ -n "$HOST" ] || die "--host is required"

# Auth is mandatory in distribution: a password OR trusting the Tailscale proxy.
if [ -z "$PASSWORD" ] && [ "$TRUST_PROXY" != "true" ]; then
  die "set --password <pw> or --trust-proxy (behind Tailscale Serve); the dashboard refuses to boot exposed without auth"
fi

COMPOSE_FILE="$DIR/compose.prod.yml"
COMPOSE_URL="$BOOTSTRAP_BASE/compose.prod.yml"

# Resolve license: a readable path becomes its contents, else treat as the token.
if [ -n "$LICENSE" ] && [ -f "$LICENSE" ]; then
  LICENSE="$(tr -d '\n' < "$LICENSE")"
fi

if [ "$CHECK_ONLY" = "true" ]; then
  # Don't write anything in check mode; just confirm compose is present or fetchable.
  if [ -f "$COMPOSE_FILE" ]; then
    compose_status="local"
  elif curl -fsIL "$COMPOSE_URL" >/dev/null 2>&1; then
    compose_status="fetchable from $COMPOSE_URL"
  else
    die "compose.prod.yml not in $DIR and not reachable at $COMPOSE_URL"
  fi
  log "check OK: docker present, compose v2, host=$HOST, image=$IMAGE, auth=$([ -n "$PASSWORD" ] && echo password || echo trust-proxy), compose=$compose_status"
  [ -n "$LICENSE" ] || warn "no --license given; premium features will be locked under LICENSE_ENFORCE=true"
  exit 0
fi

# One-liner support: when piped (curl ... | bash) compose.prod.yml is not on
# disk. Fetch it from the bootstrap repo and print its sha256 — verify before
# trusting (do not curl | bash blind).
if [ ! -f "$COMPOSE_FILE" ]; then
  log "compose.prod.yml not found; fetching from $COMPOSE_URL"
  curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_FILE" \
    || die "failed to fetch compose.prod.yml (set BOOTSTRAP_BASE, or ship it alongside install.sh)"
  log "fetched compose.prod.yml — sha256: $(sha256 "$COMPOSE_FILE")"
fi

mkdir -p "$DIR/data" "$DIR/data/ssh"

# ── per-host SSH key (executor for host crons). Never embedded; generated here. ──
SSH_KEY="$DIR/data/ssh/id_ed25519"
if [ ! -f "$SSH_KEY" ]; then
  log "generating per-host SSH key"
  ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "dashboard@$HOST" >/dev/null
  warn "add this public key to the host's authorized_keys for the executor user:"
  cat "$SSH_KEY.pub"
fi

# ── license ──
if [ -n "$LICENSE" ]; then
  printf '%s\n' "$LICENSE" > "$DIR/data/license.key"
  log "license written to data/license.key"
fi

# ── .env (no secrets from the distribution; only what the operator supplied) ──
ENV_FILE="$DIR/.env"
{
  echo "DASHBOARD_HOST=$HOST"
  echo "DASHBOARD_IMAGE=$IMAGE"
  if [ -n "$PASSWORD" ]; then
    echo "DASHBOARD_PASSWORD=$PASSWORD"
  fi
  if [ "$TRUST_PROXY" = "true" ]; then
    echo "TRUST_PROXY_AUTH=true"
  fi
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
log "wrote $ENV_FILE (mode 600)"

# ── pull + up ──
log "pulling $IMAGE"
docker pull "$IMAGE"
log "starting dashboard"
( cd "$DIR" && docker compose -f compose.prod.yml up -d )

log "done. dashboard at https://$HOST  (health: /api/health)"
