#!/usr/bin/env bash
#
# Dashboard installer — distribution mode (published Docker image).
#
# Pulls the published image (no source on this host), provisions per-host
# secrets locally (nothing is embedded in the distribution), installs the
# license, and brings the stack up via compose.prod.yml. With bootstrap on
# (default) it also installs Docker, the shared Traefik stack, and the host
# tooling clone/worktree/preview need (git, Node.js) if missing, and provisions
# the host-side agent executor (the claude-bots user + its authorized_keys + the
# claude CLI), so a fresh VM goes from zero to running agents in one command. A
# one-time `claude /login` (via the UI) is still needed before agents can run.
#
# Platforms: bootstrap (the default) provisions a Linux host executor and runs
# on Linux only. macOS/other Unix: pre-provision the executor and use
# --no-bootstrap. Windows: run inside WSL2 (Docker Desktop's WSL2 backend).
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
#   --image <ref>        Image to pull (default: ghcr.io/douglasprado/dashboard-install:latest).
#                        Prefer a digest pin: ...@sha256:<digest>.
#   --password <pw>      Optional. Adds a basic-auth identity for admin-role authz
#                        (DASHBOARD_ADMINS); not required to boot or to log in.
#   --trust-proxy        Optional. Trust a reverse-proxy identity header as the
#                        admin-role identity; not required to boot or to log in.
#   --tailscale          Install Tailscale and make this host a subnet router for
#                        its LAN, so any device on your tailnet reaches the
#                        dashboard via Traefik from anywhere — no public IP or
#                        port-forward. The default host dash.<lan-ip>.nip.io
#                        resolves to the LAN IP, delivered over the subnet route.
#                        APPROVE the advertised route once in the Tailscale admin
#                        console; Funnel stays OFF.
#   --ts-authkey <key>   Tailscale auth key for an unattended `tailscale up`
#                        (mint at login.tailscale.com/admin/settings/keys). Omit
#                        to authenticate interactively in the browser.
#   --no-bootstrap       Don't install Docker, the stack, or the executor user;
#                        require them present.
#   --no-caveman         Skip installing caveman token-compression skill for the
#                        executor (default: installed, reduces token usage ~75%).
#   --no-rtk             Skip installing RTK bash command compression for the
#                        executor (default: installed, reduces bash tokens ~60-90%).
#   --runtimes <list>    Comma-separated agent runtime CLIs to install for the
#                        executor. Default: claude-code,opencode,codex. Known:
#                        claude-code, opencode, codex, cursor (cursor is wip).
#   --dir <path>         Install directory (default: current directory).
#   --check              Validate prerequisites and inputs, then exit (no changes).
#   -h, --help           Show this help.
#
set -euo pipefail

IMAGE_DEFAULT="ghcr.io/douglasprado/dashboard-install:latest"
NODE_MAJOR="22"   # match the node:22-alpine the preview/auto-setup containers build from (see dashboard auto-setup.ts)
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
CAVEMAN_INSTALL_URL="https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh"
RTK_INSTALL_URL="https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh"
TAILSCALE_INSTALL_URL="https://tailscale.com/install.sh"

HOST=""
LICENSE=""
IMAGE="$IMAGE_DEFAULT"
PASSWORD=""
TRUST_PROXY="false"
BOOTSTRAP="true"
DIR="$PWD"
CHECK_ONLY="false"
RUNTIMES="$RUNTIMES_DEFAULT"
CAVEMAN="true"
RTK="true"
TAILSCALE="false"
TS_AUTHKEY=""

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

# Preflight: bootstrap mutates root-owned state (useradd, apt-get install,
# systemctl, /usr/local/bin symlinks, chown of $WORKSPACE_DIR, traverse on
# /root) and will half-run as a non-root user — leaving orphan files like
# data/id_ed25519 owned by the calling uid that the next sudo retry inherits
# and chokes on. Fail fast here with the exact escape hatches instead.
require_root_for_bootstrap() {
  [ "$BOOTSTRAP" = "true" ] || return 0
  [ "$(id -u)" -eq 0 ] && return 0
  die "bootstrap requires root — re-run with sudo (sudo ./install.sh ...), or pass --no-bootstrap to skip Docker install, the shared stack, and executor user setup (in which case '$EXECUTOR_USER', its authorized_keys, and the runtime CLIs on PATH must already be provisioned)"
}

