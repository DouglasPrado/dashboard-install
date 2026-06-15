#!/usr/bin/env bash
#
# Dashboard updater — force the running install to the latest published image.
#
# Self-locates the install dir from the running container's Compose labels, so
# operators don't need to remember where it lives. Re-pins DASHBOARD_IMAGE and
# recreates the container — passing the ref INLINE on each compose command so an
# exported `DASHBOARD_IMAGE` shell var (which outranks .env in compose variable
# substitution) or a stale digest pin can't silently keep the old image. Both of
# those defeated naive `docker compose pull` in the field.
#
# Usage:
#   ./update.sh                       # → the install's channel (DASHBOARD_CHANNEL)
#   ./update.sh --tag v0.5.6          # pin a specific published tag
#   ./update.sh --dir /home/me        # explicit install dir
#   curl -sSL .../update.sh | bash    # one-liner (auto-detect)
set -uo pipefail

IMAGE_REPO="ghcr.io/douglasprado/dashboard-install"
IMAGE_DEFAULT="$IMAGE_REPO:latest"
CONTAINER="dashboard-app"
COMPOSE_BASENAME="compose.prod.yml"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Parse the compose working_dir from a "<working_dir>|<config_files>" inspect
# line. Echoes the dir, or nothing when the label is absent/blank.
parse_install_dir() {
  local line="$1" dir="${1%%|*}"
  { [ -n "$dir" ] && [ "$dir" != "$line" ]; } && printf '%s\n' "$dir"
}

# Portable .env rewrite. Keep the temp file under /tmp so host-side updates run
# fine even when the install dir itself is not writable by the executor user.
pin_env_value() {
  local env_file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/dashboard-env.XXXXXX")" || return 1
  if [ -f "$env_file" ]; then
    awk -F= -v key="$key" -v value="$value" '
      BEGIN { done = 0 }
      $1 == key { print key "=" value; done = 1; next }
      { print }
      END { if (!done) print key "=" value }
    ' "$env_file" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$env_file" || { rm -f "$tmp"; return 1; }
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$env_file" 2>/dev/null || mv "$tmp" "$env_file" || { rm -f "$tmp"; return 1; }
  fi
  rm -f "$tmp"
  chmod 600 "$env_file" 2>/dev/null || true
}

pin_image_in_env() {
  local env_file="$1" ref="$2"
  pin_env_value "$env_file" DASHBOARD_IMAGE "$ref"
}

dashboard_platform() {
  [ "$(uname -s)" = "Darwin" ] && printf '%s\n' 'linux/amd64'
}

# Version baked into a local image (org.opencontainers.image.version label).
image_version() {
  docker image inspect "$1" \
    --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' 2>/dev/null
}

# Older Linux installs left .env as root:root 600, but host-side updates run as
# the non-root executor user over SSH. Repair that in place via the Docker daemon
# the executor already uses for compose, so the updater can self-heal.
repair_env_access() {
  local env_file="$1" image="$2" env_dir env_name uid gid
  [ -e "$env_file" ] || return 0
  [ -n "$image" ] || return 1
  env_dir="$(dirname "$env_file")"
  env_name="$(basename "$env_file")"
  uid="$(id -u)"
  gid="$(id -g)"
  docker run --rm --entrypoint /bin/sh -u 0:0 \
    -v "$env_dir:/work" "$image" \
    -ceu "chown $uid:$gid \"/work/$env_name\" && chmod 600 \"/work/$env_name\"" \
    >/dev/null 2>&1
}

ensure_env_access() {
  local env_file="$1" image="$2"
  [ ! -e "$env_file" ] && return 0
  [ -r "$env_file" ] && [ -w "$env_file" ] && return 0
  warn "$env_file is not readable+writable by $(id -un); attempting a one-time ownership repair via docker"
  repair_env_access "$env_file" "$image" || return 1
  [ -r "$env_file" ] && [ -w "$env_file" ]
}

