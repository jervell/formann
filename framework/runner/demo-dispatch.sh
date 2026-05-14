#!/usr/bin/env bash
# End-to-end demonstration of the slice-03 primitives:
#   1. retrieve OAuth token from Keychain (framework/runner/retrieve-token.sh)
#   2. ensure per-feature mvn cache volume (framework/runner/ensure-mvn-cache.sh)
#   3. docker run on the sandbox network with the token in env and the cache
#      volume mounted, executing `claude -p "echo hi"` inside the container
#   4. two consecutive `mvn install` runs against a tiny fixture project
#      (framework/runner/demo-fixture) to demonstrate cache reuse — the
#      second run should be measurably faster than the first
#   5. token-leakage scan: every log file produced by this run is checked
#      for the token string; demo fails if any leak is found
#
# Usage:
#   framework/runner/demo-dispatch.sh [--clean] [--feature <slug>]
#
# Flags:
#   --clean            Remove the demo's cache volume before starting, so
#                      the first `mvn install` runs against a cold cache.
#                      Without --clean, repeat invocations of the demo
#                      reuse whatever the volume already holds (cheaper,
#                      but shows a smaller first-vs-second delta).
#   --feature <slug>   Override the demo feature slug. Defaults to
#                      `afk-runner-demo` so it doesn't collide with the
#                      real `afk-runner` cache from runner runs.
#
# Output:
#   Per-run log dir at /tmp/afk-runner-demo-<unix-ts>/ containing:
#     claude.log              — `claude -p "echo hi"` stdout+stderr
#     mvn-install-1.log       — first `mvn install` (cold cache if --clean)
#     mvn-install-2.log       — second `mvn install` (warm cache)
#     summary.txt             — claude exit code + mvn timings
#
# Token safety:
#   The token is captured into a shell variable, passed to docker via
#   `-e CLAUDE_CODE_OAUTH_TOKEN="$TOKEN"`, and never echoed to terminal,
#   never written to a log file, never serialised to a process argv
#   (the leakage scan uses bash builtins to read log content into shell
#   variables and `[[ ]]` substring matching, never `grep -F "$TOKEN"`).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

CLEAN=false
FEATURE_SLUG="afk-runner-demo"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      CLEAN=true
      shift
      ;;
    --feature)
      FEATURE_SLUG="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *)
      echo "demo-dispatch.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

LOG_DIR="/tmp/afk-runner-demo-$(date +%s)"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

FIXTURE_SRC="$HERE/demo-fixture"
if [[ ! -f "$FIXTURE_SRC/pom.xml" ]]; then
  echo "demo-dispatch.sh: fixture not found at $FIXTURE_SRC" >&2
  exit 2
fi

# Copy the fixture into a fresh workdir so mvn's target/ output never
# touches the host repo. Place it under the host repo's gitignored
# .runner-state/ rather than /tmp because Docker Desktop on macOS only
# shares paths under $HOME (and not /var/folders, where `mktemp -d`
# would put it) by default.
RUNNER_STATE="$(cd "$HERE/../.." && pwd)/.runner-state"
mkdir -p "$RUNNER_STATE/demo-work"
WORK="$(mktemp -d -p "$RUNNER_STATE/demo-work" run.XXXXXX)"
cp -R "$FIXTURE_SRC/." "$WORK/"
chmod -R u+rwX "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "demo-dispatch: log dir = $LOG_DIR"
echo "demo-dispatch: feature  = $FEATURE_SLUG"
echo "demo-dispatch: fixture  = $FIXTURE_SRC"

# ---- pre-flight: image, network, cache, token -------------------------------

# Build (or reuse) the sandbox image. Stdout = image name.
IMAGE="$("$HERE/build-image.sh")"

# Ensure (or create) the sandbox bridge network. Stdout = network name.
NETWORK="$("$HERE/setup-network.sh")"

# Optional: blow away the demo's cache so the first run is from-scratch.
DEMO_VOLUME="${RUNNER_MVN_CACHE_PREFIX}${FEATURE_SLUG}"
if $CLEAN; then
  if docker volume inspect "$DEMO_VOLUME" >/dev/null 2>&1; then
    echo "demo-dispatch: removing existing cache volume ($DEMO_VOLUME)"
    docker volume rm "$DEMO_VOLUME" >/dev/null
  fi