# Install Docker + Compose v2 if missing (latest stable). No-op when already present.
ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  [ "$BOOTSTRAP" = "true" ] || die "docker/compose missing (run without --no-bootstrap to install them)"
  command -v curl >/dev/null 2>&1 || die "curl is required to install docker"
  log "installing Docker (latest stable; the stack's Traefik v3.7 speaks the modern engine API)"
  curl -fsSL https://get.docker.com | sh || die "docker install failed"
  command -v systemctl >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "docker compose v2 not available after install"
}

# Install the host-side tools the dashboard runs AS THE EXECUTOR over SSH.
#
#   git  — clone-project.ts runs `git clone` and git-worktree.ts runs
#          `git worktree` ON THE HOST (host.docker.internal), not in the
#          container. The live preview mounts the per-session worktree into
#          /app, so without host git the clone fails (exit 128) and no preview
#          ever comes up. This is the #1 reason live preview won't start on a
#          fresh VM: dev hosts ship git system-wide, a minimal VM doesn't.
#   node — lets the executor's agents run a project's dev tooling (pnpm install,
#          a dev server) directly against a worktree on the host. The dashboard's
#          own preview containers bundle node:$NODE_MAJOR-alpine, so the preview
#          feature itself doesn't need host node — agent-driven local runs do.
#
# Gated by bootstrap like docker/stack. Best-effort per tool: a failed install
# warns but doesn't abort (git failing is loud since clone needs it).
ensure_host_tooling() {
  local need_git="" need_node=""
  command -v git  >/dev/null 2>&1 || need_git=1
  command -v node >/dev/null 2>&1 || need_node=1
  if [ -z "$need_git" ] && [ -z "$need_node" ]; then
    log "host tooling present (git, node $(node -v 2>/dev/null))"
    return 0
  fi

  if [ "$BOOTSTRAP" != "true" ]; then
    die "missing host tooling:${need_git:+ git}${need_node:+ node} — clone/worktree/preview run them on the host as the executor (run without --no-bootstrap to install, or put them on the host PATH)"
    return 1
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get unavailable — install${need_git:+ git}${need_node:+ node} on the host PATH manually (clone/preview need git)"
    return 0
  fi

  apt-get update -qq >/dev/null 2>&1 || warn "apt-get update failed; tooling install may not find packages"

  if [ -n "$need_git" ]; then
    log "installing git (clone/worktree/preview run it on the host)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null 2>&1 \
      || warn "failed to install git — clone and live preview need it; install git on the host"
  fi

  if [ -n "$need_node" ]; then
    log "installing Node.js $NODE_MAJOR.x (matches the node:$NODE_MAJOR containers the preview builds)"
    # Prefer NodeSource for a current LTS matching the container; fall back to the
    # distro packages (older, but enough for agents to run dev tooling) if the
    # NodeSource setup doesn't support this release.
    if ! { command -v curl >/dev/null 2>&1 \
        && curl -fsSL "https://deb.nodesource.com/setup_$NODE_MAJOR.x" | bash - >/dev/null 2>&1 \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null 2>&1; }; then
      warn "NodeSource setup failed; falling back to the distro nodejs/npm packages (older version)"
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs npm >/dev/null 2>&1 \
        || warn "failed to install Node.js — install it on the host PATH so agents can run project dev tooling"
    fi
    # corepack ships with Node >=16 and provisions pnpm/yarn on demand; projects here use pnpm.
    command -v corepack >/dev/null 2>&1 && corepack enable >/dev/null 2>&1 || true
  fi

  command -v git  >/dev/null 2>&1 && log "git ready ($(git --version 2>/dev/null))"
  command -v node >/dev/null 2>&1 && log "node ready ($(node --version 2>/dev/null))"
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

# Detect the primary LAN CIDR to advertise as a subnet route (e.g. 192.168.3.0/24)
# from the kernel "scope link" route on the default-route interface. Empty when it
# can't be determined.
detect_lan_cidr() {
  local dev
  dev="$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
  [ -n "$dev" ] || return 0
  ip -4 -o route show dev "$dev" scope link 2>/dev/null | awk '{print $1}' | grep -E '/[0-9]+$' | head -1
}

# Install Tailscale and make this host a SUBNET ROUTER for its LAN, so any device
# on your tailnet reaches the dashboard (via Traefik, at dash.<lan-ip>.nip.io)
# from anywhere — no public IP, no port-forward. Enables IPv4 forwarding (a subnet
# router drops packets without it) and advertises the detected LAN CIDR. Funnel
# stays OFF. Node auth (`tailscale up`) is OAuth/browser unless --ts-authkey is
# given, so a piped, non-interactive run needs the key. The advertised route must
# be APPROVED once in the Tailscale admin console. Idempotent; gated by --tailscale.
ensure_tailscale() {
  [ "$TAILSCALE" = "true" ] || return 0

  # 1. CLI/daemon
  if ! command -v tailscale >/dev/null 2>&1; then
    [ "$BOOTSTRAP" = "true" ] || die "tailscale missing (run without --no-bootstrap to install it, or install Tailscale first)"
    command -v curl >/dev/null 2>&1 || die "curl is required to install tailscale"
    log "installing Tailscale"
    curl -fsSL "$TAILSCALE_INSTALL_URL" | sh || die "tailscale install failed"
  fi

  # 2. tailscaled must be running. The installer enables it under systemd;
  #    minimal/WSL hosts without systemd need it started by hand with userspace
  #    networking (no /dev/net/tun).
  if ! tailscale status >/dev/null 2>&1; then
    command -v systemctl >/dev/null 2>&1 && systemctl enable --now tailscaled >/dev/null 2>&1 || true
    if ! tailscale status >/dev/null 2>&1; then
      warn "tailscaled may not be running — on WSL without systemd, start it once: sudo tailscaled --tun=userspace-networking >/tmp/tailscaled.log 2>&1 &"
    fi
  fi

  # 3. IPv4 forwarding — a subnet router forwards LAN traffic only when the kernel
  #    has it enabled; otherwise the route is advertised but packets are dropped.
  if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
    if [ "$(id -u)" -eq 0 ]; then
      log "enabling IPv4/IPv6 forwarding (subnet router needs it)"
      printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > /etc/sysctl.d/99-tailscale.conf 2>/dev/null || true
      sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    else
      warn "IPv4 forwarding is off — enable it so the subnet route works: sudo sysctl -w net.ipv4.ip_forward=1"
    fi
  fi

  # 4. advertise the LAN CIDR and bring the node up. Reuse the running login when
  #    already up (just (re)set the route); else use the auth key, else interactive
  #    browser auth from a TTY, else fail loud instead of hanging.
  local cidr; cidr="$(detect_lan_cidr)"
  [ -n "$cidr" ] || warn "could not detect the LAN CIDR — after install run: sudo tailscale up --advertise-routes=<your-lan>/24"
  if tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -qi 'logged out'; then
    log "tailscale already up; advertising route ${cidr:-<none>}"
    [ -n "$cidr" ] && { tailscale set --advertise-routes="$cidr" 2>/dev/null \
      || warn "could not set the route — run: sudo tailscale up --advertise-routes=$cidr"; }
  elif [ -n "$TS_AUTHKEY" ]; then
    log "tailscale up (auth key; advertising ${cidr:-<none>})"
    tailscale up --authkey "$TS_AUTHKEY" ${cidr:+--advertise-routes="$cidr"} || die "tailscale up failed — check the auth key"
  elif [ -t 0 ] && [ -t 1 ]; then
    log "tailscale up — authenticate in the browser when the login URL is printed (advertising ${cidr:-<none>})"
    tailscale up ${cidr:+--advertise-routes="$cidr"} || die "tailscale up failed or was cancelled"
  else
    die "tailscale is not logged in and no --ts-authkey was given (non-interactive run). Mint a key at https://login.tailscale.com/admin/settings/keys and re-run with --ts-authkey <key>, or run 'sudo tailscale up --advertise-routes=${cidr:-<lan>/24}' first."
  fi
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

# Map a runtime id to "<auth-probe-relpath>|<login-command>". The probe is a
# file under the executor home whose presence means the runtime is logged in;
# empty = no CLI probe (auth is env/OAuth, status unknown). The login command
# is interactive (OAuth/API key) and is run AS the executor user.
runtime_login_spec() { # <runtime-id>
  case "$1" in
    claude-code) echo ".claude/.credentials.json|claude /login" ;;
    opencode)    echo ".local/share/opencode/auth.json|opencode auth login" ;;
    codex)       echo ".codex/auth.json|codex login" ;;
    cursor)      echo "|cursor-agent login" ;;
    *)           return 1 ;;
  esac
}

