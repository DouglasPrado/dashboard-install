#!/usr/bin/env bash
#
# Dashboard installer — macOS-native (distribution mode, published Docker image).
#
# This is the macOS twin of install.sh: identical steps, macOS commands. Where
# the Linux installer provisions a dedicated `claude-bots` executor user, on
# macOS the host executor is the ADMIN USER you sudo from (the Docker Desktop
# owner) — a dedicated user cannot reach Docker Desktop's per-user socket, so the
# dashboard's host-side `docker compose` (update-live / branch-switch restart)
# would break. So bootstrap here provisions THAT account: authorizes the
# dashboard SSH key, enables Remote Login (sshd), creates the host workspace, and
# installs the agent runtime CLIs — and uses Homebrew for Docker Desktop / git /
# Node (Homebrew refuses to run as root, so every brew call drops to the admin
# user). A fresh Mac goes from zero to running agents in one `sudo` command. A
# one-time `claude /login` (via the UI) is still needed before agents can run.
#
# Platform: macOS only (Darwin). For Linux use ./install.sh. Docker runtime:
# Docker Desktop (its /var/run/docker.sock symlink and native
# host.docker.internal are what the container needs).
#
# Usage:
#   sudo ./install-macos.sh --host dash.example.com --license <key> [options]
#   curl -sSL .../install.sh | bash      # install.sh dispatches here on Darwin
#
# Options: identical to install.sh — run with -h for the list.
#
set -euo pipefail

IMAGE_DEFAULT="ghcr.io/douglasprado/dashboard-install:latest"
NODE_MAJOR="22"   # match the node:22-alpine the preview/auto-setup containers build from (see dashboard auto-setup.ts)
# Host executor: the ADMIN user you sudo from owns Docker Desktop's socket, so it
# (not a dedicated claude-bots) must be the account the dashboard SSHes into.
EXECUTOR_USER="${SUDO_USER:-$(id -un)}"
EXECUTOR_GROUP="$(id -gn "$EXECUTOR_USER" 2>/dev/null || echo staff)"   # macOS primary group is `staff`, not a per-user group
WORKSPACE_DIR="/root/workspace"   # where the image clones projects (hardcoded host path in clone-project.ts)

# Agent runtime CLIs the dashboard can drive (see server/runtime-adapter/registry.ts).
CLAUDE_INSTALL_URL="https://claude.ai/install.sh"
OPENCODE_INSTALL_URL="https://opencode.ai/install"
CODEX_INSTALL_URL="https://chatgpt.com/codex/install.sh"
CURSOR_INSTALL_URL="https://cursor.com/install"
RUNTIMES_DEFAULT="claude-code,opencode,codex"
CAVEMAN_INSTALL_URL="https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh"
RTK_INSTALL_URL="https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh"

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

# Best-effort primary-IP probe. macOS has no `ip` (iproute2): resolve the
# default-route interface with `route -n get`, then its address with `ipconfig
# getifaddr`. Like the Linux twin, this is assigned under `set -e`, so it MUST
# end 0 (emit empty on no match) or it aborts the installer silently before the
# platform guard prints — the "curl | bash does nothing on macOS" footgun.
detect_ip() {
  local iface
  iface="$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}' | head -1)"
  [ -n "$iface" ] && ipconfig getifaddr "$iface" 2>/dev/null | head -1 || true
}

# Resolve a user's home dir. macOS has no getent/NSS; query the directory
# service. Prints the path (empty + non-zero when the user is unknown).
user_home() { # <user>
  dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
}

# Validate --host before it lands in the Traefik label rule (same charset gate as
# the Linux twin).
valid_host() { # <host>
  case "$1" in
    ""|*[!a-zA-Z0-9.-]*) return 1 ;;
    *) return 0 ;;
  esac
}

image_is_pinned() { # <image-ref>
  case "$1" in
    *@sha256:*) return 0 ;;
    *)          return 1 ;;
  esac
}

pin_to_digest() { # <image-ref> <sha256:digest>
  local repo="${1%@*}"
  case "${repo##*/}" in
    *:*) repo="${repo%:*}" ;;
  esac
  printf '%s@%s' "$repo" "$2"
}

# Write the license token as a secret: mode 600, owned by the executor (the
# container reads it as that uid over the /data bind). chown to the user only —
# macOS has no per-user group, and 600 already keeps it executor-private.
write_license() { # <token> <dest> <owner>
  ( umask 077; printf '%s\n' "$1" > "$2" )
  chmod 600 "$2"
  chown "$3" "$2" 2>/dev/null || true
}

# True when something is listening on TCP :22 (the executor SSH endpoint the
# dashboard reaches over host.docker.internal). macOS lacks `ss` and GNU
# `netstat -ltn`; probe with lsof.
sshd_listening() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:22 -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

