#!/usr/bin/env bash
# PreToolUse hook for AFK-dispatch sandboxes: deny backgrounded Bash.
#
# A headless `claude -p` dispatch is single-shot — there is no re-invocation.
# An agent that backgrounds a slow build/test (`run_in_background: true`) and
# then ends its turn to "wait for the result" terminates the session with the
# work uncommitted; the runner's dirty-checkout guard then aborts the issue
# and discards everything. Prompt guidance alone did not stop this (the model
# reliably chose to background and sign off anyway), so we remove the
# affordance: every Bash call must run in the foreground and the agent must
# stay in the loop until it commits.
#
# Reads the PreToolUse event JSON on stdin; emits a deny decision when the
# Bash call requests background execution, otherwise allows it through.
# grep-only (no jq dependency) so it works in any sandbox image.

set -u

input="$(cat)"

if printf '%s' "$input" | grep -qE '"run_in_background"[[:space:]]*:[[:space:]]*true'; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Background execution (run_in_background) is disabled in this AFK dispatch. This is a single-shot session with NO re-invocation: if you end your turn to wait on a backgrounded build/test, the session ends and your uncommitted work is discarded. Re-run this command in the FOREGROUND (omit run_in_background) and wait for it to finish in this same turn. If the build is slow, narrow its scope (build/test only the affected module) instead of backgrounding it."}}
JSON
  exit 0
fi

exit 0
