#!/usr/bin/env bash
#
# Dashboard installer — distribution mode (published Docker image).
#
# Pulls the published image (no source on this host), provisions per-host
# secrets locally (nothing is embedded in the distribution), installs the
# license, and brings the stack up via compose.prod.yml. With bootstrap on
# (default) it also installs Docker and the shared Traefik stack if missing,
# so a fresh VM goes from zero to running in one command.
#
# Usage:
#   curl -sSL .../install.sh | bash            # zero-arg on a fresh host
#   ./install.sh --host dash.example.com --license <key> [options]
#
# Options:
#   --host <domain>      Host the dashboard is served at. Default: dash.<ip>.nip.io.
#   --license <key>      License token, or a path to a file containing it.
#   --image <ref>        Image to pull (default: ghcr.io/douglasprado/dashboard:latest).
#                        Prefer a digest pin: ...@sha256:<digest>.
#   --password <pw>      Basic-auth password. Omitted: a random one is generated.
#   --trust-proxy        Trust a reverse-proxy identity header instead of a password.
#   --no-bootstrap       Don't install Docker or the stack; require them present.
#   --dir <path>         Install directory (default: current directory).
#   --check              Validate prerequisites and inputs, then exit (no changes).
#   -h, --help           Show this help.
#
set -euo pipefail

IMAGE_DEFAULT="ghcr.io/douglasprado/dashboard:latest"
DOCKER_VERSION="28.5"   # pin: engine 29 raised the min API version; the stack's Traefik client is pinned to 1.24

HOST=""
LICENSE=""
IMAGE="$IMAGE_DEFAULT"
PASSWORD=""
TRUST_PROXY="false"
BOOTSTRAP="true"
DIR="$PWD"
CHECK_ONLY="false"
GEN_PASSWORD="false"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
sha256() { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }
gen_secret() { openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
detect_ip() { ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1; }

# Public bootstrap repo hosting install.sh, compose.prod.yml and the minimal
# Traefik stack. Piped installs fetch these from here. Override with
# BOOTSTRAP_BASE for a fork or a pinned ref.
BOOTSTRAP_BASE="${BOOTSTRAP_BASE:-https://raw.githubusercontent.com/DouglasPrado/dashboard-install/main}"

usage() { sed -n '2,/^set -euo/{/^set -euo/!p}' "$0" | sed 's/^# \{0,1\}//'; }

# Fetch a bootstrap file to a path if it isn't already there.
fetch() { # <relpath> <dest>
  [ -f "$2" ] && return 0
  curl -fsSL "$BOOTSTRAP_BASE/$1" -o "$2" || die "failed to fetch $1 from $BOOTSTRAP_BASE"
}

# Install Docker + Compose v2 if missing (pinned). No-op when already present.
ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  [ "$BOOTSTRAP" = "true" ] || die "docker/compose missing (run without --no-bootstrap to install them)"
  command -v curl >/dev/null 2>&1 || die "curl is required to install docker"
  log "installing Docker $DOCKER_VERSION.x (engine 29 breaks the pinned Traefik client)"
  curl -fsSL https://get.docker.com | sh -s -- --version "$DOCKER_VERSION" || die "docker install failed"
  command -v systemctl >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "docker compose v2 not available after install"
}

# Create the stack_web network + minimal Traefik if the network is absent.
ensure_stack() {
  if docker network inspect stack_web >/dev/null 2>&1; then
    log "stack_web network present"
    return 0
  fi
  [ "$BOOTSTRAP" = "true" ] || die "stack_web network missing (run without --no-bootstrap to create it)"
  log "bringing up the shared stack (Traefik + stack_web network)"
  mkdir -p "$DIR/traefik"
  fetch "stack.compose.yml" "$DIR/stack.compose.yml"
  fetch "traefik/traefik.yml" "$DIR/traefik/traefik.yml"
  ( cd "$DIR" && docker compose -p stack -f stack.compose.yml up -d ) || die "failed to bring up the stack"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host)         HOST="${2:-}"; shift 2 ;;
    --license)      LICENSE="${2:-}"; shift 2 ;;
    --image)        IMAGE="${2:-}"; shift 2 ;;
    --password)     PASSWORD="${2:-}"; shift 2 ;;
    --trust-proxy)  TRUST_PROXY="true"; shift ;;
    --no-bootstrap) BOOTSTRAP="false"; shift ;;
    --dir)          DIR="${2:-}"; shift 2 ;;
    --check)        CHECK_ONLY="true"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown argument: $1 (see --help)" ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl not found in PATH"

# ── host default: dash.<primary-ip>.nip.io ──
if [ -z "$HOST" ]; then
  ip="$(detect_ip)"; ip="${ip:-127.0.0.1}"
  HOST="dash.${ip}.nip.io"
  log "no --host given; defaulting to $HOST"
fi

# ── auth: a password OR a trusted proxy header. With bootstrap on, an absent
# choice means "generate a password" so the host is never exposed without auth.
# Without bootstrap we refuse — the dashboard will not boot exposed unauthenticated.
if [ -z "$PASSWORD" ] && [ "$TRUST_PROXY" != "true" ]; then
  if [ "$BOOTSTRAP" = "true" ]; then
    PASSWORD="$(gen_secret)"
    GEN_PASSWORD="true"
    log "no auth flag given; generated a dashboard password (shown at the end)"
  else
    die "set --password <pw> or --trust-proxy; the dashboard refuses to boot exposed without auth"
  fi
fi

COMPOSE_FILE="$DIR/compose.prod.yml"
COMPOSE_URL="$BOOTSTRAP_BASE/compose.prod.yml"

# Resolve license: a readable path becomes its contents, else treat as the token.
if [ -n "$LICENSE" ] && [ -f "$LICENSE" ]; then
  LICENSE="$(tr -d '\n' < "$LICENSE")"
fi

if [ "$CHECK_ONLY" = "true" ]; then
  # Report only; --check never installs or writes anything.
  docker_status="present"
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 \
    || docker_status="$([ "$BOOTSTRAP" = true ] && echo "absent (would install $DOCKER_VERSION.x)" || echo "absent — FAILS without bootstrap")"
  net_status="$(docker network inspect stack_web >/dev/null 2>&1 && echo present || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would create)" || echo "absent — FAILS without bootstrap")")"
  if [ -f "$COMPOSE_FILE" ]; then
    compose_status="local"
  elif curl -fsIL "$COMPOSE_URL" >/dev/null 2>&1; then
    compose_status="fetchable"
  else
    compose_status="UNREACHABLE at $COMPOSE_URL"
  fi
  log "check: host=$HOST, image=$IMAGE, auth=$([ "$TRUST_PROXY" = true ] && echo trust-proxy || echo password), bootstrap=$BOOTSTRAP"
  log "       docker=$docker_status, stack_web=$net_status, compose=$compose_status"
  [ -n "$LICENSE" ] || warn "no --license given; premium features will be locked under LICENSE_ENFORCE=true"
  exit 0
fi

# ── bootstrap: Docker, then the shared stack ──
ensure_docker
ensure_stack

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

log "done. dashboard at http://$HOST  (health: /api/health)"
if [ "$GEN_PASSWORD" = "true" ]; then
  printf '\033[1;32m==> login: dashboard / %s\033[0m\n' "$PASSWORD"
  warn "this password is also in $ENV_FILE — change it there and re-run 'docker compose -f compose.prod.yml up -d'"
fi
