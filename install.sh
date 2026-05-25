#!/usr/bin/env bash
#
# Dashboard installer — distribution mode (published Docker image).
#
# Pulls the published image (no source on this host), provisions per-host
# secrets locally (nothing is embedded in the distribution), installs the
# license, and brings the stack up via compose.prod.yml. With bootstrap on
# (default) it also installs Docker and the shared Traefik stack if missing,
# and provisions the host-side agent executor (the claude-bots user + its
# authorized_keys + the claude CLI), so a fresh VM goes from zero to running
# agents in one command. A one-time `claude /login` (via the UI) is still
# needed before agents can run.
#
# Usage:
#   curl -sSL .../install.sh | bash            # zero-arg on a fresh host
#   ./install.sh --host dash.example.com --license <key> [options]
#
# Options:
#   --host <domain>      Host the dashboard is served at. Default: dash.<ip>.nip.io.
#   --license <key>      License token, or a path to a file containing it. The
#                        license is the login credential — every route is gated
#                        behind a license-key session. Omit to paste the key on
#                        the first-run login screen instead.
#   --image <ref>        Image to pull (default: ghcr.io/douglasprado/dashboard:latest).
#                        Prefer a digest pin: ...@sha256:<digest>.
#   --password <pw>      Optional. Adds a basic-auth identity for admin-role authz
#                        (DASHBOARD_ADMINS); not required to boot or to log in.
#   --trust-proxy        Optional. Trust a reverse-proxy identity header as the
#                        admin-role identity; not required to boot or to log in.
#   --no-bootstrap       Don't install Docker, the stack, or the executor user;
#                        require them present.
#   --dir <path>         Install directory (default: current directory).
#   --check              Validate prerequisites and inputs, then exit (no changes).
#   -h, --help           Show this help.
#
set -euo pipefail

IMAGE_DEFAULT="ghcr.io/douglasprado/dashboard:latest"
DOCKER_VERSION="28.5"   # pin: engine 29 raised the min API version; the stack's Traefik client is pinned to 1.24
EXECUTOR_USER="claude-bots"   # host user the dashboard SSHes into to run `claude`
CLAUDE_INSTALL_URL="https://claude.ai/install.sh"

HOST=""
LICENSE=""
IMAGE="$IMAGE_DEFAULT"
PASSWORD=""
TRUST_PROXY="false"
BOOTSTRAP="true"
DIR="$PWD"
CHECK_ONLY="false"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
sha256() { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }
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

# Provision the host-side agent executor: a dedicated `claude-bots` user the
# dashboard SSHes into (host.docker.internal) to run `claude`. Without this a
# fresh host can't run agents ("Claude Code não instalado"). Idempotent; gated
# by bootstrap like docker/stack. Requires $SSH_KEY.pub to exist (key gen runs
# first). A one-time `claude /login` is still needed afterwards, via the UI.
ensure_executor() {
  if [ "$BOOTSTRAP" != "true" ]; then
    warn "skipping executor setup (--no-bootstrap); ensure user '$EXECUTOR_USER', its authorized_keys, and 'claude' on PATH exist on the host"
    return 0
  fi

  # 1. executor user
  if ! id "$EXECUTOR_USER" >/dev/null 2>&1; then
    log "creating executor user $EXECUTOR_USER"
    useradd -m -s /bin/bash "$EXECUTOR_USER" || die "failed to create user $EXECUTOR_USER"
  fi
  local home; home="$(getent passwd "$EXECUTOR_USER" | cut -d: -f6)"
  [ -n "$home" ] && [ -d "$home" ] || die "could not resolve home dir for $EXECUTOR_USER"

  # 2. authorize the dashboard's generated key (append-once, idempotent)
  install -d -m 700 -o "$EXECUTOR_USER" -g "$EXECUTOR_USER" "$home/.ssh"
  local ak="$home/.ssh/authorized_keys" pub
  pub="$(cat "$SSH_KEY.pub")"
  if [ ! -f "$ak" ] || ! grep -qF "$pub" "$ak"; then
    printf '%s\n' "$pub" >> "$ak"
    log "authorized dashboard key for $EXECUTOR_USER"
  fi
  chown "$EXECUTOR_USER:$EXECUTOR_USER" "$ak"; chmod 600 "$ak"

  # 3. sshd must accept the container->host connection (over host-gateway)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now ssh >/dev/null 2>&1 \
      || systemctl enable --now sshd >/dev/null 2>&1 \
      || warn "could not start sshd — start it so the dashboard can reach the host executor"
  fi

  # 4. claude CLI on a PATH the non-interactive ssh session sees. The native
  # installer drops it in ~/.local/bin (not read by `ssh user@host '<cmd>'`),
  # so symlink it onto /usr/local/bin.
  if [ ! -x /usr/local/bin/claude ]; then
    log "installing Claude Code CLI for $EXECUTOR_USER"
    if runuser -u "$EXECUTOR_USER" -- bash -lc "curl -fsSL $CLAUDE_INSTALL_URL | bash"; then
      local cbin="$home/.local/bin/claude"
      if [ -x "$cbin" ]; then
        ln -sf "$cbin" /usr/local/bin/claude
      else
        warn "claude installed but not at $cbin — add it to /usr/local/bin manually"
      fi
    else
      warn "claude install failed — install it manually for $EXECUTOR_USER and symlink to /usr/local/bin/claude"
    fi
  fi

  if [ -x /usr/local/bin/claude ]; then
    log "executor ready: $EXECUTOR_USER + claude ($(/usr/local/bin/claude --version 2>/dev/null || echo 'version unknown'))"
  fi
  warn "one-time step: open the dashboard → Claude section → login (claude /login OAuth) before running agents"
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

# ── auth: the license-key session gates every API route, so the dashboard boots
# safe with no password/proxy. --password / --trust-proxy are optional and only
# supply an operator identity for admin-role authz. Without a license nobody can
# log in — warn, don't die, since the key can be pasted on the first-run screen.
if [ -z "$LICENSE" ]; then
  warn "no --license given; the dashboard will start at the first-run activation screen, where a valid license key is required to log in"
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
  identity=""
  if [ -n "$PASSWORD" ]; then identity="password"; fi
  if [ "$TRUST_PROXY" = "true" ]; then identity="${identity:+$identity,}trust-proxy"; fi
  exec_user_status="$(id "$EXECUTOR_USER" >/dev/null 2>&1 && echo present || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would create)" || echo "absent — agents won't run")")"
  claude_status="$([ -x /usr/local/bin/claude ] && echo present || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would install)" || echo "absent — agents won't run")")"
  log "check: host=$HOST, image=$IMAGE, auth=license-session, identity=${identity:-none}, bootstrap=$BOOTSTRAP"
  log "       docker=$docker_status, stack_web=$net_status, compose=$compose_status"
  log "       executor($EXECUTOR_USER)=$exec_user_status, claude=$claude_status"
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
  log "generated executor SSH key"
fi

# ── host-side agent executor (claude-bots user + authorized_keys + claude CLI) ──
ensure_executor

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
if [ -n "$LICENSE" ]; then
  log "open the dashboard and log in with your license key"
else
  log "open the dashboard; the first-run screen will ask for your license key"
fi
log "to run agents: dashboard → Claude section → login (one-time claude /login OAuth)"
