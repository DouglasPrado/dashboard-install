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
#   --runtimes <list>    Comma-separated agent runtime CLIs to install for the
#                        executor. Default: claude-code,opencode,codex. Known:
#                        claude-code, opencode, codex, cursor (cursor is wip).
#   --dir <path>         Install directory (default: current directory).
#   --check              Validate prerequisites and inputs, then exit (no changes).
#   -h, --help           Show this help.
#
set -euo pipefail

IMAGE_DEFAULT="ghcr.io/douglasprado/dashboard-install:latest"
DOCKER_VERSION="28.5"   # pin: engine 29 raised the min API version; the stack's Traefik client is pinned to 1.24
EXECUTOR_USER="claude-bots"   # host user the dashboard SSHes into to run agent CLIs
WORKSPACE_DIR="/root/workspace"   # where the image clones projects (hardcoded host path in clone-project.ts)

# Agent runtime CLIs the dashboard can drive (see server/runtime-adapter/registry.ts).
# Each maps an id → install command; the resolved binary is symlinked onto
# /usr/local/bin so the non-interactive ssh executor session sees it.
CLAUDE_INSTALL_URL="https://claude.ai/install.sh"
OPENCODE_INSTALL_URL="https://opencode.ai/install"
CODEX_INSTALL_URL="https://chatgpt.com/codex/install.sh"
CURSOR_INSTALL_URL="https://cursor.com/install"
# Default: the runtimes marked status=available in the registry. cursor is wip
# there, so it's omitted by default but can be requested via --runtimes.
RUNTIMES_DEFAULT="claude-code,opencode,codex"

HOST=""
LICENSE=""
IMAGE="$IMAGE_DEFAULT"
PASSWORD=""
TRUST_PROXY="false"
BOOTSTRAP="true"
DIR="$PWD"
CHECK_ONLY="false"
RUNTIMES="$RUNTIMES_DEFAULT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
sha256() { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }
detect_ip() { ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1; }

# True when something is listening on TCP :22 (the executor SSH endpoint the
# dashboard reaches over host.docker.internal). Used to verify sshd actually
# came up, since enabling it can silently no-op on minimal/LXC hosts.
sshd_listening() {
  if command -v ss >/dev/null 2>&1; then
    [ -n "$(ss -ltnH 'sport = :22' 2>/dev/null)" ]
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -qE '[:.]22[[:space:]]'
  else
    return 1
  fi
}

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

# Map a runtime id to "<binary> <install-command>". Unknown id → non-zero.
# Keep ids in sync with server/runtime-adapter/registry.ts.
runtime_spec() { # <runtime-id>
  case "$1" in
    claude-code) echo "claude|curl -fsSL $CLAUDE_INSTALL_URL | bash" ;;
    opencode)    echo "opencode|curl -fsSL $OPENCODE_INSTALL_URL | bash" ;;
    codex)       echo "codex|curl -fsSL $CODEX_INSTALL_URL | sh" ;;
    cursor)      echo "cursor-agent|curl -fsS $CURSOR_INSTALL_URL | bash" ;;
    *)           return 1 ;;
  esac
}