# True when the runtime's auth probe file exists under the executor home. An
# empty probe → unknown → reported as not-authed (non-zero) so the login hint
# is still surfaced.
runtime_authed() { # <runtime-id> <home>
  local lspec probe
  lspec="$(runtime_login_spec "$1")" || return 1
  probe="${lspec%%|*}"
  [ -n "$probe" ] && [ -f "$2/$probe" ]
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

# Install caveman for the executor user. Caveman is a skill that compresses
# token usage by ~75% while keeping full technical accuracy. It runs as a
# SessionStart hook and persists in .claude/settings.json. Idempotent.
install_caveman() {
  [ "$CAVEMAN" = "true" ] || return 0
  [ "$BOOTSTRAP" = "true" ] || return 0

  # Skip if already installed (settings.json has caveman hooks or enabledPlugins)
  local home; home="$(getent passwd "$EXECUTOR_USER" | cut -d: -f6)"
  local settings="$home/.claude/settings.json"
  if [ -f "$settings" ]; then
    if grep -q '"caveman' "$settings" 2>/dev/null; then
      log "caveman already installed for $EXECUTOR_USER"
      return 0
    fi
  fi

  log "installing caveman for $EXECUTOR_USER (token compression skill)"
  # Caveman installer is a Node script that detects installed runtimes and
  # configures hooks/settings.json. Run as the executor user with explicit
  # --config-dir and NPM_CONFIG_PREFIX to avoid writing to /root/.agents.
  if ! runuser -u "$EXECUTOR_USER" -- bash -lc "
    command -v node >/dev/null 2>&1 || { echo 'node required for caveman'; exit 1; }
    export NPM_CONFIG_PREFIX='$home/.npm-global'
    export npm_config_prefix='$home/.npm-global'
    mkdir -p '$home/.npm-global/bin'
    export PATH=\"\$PATH:'$home/.npm-global/bin'\"
    curl -fsSL $CAVEMAN_INSTALL_URL | bash -s -- --non-interactive --with-hooks --config-dir '$home/.claude'
  "; then
    warn "caveman install failed — agents will work without token compression"
    return 0
  fi

  log "caveman ready: agents will use compressed token mode by default"
}

# Install RTK (Rust Token Killer) for the executor user. RTK reduces token
# usage by 60-90% on bash commands by filtering and compressing output.
# Intercepts commands (e.g., `git status` → `rtk git status`) via hook.
# Idempotent.
install_rtk() {
  [ "$RTK" = "true" ] || return 0
  [ "$BOOTSTRAP" = "true" ] || return 0

  # Skip if already installed (rtk binary exists)
  local home; home="$(getent passwd "$EXECUTOR_USER" | cut -d: -f6)"
  if [ -x "$home/.local/bin/rtk" ]; then
    log "rtk already installed for $EXECUTOR_USER"
    return 0
  fi

  log "installing RTK for $EXECUTOR_USER (bash command token compression)"
  # RTK installer is a shell script that installs to ~/.local/bin.
  # Run as the executor user. Then initialize the hook for Claude Code.
  if ! runuser -u "$EXECUTOR_USER" -- bash -lc "
    curl -fsSL $RTK_INSTALL_URL | sh
    [ -x ~/.local/bin/rtk ] || { echo 'rtk binary not found'; exit 1; }
    ~/.local/bin/rtk init -g --auto-patch
  "; then
    warn "RTK install failed — agents will work without bash compression"
    return 0
  fi

  # Symlink rtk to /usr/local/bin so the non-interactive ssh session sees it
  if [ -x "$home/.local/bin/rtk" ]; then
    ln -sf "$home/.local/bin/rtk" "/usr/local/bin/rtk"
    log "rtk ready: bash commands compressed via rtk hook"
  fi
}

# Install the canonical Claude Code subagents for the executor user. Dropping
# test-writer into ~/.claude/agents (user level) makes `subagent_type: test-writer`
# resolvable from ANY project the dashboard's agents run in — not only repos that
# happen to ship their own .claude/agents dir. Lets the assistant agent delegate
# test work to a cheaper haiku subagent regardless of the run's cwd.
# Idempotent: skips a subagent that already exists (preserves local edits).
install_subagents() {
  [ "$BOOTSTRAP" = "true" ] || return 0

  local home; home="$(getent passwd "$EXECUTOR_USER" | cut -d: -f6)"
  [ -n "$home" ] || { warn "could not resolve home for $EXECUTOR_USER — skipping subagents"; return 0; }
  local f="$home/.claude/agents/test-writer.md"

  if [ -f "$f" ]; then
    log "subagent test-writer already present for $EXECUTOR_USER"
    return 0
  fi

  mkdir -p "$home/.claude/agents"
  cat > "$f" <<'EOF'
---
name: test-writer
description: Writes and runs tests for the current repo. Use for creating tests, running an existing suite, and the Red/Green steps of TDD. Returns the test diff and run output.
model: haiku
tools: Read, Write, Edit, Grep, Glob, Bash
---

You are the **test-writer** subagent. You own the test work delegated to you by the main agent. Keep it focused: write and run tests, report back.

## Tasks
1. Detect the test framework (vitest, jest, etc.) and package manager from `package.json` + lockfile. Don't assume pnpm.
2. Follow the existing test convention — read 2-3 existing tests for directory, naming and extension before writing.
3. TDD Red: write the failing test that reproduces the gap. Run it. Confirm it fails for the *right* reason (a real assertion, not an import/typo error).
4. When asked to run an existing suite, run it and report the result — pass or fail, plainly.
5. Return: the test file diff + the last ~20 lines of test output.

## Constraints
- NEVER modify production source (`src/`, `lib/`, etc.) — only test files (`tests/`, `__tests__/`, `*.test.*`, `*.spec.*`).
- Do NOT commit, push, or open PRs — the main agent owns git.
- Do NOT run `git push --force`.
- If you can't infer the project convention after reading existing tests, say so and stop instead of guessing.
EOF
  chown -R "$EXECUTOR_USER:$EXECUTOR_USER" "$home/.claude" 2>/dev/null || true
  log "installed test-writer subagent for $EXECUTOR_USER (haiku)"
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

  # 1b. credential-dir sanity. The executor MUST own its own $home/.claude so its
  #     OAuth token stays readable. A common manual hack symlinks it to (or shares
  #     it with) root's dir to "share one login" — but then root running `claude`
  #     rewrites .credentials.json as root:root and the executor loses read access
  #     ("Not logged in"). Refuse the symlink; auto-correct stray root ownership.
  if [ -L "$home/.claude" ]; then
    die "$home/.claude is a symlink ($(readlink "$home/.claude")) — remove it; the executor needs its own dir, else root overwrites its credentials and the agent shows 'Not logged in'"
  fi
  local creds="$home/.claude/.credentials.json"
  if [ -e "$creds" ] && [ "$(stat -c %U "$creds" 2>/dev/null)" != "$EXECUTOR_USER" ]; then
    warn "$creds not owned by $EXECUTOR_USER — fixing"
    chown "$EXECUTOR_USER:$EXECUTOR_USER" "$creds"; chmod 600 "$creds"
  fi

  # 1c. reconcile ~/.claude ownership. Earlier root-run containers (before the
  #     compose ran as the executor uid) left root-owned files here — transcripts
  #     under projects/, settings.json.bak, cloud-usage.json — which then block
  #     the executor (and the now-non-root container) with EACCES: agent runs
  #     fail and the Consumo tab reads no transcripts. Idempotent; safe to repeat.
  if [ -d "$home/.claude" ]; then
    chown -R "$EXECUTOR_USER:$EXECUTOR_USER" "$home/.claude" 2>/dev/null || true
  fi

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

  # 4b. caveman token-compression skill for all installed runtimes.
  install_caveman

  # 4c. RTK bash command compression for all installed runtimes.
  install_rtk

  # 4d. Canonical Claude Code subagents (test-writer) at user level.
  install_subagents

  # 5. guided login. Agent auth is OAuth/API-key (interactive) — it can't be
  # fully automated — so report per-runtime auth status and the exact login
  # command, and when run from a TTY offer to drop into each missing login now
  # (as the executor user). Piped installs (curl | bash) are non-interactive and
  # just print the commands.
  log "runtime login status (one-time per runtime):"
  local rt2 spec2 bin2 lspec2 lcmd2 ans
  IFS=',' read -ra _login_runtimes <<< "$RUNTIMES"
  for rt2 in "${_login_runtimes[@]}"; do
    rt2="$(echo "$rt2" | tr -d '[:space:]')"; [ -n "$rt2" ] || continue
    spec2="$(runtime_spec "$rt2")" || continue
    bin2="${spec2%%|*}"
    [ -x "/usr/local/bin/$bin2" ] || continue   # not installed; nothing to log in
    lspec2="$(runtime_login_spec "$rt2")" || { log "  $rt2: authenticated (no probe)"; continue; }
    lcmd2="${lspec2#*|}"
    if runtime_authed "$rt2" "$home"; then
      log "  $rt2: authenticated"
      continue
    fi
    warn "  $rt2: NOT authenticated — run as $EXECUTOR_USER: $lcmd2"
    if [ -t 0 ] && [ -t 1 ]; then
      printf '       log in to %s now? [y/N] ' "$rt2"
      ans=""; read -r ans </dev/tty 2>/dev/null || ans=""
      case "$ans" in
        y|Y) runuser -u "$EXECUTOR_USER" -- bash -lc "$lcmd2" || warn "  $rt2 login failed or cancelled" ;;
      esac
    fi
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host)         HOST="${2:-}"; shift 2 ;;
    --license)      LICENSE="${2:-}"; shift 2 ;;
    --image)        IMAGE="${2:-}"; shift 2 ;;
    --password)     PASSWORD="${2:-}"; shift 2 ;;
    --trust-proxy)  TRUST_PROXY="true"; shift ;;
    --tailscale)    TAILSCALE="true"; shift ;;
    --ts-authkey)   TS_AUTHKEY="${2:-}"; shift 2 ;;
    --no-bootstrap) BOOTSTRAP="false"; shift ;;
    --no-caveman)   CAVEMAN="false"; shift ;;
    --no-rtk)       RTK="false"; shift ;;
    --runtimes)     RUNTIMES="${2:-}"; shift 2 ;;
    --dir)          DIR="${2:-}"; shift 2 ;;
    --check)        CHECK_ONLY="true"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown argument: $1 (see --help)" ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl not found in PATH"