fi

# Ensure (or create) the per-feature cache. Stdout = volume name.
VOLUME="$("$HERE/ensure-mvn-cache.sh" "$FEATURE_SLUG")"

# Retrieve the OAuth token. Stdout = token (captured here, then never
# echoed). retrieve-token.sh fails fast with a setup hint if the
# Keychain entry is missing.
TOKEN="$("$HERE/retrieve-token.sh")"

# ---- 1. claude -p "echo hi" -------------------------------------------------

echo "demo-dispatch: running \`claude -p \"echo hi\"\` in sandbox container"
CLAUDE_RC=0
docker run --rm \
  -e CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" \
  --network "$NETWORK" \
  -v "$VOLUME:$RUNNER_CONTAINER_M2_PATH" \
  "$IMAGE" \
  claude -p "echo hi" \
  >"$LOG_DIR/claude.log" 2>&1 || CLAUDE_RC=$?

if [[ $CLAUDE_RC -ne 0 ]]; then
  echo "demo-dispatch: claude -p exited $CLAUDE_RC; see $LOG_DIR/claude.log" >&2
fi

# ---- 2. mvn install x2 ------------------------------------------------------

run_mvn_install() {
  local n="$1"
  local logfile="$LOG_DIR/mvn-install-${n}.log"
  SECONDS=0
  local rc=0
  docker run --rm \
    --network "$NETWORK" \
    -v "$VOLUME:$RUNNER_CONTAINER_M2_PATH" \
    -v "$WORK:/work:rw" \
    -w /work \
    "$IMAGE" \
    mvn -B install \
    >"$logfile" 2>&1 || rc=$?
  echo "${SECONDS} ${rc}"
}

echo "demo-dispatch: first mvn install (cold cache if --clean)..."
read -r MVN1_SEC MVN1_RC <<<"$(run_mvn_install 1)"

echo "demo-dispatch: second mvn install (warm cache)..."
read -r MVN2_SEC MVN2_RC <<<"$(run_mvn_install 2)"

# ---- 3. token-leakage scan --------------------------------------------------
#
# Read each log file into a shell variable and use `[[ ]]` substring
# matching. This keeps the token out of grep's argv and out of any
# intermediate temp file.

LEAK_FOUND=0
for log in "$LOG_DIR"/*.log; do
  content="$(<"$log")"
  if [[ "$content" == *"$TOKEN"* ]]; then
    echo "demo-dispatch: TOKEN LEAK in $log" >&2
    LEAK_FOUND=1
  fi
done

# ---- 4. summary -------------------------------------------------------------

{
  echo "demo-dispatch summary"
  echo "  log dir:         $LOG_DIR"
  echo "  feature slug:    $FEATURE_SLUG"
  echo "  cache volume:    $VOLUME"
  echo "  network:         $NETWORK"
  echo "  image:           $IMAGE"
  echo
  echo "  claude -p result: exit=$CLAUDE_RC"
  echo "  mvn install run 1: exit=$MVN1_RC, ${MVN1_SEC}s"
  echo "  mvn install run 2: exit=$MVN2_RC, ${MVN2_SEC}s"
  if [[ $MVN1_SEC -gt 0 ]]; then
    pct=$(( MVN2_SEC * 100 / MVN1_SEC ))
    echo "  cache speedup:    $(( MVN1_SEC - MVN2_SEC ))s saved; run 2 took ${pct}% of run 1's time"
  fi
  echo
  if [[ $LEAK_FOUND -eq 0 ]]; then
    echo "  token-leakage scan: PASS (token string absent from all log files)"
  else
    echo "  token-leakage scan: FAIL (token string found in log files; see stderr above)"
  fi
} | tee "$LOG_DIR/summary.txt"

# Drop the token from the shell process before exiting (defence-in-depth;
# the kernel will free this memory on exit anyway, but explicit is nice).
unset TOKEN

# Exit non-zero if anything failed, so a CI-style invocation flags it.
if [[ $CLAUDE_RC -ne 0 || $MVN1_RC -ne 0 || $MVN2_RC -ne 0 || $LEAK_FOUND -ne 0 ]]; then
  exit 1
fi
