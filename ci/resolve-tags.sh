#!/usr/bin/env bash
#
# Resolve the image tags to publish for a release. Sourced by the release
# workflow (.github/workflows/release.yml) and unit-tested by
# test/resolve-tags.test.sh.
#
# `version` is the raw ref being released: vX.Y.Z, vX.Y.Z-rc.N, edge-<sha>, or
# the bare `edge`/`latest` inputs. `image` is the GHCR repo (no tag).
#
# A stable release publishes the immutable tag in BOTH forms — the v-prefixed
# `:vX.Y.Z` (historical) and the clean `:X.Y.Z` — and moves `:latest`. The clean
# tag is the documented contract (RELEASING.md) and the one the app pulls /
# checks: it matches package.json and the app's reported VERSION, so publishing
# only the v-prefixed form made `:X.Y.Z` 404 for the in-app update and for
# `install.sh --image ...:X.Y.Z`.
#
# Pre-releases (vX.Y.Z-rc.N) publish both forms but never move `:latest`.
# A per-commit `edge-<sha>` publishes its immutable ref and moves `:edge`.
# Bare `edge`/`latest` inputs publish only themselves.
resolve_tags() {
  local version="$1" image="$2"
  local clean="${version#v}"

  echo "$image:$version"
  # Clean (no-v) form whenever it differs — i.e. every v-prefixed release.
  [ "$clean" != "$version" ] && echo "$image:$clean"

  case "$version" in
    edge-*)          echo "$image:edge" ;;
    latest|edge|*-*) ;;                      # floating inputs / pre-releases: no pointer move
    *)               echo "$image:latest" ;; # stable semver advances :latest
  esac
}