usage() {
  cat <<EOF
Usage: update.sh [options]
  --image <ref>   Full image ref to pull (default: the install's DASHBOARD_CHANNEL, e.g. $IMAGE_DEFAULT)
  --tag <tag>     Shorthand for $IMAGE_REPO:<tag>
  --dir <path>    Install dir holding $COMPOSE_BASENAME + .env (auto-detected if omitted)
  -h, --help      Show this help
EOF
}

# Read the configured update channel from an install's .env (DASHBOARD_CHANNEL),
# defaulting to `latest` when the file or key is absent. Lets `./update.sh` with
# no args follow whatever channel the install was set up to track (`main` rides
# every merge; `latest` rides stable releases).
env_channel() { # <env-file>
  local f="$1" line=""
  [ -f "$f" ] && line="$(grep -E '^DASHBOARD_CHANNEL=' "$f" 2>/dev/null | tail -1)"
  line="${line#DASHBOARD_CHANNEL=}"
  printf '%s' "${line:-latest}"
}

# When sourced (tests), stop here so only the helpers above are defined.
(return 0 2>/dev/null) && return 0

# ─────────────────────────── main ───────────────────────────
REF=""   # empty → resolved from the install's channel once .env is located
DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --image) REF="${2:?--image needs a ref}"; shift 2 ;;
    --tag)   REF="$IMAGE_REPO:${2:?--tag needs a tag}"; shift 2 ;;
    --dir)   DIR="${2:?--dir needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not available"

# Locate the install dir: explicit --dir, else the running container's compose
# label, else the current dir if it holds the compose file.
if [ -z "$DIR" ]; then
  inspect_line="$(docker inspect "$CONTAINER" \
    --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}|{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null || true)"
  DIR="$(parse_install_dir "$inspect_line")"
fi
[ -z "$DIR" ] && [ -f "./$COMPOSE_BASENAME" ] && DIR="$(pwd)"
[ -n "$DIR" ] || die "could not locate the install dir — pass --dir <path>"

COMPOSE_FILE="$DIR/$COMPOSE_BASENAME"
[ -f "$COMPOSE_FILE" ] || die "$COMPOSE_FILE not found — pass --dir <path>"
ENV_FILE="$DIR/.env"

# No explicit --image/--tag → follow the channel the install tracks.
[ -n "$REF" ] || REF="$IMAGE_REPO:$(env_channel "$ENV_FILE")"

CURRENT_IMAGE="$(docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || true)"
before="$(image_version "$CURRENT_IMAGE")"
log "install dir : $DIR"
log "pulling     : $REF"
[ -n "$before" ] && log "running     : v$before"

ensure_env_access "$ENV_FILE" "$CURRENT_IMAGE" \
  || die "$ENV_FILE is not readable+writable by $(id -un), and the docker ownership repair failed. Re-run install.sh or chown the file to the executor user."
pin_image_in_env "$ENV_FILE" "$REF" \
  || die "failed to update $ENV_FILE"
PLATFORM="$(dashboard_platform || true)"
if [ -n "$PLATFORM" ]; then
  export DOCKER_DEFAULT_PLATFORM="$PLATFORM"
  pin_env_value "$ENV_FILE" DASHBOARD_PLATFORM "$PLATFORM" \
    || die "failed to update $ENV_FILE with DASHBOARD_PLATFORM"
  log "platform    : $PLATFORM"
fi

# Inline DASHBOARD_IMAGE wins over both an exported shell var and .env, so the
# pull/recreate always target the intended ref.
docker pull "$REF" \
  || die "image pull failed (auth/network? for a private image run: docker login ghcr.io)"
DASHBOARD_IMAGE="$REF" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull \
  || die "image pull failed (auth/network? for a private image run: docker login ghcr.io)"
DASHBOARD_IMAGE="$REF" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --force-recreate \
  || die "compose up failed — see: docker logs $CONTAINER"

# Confirm the recreated container is running the freshly pulled image.
after="$(image_version "$REF")"
running="$(image_version "$(docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null)")"
if [ -n "$after" ] && [ "$running" = "$after" ]; then
  log "updated     : v$after  (was ${before:-unknown})"
  log "done."
else
  warn "container is running v${running:-unknown}, expected v${after:-unknown}"
  warn "inspect: docker logs $CONTAINER  |  docker inspect $CONTAINER --format '{{.Config.Image}}'"
  exit 1
fi
