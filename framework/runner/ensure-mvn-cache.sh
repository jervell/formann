#!/usr/bin/env bash
# Ensure a per-feature Maven cache Docker volume exists for the given
# feature slug. Idempotent — `docker volume create` is itself idempotent
# on identical names; this wrapper just provides a stable, well-named
# entry point for slice 04 to call from pre-flight.
#
# Usage:
#   ensure-mvn-cache.sh <feature-slug>
#
# Output:
#   stdout — the volume name (so callers can capture and pass to
#            `docker run -v <vol>:<container-m2>`).
#   stderr — `docker volume create` log on first creation only; nothing
#            on repeat invocations.
#
# Convention: the volume mounts at $RUNNER_CONTAINER_M2_PATH inside the
# sandbox container (currently /home/runner/.m2). Slice 04 reads
# RUNNER_CONTAINER_M2_PATH from lib.sh too, so the host- and container-
# side names stay in sync.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  cat >&2 <<USAGE
usage: ensure-mvn-cache.sh <feature-slug>

Ensures a Docker volume named ${RUNNER_MVN_CACHE_PREFIX}<feature-slug>
exists. Idempotent. Prints the volume name on stdout.
USAGE
  exit 2
fi

FEATURE_SLUG="$1"

# Validate slug shape — keep it docker-volume-safe and predictable.
# Volume names must match [a-zA-Z0-9][a-zA-Z0-9_.-]*; we narrow further
# to lowercase + digits + hyphens to match how we name feature dirs.
if [[ ! "$FEATURE_SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "ensure-mvn-cache.sh: invalid feature slug: '$FEATURE_SLUG'" >&2
  echo "expected lowercase alphanumeric + hyphens, starting with [a-z0-9]" >&2
  exit 2
fi

VOLUME_NAME="${RUNNER_MVN_CACHE_PREFIX}${FEATURE_SLUG}"

if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
  docker volume create "$VOLUME_NAME" >&2
  # Newly-created Docker volumes mount as root-owned. The sandbox image
  # runs as the non-root `runner` user (uid 1000); without a chown the
  # container can't write to /home/runner/.m2. Initialise ownership
  # one-shot on creation so every later mount is writable as runner.
  docker run --rm \
    -v "$VOLUME_NAME:/cache" \
    alpine:latest \
    chown -R 1000:1000 /cache >&2
fi

echo "$VOLUME_NAME"