# ── Homebrew: the macOS package manager for Docker Desktop / git / Node. It
# REFUSES to run as root, so every call drops to the admin user via sudo. Resolve
# the brew binary by its known prefixes (Apple Silicon /opt/homebrew, Intel
# /usr/local) — a non-login `sudo -u ... bash -lc` may not source the zsh
# .zprofile that puts brew on PATH. ──
brew_bin() {
  local p
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
have_brew() { brew_bin >/dev/null 2>&1; }
run_brew() { # brew args...
  local b; b="$(brew_bin)" || return 1
  sudo -H -u "$EXECUTOR_USER" "$b" "$@"
}

BOOTSTRAP_BASE="${BOOTSTRAP_BASE:-https://raw.githubusercontent.com/DouglasPrado/dashboard-install/main}"

usage() { sed -n '2,/^set -euo/{/^set -euo/!p}' "$0" | sed 's/^# \{0,1\}//'; }

fetch() { # <relpath> <dest>
  [ -f "$2" ] && return 0
  curl -fsSL "$BOOTSTRAP_BASE/$1" -o "$2" || die "failed to fetch $1 from $BOOTSTRAP_BASE"
}

# Preflight: bootstrap mutates root-owned state (Remote Login, /root, /usr/local/
# bin symlinks). It needs root (sudo) — but Homebrew must NOT run as root, and
# the account we sudo from is also the dashboard executor, so SUDO_USER must
# point at a real admin. Fail fast with the exact escape hatch.
require_root_for_bootstrap() {
  [ "$BOOTSTRAP" = "true" ] || return 0
  [ "$(id -u)" -eq 0 ] || die "bootstrap requires root — re-run from your admin account: sudo ./install-macos.sh ..., or pass --no-bootstrap to skip Docker/Remote-Login/executor setup (then '$EXECUTOR_USER' must already have the dashboard key in authorized_keys, sshd on :22, and the runtime CLIs on PATH)"
  { [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; } || die "run via 'sudo' FROM your admin account (the Docker Desktop user) — SUDO_USER must name a non-root admin: Homebrew refuses to run as root and that account becomes the dashboard executor. Don't run as the root user directly."
}

# Install the compose v2 plugin when the docker CLI is present but `docker compose`
# is not. Docker Desktop bundles the plugin, but a Homebrew-formula docker CLI (or
# a Colima/lima engine) ships only the bare CLI. Symlink it into the system plugin
# dir so BOTH this root bootstrap and the executor's SSH sessions discover it.
ensure_compose_plugin() {
  have_brew || die "docker compose v2 plugin missing and Homebrew unavailable — install Docker Desktop (bundles compose) or run 'brew install docker-compose', then re-run"
  log "docker compose v2 plugin missing — installing docker-compose (brew, as $EXECUTOR_USER)"
  run_brew install docker-compose || die "docker-compose install failed — install it manually: brew install docker-compose"

  local cbin
  cbin="$(run_brew --prefix docker-compose 2>/dev/null)/bin/docker-compose"
  [ -x "$cbin" ] || cbin="$(sudo -H -u "$EXECUTOR_USER" bash -lc 'command -v docker-compose' 2>/dev/null)"
  [ -n "$cbin" ] && [ -x "$cbin" ] || die "docker-compose installed but its binary was not found — symlink it into /usr/local/lib/docker/cli-plugins/docker-compose manually"
  mkdir -p /usr/local/lib/docker/cli-plugins
  ln -sf "$cbin" /usr/local/lib/docker/cli-plugins/docker-compose
}

# Install Docker Desktop if missing and wait for the engine. Docker Desktop needs
# a one-time GUI launch to create the socket and accept its terms; bootstrap can
# install + open it, but the operator may still have to click through first run.
ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "docker engine reachable ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo running))"
    return 0
  fi
  [ "$BOOTSTRAP" = "true" ] || die "docker not reachable — start Docker Desktop (open -a Docker) or install it (run without --no-bootstrap)"

  # Only install + open Desktop if the docker CLI is absent. A CLI that is already
  # present (brew formula, Colima) may just have its engine down or lack the compose
  # plugin — don't shell out to a Docker.app that isn't there.
  if ! command -v docker >/dev/null 2>&1; then
    have_brew || die "Homebrew is required to install Docker Desktop — install it first from https://brew.sh, then re-run"
    log "installing Docker Desktop (brew cask, as $EXECUTOR_USER)"
    run_brew install --cask docker || die "Docker Desktop install failed — install it manually from https://www.docker.com/products/docker-desktop"
    log "starting Docker Desktop (first launch may prompt you to accept the terms)"
    open -a Docker >/dev/null 2>&1 || true
  elif ! docker info >/dev/null 2>&1; then
    log "docker CLI present but engine unreachable — attempting to start Docker Desktop"
    open -a Docker >/dev/null 2>&1 || true
  fi

  local i
  for i in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done
  docker info >/dev/null 2>&1 || die "Docker engine did not become ready — start your runtime (Docker Desktop: open -a Docker, accept the terms; Colima: colima start) and wait for it, then re-run"

  # Desktop bundles compose v2; a brew-formula CLI or Colima does not. Install it
  # rather than dying with a misleading "update Docker Desktop".
  docker compose version >/dev/null 2>&1 || ensure_compose_plugin
  docker compose version >/dev/null 2>&1 || die "docker compose v2 still unavailable after install — symlink the plugin into /usr/local/lib/docker/cli-plugins/docker-compose manually, then re-run"
}

# Install the host-side tools the dashboard runs AS THE EXECUTOR over SSH: git
# (clone-project.ts / git-worktree.ts run on the host) and Node.js (agents run a
# project's dev tooling against a host worktree). Homebrew, gated by bootstrap.
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
  fi
  if ! have_brew; then
    warn "Homebrew unavailable — install${need_git:+ git}${need_node:+ node} on the host PATH manually (clone/preview need git). Get Homebrew at https://brew.sh"
    return 0
  fi

  if [ -n "$need_git" ]; then
    log "installing git (clone/worktree/preview run it on the host)"
    run_brew install git || warn "failed to install git — clone and live preview need it; install git on the host"
  fi

  if [ -n "$need_node" ]; then
    log "installing Node.js $NODE_MAJOR.x (matches the node:$NODE_MAJOR containers the preview builds)"
    if ! run_brew install "node@$NODE_MAJOR"; then
      run_brew install node || warn "failed to install Node.js — install it on the host PATH so agents can run project dev tooling"
    fi
    # node@$NODE_MAJOR is keg-only; force-link it onto the brew prefix PATH.
    run_brew link --overwrite --force "node@$NODE_MAJOR" >/dev/null 2>&1 || true
    # corepack ships with Node >=16 and provisions pnpm/yarn on demand.
    sudo -H -u "$EXECUTOR_USER" bash -lc 'command -v corepack >/dev/null 2>&1 && corepack enable >/dev/null 2>&1' || true
  fi

  # Symlink onto /usr/local/bin: a non-interactive `ssh user@host '<cmd>'` on
  # macOS does not get the brew prefix on PATH, but /usr/local/bin is on the
  # default PATH. Mirrors how the runtimes are exposed below.
  mkdir -p /usr/local/bin
  local b
  for b in git node npm npx corepack; do
    local src; src="$(sudo -H -u "$EXECUTOR_USER" bash -lc "command -v $b" 2>/dev/null || true)"
    [ -n "$src" ] && [ -x "$src" ] && [ "$src" != "/usr/local/bin/$b" ] && ln -sf "$src" "/usr/local/bin/$b"
  done

  command -v git  >/dev/null 2>&1 && log "git ready ($(git --version 2>/dev/null))"
  command -v node >/dev/null 2>&1 && log "node ready ($(node --version 2>/dev/null))"
}

