#!/usr/bin/env bash
# AFK runner sandbox entrypoint.
#
# Minimal pass-through. The caller (slice 04 runner script today, ad-hoc
# `docker run` for verification) supplies the command to execute. We do
# not touch CLAUDE_CODE_OAUTH_TOKEN or any other env var; the caller is
# responsible for what enters the container.

set -e

# Suppress kernel core dumps inside the container. The bookworm-slim
# default `core_pattern` is just `core` (CWD-relative); a crash in any
# in-container process — bats subprocess, claude CLI, anything else —
# would drop a `core` file at its CWD, which is bind-mounted from the
# runner-checkout. That file then survives the next dispatch's `git
# reset --hard` (untracked) and trips the post-gate dirty-check. Belt
# (this) and suspenders (`git clean -fd` in ensure_runner_checkout) keep
# the runner-checkout honest about *this* iteration's leakage.
ulimit -c 0

exec "$@"