# Resolve where an installer dropped a binary for the executor user. The native
# installers add it to ~/.local/bin (and runtime-specific dirs), none of which a
# non-interactive `ssh user@host '<cmd>'` reads — so we resolve it here and
# symlink onto /usr/local/bin. Try the login shell's PATH first (sources rc
# files the installer edits), then known install dirs. Prints the path on stdout.
resolve_runtime_bin() { # <binary> <home>
  local bin="$1" home="$2" p cand
  # 1. login shell PATH (sources the rc files the installer edits) — the
  #    installer-blessed path, robust to future install-dir changes.
  p="$(runuser -u "$EXECUTOR_USER" -- bash -lc "command -v $bin" 2>/dev/null)" || true
  if [ -n "$p" ] && [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
  # 2. known fixed install dirs across the native installers. The codex
  #    standalone installer nests the binary under packages/standalone/current.
  for p in \
    "$home/.local/bin/$bin" \
    "$home/.opencode/bin/$bin" \
    "$home/.codex/bin/$bin" \
    "$home/.codex/packages/standalone/current/bin/$bin" \
    "$home/.cursor/bin/$bin" \
    "$home/bin/$bin"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  # 3. versioned dirs (cursor drops the binary under versions/<ver>/). The glob
  #    sorts lexically and version dirs are date-stamped, so the last match is
  #    the newest.
  p=""
  for cand in "$home"/.local/share/cursor-agent/versions/*/"$bin"; do
    [ -x "$cand" ] && p="$cand"
  done
  if [ -n "$p" ] && [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
  return 1
}

# Install one runtime CLI for the executor user and symlink it onto
# /usr/local/bin. Idempotent (skips when the symlink target exists). Non-fatal:
# a failed runtime warns but doesn't abort the install — others may still work.
install_runtime() { # <runtime-id>
  local id="$1" spec bin cmd src
  spec="$(runtime_spec "$id")" || { warn "unknown runtime '$id' — skipping (known: claude-code, opencode, codex, cursor)"; return 0; }
  bin="${spec%%|*}"; cmd="${spec#*|}"

  if [ -x "/usr/local/bin/$bin" ]; then
    log "runtime $id present ($bin)"
    return 0
  fi

  log "installing runtime $id ($bin) for $EXECUTOR_USER"
  if ! runuser -u "$EXECUTOR_USER" -- bash -lc "$cmd"; then
    warn "runtime $id install failed — install '$bin' manually for $EXECUTOR_USER and symlink to /usr/local/bin/$bin"
    return 0
  fi

  local home; home="$(getent passwd "$EXECUTOR_USER" | cut -d: -f6)"
  if src="$(resolve_runtime_bin "$bin" "$home")"; then
    ln -sf "$src" "/usr/local/bin/$bin"
    log "runtime $id ready: $bin -> $src"
  else
    warn "runtime $id installed but '$bin' not found on PATH or known dirs — add it to /usr/local/bin manually"
  fi
}

# Provision the host-side agent executor: a dedicated `claude-bots` user the
# dashboard SSHes into (host.docker.internal) to run the agent runtime CLIs.
# Without this a fresh host can't run agents ("Claude Code não instalado").
# Idempotent; gated by bootstrap like docker/stack. Requires $SSH_KEY.pub to
# exist (key gen runs first). Installs the runtimes named in $RUNTIMES. A
# one-time per-runtime login (e.g. `claude /login`) is still needed afterwards.
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

  # 2b. workspace ownership: the dashboard clones projects into $WORKSPACE_DIR
  #     (a host path hardcoded in the image) but runs git as the non-root
  #     executor over SSH. Without ownership + traverse into /root, clone fails
  #     with exit 128 "could not create leading directories ... Permission denied".
  mkdir -p "$WORKSPACE_DIR"
  chown "$EXECUTOR_USER:$EXECUTOR_USER" "$WORKSPACE_DIR"
  # /root is mode 700; grant the executor traverse (x) without exposing a listing.
  # Prefer a targeted ACL; fall back to o+x (any local user can traverse, not read).
  if command -v setfacl >/dev/null 2>&1 && setfacl -m "u:$EXECUTOR_USER:x" /root 2>/dev/null; then
    :
  else
    chmod o+x /root
  fi
  log "workspace $WORKSPACE_DIR owned by $EXECUTOR_USER (executor can clone)"

  # 3. sshd must accept the container->host connection (over host-gateway). A
  #    fresh VM may ship no openssh-server, no host keys, or no working init
  #    (minimal LXC), so each step is best-effort and the result is verified on
  #    :22 at the end — a refused connection here is the #1 reason clone/agents
  #    fail with "connect to host host.docker.internal port 22: Connection refused".
  if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    if command -v apt-get >/dev/null 2>&1; then
      log "installing openssh-server"
      # Refresh the index first — a fresh VM's apt cache is often empty, which
      # makes the install fail with "Unable to locate package openssh-server".
      apt-get update -qq >/dev/null 2>&1 || warn "apt-get update failed; openssh-server install may not find the package"
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null 2>&1 \
        || warn "failed to install openssh-server — install an SSH server so the dashboard can reach the host executor"
    else
      warn "sshd not found and apt-get unavailable — install an SSH server so the dashboard can reach the host executor"
    fi
  fi

  # Host keys: a partial/failed install can leave sshd unable to start. Generate
  # any that are missing (no-op when they already exist).
  if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
    ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || ssh-keygen -A >/dev/null 2>&1 || true
  fi

  # Start sshd, trying init systems in order: systemd, SysV/service, then the
  # daemon directly (minimal LXC images often have no working init manager).
  if ! sshd_listening && command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
    systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
  fi
  if ! sshd_listening; then
    service ssh start >/dev/null 2>&1 || service sshd start >/dev/null 2>&1 || true
  fi
  if ! sshd_listening && [ -x /usr/sbin/sshd ]; then
    /usr/sbin/sshd >/dev/null 2>&1 || true
  fi
  if sshd_listening; then
    log "sshd listening on :22 (executor reachable)"
  else
    warn "sshd is NOT listening on :22 — the dashboard's SSH to host.docker.internal will be refused and clone/agents won't run; start an SSH server on the host manually"
  fi

  # 4. agent runtime CLIs on a PATH the non-interactive ssh session sees. The
  # native installers drop binaries in ~/.local/bin (not read by `ssh
  # user@host '<cmd>'`), so install_runtime symlinks each onto /usr/local/bin.
  local rt
  IFS=',' read -ra _runtimes <<< "$RUNTIMES"
  for rt in "${_runtimes[@]}"; do
    rt="$(echo "$rt" | tr -d '[:space:]')"
    [ -n "$rt" ] && install_runtime "$rt"
  done

  if [ -x /usr/local/bin/claude ]; then
    log "executor ready: $EXECUTOR_USER + claude ($(/usr/local/bin/claude --version 2>/dev/null || echo 'version unknown'))"
  fi
  warn "one-time step per runtime: log in before running agents (e.g. dashboard → Claude → login (claude /login OAuth); codex login / OPENAI_API_KEY; opencode auth)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host)         HOST="${2:-}"; shift 2 ;;
    --license)      LICENSE="${2:-}"; shift 2 ;;
    --image)        IMAGE="${2:-}"; shift 2 ;;
    --password)     PASSWORD="${2:-}"; shift 2 ;;
    --trust-proxy)  TRUST_PROXY="true"; shift ;;
    --no-bootstrap) BOOTSTRAP="false"; shift ;;
    --runtimes)     RUNTIMES="${2:-}"; shift 2 ;;
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
  runtimes_status=""
  IFS=',' read -ra _chk_runtimes <<< "$RUNTIMES"
  for rt in "${_chk_runtimes[@]}"; do
    rt="$(echo "$rt" | tr -d '[:space:]')"; [ -n "$rt" ] || continue
    if spec="$(runtime_spec "$rt")"; then
      bin="${spec%%|*}"
      st="$([ -x "/usr/local/bin/$bin" ] && echo present || echo "$([ "$BOOTSTRAP" = true ] && echo "would install" || echo "absent")")"
    else
      st="unknown id"
    fi
    runtimes_status="${runtimes_status:+$runtimes_status, }$rt=$st"
  done
  if sshd_listening; then
    sshd_status="listening :22"
  elif command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
    sshd_status="$([ "$BOOTSTRAP" = true ] && echo "installed, not listening (would start)" || echo "installed, NOT listening — clone/agents refused")"
  else
    sshd_status="$([ "$BOOTSTRAP" = true ] && echo "absent (would install)" || echo "absent — clone/agents won't run")"
  fi
  log "check: host=$HOST, image=$IMAGE, auth=license-session, identity=${identity:-none}, bootstrap=$BOOTSTRAP"
  log "       docker=$docker_status, stack_web=$net_status, compose=$compose_status"
  ws_status="$([ -d "$WORKSPACE_DIR" ] && echo "owner=$(stat -c '%U' "$WORKSPACE_DIR" 2>/dev/null || echo '?')" || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would create)" || echo "absent — clone fails")")"
  log "       executor($EXECUTOR_USER)=$exec_user_status, sshd=$sshd_status, workspace=$ws_status"
  log "       runtimes: $runtimes_status"
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