# Create the stack_web network + minimal Traefik if absent. OS-agnostic (docker
# compose), identical to the Linux twin.
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

# Install Tailscale and bring the node up. macOS: the open-source CLI/daemon via
# Homebrew + `tailscaled install-system-daemon` (no systemd). Same routing model
# as the Linux twin (serve at dash.<ts-ip>.nip.io via Traefik; Funnel OFF).
ensure_tailscale() {
  [ "$TAILSCALE" = "true" ] || return 0

  if ! command -v tailscale >/dev/null 2>&1; then
    [ "$BOOTSTRAP" = "true" ] || die "tailscale missing (run without --no-bootstrap to install it, or install Tailscale first)"
    have_brew || die "Homebrew is required to install Tailscale — install it from https://brew.sh"
    log "installing Tailscale (brew)"
    run_brew install tailscale || die "tailscale install failed"
    # Expose the brew-installed binary on the default PATH.
    local tsbin; tsbin="$(sudo -H -u "$EXECUTOR_USER" bash -lc 'command -v tailscale' 2>/dev/null || true)"
    [ -n "$tsbin" ] && { mkdir -p /usr/local/bin; ln -sf "$tsbin" /usr/local/bin/tailscale; }
  fi

  # tailscaled must be running; install it as a system daemon (idempotent).
  if ! tailscale status >/dev/null 2>&1; then
    tailscaled install-system-daemon >/dev/null 2>&1 || sudo tailscaled install-system-daemon >/dev/null 2>&1 || true
    if ! tailscale status >/dev/null 2>&1; then
      warn "tailscaled may not be running — start it once: sudo tailscaled install-system-daemon"
    fi
  fi

  if tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -qi 'logged out'; then
    log "tailscale already up"
  elif [ -n "$TS_AUTHKEY" ]; then
    log "tailscale up (auth key)"
    tailscale up --authkey "$TS_AUTHKEY" || die "tailscale up failed — check the auth key"
  elif [ -t 0 ] && [ -t 1 ]; then
    log "tailscale up — authenticate in the browser when the login URL is printed"
    tailscale up || die "tailscale up failed or was cancelled"
  else
    die "tailscale is not logged in and no --ts-authkey was given (non-interactive run). Mint a key at https://login.tailscale.com/admin/settings/keys and re-run with --ts-authkey <key>, or run 'sudo tailscale up' first."
  fi
}

