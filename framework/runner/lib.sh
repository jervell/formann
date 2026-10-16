# Shared constants and helper functions for the AFK runner sandbox primitives.
# Sourced by the runner scripts.

# Print the SHA-256 hex digest of stdin. Uses whichever of sha256sum (Linux)
# and shasum (macOS) is present; both yield the same digest.
runner_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Print the name of the Docker image carrying JDK + Maven + git + claude CLI
# for the consumer rooted at $1. Each consumer gets its own image, so two
# consumer repos on one host (each with its own runner/Dockerfile) never run
# in each other's image. The default is
#   formann-runner-<dir>-<pathhash>
# where <pathhash> is the first 8 hex of the SHA-256 of the consumer root's
# physical path (symlinks resolved, so one checkout always yields one name)
# and <dir> is its basename cleaned to Docker's tag rules: lowercased,
# anything outside [a-z0-9._-] turned into `-`, separator runs collapsed to a
# single `-`, edge separators stripped, cut to 40 characters. A <dir> that
# cleans to nothing leaves `formann-runner-<pathhash>`.
# RUNNER_IMAGE_NAME, when set, overrides the default:
#   RUNNER_IMAGE_NAME=my-project-runner .formann/runner/run-the-queue.sh …
# The network, bridge and subnet stay shared; only the image is per-consumer.
runner_image_name() {
  if [ -n "${RUNNER_IMAGE_NAME:-}" ]; then
    echo "$RUNNER_IMAGE_NAME"
    return 0
  fi
  local root dir pathhash
  root="$(cd "$1" && pwd -P)" || return 1
  pathhash="$(printf '%s' "$root" | runner_sha256 | cut -c1-8)"
  dir="$(printf '%s' "${root##*/}" \
    | LC_ALL=C tr 'A-Z' 'a-z' \
    | LC_ALL=C tr -c 'a-z0-9._-' '-' \
    | LC_ALL=C sed -e 's/[._-][._-]*/-/g' -e 's/^-//' -e 's/-$//')"
  dir="${dir:0:40}"
  dir="${dir%-}"
  if [ -n "$dir" ]; then
    echo "formann-runner-$dir-$pathhash"
  else
    echo "formann-runner-$pathhash"
  fi
}

# Image label carrying the context hash the image was built from.
RUNNER_CONTEXT_HASH_LABEL="formann.runner.context-hash"

# Print the SHA-256 over the consumer's runner/ build context (consumer root
# $1). Every entry under runner/ contributes its path relative to runner/,
# its kind (executable file, plain file, or symlink) and the SHA-256 of its
# content (a symlink's target), in LC_ALL=C sorted path order. Each record is
# fixed-width up to its NUL-terminated path, so editing, adding, removing or
# renaming a file, or flipping its executable bit, changes the hash, while
# the order the files were written in does not.
runner_context_hash() {
  local context="$1/$RUNNER_CONSUMER_PROMPTS_DIR" path kind digest
  if [ ! -d "$context" ]; then
    echo "runner_context_hash: no build context at $context" >&2
    return 1
  fi
  (
    set -o pipefail
    cd "$context" || exit 1
    find . ! -type d -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' path; do
      if [ -L "$path" ]; then
        kind=l
        digest="$(readlink "$path" | runner_sha256)"
      else
        if [ -x "$path" ]; then kind=x; else kind=f; fi
        digest="$(runner_sha256 < "$path")" || exit 1
      fi
      printf '%s %s %s\0' "$kind" "$digest" "${path#./}"
    done | runner_sha256
  )
}

# Custom Docker bridge network with RFC1918 outbound denied.
RUNNER_NETWORK_NAME="afk-runner-sandbox"

# Linux bridge interface name (max 15 chars, IFNAMSIZ).
RUNNER_BRIDGE_NAME="afk-rnr-br0"

# Sandbox bridge subnet. Must be RFC1918 (Docker's default constraint) and
# stay clear of subnets you actually use on the LAN. The setup script allows
# intra-bridge traffic explicitly so the deny-RFC1918 rules don't block
# container-to-container packets.
RUNNER_SUBNET="192.168.219.0/24"

# Custom iptables chain holding the deny-RFC1918 policy. DOCKER-USER jumps
# here for packets entering the sandbox bridge.
RUNNER_FW_CHAIN="AFK-RUNNER-SANDBOX-FW"

# Keychain coordinates for the long-lived OAuth token. Populate with:
#   security add-generic-password -s claude-code-oauth -a anthropic -w
# pasting the token from `claude setup-token` (no trailing newline).
# Override at runner-invoke time to select an alternate stored token, e.g.
#   RUNNER_OAUTH_KEYCHAIN_ACCOUNT=anthropic-alt .formann/runner/run-the-queue.sh …
RUNNER_OAUTH_KEYCHAIN_SERVICE="${RUNNER_OAUTH_KEYCHAIN_SERVICE:-claude-code-oauth}"
RUNNER_OAUTH_KEYCHAIN_ACCOUNT="${RUNNER_OAUTH_KEYCHAIN_ACCOUNT:-anthropic}"

# Git identity injected into the sandbox container via GIT_AUTHOR_NAME /
# GIT_AUTHOR_EMAIL / GIT_COMMITTER_NAME / GIT_COMMITTER_EMAIL env vars.
# Override at runner-invoke time to attribute commits differently.
RUNNER_GIT_USER_NAME="${RUNNER_GIT_USER_NAME:-Claude}"
RUNNER_GIT_USER_EMAIL="${RUNNER_GIT_USER_EMAIL:-claude@anthropic.com}"

# Per-feature Maven cache volume name template. The actual volume is
# named "${RUNNER_MVN_CACHE_PREFIX}<feature-slug>" so each feature gets
# an isolated repository.
RUNNER_MVN_CACHE_PREFIX="runner-mvn-cache-"

# Path inside the container where the per-feature Maven cache mounts.
# Matches the Dockerfile's non-root user home (`runner` at /home/runner).
RUNNER_CONTAINER_M2_PATH="/home/runner/.m2"

# Per-project runner state. All paths below are relative to the host repo
# root and resolved at runtime by the runner script. Everything here is
# gitignored — `.gitignore` carries `/.runner-state/`.
RUNNER_STATE_DIR=".runner-state"
RUNNER_LOCK_PATH="$RUNNER_STATE_DIR/lock"
RUNNER_CHECKOUT_PATH="$RUNNER_STATE_DIR/checkout"
RUNNER_RUNS_PATH="$RUNNER_STATE_DIR/runs"
RUNNER_ABORT_PATH="$RUNNER_STATE_DIR/aborted"

# Path inside the container where the runner-checkout mounts. The
# entrypoint runs from this directory; `claude -p "/implement <ref>"`
# operates against this working tree.
RUNNER_CONTAINER_REPO_PATH="/repo"

# Consumer-repo-relative directory that holds the post-implement manifest
# and any consumer-supplied prompt files referenced by it. The installer seeds
# runner/Dockerfile and runner/manifest.md into this directory; consumer
# prompts placed here shadow framework prompts of the same relative path.
# Fixed by convention; the resolver uses this directory as the consumer root.
RUNNER_CONSUMER_PROMPTS_DIR="runner"

# Consumer-repo-relative path to the post-implement steps manifest.
# The manifest lists ordered post-implement Dispatches; the runner resolves
# it at pre-flight and walks the entries after each successful /implement.
# A pre-flight invariant verifies the file's presence and validity before
# the loop starts.
RUNNER_MANIFEST_FILE="${RUNNER_CONSUMER_PROMPTS_DIR}/manifest.md"