# ── host default: dash.<primary-ip>.nip.io. With --tailscale this resolves to
# the LAN IP, reached over the advertised subnet route (Traefik matches Host). ──
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
    || docker_status="$([ "$BOOTSTRAP" = true ] && echo "absent (would install latest stable)" || echo "absent — FAILS without bootstrap")"
  net_status="$(docker network inspect stack_web >/dev/null 2>&1 && echo present || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would create)" || echo "absent — FAILS without bootstrap")")"
  # git is the hard one: clone/worktree/preview run it on the host. node is for
  # agent-driven local dev tooling. Without bootstrap, missing git == clone/preview break.
  git_status="$(command -v git >/dev/null 2>&1 && echo "present ($(git --version 2>/dev/null | awk '{print $3}'))" || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would install)" || echo "absent — clone/preview FAIL")")"
  node_status="$(command -v node >/dev/null 2>&1 && echo "present ($(node -v 2>/dev/null))" || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would install $NODE_MAJOR.x)" || echo "absent — agent local dev tooling won't run")")"
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
  chk_home="$(getent passwd "$EXECUTOR_USER" 2>/dev/null | cut -d: -f6)"
  runtimes_status=""
  IFS=',' read -ra _chk_runtimes <<< "$RUNTIMES"
  for rt in "${_chk_runtimes[@]}"; do
    rt="$(echo "$rt" | tr -d '[:space:]')"; [ -n "$rt" ] || continue
    if spec="$(runtime_spec "$rt")"; then
      bin="${spec%%|*}"
      if [ -x "/usr/local/bin/$bin" ]; then
        # Installed: also report login state so --check shows what still needs auth.
        if [ -n "$chk_home" ] && runtime_authed "$rt" "$chk_home"; then
          st="present, authed"
        else
          st="present, NOT authed"
        fi
      else
        st="$([ "$BOOTSTRAP" = true ] && echo "would install" || echo "absent")"
      fi
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
  if [ "$TAILSCALE" = "true" ]; then
    if command -v tailscale >/dev/null 2>&1; then
      if tailscale status >/dev/null 2>&1; then
        tailscale status 2>/dev/null | grep -qi 'logged out' && ts_status="installed, logged out (would run 'up')" || ts_status="installed, up (would advertise route)"
      else
        ts_status="installed, daemon down (would start)"
      fi
    else
      ts_status="$([ "$BOOTSTRAP" = true ] && echo "absent (would install)" || echo "absent — FAILS without bootstrap")"
    fi
  fi
  log "check: host=$HOST, image=$IMAGE, auth=license-session, identity=${identity:-none}, bootstrap=$BOOTSTRAP"
  log "       docker=$docker_status, stack_web=$net_status, compose=$compose_status"
  log "       git=$git_status, node=$node_status"
  [ "$TAILSCALE" = "true" ] && log "       tailscale=$ts_status (subnet router + Traefik; approve route in admin console)"
  ws_status="$([ -d "$WORKSPACE_DIR" ] && echo "owner=$(stat -c '%U' "$WORKSPACE_DIR" 2>/dev/null || echo '?')" || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would create)" || echo "absent — clone fails")")"
  log "       executor($EXECUTOR_USER)=$exec_user_status, sshd=$sshd_status, workspace=$ws_status"
  log "       runtimes: $runtimes_status"
  exit 0
