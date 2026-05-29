#!/usr/bin/env bash
# Build the AFK runner sandbox image, idempotently.
#
# - Reuses the cached image if it exists.
# - --rebuild forces a build (layer cache still applies — cheap; picks up
#   Dockerfile edits but keeps already-installed tools at cached versions).
# - --fresh forces a build with no layer cache and a base-image re-pull, so
#   every tool (apt, JDK, Node, Claude CLI) re-resolves to its current version.
# - Prints the image name on stdout on success so the caller can capture it
#   (e.g. IMG="$(./build-image.sh)").
#
# Run this from anywhere inside the consumer repo. The script walks $PWD
# upward to find the .formann ancestor (the consumer root) and builds from
# <consumer>/runner/Dockerfile.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

resolve_host_repo() {
  local dir="${PWD}"
  while [ "$dir" != "/" ]; do
    if [ -e "$dir/.formann" ]; then
      HOST_REPO="$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  echo "build-image.sh: could not find .formann ancestor from $PWD" >&2
  return 1
}

REBUILD=false
FRESH=false
for arg in "$@"; do
  case "$arg" in
    --rebuild)
      REBUILD=true
      ;;
    --fresh)
      FRESH=true
      ;;
    -h|--help)
      cat <<USAGE
usage: build-image.sh [--rebuild | --fresh]

Builds the ${RUNNER_IMAGE_NAME} image from <consumer>/runner/Dockerfile.
Run from anywhere inside the consumer repo; the script locates the consumer
root by walking \$PWD upward to find the .formann indirection symlink.

Reuses the cached image if it already exists. --rebuild forces a build that
still reuses the layer cache, so it picks up Dockerfile edits cheaply but
leaves already-installed tools at their cached versions. --fresh forces a build
that bypasses the layer cache and re-pulls the base image, so every tool — apt
packages, the JDK, Node, and the Claude CLI — re-resolves to its current
published version. Prints the image name on stdout on success.
USAGE
      exit 0
      ;;
    *)
      echo "build-image.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

needs_build=false
if $REBUILD || $FRESH; then
  needs_build=true
elif ! docker image inspect "$RUNNER_IMAGE_NAME" >/dev/null 2>&1; then
  needs_build=true
fi

if $needs_build; then
  resolve_host_repo
  # --fresh re-resolves every tool: --no-cache re-runs the apt/vendor/npm
  # install layers (which fetch current versions at build time), and --pull
  # refreshes the base-image tag. Without it a build reuses cached layers and
  # freezes those versions.
  build_args=()
  if $FRESH; then
    build_args+=(--no-cache --pull)
  fi
  docker build ${build_args[@]+"${build_args[@]}"} --tag "$RUNNER_IMAGE_NAME" "$HOST_REPO/runner" >&2
fi

echo "$RUNNER_IMAGE_NAME"
