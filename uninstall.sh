#!/usr/bin/env bash
#
# Dashboard uninstaller — removes installed components.
#
# Reverses install.sh operations: stops containers, removes the executor user,
# cleans generated files, and optionally restores host state. Use --check for
# a dry-run preview of what would be removed.
#
# Usage:
#   ./uninstall.sh [--dir <path>] [--components <list>] [--check] [-h]
#
# Options:
#   --dir <path>         Install directory to clean (default: current directory).
#   --components <list>  Comma-separated components to remove. Default: all.
#                        Valid: all,containers,executor,files,workspace,stack.
#   --keep-user         Don't remove the executor user (useful for sharing).
#   --check             Dry-run: show what would be removed without changing anything.
#   -h, --help          Show this help.
#
set -euo pipefail

EXECUTOR_USER="claude-bots"
WORKSPACE_DIR="/root/workspace"
DIR="$PWD"
COMPONENTS="all"
CHECK_ONLY="false"
KEEP_USER="false"

# Detect the install DIR if not specified: look for compose.prod.yml
detect_install_dir() {
  local dir="$1"
  if [ ! -f "$dir/compose.prod.yml" ]; then
    # Try current directory if the specified one doesn't have the marker
    if [ -f "./compose.prod.yml" ]; then
      echo "./compose.prod.yml found in current directory"
      DIR="$PWD"
    elif [ -f "/root/workspace/dashboard-install/compose.prod.yml" ]; then
      DIR="/root/workspace/dashboard-install"
    else
      echo "compose.prod.yml not found in $dir or default locations"
      return 1
    fi
  fi
  echo "install directory: $DIR"
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Check if a component is enabled for removal
has_component() {
  local comp="$1"
  [ "$COMPONENTS" = "all" ] && return 0
  echo "$COMPONENTS" | grep -qE "(^|,)$comp(,|$)"
}

# Container operations
stop_containers() {
  if ! has_component "containers" && ! has_component "all"; then
    log "skipping containers (not in --components)"
    return 0
  fi

  local compose_file="$DIR/compose.prod.yml"
  if [ ! -f "$compose_file" ]; then
    warn "compose.prod.yml not found at $compose_file"
    return 0
  fi

  log "stopping dashboard containers"
  if [ "$CHECK_ONLY" = "true" ]; then
    echo "would run: docker compose -f \"$compose_file\" down"
    return 0
  fi

  ( cd "$DIR" && docker compose -f compose.prod.yml down ) || warn "docker compose down failed"
}

# Executor user removal
remove_executor() {
  if ! has_component "executor" && ! has_component "all"; then
    log "skipping executor removal (not in --components)"
    return 0
  fi

  if [ "$KEEP_USER" = "true" ]; then
    log "keeping executor user $EXECUTOR_USER (--keep-user)"
    return 0
  fi

  if ! id "$EXECUTOR_USER" >/dev/null 2>&1; then
    log "executor user $EXECUTOR_USER not found"
    return 0
  fi

  log "removing executor user $EXECUTOR_USER"
  if [ "$CHECK_ONLY" = "true" ]; then
    echo "would run: userdel -r $EXECUTOR_USER"
    return 0
  fi

  # Kill any user processes first
  pkill -u "$EXECUTOR_USER" 2>/dev/null || true
  sleep 1

  # Try userdel, fall back to manual removal
  if command -v userdel >/dev/null 2>&1; then
    /usr/sbin/userdel -r "$EXECUTOR_USER" 2>/dev/null || warn "userdel failed (may have running processes)"
  elif command -v deluser >/dev/null 2>&1; then
    deluser --remove-home "$EXECUTOR_USER" 2>/dev/null || warn "deluser failed"
  else
    warn "neither userdel nor deluser found — manual cleanup required"
  fi
}

# Runtime symlinks cleanup
remove_runtimes() {
  if ! has_component "executor" && ! has_component "all"; then
    return 0
  fi

  local runtimes="claude opencode codex cursor-agent"
  local bin removed=0

  for bin in $runtimes; do
    local path="/usr/local/bin/$bin"
    if [ -L "$path" ]; then
      log "removing runtime symlink: $path"
      if [ "$CHECK_ONLY" = "true" ]; then
        echo "would remove: $path"
        ((removed++))
        continue
      fi
      rm -f "$path" && ((removed++))
    fi
  done

  [ "$removed" -gt 0 ] || log "no runtime symlinks found"
}

# Workspace ownership restoration
restore_workspace() {
  if ! has_component "workspace" && ! has_component "all"; then
    return 0
  fi

  if [ ! -d "$WORKSPACE_DIR" ]; then
    log "workspace $WORKSPACE_DIR not found"
    return 0
  fi

  local current_owner
  current_owner="$(stat -c '%U:%G' "$WORKSPACE_DIR" 2>/dev/null || stat -f '%Su:%Sg' "$WORKSPACE_DIR" 2>/dev/null)"

  if [ "$current_owner" = "root:root" ]; then
    log "workspace already owned by root"
    return 0
  fi

  log "restoring workspace ownership: $WORKSPACE_DIR -> root:root"
  if [ "$CHECK_ONLY" = "true" ]; then
    echo "would run: chown -R root:root \"$WORKSPACE_DIR\""
    return 0
  fi

  chown -R root:root "$WORKSPACE_DIR"
}

# Remove /root traverse permission if added
restore_root_perms() {
  if ! has_component "workspace" && ! has_component "all"; then
    return 0
  fi

  local perms
  perms="$(stat -c '%A' /root 2>/dev/null || stat -f '%Sp' /root 2>/dev/null)"

  # Check if 'o+x' is set (last char should be 'x' not '-')
  if [[ "$perms" =~ ^drwxr-x.{6}x$ ]]; then
    log "removing o+x from /root"
    if [ "$CHECK_ONLY" = "true" ]; then
      echo "would run: chmod o-x /root"
      return 0
    fi
    chmod o-x /root
  else
    log "/root permissions unchanged ($perms)"
  fi
}

# Generated files cleanup
clean_files() {
  if ! has_component "files" && ! has_component "all"; then
    return 0
  fi

  if [ ! -d "$DIR" ]; then
    warn "install directory $DIR not found"
    return 0
  fi

  log "cleaning generated files in $DIR"

  local files=(
    "$DIR/.env"
    "$DIR/data/license.key"
    "$DIR/data/ssh/id_ed25519"
    "$DIR/data/ssh/id_ed25519.pub"
  )

  local f
  for f in "${files[@]}"; do
    if [ -e "$f" ]; then
      if [ "$CHECK_ONLY" = "true" ]; then
        echo "would remove: $f"
      else
        rm -f "$f"
      fi
    fi
  done

  # Clean empty directories
  local dirs=(
    "$DIR/data/ssh"
    "$DIR/data"
  )

  local d
  for d in "${dirs[@]}"; do
    if [ -d "$d" ] && [ -z "$(ls -A "$d")" ]; then
      if [ "$CHECK_ONLY" = "true" ]; then
        echo "would remove empty dir: $d"
      else
        rmdir "$d" 2>/dev/null || true
      fi
    fi
  done
}

# Stack removal (Traefik, network) — ONLY if no other containers use it
remove_stack() {
  if ! has_component "stack"; then
    return 0
  fi

  if ! docker network inspect stack_web >/dev/null 2>&1; then
    log "stack_web network not found"
    return 0
  fi

  local container_count
  container_count="$(docker network inspect stack_web --format '{{len .Containers}}' 2>/dev/null || echo "0")"

  if [ "$container_count" -gt 0 ]; then
    warn "stack_web network has $container_count containers — not removing (--force-stack to override)"
    return 0
  fi

  log "removing stack_web network"
  if [ "$CHECK_ONLY" = "true" ]; then
    echo "would run: docker network rm stack_web"
    return 0
  fi

  docker network rm stack_web
}

usage() {
  sed -n '2,/^set -euo/{/^set -euo/!p}' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)         DIR="${2:-}"; shift 2 ;;
    --components)  COMPONENTS="${2:-}"; shift 2 ;;
    --keep-user)   KEEP_USER="true"; shift ;;
    --check)       CHECK_ONLY="true"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown argument: $1 (see --help)" ;;
  esac
done

log "uninstall: dir=$DIR, components=$COMPONENTS, check=$CHECK_ONLY, keep_user=$KEEP_USER"

# Validate components
if [ "$COMPONENTS" != "all" ]; then
  for comp in ${COMPONENTS//,/ }; do
    case "$comp" in
      all|containers|executor|files|workspace|stack) ;;
      *) die "invalid component: $comp (valid: all,containers,executor,files,workspace,stack)" ;;
    esac
  done
fi

# Run removal steps
detect_install_dir "$DIR"
stop_containers
remove_executor
remove_runtimes
restore_workspace
restore_root_perms
clean_files
remove_stack

log "done. review with --check for dry-run preview"
