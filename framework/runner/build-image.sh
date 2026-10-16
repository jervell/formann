#!/usr/bin/env bash
# Build the consumer's AFK runner sandbox image, idempotently.
#
# - The image name is the consumer's own (see runner_image_name in lib.sh):
#   formann-runner-<dir>-<pathhash>, or RUNNER_IMAGE_NAME when set.
# - Every build labels the image formann.runner.context-hash=<hash>, the
#   SHA-256 of the consumer's runner/ build context (runner_context_hash).
# - Without flags, builds only when no image exists under the name or its
#   label differs from the current context hash; the build reuses the layer
#   cache, so an unchanged recipe costs nothing. Otherwise reuses the image.
# - --rebuild forces a build (layer cache still applies — cheap; keeps
#   already-installed tools at cached versions).
# - --fresh forces a build with no layer cache and a base-image re-pull, so
#   every tool (apt, JDK, Node, Claude CLI) re-resolves to its current version.
# - Prints the image name on stdout on success so the caller can capture it
#   (e.g. IMG="$(./build-image.sh)").
#
# Run this from anywhere inside the consumer repo. The script walks $PWD
# upward to find the .formann ancestor (the consumer root), which fixes the
# image name and the context hash, and builds from <consumer>/runner/Dockerfile.

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

Builds the consumer's runner image from <consumer>/runner/Dockerfile.
Run from anywhere inside the consumer repo; the script locates the consumer
root by walking \$PWD upward to find the .formann indirection symlink.

The image is named formann-runner-<dir>-<pathhash> after the consumer root
(its directory name and a hash of its path), unless RUNNER_IMAGE_NAME is set.

Every build labels the image formann.runner.context-hash with a hash of the
consumer's runner/ directory. Without flags, builds only when no image exists
under the name or its label differs from the current hash (any file under
runner/ edited, added, removed, renamed or made (non-)executable); that build
reuses the layer cache. Otherwise the existing image is reused.

--rebuild forces a build that still reuses the layer cache, so it leaves
already-installed tools at their cached versions. --fresh forces a build
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

resolve_host_repo
image_name="$(runner_image_name "$HOST_REPO")"
context_hash="$(runner_context_hash "$HOST_REPO")"

needs_build=false
if $REBUILD || $FRESH; then
  needs_build=true
elif ! image_hash="$(docker image inspect \
    --format "{{ index .Config.Labels \"$RUNNER_CONTEXT_HASH_LABEL\" }}" \
    "$image_name" 2>/dev/null)"; then
  needs_build=true
elif [ "$image_hash" != "$context_hash" ]; then
  needs_build=true
fi

if $needs_build; then
  # --fresh re-resolves every tool: --no-cache re-runs the apt/vendor/npm
  # install layers (which fetch current versions at build time), and --pull
  # refreshes the base-image tag. Without it a build reuses cached layers and
  # freezes those versions.
  build_args=(--label "$RUNNER_CONTEXT_HASH_LABEL=$context_hash")
  if $FRESH; then
    build_args+=(--no-cache --pull)
  fi
  docker build "${build_args[@]}" --tag "$image_name" "$HOST_REPO/runner" >&2
fi

echo "$image_name"