fi

# ── host OS guard: bootstrap provisions a Linux host executor (dedicated user
# via useradd, sshd over host-gateway, runtimes symlinked onto /usr/local/bin).
# That path is Linux-specific. --no-bootstrap is OS-agnostic (just docker compose
# up against a pre-provisioned executor), so only block bootstrap on non-Linux. ──
OS="$(uname -s 2>/dev/null || echo unknown)"
if [ "$BOOTSTRAP" = "true" ] && [ "$OS" != "Linux" ]; then
  case "$OS" in
    Darwin) die "host provisioning (bootstrap) is Linux-only — the executor model uses useradd, sshd and /usr/local/bin symlinks. On macOS: pre-provision the '$EXECUTOR_USER' user (authorized_keys + runtimes on PATH) and re-run with --no-bootstrap, or run the dashboard on a Linux VM." ;;
    *)      die "unsupported host OS '$OS' for bootstrap. On Windows, run inside WSL2 (Ubuntu) — Docker Desktop's WSL2 backend is the Linux host the dashboard SSHes into. Native Windows is not supported; pre-provision and use --no-bootstrap on other Unix hosts." ;;
  esac
fi

# ── root preflight: stop a bootstrap-as-non-root invocation BEFORE side effects ──
require_root_for_bootstrap

