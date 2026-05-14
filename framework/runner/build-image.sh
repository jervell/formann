#!/usr/bin/env bash
# Build the AFK runner sandbox image, idempotently.
#
# - Reuses the cached image if it exists.
# - --rebuild forces a fresh build (layer cache still applies).
# - Prints the image name on stdout on success so the caller can capture it
#   (e.g. IMG="$(framework/runner/build-image.sh)").

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

REBUILD=false
for arg in "$@"; do
  case "$arg" in
    --rebuild)
      REBUILD=true
      ;;
    -h|--help)
      cat <<USAGE
usage: build-image.sh [--rebuild]

Builds the ${RUNNER_IMAGE_NAME} image from framework/runner/Dockerfile.
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
  docker build --tag "$RUNNER_IMAGE_NAME" "$HERE" >&2
fi

echo "$RUNNER_IMAGE_NAME"
