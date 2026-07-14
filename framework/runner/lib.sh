# Shared constants for the AFK runner sandbox primitives.
# Sourced by build-image.sh, setup-network.sh, and (eventually) the runner script.

# Docker image carrying JDK + Maven + git + claude CLI.
RUNNER_IMAGE_NAME="afk-runner-sandbox"

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