# ── bootstrap: Docker, host tooling (git/node), then the shared stack ──
ensure_docker
ensure_host_tooling
ensure_stack

# ── Tailscale: install + make this host a subnet router for its LAN ──
ensure_tailscale

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

# The container runs as the executor uid (compose `user:`), so the data dir it
# writes to (SQLite, license.key, session.key, ssh key) must be owned by that
# user — otherwise the non-root process can't open its own database.
chown -R "$EXECUTOR_USER:$EXECUTOR_USER" "$DIR/data"

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
  # Run the container as the executor uid (compose `user:` reads these). Keeps
  # files the dashboard writes into the shared /claude and /data binds owned by
  # claude-bots, so the executor that runs the agent CLI over SSH can read/write
  # them — cap_drop:ALL removes CAP_CHOWN, so the container can't fix ownership
  # at runtime. DOCKER_GID lets the non-root uid reach /var/run/docker.sock
  # (root:docker on the host); omitted when the host has no docker group.
  echo "EXECUTOR_UID=$(id -u "$EXECUTOR_USER")"
  echo "EXECUTOR_GID=$(id -g "$EXECUTOR_USER")"
  _docker_gid="$(getent group docker | cut -d: -f3)"
  [ -n "$_docker_gid" ] && echo "DOCKER_GID=$_docker_gid"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