# Map a runtime id to "<binary> <install-command>". Keep ids in sync with
# server/runtime-adapter/registry.ts.
runtime_spec() { # <runtime-id>
  case "$1" in
    claude-code) echo "claude|curl -fsSL $CLAUDE_INSTALL_URL | bash" ;;
    opencode)    echo "opencode|curl -fsSL $OPENCODE_INSTALL_URL | bash" ;;
    codex)       echo "codex|curl -fsSL $CODEX_INSTALL_URL | sh" ;;
    cursor)      echo "cursor-agent|curl -fsS $CURSOR_INSTALL_URL | bash" ;;
    *)           return 1 ;;
  esac
}

runtime_login_spec() { # <runtime-id>
  case "$1" in
    claude-code) echo ".claude/.credentials.json|claude /login" ;;
    opencode)    echo ".local/share/opencode/auth.json|opencode auth login" ;;
    codex)       echo ".codex/auth.json|codex login" ;;
    cursor)      echo "|cursor-agent login" ;;
    *)           return 1 ;;
  esac
}

runtime_authed() { # <runtime-id> <home>
  local lspec probe
  lspec="$(runtime_login_spec "$1")" || return 1
  probe="${lspec%%|*}"
  [ -n "$probe" ] && [ -f "$2/$probe" ]
}

