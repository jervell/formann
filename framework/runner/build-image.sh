#!/usr/bin/env bash
# Build the AFK runner sandbox image, idempotently.
#
# - Reuses the cached image if it exists.
# - --rebuild forces a fresh build (layer cache still applies).
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
for arg in "$@"; do
  case "$arg" in
    --rebuild)
      REBUILD=true
      ;;
    -h|--help)
      cat <<USAGE
usage: build-image.sh [--rebuild]

Builds the ${RUNNER_IMAGE_NAME} image from <consumer>/runner/Dockerfile.
Run from anywhere inside the consumer repo; the script locates the consumer
root by walking \$PWD upward to find the .formann indirection symlink.
Reuses the cached image if it already exists; --rebuild forces a build.
Prints the image name on stdout on success.
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
if $REBUILD; then
  needs_build=true
elif ! docker image inspect "$RUNNER_IMAGE_NAME" >/dev/null 2>&1; then
  needs_build=true
fi

if $needs_build; then
  resolve_host_repo
  docker build --tag "$RUNNER_IMAGE_NAME" "$HOST_REPO/runner" >&2
fi

echo "$RUNNER_IMAGE_NAME"