log "wrote $ENV_FILE (mode 600)"

# ── pull + up ──
log "pulling $IMAGE"
docker pull "$IMAGE"
log "starting dashboard"
( cd "$DIR" && docker compose -f compose.prod.yml up -d )

# Post-up routing probe. A bare "up" can succeed while no request ever reaches
# the container: Traefik may have registered no routers (engine/API mismatch),
# or the host iptables for stack_web get desynced (common on WSL2 after a daemon
# restart) so FORWARD drops container traffic and requests hang. Probe
# end-to-end through Traefik, with a bounded timeout so a hang does not stall us
# ~20s per attempt, and fail loud instead of printing a misleading "done".
probe_ok=false
log "probing http://$HOST/api/health through Traefik"
for _i in $(seq 1 15); do
  if curl -fsS --max-time 3 "http://$HOST/api/health" >/dev/null 2>&1; then
    probe_ok=true
    break
  fi
  sleep 2
done

if [ "$probe_ok" = true ]; then
  log "done. dashboard reachable at http://$HOST  (health: /api/health)"
else
  warn "dashboard containers are up, but http://$HOST/api/health never answered."
  warn "the stack started, yet traffic is not reaching it — almost always host networking:"
  warn "  • stack_web iptables desynced (common on WSL2) — reprogram every network with:"
  warn "      sudo systemctl restart docker"
  warn "  • or recreate just this network:"
  warn "      docker compose -p stack -f $DIR/stack.compose.yml down && docker network rm stack_web && docker compose -p stack -f $DIR/stack.compose.yml up -d"
  warn "then re-check: curl -fsS http://$HOST/api/health"
fi

# ── Tailscale subnet route reminder. The node advertises its LAN; the route
# must be APPROVED once in the admin console before remote devices reach it. ──
if [ "$TAILSCALE" = "true" ]; then
  log "Tailscale: this host advertises its LAN as a subnet route."
  log "  Approve it: https://login.tailscale.com/admin/machines → this host → Edit route settings"
  log "  Then reach the dashboard from any tailnet device at http://$HOST"
fi

if [ -n "$LICENSE" ]; then
  log "open the dashboard and log in with your license key"
else
  log "open the dashboard; the first-run screen will ask for your license key"
fi
log "to run agents: dashboard → Claude section → login (one-time claude /login OAuth)"