# Resolve where an installer dropped a binary for the executor. The native
# installers add it to ~/.local/bin (and runtime dirs), none of which a
# non-interactive ssh session reads — so resolve it and symlink onto
# /usr/local/bin. Try the login shell's PATH first, then known dirs.
resolve_runtime_bin() { # <binary> <home>
  local bin="$1" home="$2" p cand
  p="$(sudo -H -u "$EXECUTOR_USER" bash -lc "command -v $bin" 2>/dev/null)" || true
  if [ -n "$p" ] && [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
  for p in \
    "$home/.local/bin/$bin" \
    "$home/.opencode/bin/$bin" \
    "$home/.codex/bin/$bin" \
    "$home/.codex/packages/standalone/current/bin/$bin" \
    "$home/.cursor/bin/$bin" \
    "$home/bin/$bin"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  p=""
  for cand in "$home"/.local/share/cursor-agent/versions/*/"$bin"; do
    [ -x "$cand" ] && p="$cand"
  done
  if [ -n "$p" ] && [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
  return 1
}

# Install one runtime CLI for the executor and symlink it onto /usr/local/bin.
# Idempotent; non-fatal. `sudo -H -u` sets the executor's HOME (unlike Linux's
# runuser which keeps the caller's), so the cwd/HOME pin is just belt-and-braces.
install_runtime() { # <runtime-id>
  local id="$1" spec bin cmd src
  spec="$(runtime_spec "$id")" || { warn "unknown runtime '$id' — skipping (known: claude-code, opencode, codex, cursor)"; return 0; }
  bin="${spec%%|*}"; cmd="${spec#*|}"

  if [ -x "/usr/local/bin/$bin" ]; then
    log "runtime $id present ($bin)"
    return 0
  fi

  log "installing runtime $id ($bin) for $EXECUTOR_USER"
  local home; home="$(user_home "$EXECUTOR_USER")"
  if ! sudo -H -u "$EXECUTOR_USER" bash -lc "export HOME='$home'; cd '$home' || exit 1; set -o pipefail; $cmd"; then
    warn "runtime $id install failed — install '$bin' manually for $EXECUTOR_USER and symlink to /usr/local/bin/$bin"
    return 0
  fi

  mkdir -p /usr/local/bin
  if src="$(resolve_runtime_bin "$bin" "$home")"; then
    ln -sf "$src" "/usr/local/bin/$bin"
    log "runtime $id ready: $bin -> $src"
  else
    warn "runtime $id installed but '$bin' not found on PATH or known dirs — add it to /usr/local/bin manually"
  fi
}

# Install caveman (token-compression skill) for the executor. Idempotent.
install_caveman() {
  [ "$CAVEMAN" = "true" ] || return 0
  [ "$BOOTSTRAP" = "true" ] || return 0

  local home; home="$(user_home "$EXECUTOR_USER")"
  local settings="$home/.claude/settings.json"
  if [ -f "$settings" ] && grep -q '"caveman' "$settings" 2>/dev/null; then
    log "caveman already installed for $EXECUTOR_USER"
    return 0
  fi

  log "installing caveman for $EXECUTOR_USER (token compression skill)"
  if ! sudo -H -u "$EXECUTOR_USER" bash -lc "
    export HOME='$home'; cd '$home' || exit 1
    command -v node >/dev/null 2>&1 || { echo 'node required for caveman'; exit 1; }
    export NPM_CONFIG_PREFIX='$home/.npm-global'
    export npm_config_prefix='$home/.npm-global'
    mkdir -p '$home/.npm-global/bin'
    export PATH=\"\$PATH:$home/.npm-global/bin\"
    curl -fsSL $CAVEMAN_INSTALL_URL | bash -s -- --non-interactive --with-hooks --config-dir '$home/.claude'
  "; then
    warn "caveman install failed — agents will work without token compression"
    return 0
  fi

  sudo -H -u "$EXECUTOR_USER" bash -lc "
    export HOME='$home'; cd '$home' || exit 1
    command -v claude >/dev/null 2>&1 || exit 0
    claude mcp remove caveman-shrink >/dev/null 2>&1 || true
    claude mcp add caveman-shrink --scope user -- npx -y caveman-shrink >/dev/null 2>&1 || true
  " || true

  log "caveman ready: agents will use compressed token mode by default"
}

# Install RTK (bash command compression) for the executor. Idempotent.
install_rtk() {
  [ "$RTK" = "true" ] || return 0
  [ "$BOOTSTRAP" = "true" ] || return 0

  local home; home="$(user_home "$EXECUTOR_USER")"
  if [ -x "$home/.local/bin/rtk" ]; then
    log "rtk already installed for $EXECUTOR_USER"
    return 0
  fi

  log "installing RTK for $EXECUTOR_USER (bash command token compression)"
  if ! sudo -H -u "$EXECUTOR_USER" bash -lc "
    export HOME='$home'; cd '$home' || exit 1
    curl -fsSL $RTK_INSTALL_URL | sh
    [ -x ~/.local/bin/rtk ] || { echo 'rtk binary not found'; exit 1; }
    ~/.local/bin/rtk init -g --auto-patch
  "; then
    warn "RTK install failed — agents will work without bash compression"
    return 0
  fi

  if [ -x "$home/.local/bin/rtk" ]; then
    mkdir -p /usr/local/bin
    ln -sf "$home/.local/bin/rtk" "/usr/local/bin/rtk"
    log "rtk ready: bash commands compressed via rtk hook"
  fi
}

# Install the canonical Claude Code subagents (test-writer) at user level for the
# executor. Idempotent: skips when it already exists.
install_subagents() {
  [ "$BOOTSTRAP" = "true" ] || return 0

  local home; home="$(user_home "$EXECUTOR_USER")"
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
2. Ensure deps are installed before running anything: if `node_modules` is missing (common in fresh worktrees) or the first run fails with module-not-found, run the detected package manager's install once (`pnpm install` / `npm ci` / `yarn`), then proceed. A missing-dependency error is NOT a legitimate Red.
3. Follow the existing test convention — read 2-3 existing tests for directory, naming and extension before writing.
4. TDD Red: write the failing test that reproduces the gap. Run it. Confirm it fails for the *right* reason (a real assertion, not an import/typo error).
5. When asked to run an existing suite, run it and report the result — pass or fail, plainly.
6. Return: the test file diff + the last ~20 lines of test output.

## Constraints
- NEVER modify production source (`src/`, `lib/`, etc.) — only test files (`tests/`, `__tests__/`, `*.test.*`, `*.spec.*`).
- Do NOT commit, push, or open PRs — the main agent owns git.
- Do NOT run `git push --force`.
- If you can't infer the project convention after reading existing tests, say so and stop instead of guessing.
EOF
  chown -R "$EXECUTOR_USER:$EXECUTOR_GROUP" "$home/.claude/agents" 2>/dev/null || true
  log "installed test-writer subagent for $EXECUTOR_USER (haiku)"
}

# Provision the host-side agent executor: the ADMIN user the dashboard SSHes into
# (host.docker.internal) to run the agent runtime CLIs. Unlike the Linux twin we
# DON'T create a user — the admin who owns Docker Desktop's socket must be the
# executor (a dedicated user can't reach that per-user socket). Idempotent; gated
# by bootstrap. Requires $SSH_KEY.pub to exist (key gen runs first).
ensure_executor() {
  if [ "$BOOTSTRAP" != "true" ]; then
    warn "skipping executor setup (--no-bootstrap); ensure user '$EXECUTOR_USER' has the dashboard key in authorized_keys, sshd on :22, and 'claude' on PATH"
    return 0
  fi

  # 1. the executor is an existing account (the admin you sudo from).
  id "$EXECUTOR_USER" >/dev/null 2>&1 || die "executor user '$EXECUTOR_USER' does not exist — run via sudo from your admin account so SUDO_USER names it"
  local home; home="$(user_home "$EXECUTOR_USER")"
  [ -n "$home" ] && [ -d "$home" ] || die "could not resolve home dir for $EXECUTOR_USER"

  # 1b. credential-dir sanity: refuse a symlinked ~/.claude (a shared-login hack
  #     where root rewrites the executor's credentials), auto-correct stray root
  #     ownership of the token.
  if [ -L "$home/.claude" ]; then
    die "$home/.claude is a symlink ($(readlink "$home/.claude")) — remove it; the executor needs its own dir, else root overwrites its credentials and the agent shows 'Not logged in'"
  fi
  local creds="$home/.claude/.credentials.json"
  if [ -e "$creds" ] && [ "$(stat -f %Su "$creds" 2>/dev/null)" != "$EXECUTOR_USER" ]; then
    warn "$creds not owned by $EXECUTOR_USER — fixing"
    chown "$EXECUTOR_USER:$EXECUTOR_GROUP" "$creds"; chmod 600 "$creds"
  fi

  # 1c. reconcile ~/.claude ownership: earlier root-run containers can leave
  #     root-owned files here that block the executor with EACCES. Idempotent.
  if [ -d "$home/.claude" ]; then
    chown -R "$EXECUTOR_USER:$EXECUTOR_GROUP" "$home/.claude" 2>/dev/null || true
  fi

  # 1d. NO host docker group: on macOS with Docker Desktop, /var/run/docker.sock
  #     is owned by the GUI user (this admin), not a `docker` group — which is
  #     exactly why the executor is this admin and not a dedicated claude-bots.
  #     Host-side `docker compose` (update-live / branch-switch restart) already
  #     reaches the socket as this user. Nothing to grant.

  # 2. authorize the dashboard's generated key. Prune prior dashboard-tagged keys
  #    first, then append the current one once.
  install -d -m 700 -o "$EXECUTOR_USER" -g "$EXECUTOR_GROUP" "$home/.ssh"
  local ak="$home/.ssh/authorized_keys" pub
  pub="$(cat "$SSH_KEY.pub")"
  if [ -f "$ak" ] && grep -q ' dashboard@' "$ak"; then
    grep -v ' dashboard@' "$ak" > "$ak.tmp" || true
    mv "$ak.tmp" "$ak"
  fi
  if [ ! -f "$ak" ] || ! grep -qF "$pub" "$ak"; then
    printf '%s\n' "$pub" >> "$ak"
    log "authorized dashboard key for $EXECUTOR_USER"
  fi
  chown "$EXECUTOR_USER:$EXECUTOR_GROUP" "$ak"; chmod 600 "$ak"

  # 2b. workspace: the image clones projects into $WORKSPACE_DIR (a host path
  #     hardcoded in the image: /root/workspace) but runs git as the executor
  #     over SSH. macOS has no /root, so create it, hand the workspace to the
  #     executor, and grant traverse (x) on /root without exposing a listing.
  mkdir -p "$WORKSPACE_DIR"
  chown "$EXECUTOR_USER:$EXECUTOR_GROUP" "$WORKSPACE_DIR"
  chmod 711 /root   # o+x: executor can traverse into /root/workspace, can't list /root
  log "workspace $WORKSPACE_DIR owned by $EXECUTOR_USER (executor can clone)"

  # 3. sshd: macOS ships sshd; enable Remote Login so the container can SSH back
  #    over host.docker.internal. systemsetup may require Full Disk Access in
  #    recent macOS; fall back to loading the launchd job directly.
  if ! sshd_listening; then
    log "enabling Remote Login (sshd) on the host"
    systemsetup -setremotelogin on >/dev/null 2>&1 \
      || launchctl load -w /System/Library/LaunchDaemons/ssh.plist >/dev/null 2>&1 \
      || true
  fi
  if sshd_listening; then
    log "sshd listening on :22 (executor reachable)"
  else
    warn "sshd is NOT listening on :22 — enable it in System Settings → General → Sharing → Remote Login (systemsetup needs Full Disk Access for your terminal); otherwise the dashboard's SSH to host.docker.internal is refused and clone/agents won't run"
  fi

  # 4. agent runtime CLIs on a PATH the non-interactive ssh session sees.
  local rt
  IFS=',' read -ra _runtimes <<< "$RUNTIMES"
  for rt in "${_runtimes[@]}"; do
    rt="$(echo "$rt" | tr -d '[:space:]')"
    [ -n "$rt" ] && install_runtime "$rt"
  done

  if [ -x /usr/local/bin/claude ]; then
    log "executor ready: $EXECUTOR_USER + claude ($(/usr/local/bin/claude --version 2>/dev/null || echo 'version unknown'))"
  fi

  # 4b/c/d. caveman, RTK, canonical subagents.
  install_caveman
  install_rtk
  install_subagents

  # 5. guided login (interactive OAuth/API-key per runtime).
  log "runtime login status (one-time per runtime):"
  local rt2 spec2 bin2 lspec2 lcmd2 ans
  IFS=',' read -ra _login_runtimes <<< "$RUNTIMES"
  for rt2 in "${_login_runtimes[@]}"; do
    rt2="$(echo "$rt2" | tr -d '[:space:]')"; [ -n "$rt2" ] || continue
    spec2="$(runtime_spec "$rt2")" || continue
    bin2="${spec2%%|*}"
    [ -x "/usr/local/bin/$bin2" ] || continue
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
        y|Y) sudo -H -u "$EXECUTOR_USER" bash -lc "$lcmd2" || warn "  $rt2 login failed or cancelled" ;;
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

# ── host default: dash.<primary-ip>.nip.io. With --tailscale resolve later. ──
if [ -z "$HOST" ] && [ "$TAILSCALE" != "true" ]; then
  ip="$(detect_ip)"
  if [ -z "$ip" ]; then
    ip="127.0.0.1"
    warn "could not detect a primary IP; defaulting host to 127.0.0.1 — the dashboard will be reachable only on this host. Pass --host <name> for a reachable address."
  fi
  HOST="dash.${ip}.nip.io"
  log "no --host given; defaulting to $HOST"
fi

if [ -n "$HOST" ] && ! valid_host "$HOST"; then
  die "invalid --host '$HOST' — use a DNS name (letters, digits, dots, hyphens); it becomes a Traefik Host() rule"
fi

if [ -z "$LICENSE" ]; then
  warn "no --license given; the dashboard will start at the first-run activation screen, where a valid license key is required to log in"
fi

COMPOSE_FILE="$DIR/compose.prod.yml"
COMPOSE_URL="$BOOTSTRAP_BASE/compose.prod.yml"

if [ -n "$LICENSE" ] && [ -f "$LICENSE" ]; then
  LICENSE="$(tr -d '\n' < "$LICENSE")"
fi

if [ "$CHECK_ONLY" = "true" ]; then
  docker_status="present"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker info >/dev/null 2>&1 && docker_status="present, engine running" || docker_status="installed, engine NOT running (open -a Docker)"
  else
    docker_status="$([ "$BOOTSTRAP" = true ] && echo "absent (would install Docker Desktop)" || echo "absent — FAILS without bootstrap")"
  fi
  net_status="$(docker network inspect stack_web >/dev/null 2>&1 && echo present || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would create)" || echo "absent — FAILS without bootstrap")")"
  git_status="$(command -v git >/dev/null 2>&1 && echo "present ($(git --version 2>/dev/null | awk '{print $3}'))" || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would install)" || echo "absent — clone/preview FAIL")")"
  node_status="$(command -v node >/dev/null 2>&1 && echo "present ($(node -v 2>/dev/null))" || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would install $NODE_MAJOR.x)" || echo "absent — agent local dev tooling won't run")")"
  brew_status="$(have_brew && echo "present ($(brew_bin))" || echo "absent — needed to install Docker/git/node; get it at https://brew.sh")"
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
  exec_user_status="$(id "$EXECUTOR_USER" >/dev/null 2>&1 && echo "present ($EXECUTOR_USER)" || echo "MISSING — run via sudo from your admin account")"
  chk_home="$(user_home "$EXECUTOR_USER")"
  runtimes_status=""
  IFS=',' read -ra _chk_runtimes <<< "$RUNTIMES"
  for rt in "${_chk_runtimes[@]}"; do
    rt="$(echo "$rt" | tr -d '[:space:]')"; [ -n "$rt" ] || continue
    if spec="$(runtime_spec "$rt")"; then
      bin="${spec%%|*}"
      if [ -x "/usr/local/bin/$bin" ]; then
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
  else
    sshd_status="$([ "$BOOTSTRAP" = true ] && echo "not listening (would enable Remote Login)" || echo "NOT listening — clone/agents refused")"
  fi
  if [ "$TAILSCALE" = "true" ]; then
    if command -v tailscale >/dev/null 2>&1; then
      if tailscale status >/dev/null 2>&1; then
        tailscale status 2>/dev/null | grep -qi 'logged out' && ts_status="installed, logged out (would run 'up')" || ts_status="installed, up (would route via Traefik)"
      else
        ts_status="installed, daemon down (would start)"
      fi
    else
      ts_status="$([ "$BOOTSTRAP" = true ] && echo "absent (would install)" || echo "absent — FAILS without bootstrap")"
    fi
  fi
  image_is_pinned "$IMAGE" || warn "image '$IMAGE' is not digest-pinned (mutable tag) — prefer --image ...@sha256:<digest> for the socket-mounted orchestrator"
  log "check: host=${HOST:-<tailscale-ip nip.io>}, image=$IMAGE, auth=license-session, identity=${identity:-none}, bootstrap=$BOOTSTRAP"
  log "       docker=$docker_status, stack_web=$net_status, compose=$compose_status, brew=$brew_status"
  log "       git=$git_status, node=$node_status"
  [ "$TAILSCALE" = "true" ] && log "       tailscale=$ts_status (Traefik http→dash.<ts-ip>.nip.io, Funnel OFF)"
  ws_status="$([ -d "$WORKSPACE_DIR" ] && echo "owner=$(stat -f '%Su' "$WORKSPACE_DIR" 2>/dev/null || echo '?')" || echo "$([ "$BOOTSTRAP" = true ] && echo "absent (would create)" || echo "absent — clone fails")")"
  log "       executor($EXECUTOR_USER)=$exec_user_status, sshd=$sshd_status, workspace=$ws_status"
  log "       runtimes: $runtimes_status"
  exit 0
fi

# ── host OS guard: this is the Darwin-native installer. On Linux use install.sh. ──
OS="$(uname -s 2>/dev/null || echo unknown)"
if [ "$OS" != "Darwin" ]; then
  die "install-macos.sh is the macOS-native installer (bootstrap uses dscl, Remote Login, lsof, Homebrew). Detected '$OS' — on Linux run ./install.sh instead."
fi

# ── root preflight: stop a bootstrap-as-non-root (or as-root-not-via-sudo) run ──
require_root_for_bootstrap

# ── bootstrap: Docker Desktop, host tooling (git/node), then the shared stack ──
ensure_docker
ensure_host_tooling
ensure_stack

# ── Tailscale: install + bring the node up ──
ensure_tailscale

if [ "$TAILSCALE" = "true" ]; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$TS_IP" ] || die "could not read the Tailscale IP (is 'tailscale up' done?) — re-run, or pass --host"
  if [ -z "$HOST" ]; then
    HOST="dash.${TS_IP}.nip.io"
    log "using Tailscale host $HOST"
  fi
fi

# One-liner support: fetch compose.prod.yml when piped, print its sha256.
if [ ! -f "$COMPOSE_FILE" ]; then
  log "compose.prod.yml not found; fetching from $COMPOSE_URL"
  curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_FILE" \
    || die "failed to fetch compose.prod.yml (set BOOTSTRAP_BASE, or ship it alongside install-macos.sh)"
  log "fetched compose.prod.yml — sha256: $(sha256 "$COMPOSE_FILE")"
fi

mkdir -p "$DIR/data" "$DIR/data/ssh"

# ── per-host SSH key (executor). Never embedded; generated here. ──
SSH_KEY="$DIR/data/ssh/id_ed25519"
if [ ! -f "$SSH_KEY" ]; then
  log "generating per-host SSH key"
  ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "dashboard@$HOST" >/dev/null
  log "generated executor SSH key"
fi

# ── host-side agent executor (authorize key + Remote Login + runtimes) ──
ensure_executor

# The container runs as the executor uid (compose `user:`), so the data dir must
# be owned by that user.
chown -R "$EXECUTOR_USER:$EXECUTOR_GROUP" "$DIR/data"

# ── license ── (secret: 600, owned by the executor)
if [ -n "$LICENSE" ]; then
  write_license "$LICENSE" "$DIR/data/license.key" "$EXECUTOR_USER"
  log "license written to data/license.key (mode 600)"
fi

# ── pull + auto-pin to digest (trust-on-first-use) ──
log "pulling $IMAGE"
docker pull "$IMAGE"
if _repo_digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null)" && [ -n "$_repo_digest" ]; then
  IMAGE="$(pin_to_digest "$IMAGE" "${_repo_digest##*@}")"
  log "pinned image to digest: $IMAGE"
else
  warn "could not resolve a registry digest for '$IMAGE' — running the socket-mounted container on a mutable tag. Re-run once the registry has a digest, or pass --image ${IMAGE%%:*}@sha256:<digest> (resolve with: docker buildx imagetools inspect $IMAGE)"
fi

# ── .env (only what the operator supplied + the resolved executor identity) ──
# EXECUTOR_USER/EXECUTOR_CLAUDE_DIR drive the parametrized compose binds so the
# admin-user executor (not claude-bots) is what the container SSHes into and
# whose ~/.claude is mounted at /claude.
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
  if [ "$TAILSCALE" = "true" ] && [ -n "${TS_IP:-}" ]; then
    echo "HOST_IP=$TS_IP"
  fi
  echo "EXECUTOR_UID=$(id -u "$EXECUTOR_USER")"
  echo "EXECUTOR_GID=$(id -g "$EXECUTOR_USER")"
  echo "EXECUTOR_USER=$EXECUTOR_USER"
  echo "EXECUTOR_CLAUDE_DIR=$(user_home "$EXECUTOR_USER")/.claude"
  # No DOCKER_GID on macOS: Docker Desktop has no host `docker` group; the
  # socket is reached as the executor (the GUI user). compose defaults group_add
  # to 0, which is harmless here.
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
chown "$EXECUTOR_USER:$EXECUTOR_GROUP" "$ENV_FILE" 2>/dev/null || true
log "wrote $ENV_FILE (mode 600)"

# ── up ──
log "starting dashboard"
( cd "$DIR" && docker compose -f compose.prod.yml up -d )

# Post-up routing probe through Traefik (bounded; fail loud).
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
  warn "the stack started, yet traffic is not reaching it — check Docker Desktop is running and Traefik registered the router:"
  warn "  • restart the stack network:"
  warn "      docker compose -p stack -f $DIR/stack.compose.yml down && docker network rm stack_web && docker compose -p stack -f $DIR/stack.compose.yml up -d"
  warn "then re-check: curl -fsS http://$HOST/api/health"
fi

if [ "$TAILSCALE" = "true" ]; then
  log "reachable from any device on your tailnet at http://$HOST (Traefik via Tailscale; Funnel OFF)"
fi

if [ -n "$LICENSE" ]; then
  log "open the dashboard and log in with your license key"
else
  log "open the dashboard; the first-run screen will ask for your license key"
fi
log "to run agents: dashboard → Claude section → login (one-time claude /login OAuth)"
