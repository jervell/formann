#!/usr/bin/env bash
# AFK runner.
#
# Usage:
#   run-the-queue.sh [--model <id>]                            # drain mode — every active feature
#   run-the-queue.sh [--model <id>] --feature <slug>           # loop mode — one feature
#   run-the-queue.sh [--model <id>] --issue <feature>/<NN>     # single-dispatch mode
#
# `--model <id>` overrides the model for every dispatch in the run (implement
# and each walk item). An unknown id is rejected by the CLI inside the
# container and surfaces as a normal dispatch failure. Without the flag,
# the CLI defaults apply and output is byte-identical to prior behavior.
#
# Bare invocation walks every feature returned by `tracker-snapshot --list`
# and drains the ones it's allowed to touch (per-feature gate decides).
# Features blocked by per-feature gates (fetch-failed, feature-snapshot-failed,
# queue-empty) produce a SUMMARY row and the run continues.
#
# Runs pre-flight invariants, dispatches `/implement <ref>` inside the sandbox
# container, classifies the outcome by `tracker-snapshot` delta, and on
# success propagates the runner-checkout's branch ref to host via
# `git fetch <runner-checkout> <branch>:<branch>` (no HEAD or working-tree
# side effects).
#
# Drain mode picks the next feature in discovery order each iteration; loop
# mode picks the next eligible issue per iteration via a fresh
# `tracker-snapshot` call, so issues unblocked mid-run by an earlier
# success become selectable without restarting.
#
# Stop reasons (drain mode):
#   - `completed`             — every discovery slug considered.
#   - `interrupted`           — Ctrl-C during the outer loop.
#   - `propagation-error`     — parking-ref publish failed inside a feature loop.
#   - `runaway-halt (<ref>)`  — post-implement step pushed issue back to eligible.
#   - `preflight-abort: discovery` — `tracker-snapshot --list` failed.
#
# Stop reasons (narrowed modes):
#   - `queue-empty` / `interrupted` / `snapshot-failed` / `propagation-error`.
#   - `runaway-halt (<ref>)`  — post-implement step pushed issue back to eligible.
#   - `feature-restricted (refused: <reason>)` (--feature).
#   - `single-dispatch (success|failure|refused: <reason>)` (--issue).
#
# Exit codes:
#   0  — drain completed / interrupted; single dispatch succeeded;
#         or loop drained / was interrupted (those treat the stop conditions
#         as 0).
#   1  — single dispatch failed (status didn't flip to in-review/done); or
#         loop mode aborted because tracker-snapshot crashed mid-loop
#         (`snapshot-failed`), a propagation error halted the loop
#         (`propagation-error`), or the runaway guard fired (`runaway-halt`).
#   2  — pre-flight failed; the line printed before exit names which
#         invariant tripped; or refusal (feature-restricted, single-dispatch
#         refused).
#
# The script is also sourceable; pure logic (`classify_outcome`,
# `next_eligible_ref`, `next_eligible_feature`, `classify_item_action`,
# `walk_post_implement_steps`, `format_multi_feature_summary_md`) is exposed
# for the bats suite. `main` only runs when the script is executed directly.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
# shellcheck source=validate-binding-env.sh
source "$HERE/validate-binding-env.sh"
# shellcheck source=resolve-manifest.sh
source "$HERE/resolve-manifest.sh"
# liveness.sh provides the liveness-line module (derive_phase,
# format_liveness_line, liveness_render_loop) and humanize_duration,
# which the progress-line formatters below also use.
# shellcheck source=liveness.sh
source "$HERE/liveness.sh"

# === Configuration =========================================================

# How long to wait for the in-flight container after SIGTERM before
# escalating to SIGKILL on Ctrl-C. Tuned to the larger of "any reasonable
# /implement teardown" and "noticeably less than the operator giving up
# and Ctrl-C-twice'ing".
RUNNER_KILL_GRACE_SECONDS=10

# Transport-crash retry policy. A ~4.5-minute Anthropic API blip (observed
# 2026-05-16) crashed four sequential dispatches. The 30+90+240=360s window
# comfortably covers the observed ~270s blip; the step sizes keep mid-blip
# waits short while the total budget stays bounded under 6 minutes. Four
# attempts total: initial + three retries spaced by the backoff schedule.
: "${RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS:=4}"
: "${RUNNER_TRANSPORT_RETRY_BACKOFFS:=30 90 240}"
# When set to 1, the wrapper short-circuits to a single attempt regardless of
# is_transport_crash's verdict — useful for testing and declared-outage
# situations where the operator wants to fail fast.
: "${RUNNER_DISABLE_TRANSPORT_RETRY:=0}"

# Window-exhausted retry policy (issue #75). An exhausted five-hour usage
# window is not a transport blip: the dispatch dies in ~400ms with a
# well-formed stream whose `rate_limit_event` carries `status:"rejected"`
# (and usually a `resetsAt` epoch), dressed as a 429 terminal result. Burning
# the bounded transport backoff against a quota that is hours from returning
# is pointless, so the runner sleeps until resetsAt + 60s slack (fixed, not
# configurable) and re-dispatches instead.
#
# RUNNER_WINDOW_RETRY_FALLBACK_WAIT — seconds to wait when the rejected
# event carries no resetsAt. RUNNER_WINDOW_RETRY_MAX_WAITS — window-waits
# allowed per dispatch before giving up with outcome `window-exhausted`.
: "${RUNNER_WINDOW_RETRY_FALLBACK_WAIT:=3600}"
: "${RUNNER_WINDOW_RETRY_MAX_WAITS:=2}"
# When set to 1, the rejected-event check is skipped entirely and a window-
# exhausted 429 degrades to the transport path exactly as before #75.
: "${RUNNER_DISABLE_WINDOW_RETRY:=0}"

# When set to 1, no liveness renderer is spawned — the dispatch runs exactly
# as on a detached terminal. Useful for testing and for operators who don't
# want the live line.
: "${RUNNER_DISABLE_LIVENESS:=0}"

# === Pure logic ============================================================
#
# These functions take JSON inputs and return string outputs. No I/O, no
# globals beyond their arguments. Exercised by tests/run-the-queue.bats.

# Classify a dispatch outcome by snapshot delta. Inputs:
#   $1 — pre-dispatch tracker-snapshot JSON
#   $2 — post-dispatch tracker-snapshot JSON
#   $3 — canonical issue ref (<feature>/<NN>)
#   $4 — transport-crash boolean (default: false); when true, emits
#         `dispatch-aborted` instead of `failure` on the non-success path.
#
# Output (stdout): exactly one of `success`, `failure`, or `dispatch-aborted`.
#
# Success requires the named ref's `status` to flip from `ready-for-agent`
# (pre) to either `in-review` or `done` (post). Anything else — including
# missing entries, unchanged status, or pre-status that wasn't
# `ready-for-agent` — is failure (or dispatch-aborted when $4=true).
classify_outcome() {
  local pre_json="$1" post_json="$2" ref="$3" transport_crash="${4:-false}"
  local pre_status post_status
  # `// empty` makes a missing entry render as the empty string rather
  # than literal "null"; we coerce both into "missing".
  pre_status="$(jq -r --arg r "$ref" \
    '(.issues[] | select(.ref == $r) | .status) // empty' <<<"$pre_json")"
  post_status="$(jq -r --arg r "$ref" \
    '(.issues[] | select(.ref == $r) | .status) // empty' <<<"$post_json")"

  if [ "$pre_status" != "ready-for-agent" ]; then
    echo "failure"
    return 0
  fi
  case "$post_status" in
    in-review|done) echo "success" ;;
    *)
      [ "$transport_crash" = "true" ] && echo "dispatch-aborted" || echo "failure"
      ;;
  esac
}

# Return the first eligible ref from a tracker-snapshot JSON. "Eligible"
# is whatever the snapshot's `eligible: true` flag says — tracker-snapshot
# already encodes the full rule (status == ready-for-agent, type == AFK,
# all blockers done, no parse error). Source order is the snapshot's
# array order, which tracker-snapshot emits sorted by filename. Output:
# the ref on stdout, or empty if no issue is eligible.
next_eligible_ref() {
  local snapshot_json="$1"
  jq -r 'first(.issues[] | select(.eligible == true) | .ref) // empty' \
    <<<"$snapshot_json"
}

# Classify the per-item control-flow action after a post-implement step runs.
# Inputs:
#   $1 — post-item status string (already extracted from the snapshot by the
#         caller; NOT a snapshot JSON blob)
#   $2 — Dispatch exit code
#
# Output (stdout): exactly one of `stop-success`, `continue`, `terminate-run`,
# or `fail`.
#
#   stop-success   — exit 0 AND status is done, wontfix, or empty (github-issues
#                    binding closes the work-item parent on done, so absence is
#                    the binding-native signal for done).
#   continue       — exit 0 AND status is in-review; proceed to the next step.
#   terminate-run  — exit 0 AND status is ready-for-agent (runaway: the step
#                    re-opened an eligible issue that the next loop iteration
#                    would re-dispatch).
#   fail           — nonzero exit, or exit 0 with any other status (including
#                    ready-for-human, needs-triage, needs-info, and unknown).
#
# No transport_crash input and no transport-flavoured verdict — transport vs
# technical abort-flag typing is the caller's concern.
#
# Pure logic — no I/O beyond stdin/stdout. Sourceable from bats.
classify_item_action() {
  local status="$1" exit_code="$2"

  if [ "$exit_code" != "0" ]; then
    echo "fail"
    return 0
  fi

  case "$status" in
    done|wontfix|"") echo "stop-success" ;;
    in-review)       echo "continue" ;;
    ready-for-agent) echo "terminate-run" ;;
    *)               echo "fail" ;;
  esac
}

# Extract the last complete `result` event line from a streamed-event artifact.
# Greps the candidate `"type":"result"` lines (cheap) and returns the last one
# that parses as JSON. Empty output when the stream is absent, empty, or carries
# no complete result event (e.g. a truncated tail). Fail-safe: any jq/grep
# failure degrades to empty, never an error that propagates.
#
# Pure — reads only the named file. Sourceable from bats.
_terminal_result_line() {
  local stream_file="$1"
  [ -s "$stream_file" ] || return 0
  local line last=""
  while IFS= read -r line; do
    if printf '%s' "$line" | jq -e '.type == "result"' >/dev/null 2>&1; then
      last="$line"
    fi
  done < <(grep -F '"type":"result"' "$stream_file" 2>/dev/null || true)
  printf '%s' "$last"
}

# Decide whether a dispatch is a transport-class crash to retry, from its stdout
# event stream and exit code (issue #71's locked two-rung contract; #70). stderr
# is never read — the spike proved it carries no transport signal.
#
# Rung 1 — the terminal `result` event's is_error / api_error_status:
#   is_error false                               → success (not a crash)
#   is_error true + status in {429} ∪ {500–599}  → transport crash → retry
#   is_error true + status null/absent           → connection-layer fault (DNS /
#                                                   connect / reset / timeout, no
#                                                   HTTP response) → retry
#   is_error true + any other status (4xx, …)    → genuine failure (not a crash)
# If the terminal result line is truncated and fails strict jq, a lenient
# byte-level extraction of the same two keys is attempted before Rung 2.
#
# Rung 2 — reached only when no result event is recoverable:
#   nonzero exit (incl. empty/whitespace stdout)  → conservative transport-suspect → retry
#   clean exit 0 with no parseable result         → indeterminate → defer (not a crash)
#
# Fail-safe by construction: every step degrades to the next on any parse/IO
# surprise; the final rung always yields a defined verdict, never an error that
# aborts the run. Returns 0 (crash → retry) or 1 (not a crash). Pure — reads
# only the stream file. Sourceable from bats.
is_transport_crash() {
  local stream_file="$1" exit_code="${2:-}"

  # Rung 1 — structured verdict from the terminal result event.
  local result_line
  result_line="$(_terminal_result_line "$stream_file")"
  if [ -n "$result_line" ]; then
    local is_error api_status
    is_error="$(printf '%s' "$result_line" | jq -r '.is_error' 2>/dev/null || true)"
    api_status="$(printf '%s' "$result_line" \
      | jq -r 'if has("api_error_status") then (.api_error_status | tostring) else "absent" end' \
      2>/dev/null || true)"
    case "$is_error" in
      false) return 1 ;;
      true)
        case "$api_status" in
          null|absent) return 0 ;;
          429)         return 0 ;;
          5[0-9][0-9]) return 0 ;;
          *)           return 1 ;;
        esac
        ;;
      # Neither true nor false → malformed; fall through to the lenient path.
    esac
  fi

  # Rung 1 (lenient) — a truncated final result line that failed strict jq.
  # Recover the same two keys by regex from the last result-ish line.
  local raw_line
  raw_line="$(grep -F '"type":"result"' "$stream_file" 2>/dev/null | tail -n 1 || true)"
  if [ -n "$raw_line" ]; then
    local lenient_err lenient_status
    lenient_err="$(printf '%s' "$raw_line" \
      | grep -oE '"is_error"[[:space:]]*:[[:space:]]*(true|false)' \
      | grep -oE 'true|false' | tail -n 1 || true)"
    if [ "$lenient_err" = "false" ]; then return 1; fi
    if [ "$lenient_err" = "true" ]; then
      if printf '%s' "$raw_line" | grep -qE '"api_error_status"[[:space:]]*:[[:space:]]*null'; then
        return 0
      fi
      lenient_status="$(printf '%s' "$raw_line" \
        | grep -oE '"api_error_status"[[:space:]]*:[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+' | tail -n 1 || true)"
      case "$lenient_status" in
        429|5[0-9][0-9]) return 0 ;;
        "")              return 0 ;;
        *)               return 1 ;;
      esac
    fi
  fi

  # Rung 2 — safety net (no recoverable result event).
  if [ -n "$exit_code" ] && [ "$exit_code" != "0" ]; then
    return 0
  fi
  return 1
}

# Extract the last parseable `rate_limit_event` line from a streamed-event
# artifact. `rate_limit_event` lines can be injected mid-NDJSON-line,
# corrupting adjacent lines (claude-code#49640) — unparseable candidates are
# skipped, in the same fail-safe style as `_terminal_result_line`. Empty
# output when the stream is absent, empty, or carries no parseable
# rate_limit_event.
#
# Pure — reads only the named file. Sourceable from bats.
_last_rate_limit_event_line() {
  local stream_file="$1"
  [ -s "$stream_file" ] || return 0
  local line last=""
  while IFS= read -r line; do
    if printf '%s' "$line" | jq -e '.type == "rate_limit_event"' >/dev/null 2>&1; then
      last="$line"
    fi
  done < <(grep -F '"type":"rate_limit_event"' "$stream_file" 2>/dev/null || true)
  printf '%s' "$last"
}

# Window-exhausted detection predicate (issue #75): the last parseable
# `rate_limit_event` in the dispatch's stdout stream has `status:"rejected"`.
# Any rateLimitType qualifies. Detection never keys on assistant/result text —
# the human-readable wording varies across CLI versions; only the structured
# event is stable. Returns 0 (window exhausted) or 1. Fail-safe: any parse
# surprise degrades to 1 (not exhausted), never an error that aborts a run.
#
# Pure — reads only the stream file. Sourceable from bats.
is_window_exhausted() {
  local stream_file="$1"
  local ev
  ev="$(_last_rate_limit_event_line "$stream_file")"
  [ -n "$ev" ] || return 1
  [ "$(printf '%s' "$ev" | jq -r '.rate_limit_info.status // empty' 2>/dev/null || true)" = "rejected" ]
}

# Extract `resetsAt` (epoch seconds) from the stream's last parseable
# rate_limit_event. Empty when the event or the field is absent or
# non-numeric. Pure — reads only the stream file. Sourceable from bats.
window_resets_at() {
  local stream_file="$1"
  local ev v
  ev="$(_last_rate_limit_event_line "$stream_file")"
  [ -n "$ev" ] || return 0
  v="$(printf '%s' "$ev" | jq -r '.rate_limit_info.resetsAt // empty' 2>/dev/null || true)"
  case "$v" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s' "$v"
}

# rateLimitType label from the stream's last parseable rate_limit_event, for
# the wait-start progress line. "unknown" when absent. Pure. Sourceable.
window_rate_limit_type() {
  local stream_file="$1"
  local ev
  ev="$(_last_rate_limit_event_line "$stream_file")"
  if [ -z "$ev" ]; then
    echo "unknown"
    return 0
  fi
  printf '%s' "$ev" | jq -r '.rate_limit_info.rateLimitType // "unknown"' 2>/dev/null \
    || echo "unknown"
}

# Seconds to wait before re-dispatching after a window rejection: the time
# until resetsAt plus a fixed 60s slack. A resetsAt at-or-before now degrades
# to the bare 60s slack — no special case. Args: $1=resetsAt $2=now (both
# epoch seconds). Pure. Sourceable from bats.
window_wait_seconds() {
  local resets_at="$1" now="$2"
  local delta=$(( resets_at - now ))
  [ "$delta" -lt 0 ] && delta=0
  echo $(( delta + 60 ))
}

# Extract the agent's closing message from a streamed-event artifact, for the
# per-dispatch readable summary (issue #71). Prints the terminal `result`
# event's `.result` text. When no result event is recoverable (truncated /
# empty / crashed stream), prints a short placeholder naming the condition so
# the skim file is never silently empty. Fail-safe: always returns 0.
#
# Pure — reads only the named file. Sourceable from bats.
extract_result_summary() {
  local stream_file="$1"
  local result_line result_text
  result_line="$(_terminal_result_line "$stream_file")"
  if [ -n "$result_line" ]; then
    result_text="$(printf '%s' "$result_line" | jq -r '.result // empty' 2>/dev/null || true)"
    if [ -n "$result_text" ]; then
      printf '%s\n' "$result_text"
      return 0
    fi
  fi
  printf '(no result event in the dispatch stream — no closing message; see the .stderr.log sibling for diagnostics)\n'
  return 0
}

# Pre-dispatch sync-base selector. Pure function — takes a pre-computed
# parking-ref relation and returns which tip the runner-checkout should sync
# to before each dispatch.
#
# Input:
#   $1 — parking_rel: absent | equal | ahead | behind | diverged
#          absent   — parking ref doesn't exist yet (no prior runner output)
#          equal    — parking ref tip equals host's branch tip
#          ahead    — parking ref tip is strictly ahead of host's branch tip
#          behind   — host's branch tip is strictly ahead of parking ref tip
#          diverged — neither tip is an ancestor of the other
#
# Output (stdout): host-branch | parking-ref
#
# Rules: absent → host-branch; equal → host-branch; ahead → parking-ref;
#        behind → host-branch; diverged → parking-ref.
# Rationale for diverged → parking-ref: the runner's chain is authoritative;
# the maintainer reconciles via `git pull runner <feature>`.
select_sync_base() {
  local parking_rel="${1:-}"
  case "$parking_rel" in
    absent|equal|behind) echo "host-branch" ;;
    ahead|diverged)      echo "parking-ref" ;;
    *)
      echo "runner: select_sync_base: unknown relation '$parking_rel'" >&2
      return 1
      ;;
  esac
}

# Select the next feature the outer drain loop should consider. Analogue
# of `next_eligible_ref` at the feature level. Pure function — bats
# coverage exercises both modes exhaustively.
#
# Inputs:
#   $1 — discovery JSON array (`["alpha","beta",…]`).
#   $2 — newline-delimited slugs already considered in this run (drain mode
#        excludes them so each feature is visited once).
#   $3 — narrow_to: empty for drain mode; a slug for `--feature` / `--issue`.
#
# Output (stdout): the next slug to consider, or empty when nothing remains.
#
# Drain mode (narrow_to empty): the first discovery slug not in considered.
# Narrow mode (narrow_to set): the narrowed slug iff it appears in discovery
# AND is not in considered; empty otherwise.
next_eligible_feature() {
  local discovery_json="$1" considered="$2" narrow_to="$3"

  if [ -n "$narrow_to" ]; then
    # Narrow mode — pick narrow_to iff present in discovery and not considered.
    if ! jq -e --arg s "$narrow_to" 'any(.[]; . == $s)' >/dev/null 2>&1 <<<"$discovery_json"; then
      return 0
    fi
    if printf '%s\n' "$considered" | grep -Fxq -- "$narrow_to"; then
      return 0
    fi
    printf '%s\n' "$narrow_to"
    return 0
  fi

  # Drain mode — first discovery slug not in considered. Iterate discovery
  # explicitly (not via jq's set ops) to preserve the binding's emitted
  # ordering: the SUMMARY narrative must match discovery.json order, and a
  # set-difference would silently re-sort on some jq versions.
  local slug
  while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    if printf '%s\n' "$considered" | grep -Fxq -- "$slug"; then
      continue
    fi
    printf '%s\n' "$slug"
    return 0
  done < <(jq -r '.[]' <<<"$discovery_json")
}

# Look up the binding-native ref for a (feature, N) pair by indexing into a
# snapshot's issues array. Returns the ref on stdout. Fails loudly (non-zero
# + stderr message) if (feature, N) is not present in the snapshot.
#
# Args: $1=feature  $2=nn  $3=snapshot_json
#
# Why index by nn rather than constructing the ref from parts: the binding-
# native ref shape varies by binding (local-markdown: `<feature>/NN`;
# github-issues: `#N`). The snapshot's `nn` field is the binding-agnostic
# numeric key; this function is the single place where nn → native ref
# resolution lives.
binding_native_ref() {
  local feature="$1" nn="$2" snapshot_json="$3"
  local ref
  ref="$(jq -r --arg n "$nn" \
    'first(.issues[] | select((.nn | tonumber) == ($n | tonumber)) | .ref) // empty' <<<"$snapshot_json")"
  if [ -z "$ref" ]; then
    echo "runner: binding_native_ref: ($feature, $nn) not found in snapshot" >&2
    return 1
  fi
  printf '%s\n' "$ref"
}

# === Helpers ===============================================================

now_ts() { date +"%Y%m%d-%H%M%S"; }
now_clock() { date +"%H:%M:%S"; }

# HH:MM:SS local clock for an epoch timestamp. BSD date takes `-r <epoch>`;
# GNU date treats `-r` as a file reference and needs `-d @<epoch>` — try BSD
# first, fall back to GNU.
epoch_clock() {
  local epoch="$1"
  date -r "$epoch" +"%H:%M:%S" 2>/dev/null || date -d "@$epoch" +"%H:%M:%S"
}

# === Output formatters (pure) ==============================================
#
# These take inputs and emit text — no I/O beyond stdin/stdout, no globals.
# Exercised by tests/run-the-queue.bats; pinned by AC because the operator
# reads them live during a run and again after the fact in SUMMARY.md.
#
# Each iteration emits per-stage progress lines. AFK iterations produce
# two lines per walk item (starting/outcome) plus two for implement.
# HITL iterations produce two (implement only — walk is skipped). When a
# parking-ref publish fails after a stage, a follow-up `halt → <recorded
# outcome>` line is emitted so the operator's terminal record matches
# the SUMMARY.md row.
#
# Stage names: `implement` for the /implement dispatch; each walk-item
# dispatch uses that item's manifest label (e.g. `review`).
#
# Outcome label vocabulary by stage:
#   implement:   in-review | done | dispatch-aborted | window-exhausted | FAIL | halt → FAIL
#   <item-label>: clean → done | left-for-human | review-aborted | window-exhausted | gate-failed | halt → gate-failed | halt → runaway
#
# Combined per-iteration outcome (used in the end-of-run table and
# SUMMARY.md row): `done | left-for-human | gate-failed | review-aborted | dispatch-aborted | window-exhausted | in-review | FAIL | halt → runaway`.
#   done             — AFK + walk item reached done/wontfix/absent (stop-success)
#   left-for-human   — AFK + walk exhausted, issue still at in-review (no abort flag)
#   gate-failed      — AFK + item dispatch errored or off-mission
#   review-aborted   — AFK + item subprocess transport-crashed (empty/5xx/429/network log)
#   dispatch-aborted — implement subprocess transport-crashed
#   window-exhausted — dispatch (implement or item) still usage-window-rejected after
#                      RUNNER_WINDOW_RETRY_MAX_WAITS window-waits (quota structurally
#                      insufficient, not a blip; the abort flag's dispatch: field
#                      names the stage)
#   in-review        — interrupt between implement and walk start (walk not run)
#   FAIL             — implement-stage failure (classifier, propagation, container)
#   halt → runaway   — AFK + post-implement step pushed issue back to ready-for-agent (run halted)

# Progress-line "starting" form: emitted at the start of a stage.
format_progress_start() {
  local clock="$1" ref="$2" stage="$3"
  printf '[%s] %s %s → starting\n' "$clock" "$ref" "$stage"
}

# Progress-line outcome form: emitted at the end of a stage with its duration.
format_progress_outcome() {
  local clock="$1" ref="$2" stage="$3" label="$4" duration="$5"
  printf '[%s] %s %s → %s (%s)\n' "$clock" "$ref" "$stage" "$label" "$(humanize_duration "$duration")"
}

# Window-wait progress lines (issue #75). Two static lines per wait — no
# heartbeat, no liveness renderer during the wait. Mirrored into runner.log
# by the existing tee capture, like every other progress line.

# Wait-start form when the rejected event carried a resetsAt: absolute
# deadline clock, humanized wait length, and `wait N of M`.
format_window_wait_line() {
  local clock="$1" rl_type="$2" deadline_clock="$3" wait_seconds="$4" wait_n="$5" max_waits="$6"
  printf '[%s] runner: usage window exhausted (%s) — waiting until %s (%s; wait %s of %s)\n' \
    "$clock" "$rl_type" "$deadline_clock" "$(humanize_duration "$wait_seconds")" \
    "$wait_n" "$max_waits"
}

# Wait-start form when the rejected event carried no resetsAt: names the
# fallback so the operator can tell a guessed wait from a known deadline.
format_window_wait_fallback_line() {
  local clock="$1" rl_type="$2" wait_seconds="$3" wait_n="$4" max_waits="$5"
  printf '[%s] runner: usage window exhausted (%s) — resetsAt absent; waiting %ss (fallback; wait %s of %s)\n' \
    "$clock" "$rl_type" "$wait_seconds" "$wait_n" "$max_waits"
}

# Resume form: emitted right before the post-wait re-dispatch.
format_window_resume_line() {
  printf '[%s] runner: usage window reset — retrying dispatch\n' "$1"
}

# Give-up form for the checkout-advance guard (issue #76): emitted instead
# of a wait-start line when the runner-checkout HEAD advanced during a
# window-exhausted round, so runner.log explains why no wait happened.
format_window_giveup_line() {
  local clock="$1" rl_type="$2"
  printf '[%s] runner: usage window exhausted (%s) — runner-checkout HEAD advanced; giving up without waiting\n' \
    "$clock" "$rl_type"
}

# End-of-run table. Reads `feature|nn|ref|outcome|duration|review_present|attempt_count|propagation`
# records on stdin (one per line — fields past `outcome` are optional and
# `review_present` is unused here). Emits a header row, one row per record,
# and a trailing `stop reason: <reason>` line. The `issue` column shows the
# binding-native `ref`; `feature` and `nn` are ignored for this view. Column
# widths size to the longest entry, bounded below by the header label widths.
# The `propagation` column shows `propagated → host`, `parked → runner/<f>`,
# or `-` when propagation was not reached.
format_end_of_run_table() {
  local stop_reason="$1"
  # `length()` returns bytes on byte-mode awk (BSD awk in non-UTF-8 locales,
  # mawk, busybox awk) and code points on UTF-8-aware awk (gawk in a UTF-8
  # locale). The propagation column contains "→" (3 bytes / 1 code point),
  # so the column padding must measure display width, not bytes, or the
  # header and data rows end at different visual columns on byte-mode awk.
  # We probe `length("→")` at startup to derive the per-arrow byte
  # overhead and apply it to every cell measurement and pad calculation.
  awk -v stop="$stop_reason" '
    BEGIN {
      FS="|"
      arrow_overhead = length("→") - 1
      max_ref=length("issue"); max_out=length("outcome")
      max_dur=length("duration"); max_prop=length("propagation")
    }
    function humanize_dur(s,    h,m,r) {
      s = int(s)
      if (s < 60)   { return s "s" }
      if (s < 3600) { m = int(s/60); r = s % 60; return m "m " r "s" }
      h = int(s/3600); m = int((s % 3600) / 60); return h "h " m "m"
    }
    function display_len(s,    n) {
      # gsub returns the replacement count; on byte-mode awk each → costs
      # arrow_overhead (2) extra bytes vs its 1-column display width.
      n = gsub(/→/, "→", s)
      return length(s) - n * arrow_overhead
    }
    function pad_right(s, w,    pad) {
      pad = w - display_len(s)
      if (pad > 0) return s sprintf("%*s", pad, "")
      return s
    }
    NF >= 5 {
      n++
      refs[n]=$3; outs[n]=$4; durs[n]=humanize_dur($5)
      props[n]=(NF >= 8 && $8 != "") ? $8 : "-"
      if (display_len(refs[n])  > max_ref)  max_ref  = display_len(refs[n])
      if (display_len(outs[n])  > max_out)  max_out  = display_len(outs[n])
      if (display_len(durs[n])  > max_dur)  max_dur  = display_len(durs[n])
      if (display_len(props[n]) > max_prop) max_prop = display_len(props[n])
    }
    END {
      printf "%s  %s  %s  %s\n", \
        pad_right("issue", max_ref), pad_right("outcome", max_out), \
        pad_right("duration", max_dur), pad_right("propagation", max_prop)
      for (i = 1; i <= n; i++) {
        printf "%s  %s  %s  %s\n", \
          pad_right(refs[i], max_ref), pad_right(outs[i], max_out), \
          pad_right(durs[i], max_dur), pad_right(props[i], max_prop)
      }
      printf "stop reason: %s\n", stop
    }
  '
}

# SUMMARY.md content for a normal run (loop drained or interrupted).
# Reads `feature|nn|ref|outcome|duration|step_logs|attempt_count|propagation`
# records on stdin (fields past `outcome` are optional — when `step_logs` is
# non-empty, the row's logs cell adds `<NN>-<suffix>.summary.md` links alongside
# `<NN>.summary.md` for each colon-separated suffix in `step_logs` (e.g.
# `01-review`, `01-review-and-gate:02-fix:03-review-and-gate`);
# `propagation` is the indicator string from `propagate_feature` —
# `propagated → host`, `parked → runner/<branch>`, or empty). The
# `propagation` column shows the indicator verbatim, or `-` when empty.
# An end-of-run "## Unpulled parked work" section follows the table whenever
# any dispatch parked; it is omitted entirely when no dispatch parked.
# `end_state` is the verb used in the run line — "ended" or "interrupted".
# Optional $7 = model id (when set, appended to the run line as ", model: <id>").
format_summary_md() {
  local feature="$1" ts="$2" start_clock="$3" end_clock="$4" end_state="$5" stop_reason="$6" \
        model="${7:-}"
  # Capture once so the table awk and the parked-work aggregator both see the
  # same records without the caller having to materialize them twice.
  local records
  records="$(cat)"
  printf '# AFK runner — %s\n\n' "$feature"
  if [ -n "$model" ]; then
    printf -- '- Run: %s (started %s, %s %s, model: %s)\n' "$ts" "$start_clock" "$end_state" "$end_clock" "$model"
  else
    printf -- '- Run: %s (started %s, %s %s)\n' "$ts" "$start_clock" "$end_state" "$end_clock"
  fi
  printf -- '- Stop reason: %s\n\n' "$stop_reason"
  printf '| issue | outcome | duration | propagation | logs |\n'
  printf '|-------|---------|----------|-------------|------|\n'
  printf '%s' "$records" | awk -F'|' '
    function humanize_dur(s,    h,m,r) {
      s = int(s)
      if (s < 60)   { return s "s" }
      if (s < 3600) { m = int(s/60); r = s % 60; return m "m " r "s" }
      h = int(s/3600); m = int((s % 3600) / 60); return h "h " m "m"
    }
    NF >= 5 {
      nn=$2; ref=$3; out=$4; dur=$5;
      review=(NF >= 6 ? $6 : "");
      attempt_count=(NF >= 7 ? $7+0 : 1);
      prop=(NF >= 8 && $8 != "") ? $8 : "-";
      if (attempt_count > 1) { out = out " (" attempt_count " attempts)" }
      logs = sprintf("[%s.summary.md](%s.summary.md)", nn, nn);
      if (review != "") {
        nsteps = split(review, rsteps, ":");
        for (si = 1; si <= nsteps; si++) {
          logs = logs " [" nn "-" rsteps[si] ".summary.md](" nn "-" rsteps[si] ".summary.md)";
        }
      }
      printf "| %s | %s | %s | %s | %s |\n", ref, out, humanize_dur(dur), prop, logs;
    }'
  printf '%s' "$records" | format_parked_ledger
}

# SUMMARY.md content for a multi-feature drain run (bare invocation).
# Renders per-feature sections: drained features carry a nested per-issue
# table (same row shape as the single-feature SUMMARY); skipped features
# render a one-line section with the reason; the special
# `feature-snapshot-failed` outcome renders without the `skipped:` prefix
# (it is a recoverable mid-run failure, not a structural skip).
#
# Input lines (one record per line) — encounter order is preserved:
#   F|<feature>|drained
#   F|<feature>|skipped:<reason>
#   F|<feature>|feature-snapshot-failed
#   I|<feature>|<nn>|<ref>|<outcome>|<duration>|<review_present>|<attempt_count>|<propagation>
#
# `I` rows belong to the most recent preceding `F|<slug>|drained` section.
# `step_logs` is a colon-separated list of walk-step log suffixes (e.g. `01-review`)
# alongside `<ref>.summary.md`. `propagation` is the indicator string from
# `propagate_feature` — `propagated → host`, `parked → runner/<branch>`,
# or empty. Summary paths in multi-feature mode embed the feature segment of the
# ref (`<feature>/<NN>.summary.md`) so per-issue artifacts don't collide across
# features that share `<NN>`. The `propagation` column shows the indicator
# verbatim, or `-` when empty; an end-of-run "## Unpulled parked work"
# section follows when any dispatch parked, and is omitted entirely when no
# dispatch parked.
# Optional $6 = model id (when set, appended to the run line as ", model: <id>").
format_multi_feature_summary_md() {
  local ts="$1" start_clock="$2" end_clock="$3" end_state="$4" stop_reason="$5" \
        model="${6:-}"
  # Capture once so the per-feature renderer and `format_parked_ledger` both
  # see the same records.
  local records
  records="$(cat)"
  printf '# AFK runner — multi-feature drain\n\n'
  if [ -n "$model" ]; then
    printf -- '- Run: %s (started %s, %s %s, model: %s)\n' "$ts" "$start_clock" "$end_state" "$end_clock" "$model"
  else
    printf -- '- Run: %s (started %s, %s %s)\n' "$ts" "$start_clock" "$end_state" "$end_clock"
  fi
  printf -- '- Stop reason: %s\n\n' "$stop_reason"
  printf '%s' "$records" | awk -F'|' '
    function humanize_dur(s,    h,m,r) {
      s = int(s)
      if (s < 60)   { return s "s" }
      if (s < 3600) { m = int(s/60); r = s % 60; return m "m " r "s" }
      h = int(s/3600); m = int((s % 3600) / 60); return h "h " m "m"
    }
    function emit_table_header() {
      printf "| issue | outcome | duration | propagation | logs |\n";
      printf "|-------|---------|----------|-------------|------|\n";
    }
    function close_drained_section() {
      if (in_drained) {
        printf "\n";
        in_drained = 0;
        in_table = 0;
      }
    }
    NF >= 3 && $1 == "F" {
      close_drained_section();
      feature=$2; outcome=$3;
      if (outcome == "drained") {
        printf "## %s — drained\n\n", feature;
        emit_table_header();
        in_drained = 1;
        in_table = 1;
      }
      else if (outcome == "feature-snapshot-failed") {
        printf "## %s — feature-snapshot-failed\n\n", feature;
      }
      else if (substr(outcome, 1, 5) == "skip:") {
        reason = substr(outcome, 6);
        printf "## %s — skipped: %s\n\n", feature, reason;
      }
      else if (substr(outcome, 1, 8) == "skipped:") {
        # Tolerate already-formatted `skipped:<reason>` records for
        # callers that hand-roll the input.
        reason = substr(outcome, 9);
        printf "## %s — skipped: %s\n\n", feature, reason;
      }
      next;
    }
    NF >= 6 && $1 == "I" && in_table {
      feature=$2; nn=$3; ref=$4; out=$5; dur=$6;
      review=(NF >= 7 ? $7 : "");
      attempt_count=(NF >= 8 ? $8+0 : 1);
      prop=(NF >= 9 && $9 != "") ? $9 : "-";
      if (attempt_count > 1) { out = out " (" attempt_count " attempts)" }
      logs = sprintf("[%s/%s.summary.md](%s/%s.summary.md)", feature, nn, feature, nn);
      if (review != "") {
        nsteps = split(review, rsteps, ":");
        for (si = 1; si <= nsteps; si++) {
          logs = logs " [" feature "/" nn "-" rsteps[si] ".summary.md](" feature "/" nn "-" rsteps[si] ".summary.md)";
        }
      }
      printf "| %s | %s | %s | %s | %s |\n", ref, out, humanize_dur(dur), prop, logs;
      next;
    }
    END {
      if (in_drained) printf "\n";
    }'
  # Drop the `I|` discriminator so the leftover line shape matches
  # `format_parked_ledger`'s flat record schema (feature in $1, propagation in $8).
  printf '%s' "$records" | sed -n 's/^I|//p' | format_parked_ledger
}

# Pure aggregator for the parked-work ledger. Reads dispatch records
# (`feature|nn|ref|label|duration|review_present|attempt_count|propagation`)
# on stdin and emits the "## Unpulled parked work" SUMMARY.md section when
# one or more dispatches have `propagation == parked`. Emits nothing when no
# dispatch parked. Groups by feature; counts per-feature parked dispatches.
# Called by `format_summary_md` and `format_multi_feature_summary_md` so the
# end-of-run section's shape lives in exactly one place.
#
# Output (when parked dispatches exist):
#   ## Unpulled parked work
#
#   - **<feature>** (<N> dispatch[es]): `git pull runner <feature>`
#   …one line per feature with at least one parked dispatch…
format_parked_ledger() {
  awk -F'|' '
    NF >= 8 && $8 ~ /^parked/ {
      if (!(($1) in parked)) { order[++n] = $1 }
      parked[$1]++
    }
    END {
      if (n == 0) exit 0;
      printf "\n## Unpulled parked work\n\n";
      for (i = 1; i <= n; i++) {
        f = order[i];
        count = parked[f];
        suffix = (count == 1) ? "dispatch" : "dispatches";
        printf "- **%s** (%d %s): `git pull runner %s`\n", f, count, suffix, f;
      }
    }
  '
}

# SUMMARY.md content for a pre-flight abort. Replaces the per-issue
# table with a single line naming the failing invariant.
format_preflight_summary_md() {
  local feature="$1" ts="$2" start_clock="$3" abort_clock="$4" invariant="$5"
  if [ -z "$feature" ]; then
    feature="(undetermined)"
  fi
  printf '# AFK runner — %s\n\n' "$feature"
  printf -- '- Run: %s (started %s, aborted %s)\n' "$ts" "$start_clock" "$abort_clock"
  printf -- '- Stop reason: preflight-abort: %s\n\n' "$invariant"
  printf 'Pre-flight invariant `%s` failed before the loop began. See `runner.log` for details.\n' "$invariant"
}

# Emits the "## Swept parking refs" SUMMARY.md section when RUN_SWEPT_REFS
# is non-empty. Omitted entirely when no parking refs were swept. Appended
# by finalize_run after the main SUMMARY.md body.
format_swept_refs_section() {
  if [ "${#RUN_SWEPT_REFS[@]}" -eq 0 ]; then
    return 0
  fi
  printf '\n## Swept parking refs\n\n'
  local ref
  for ref in "${RUN_SWEPT_REFS[@]}"; do
    printf -- '- `%s`\n' "$ref"
  done
}

# Print to stderr with a single-line "runner: <invariant>: <message>" prefix
# so failures are unambiguous and grep-friendly. Always exits non-zero.
# Also captures the invariant name into RUN_PREFLIGHT_INVARIANT so the
# EXIT trap (`finalize_run`) can write a SUMMARY.md naming the failure.
fail_invariant() {
  local invariant="$1"
  shift
  RUN_PREFLIGHT_INVARIANT="$invariant"
  echo "runner: $invariant: $*" >&2
  exit 2
}

# Write (or overwrite) the runner-private abort flag for a (feature, nn) pair.
# Written on any dispatch failure that leaves the ref stuck — i.e., where the
# next iteration's eligibility filter would otherwise re-pick it (implement
# failure with status still eligible) or where a unified "stuck" surface is
# useful to the maintainer even when the snapshot already excludes it
# (gate-failed). Overwrites on repeat so the file always reflects the most
# recent failure.
#
# The maintainer removes the flag with `rm` to re-include the ref.
# Flag format (plain text, no parser needed):
#   type: technical|transport|window
#   dispatch: implement|<item-label>
#   at: <ISO-8601 UTC>
#   exit: <container exit code>
#   log: <repo-relative path to dispatch log>
#
# `type` distinguishes transport-class failures (API 5xx/429, network errors,
# empty log) and window-exhausted failures (usage window still rejected after
# the window-wait budget — the quota is structurally insufficient, not a blip
# to `rm` and re-run) from genuine technical failures (model error, bad
# brief, etc.).
#
# Args: $1=feature  $2=nn  $3=dispatch(implement|<item-label>)  $4=exit_code  $5=log_file
#       [$6=type (default: technical)]
write_abort_flag() {
  local feature="$1" nn="$2" dispatch="$3" exit_code="$4" log_file="$5" \
        flag_type="${6:-technical}"
  [[ "$RUNNER_INTERRUPTED" -eq 1 ]] && return 0
  local abort_feature_dir="$HOST_ABORT_DIR/$feature"
  mkdir -p "$abort_feature_dir"
  local at rel_log
  at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  rel_log="${log_file#$HOST_REPO/}"
  printf 'type: %s\ndispatch: %s\nat: %s\nexit: %s\nlog: %s\n' \
    "$flag_type" "$dispatch" "$at" "$exit_code" "$rel_log" >"$abort_feature_dir/$nn"
}

# === Per-run state =========================================================
#
# Globals describing the in-flight run. Set early (so even pre-flight
# aborts have a per-run dir to land SUMMARY.md and runner.log in) and
# read by `finalize_run` on EXIT.
#
# `RUN_DISPATCHES` is an indexed array of `feature|nn|ref|outcome|duration`
# strings (bash 3.2 friendly). `record_dispatch` appends;
# `print_dispatch_records` emits them on stdout for the formatters.

RUN_TS=""
RUN_DIR=""
RUN_START_CLOCK=""
RUN_FEATURE=""
RUN_STOP_REASON=""
RUN_PREFLIGHT_INVARIANT=""
RUN_DISPATCHES=()
# Per-feature outcome records for drain mode (bash 3.2 friendly array of
# `feature|outcome` strings, in encounter order). `outcome` is one of
# `drained`, `skip:<reason>`, `feature-snapshot-failed` (see the gate
# evaluator). Single-feature / single-issue modes don't populate this.
RUN_FEATURE_OUTCOMES=()
# Per-issue artifact layout. `flat` (default — single-feature / single-issue
# modes) writes <run-dir>/<NN>.{stdout.jsonl,stderr.log,summary.md,exit};
# `nested` (drain mode) writes <run-dir>/<feature>/<NN>.* so per-issue artifacts
# don't collide when multiple features share an <NN>. dispatch_one reads this.
RUN_LOG_LAYOUT="flat"
RUNNER_TEE_PID=""
RUNNER_LOG_FIFO=""
RUNNER_LAST_PROPAGATION=""   # 'propagated → host' | 'parked → runner/<branch>' | '' (set by propagate_feature)
RUN_SWEPT_REFS=()     # parking refs deleted by sweep_stale_parking_refs; populated before dispatch
DISCOVERY_JSON=""     # populated by check_discovery pre-flight invariant
RESOLVED_MANIFEST=""  # populated by check_manifest pre-flight invariant; tab-delimited label<TAB>path pairs

# Set RUN_TS / RUN_DIR / RUN_START_CLOCK and create the per-run dir under
# `<host>/.runner-state/runs/<ts>/`. Idempotent within a run; no-op if
# already set.
setup_run_dir() {
  if [ -n "$RUN_DIR" ]; then return 0; fi
  RUN_TS="$(now_ts)"
  RUN_START_CLOCK="$(now_clock)"
  RUN_DIR="$HOST_RUNS/$RUN_TS"
  mkdir -p "$RUN_DIR"
}

# Redirect the runner's own stdout/stderr through `tee` into
# `<run-dir>/runner.log`. After this returns, every line the script
# emits — pre-flight diagnostics, progress lines, end-of-run table, EXIT
# trap output — is captured to disk while still being visible on the
# operator's terminal.
#
# Implementation uses a named fifo + backgrounded tee rather than the
# simpler `exec > >(tee …) 2>&1`. The reason is flush ordering: with a
# process substitution, bash never `wait`s on the tee child, so when
# the script exits the kernel may reap tee before it has written its
# last buffered bytes — an operator who `cat`s runner.log right after
# the runner returns sees a truncated tail (typically the end-of-run
# table from `finalize_run`). Capturing tee's PID up front lets
# `stop_runner_log_capture` close the pipe and `wait` for tee to drain
# before the script exits. Bash 3.2 doesn't reliably set `$!` after
# process substitution, so we stage the fifo explicitly.
start_runner_log_capture() {
  RUNNER_LOG_FIFO="$RUN_DIR/.runner.log.fifo"
  rm -f "$RUNNER_LOG_FIFO"
  mkfifo "$RUNNER_LOG_FIFO"
  # tee inherits the original stdout (the operator's terminal) before
  # the redirect below takes effect, so it keeps mirroring there while
  # also writing to runner.log.
  tee "$RUN_DIR/runner.log" <"$RUNNER_LOG_FIFO" &
  RUNNER_TEE_PID=$!
  exec >"$RUNNER_LOG_FIFO" 2>&1
}

# Counterpart to `start_runner_log_capture`. Closes the script's
# stdout/stderr (signalling EOF to tee), waits for tee to flush its
# buffered output to runner.log, and removes the fifo. No-op if capture
# was never started (so tests that source the script aren't affected).
# Called as the last step of `finalize_run`, after every other write.
stop_runner_log_capture() {
  if [ -z "${RUNNER_TEE_PID:-}" ]; then return 0; fi
  exec >&- 2>&-
  wait "$RUNNER_TEE_PID" 2>/dev/null || true
  rm -f "$RUNNER_LOG_FIFO"
  RUNNER_TEE_PID=""
  RUNNER_LOG_FIFO=""
}

# Append a `feature|nn|ref|label|duration|step_logs|attempt_count|propagation`
# record to RUN_DISPATCHES. `label` is the iteration's combined outcome — one of
# `done | left-for-human | gate-failed | review-aborted | dispatch-aborted | in-review | FAIL | halt → runaway`.
# `step_logs` is a colon-separated list of walk-step log suffixes produced by
# `walk_post_implement_steps` (e.g. `01-review` for a single "review" step;
# `01-review-and-gate:02-fix:03-review-and-gate` for an unrolled iterate
# manifest). Empty when no post-implement steps ran (implement-only run or
# interrupted before the walk). Formatters split on `:` to generate per-step
# summary links (`<NN>-<suffix>.summary.md`) alongside `<NN>.summary.md` in the SUMMARY table.
# `attempt_count` (default 1) is the data hook for the retry slice; the
# formatters render `(N attempts)` only when N > 1, so it is silent here.
# `propagation` is the value of $RUNNER_LAST_PROPAGATION at record time —
# `propagated → host`, `parked → runner/<branch>`, or empty when propagation
# was not reached.
record_dispatch() {
  local feature="$1" nn="$2" ref="$3" label="$4" duration="$5" review="${6:-}" \
        attempt_count="${7:-1}"
  RUN_DISPATCHES+=("$feature|$nn|$ref|$label|$duration|$review|$attempt_count|${RUNNER_LAST_PROPAGATION}")
}

# Emit RUN_DISPATCHES records on stdout (one per line) for the table /
# Markdown formatters to consume.
print_dispatch_records() {
  local rec
  if [ "${#RUN_DISPATCHES[@]}" -eq 0 ]; then return 0; fi
  for rec in "${RUN_DISPATCHES[@]}"; do
    printf '%s\n' "$rec"
  done
}

# Append a per-feature outcome record (drain mode). `outcome` is one of
# `drained`, `skip:<reason>`, or `feature-snapshot-failed`.
record_feature_outcome() {
  local feature="$1" outcome="$2"
  RUN_FEATURE_OUTCOMES+=("$feature|$outcome")
}

# Emit the interleaved F/I record stream that `format_multi_feature_summary_md`
# consumes. Walks per-feature outcomes in encounter order; for each drained
# feature, appends the matching `RUN_DISPATCHES` rows (those whose ref's
# feature segment equals the feature). Skipped / feature-snapshot-failed
# features contribute only the F record.
print_multi_feature_records() {
  if [ "${#RUN_FEATURE_OUTCOMES[@]}" -eq 0 ]; then return 0; fi
  local rec feature outcome
  for rec in "${RUN_FEATURE_OUTCOMES[@]}"; do
    feature="${rec%%|*}"
    outcome="${rec#*|}"
    printf 'F|%s|%s\n' "$feature" "$outcome"
    if [ "$outcome" = "drained" ] && [ "${#RUN_DISPATCHES[@]}" -gt 0 ]; then
      local d_rec d_feature
      for d_rec in "${RUN_DISPATCHES[@]}"; do
        d_feature="${d_rec%%|*}"
        if [ "$d_feature" = "$feature" ]; then
          printf 'I|%s\n' "$d_rec"
        fi
      done
    fi
  done
}

# EXIT trap. Writes the per-run SUMMARY.md (pre-flight or normal variant)
# and prints the end-of-run table on stdout (which `tee` mirrors into
# runner.log). Always releases the pidfile lock. Preserves the original
# exit status — `set -e` aborts shouldn't be masked by this routine.
finalize_run() {
  local rc=$?
  set +e
  trap - EXIT

  # Defensive reap: on any exit path that bypassed run_sandbox_container's
  # own reap, make sure no renderer outlives the run and no painted line
  # survives. No-op in the normal flow.
  stop_liveness_renderer

  if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then
    local end_clock
    end_clock="$(now_clock)"
    if [ -n "$RUN_PREFLIGHT_INVARIANT" ]; then
      format_preflight_summary_md \
        "$RUN_FEATURE" "$RUN_TS" "$RUN_START_CLOCK" "$end_clock" \
        "$RUN_PREFLIGHT_INVARIANT" >"$RUN_DIR/SUMMARY.md"
      printf '\nstop reason: preflight-abort: %s\n' "$RUN_PREFLIGHT_INVARIANT"
    else
      local end_state="ended"
      if [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ]; then
        end_state="interrupted"
      fi
      local stop_reason="${RUN_STOP_REASON:-unknown}"
      printf '\n'
      print_dispatch_records | format_end_of_run_table "$stop_reason"
      if [ "$RUN_MODE" = "drain" ]; then
        print_multi_feature_records | format_multi_feature_summary_md \
          "$RUN_TS" "$RUN_START_CLOCK" "$end_clock" \
          "$end_state" "$stop_reason" "${ARG_MODEL:-}" >"$RUN_DIR/SUMMARY.md"
      else
        print_dispatch_records | format_summary_md \
          "$RUN_FEATURE" "$RUN_TS" "$RUN_START_CLOCK" "$end_clock" \
          "$end_state" "$stop_reason" "${ARG_MODEL:-}" >"$RUN_DIR/SUMMARY.md"
      fi
      # Append swept parking refs section when at least one ref was swept.
      if [ "${#RUN_SWEPT_REFS[@]}" -gt 0 ]; then
        format_swept_refs_section >>"$RUN_DIR/SUMMARY.md"
      fi
    fi
  fi

  release_lock
  # Drain runner.log before exiting so the operator never sees a
  # truncated tail. Must come after every other print — once this
  # returns, stdout/stderr are closed.
  stop_runner_log_capture
  exit "$rc"
}

# === Argument parsing ======================================================

ARG_ISSUE_REF=""
ARG_FEATURE=""
ARG_MODEL=""
RUN_MODE=""           # "single" | "loop" | "drain", set by parse_args
ISSUE_FEATURE=""
ISSUE_NN=""
TARGET_FEATURE=""     # set in main() from ARG_FEATURE or ISSUE_FEATURE;
                      # empty in drain mode (per-feature iteration sets it).

parse_args() {
  # Argparse rejects (missing values, malformed flags, unknown args)
  # exit 2 directly without setting up the per-run dir. By design: a
  # malformed invocation isn't a "run" — nothing started, no invariants
  # were attempted, and the stderr message ("runner: unknown argument:
  # …") is already self-explanatory. Pre-flight aborts produce a per-
  # run dir because there's failure forensics worth capturing; argparse
  # rejects don't.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --issue)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          echo "runner: --issue requires an argument" >&2
          exit 2
        fi
        ARG_ISSUE_REF="$2"
        shift 2
        ;;
      --feature)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          echo "runner: --feature requires an argument" >&2
          exit 2
        fi
        ARG_FEATURE="$2"
        shift 2
        ;;
      --model)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          echo "runner: --model requires an argument" >&2
          exit 2
        fi
        ARG_MODEL="$2"
        shift 2
        ;;
      -h|--help)
        sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *)
        echo "runner: unknown argument: $1" >&2
        exit 2
        ;;
    esac
  done

  if [ -n "$ARG_ISSUE_REF" ]; then
    if [[ ! "$ARG_ISSUE_REF" =~ ^([a-z0-9][a-z0-9-]*)/([0-9]+)$ ]]; then
      echo "runner: --issue must look like '<feature>/<NN>', got: $ARG_ISSUE_REF" >&2
      exit 2
    fi
    ISSUE_FEATURE="${BASH_REMATCH[1]}"
    ISSUE_NN="${BASH_REMATCH[2]}"
    RUN_MODE="single"
  elif [ -n "$ARG_FEATURE" ]; then
    RUN_MODE="loop"
  else
    RUN_MODE="drain"
  fi

  if [ -n "$ARG_FEATURE" ]; then
    if [[ ! "$ARG_FEATURE" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "runner: --feature must be a slug like 'afk-runner', got: $ARG_FEATURE" >&2
      exit 2
    fi
    if [ -n "$ISSUE_FEATURE" ] && [ "$ARG_FEATURE" != "$ISSUE_FEATURE" ]; then
      echo "runner: --feature '$ARG_FEATURE' disagrees with --issue feature '$ISSUE_FEATURE'" >&2
      exit 2
    fi
  fi
}

# === Pidfile lock ==========================================================

LOCK_HELD=0

acquire_lock() {
  mkdir -p "$(dirname "$HOST_LOCK")"
  # Atomic write via noclobber: the shell kernel call fails with EEXIST if
  # the file already exists, closing the TOCTOU window that a plain
  # `[ -f ]` + `echo` pair leaves open.
  local existing_pid
  if ! ( set -o noclobber; echo "$$" >"$HOST_LOCK" ) 2>/dev/null; then
    existing_pid="$(cat "$HOST_LOCK" 2>/dev/null || true)"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      fail_invariant "no-other-runner" \
        "another runner is already running (pid $existing_pid, lock $HOST_LOCK); refusing to start"
    fi
    # Stale lock — owner gone. Reclaim.
    rm -f "$HOST_LOCK"
    if ! ( set -o noclobber; echo "$$" >"$HOST_LOCK" ) 2>/dev/null; then
      fail_invariant "no-other-runner" \
        "race on stale-lock reclaim; try again"
    fi
  fi
  LOCK_HELD=1
}

release_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    rm -f "$HOST_LOCK"
    LOCK_HELD=0
  fi
}

# === Host repo state inspection ============================================

# Resolve the host (consumer) repo root. The script lives at
# `<formann>/framework/runner/run-the-queue.sh` and is reached from a
# consumer via `<consumer>/.formann/runner/run-the-queue.sh` (where
# `.formann -> <formann-root>/framework` is a per-machine indirection
# symlink kept out of git). We walk up from $PWD looking for a
# directory that contains a `.formann` entry — same shape as git
# finding its repo root, npm finding package.json. First match wins;
# that directory is the consumer root. Hitting `/` is a loud failure.
#
# Filesystem-based, not path-string-based — so symlink resolution
# (realpath, readlink -f, wrapper scripts that normalize paths) can't
# break it. The contract is just "run me from inside the consumer".
#
# We compute paths unconditionally — including `HOST_RUNS`, so
# `setup_run_dir` can run before pre-flight and a pre-flight abort
# still produces a per-run dir. No validation beyond locating
# `.formann`: host-state inspection is intentionally out of scope
# (the runner is independent of host's HEAD and working tree), and
# structural integrity of these paths is established by their use
# downstream (the lock acquisition, runner-checkout sync, etc.).
resolve_host_repo() {
  local d="$PWD"
  HOST_REPO=""
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -e "$d/.formann" ]; then
      HOST_REPO="$d"
      break
    fi
    d="$(dirname "$d")"
  done
  if [ -z "$HOST_REPO" ]; then
    echo "run-the-queue.sh: not inside a consumer (no '.formann' ancestor of '$PWD')" >&2
    exit 2
  fi
  HOST_RUNNER_STATE="$HOST_REPO/$RUNNER_STATE_DIR"
  HOST_LOCK="$HOST_REPO/$RUNNER_LOCK_PATH"
  HOST_CHECKOUT="$HOST_REPO/$RUNNER_CHECKOUT_PATH"
  HOST_RUNS="$HOST_REPO/$RUNNER_RUNS_PATH"
  HOST_ABORT_DIR="$HOST_REPO/$RUNNER_ABORT_PATH"
}

# === Pre-flight ============================================================

# 1. Discovery: tracker-snapshot --list exits 0 and returns a parseable JSON
#    array. Populates DISCOVERY_JSON for feature-validation downstream.
check_discovery() {
  local rc=0
  local result
  result="$(TRACKER_ROOT="$HOST_REPO/.features" \
    bash "$HOST_REPO/docs/formann/issue-tracker/tracker-snapshot" --list)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail_invariant "discovery" \
      "tracker-snapshot --list exited non-zero ($rc)"
  fi
  if ! jq -e 'if type == "array" then . else error end' >/dev/null 2>&1 <<<"$result"; then
    fail_invariant "discovery" \
      "tracker-snapshot --list produced non-array JSON"
  fi
  DISCOVERY_JSON="$result"
  # Persist for forensics. Same lifecycle as runner.log — written
  # immediately, never amended. Pretty-printed so a maintainer skimming
  # `<run-dir>/discovery.json` after the fact reads it without piping
  # through jq. RUN_DIR is set in main() before preflight runs, so the
  # write is safe.
  if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then
    printf '%s\n' "$DISCOVERY_JSON" | jq '.' >"$RUN_DIR/discovery.json"
  fi
}

# Feature eligibility — TARGET_FEATURE must appear in DISCOVERY_JSON.
#     This is a CLI-input refusal (the slug came from `--feature` or
#     `--issue`), so it exits 2 with a `feature-restricted` /
#     `single-dispatch` stop reason rather than going through
#     `fail_invariant` (which would label it `preflight-abort: …`).
#
#     Returns 2 on refusal. Inside `preflight()`, `set -e` from `main()`
#     propagates the non-zero, the script exits, and the EXIT trap
#     (`finalize_run`) writes SUMMARY.md against RUN_STOP_REASON.
check_feature_eligibility() {
  local prefix
  if [ "$RUN_MODE" = "single" ]; then
    prefix="single-dispatch"
  else
    prefix="feature-restricted"
  fi

  if ! jq -e --arg s "$TARGET_FEATURE" 'any(.[]; . == $s)' >/dev/null 2>&1 <<<"$DISCOVERY_JSON"; then
    echo "runner: $prefix refused: feature '$TARGET_FEATURE' not in discovery output" >&2
    RUN_STOP_REASON="$prefix (refused: unknown-feature)"
    return 2
  fi
}

# 2a. Runner-checkout directory is present (clones from host if absent).
#     Branch-agnostic: only the clone lives here; branch-switching is in
#     ensure_runner_checkout_on_branch below. Called from preflight
#     unconditionally so the clone fires at most once per pass, before any
#     branch-sync.
#
# PRD deviation: §Git and propagation specifies `git clone --reference`
# for cheap shared-object-store clones. Empirically, that approach is
# fragile when the checkout is mounted into a container running
# unrestricted git (`/implement` with `--dangerously-skip-permissions`):
# in-container `git repack`/`git gc` operations can corrupt the
# host-pointing alternates link, leaving the runner-checkout silently
# detached from host's object store. Pre-flight then "syncs" against a
# stale local view, `/implement` builds on diverged history, and
# fast-forward propagation refuses with `Not possible to fast-forward`.
#
# Plain `git clone` produces a self-contained checkout (its own object
# store; default `--local` still hardlinks existing packs from source
# at clone time so the cost stays modest). After the initial clone,
# host commits arrive via `git fetch origin <branch>`, which copies
# loose objects into the runner-checkout's own store — no alternates
# dependency, so container-side git ops cannot decouple us from host.
ensure_runner_checkout_exists() {
  if [ ! -d "$HOST_CHECKOUT/.git" ]; then
    mkdir -p "$(dirname "$HOST_CHECKOUT")"
    if ! git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT" >&2; then
      echo "runner: ensure_runner_checkout_exists: git clone into $HOST_CHECKOUT failed" >&2
      return 1
    fi
  fi
}

# 2b. Runner-checkout is synced to the named branch's tip on host.
#     Branch-parameterized: the runner-checkout is a single clone that
#     gets branch-switched per drained feature inside the drain loop.
#     Single-feature / single-issue modes call this once with the target
#     feature. Requires the checkout directory to already exist (see
#     ensure_runner_checkout_exists above).
#
# Failure mode:
#   - Returns 1 with a stderr diagnostic for any git failure or post-sync
#     mismatch. The caller decides whether to `fail_invariant` (pre-flight
#     / narrowed mode) or record a per-feature `skip:fetch-failed` (drain
#     mode). The function itself never aborts — it has no run-mode context.
ensure_runner_checkout_on_branch() {
  local branch="$1"
  if [ -z "$branch" ]; then
    echo "runner: ensure_runner_checkout_on_branch: empty branch" >&2
    return 1
  fi

  # Detect and recover from unborn-HEAD state. This state arises when
  # sweep_stale_parking_refs deletes the source branch that HEAD still
  # symbolic-refs (the routine post-PR-merge cleanup path). git rev-parse
  # --verify --quiet HEAD exits non-zero and produces no stdout when HEAD
  # points at a missing ref. The dirty-WT scrub below uses `git reset --hard
  # HEAD`, which fails in this state, so we must restore a valid HEAD first.
  #
  # Use plumbing (update-ref + symbolic-ref) rather than `git checkout -B`:
  # the checkout porcelain refuses on a dirty WT whose tracked files conflict
  # with the new tip, which is exactly the state we land in after a merged
  # dispatch (the dispatch's staged CHANGELOG.md, .inbox.md, etc. still sit
  # in the WT — superseded by the squash-merged versions on origin, but the
  # checkout porcelain doesn't know that). The plumbing ops never touch the
  # WT, so they can't refuse; the dirty-WT scrub below then resets the WT
  # against the now-valid HEAD.
  if ! git -C "$HOST_CHECKOUT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    local default_branch
    default_branch="$(git -C "$HOST_CHECKOUT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    if [ -z "$default_branch" ]; then
      git -C "$HOST_CHECKOUT" remote set-head origin --auto >/dev/null 2>&1 || true
      default_branch="$(git -C "$HOST_CHECKOUT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    fi
    if [ -z "$default_branch" ]; then
      echo "runner: ensure_runner_checkout_on_branch: refs/remotes/origin/HEAD missing after 'git remote set-head origin --auto' — set it manually with 'git -C $HOST_CHECKOUT remote set-head origin --auto'" >&2
      return 1
    fi
    if ! git -C "$HOST_CHECKOUT" fetch --quiet origin >&2; then
      echo "runner: ensure_runner_checkout_on_branch: git fetch origin (unborn-HEAD recovery) failed" >&2
      return 1
    fi
    if ! git -C "$HOST_CHECKOUT" update-ref "refs/heads/$default_branch" "refs/remotes/origin/HEAD" >&2; then
      echo "runner: ensure_runner_checkout_on_branch: git update-ref refs/heads/$default_branch origin/HEAD (unborn-HEAD recovery) failed" >&2
      return 1
    fi
    if ! git -C "$HOST_CHECKOUT" symbolic-ref HEAD "refs/heads/$default_branch" >&2; then
      echo "runner: ensure_runner_checkout_on_branch: git symbolic-ref HEAD refs/heads/$default_branch (unborn-HEAD recovery) failed" >&2
      return 1
    fi
  fi

  # Scrub stray WT changes in the runner-checkout before attempting any
  # ref-changing operation. The runner-checkout is runtime state — no human
  # authors changes there — so any non-empty `git status` reflects either a
  # previous dispatch that failed to commit/propagate or an external write
  # that leaked in (e.g. an IDE rooted at the host repo also editing this
  # nested checkout). The downstream `checkout -B` refuses on a dirty WT
  # whenever the new tip's version of a touched file differs from HEAD's, so
  # one stray write would deadlock every subsequent pass. Log the dirty set
  # loudly so the diagnostic survives the scrub, then `reset --hard HEAD` to
  # bring the WT in line with current HEAD before the ref switch below. The
  # trailing `git clean -fd` (post-switch) still handles untracked files.
  local dirty
  dirty="$(git -C "$HOST_CHECKOUT" status --porcelain 2>/dev/null)"
  if [ -n "$dirty" ]; then
    echo "runner: ensure_runner_checkout_on_branch: dirty runner-checkout WT before sync — scrubbing:" >&2
    echo "$dirty" >&2
    if ! git -C "$HOST_CHECKOUT" reset --quiet --hard HEAD >&2; then
      echo "runner: ensure_runner_checkout_on_branch: git reset --hard HEAD failed" >&2
      return 1
    fi
  fi

  # Read the parking-ref tip directly from host's .git. The runner-checkout's
  # default origin refspec (+refs/heads/*:refs/remotes/origin/*) does NOT
  # cover host's refs/remotes/runner/*, so an origin fetch won't bring it
  # across. Reading the SHA directly from host avoids an extra round-trip.
  # Use --verify so that a missing ref yields empty stdout (plain rev-parse
  # prints the literal ref string to stdout on failure, poisoning the check).
  local host_tip parking_tip
  host_tip="$(git -C "$HOST_REPO" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)"
  parking_tip="$(git -C "$HOST_REPO" rev-parse --verify "refs/remotes/runner/$branch" 2>/dev/null || true)"

  if [ -z "$host_tip" ] && [ -z "$parking_tip" ]; then
    # Guard: the runner-checkout's local refs/heads/<branch> may hold commits
    # from a prior dispatch whose propagation failed. With both host refs absent
    # the checkout -B below would silently destroy that work. Detect this before
    # the destructive step and halt, leaving the branch ref intact so the
    # maintainer can recover the commit from the runner-checkout's reflog.
    # Resolves the remote default through refs/remotes/origin/HEAD (set by
    # `git clone`) so the guard tracks whichever branch the remote treats as
    # default rather than hardcoding `main`.
    local local_branch_tip default_tip
    local_branch_tip="$(git -C "$HOST_CHECKOUT" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)"
    default_tip="$(git -C "$HOST_CHECKOUT" rev-parse --verify "refs/remotes/origin/HEAD" 2>/dev/null || true)"
    if [ -n "$local_branch_tip" ] && [ -n "$default_tip" ] \
        && [ "$local_branch_tip" != "$default_tip" ] \
        && git -C "$HOST_CHECKOUT" merge-base --is-ancestor "$default_tip" "$local_branch_tip" 2>/dev/null; then
      echo "runner: ensure_runner_checkout_on_branch: lazy-init guard — refs/heads/$branch ($local_branch_tip) is ahead of origin's default branch with no host branch and no parking ref; aborting to preserve commits" >&2
      return 1
    fi
    # Neither the host branch nor a parking ref exists yet — first dispatch for
    # a slug whose branch was never pre-created on host. Initialize the
    # runner-checkout's branch from the remote's default branch, discovered via
    # refs/remotes/origin/HEAD (set automatically by `git clone` at checkout-
    # creation time). The first propagation's `<slug>:<slug>` refspec is
    # create-on-missing and will create refs/heads/<slug> on host.
    if ! git -C "$HOST_CHECKOUT" symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
      git -C "$HOST_CHECKOUT" remote set-head origin --auto >/dev/null 2>&1 || true
    fi
    if ! git -C "$HOST_CHECKOUT" symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
      echo "runner: ensure_runner_checkout_on_branch: refs/remotes/origin/HEAD missing after 'git remote set-head origin --auto' — set it manually with 'git -C $HOST_CHECKOUT remote set-head origin --auto'" >&2
      return 1
    fi
    if ! git -C "$HOST_CHECKOUT" fetch --quiet origin >&2; then
      echo "runner: ensure_runner_checkout_on_branch: git fetch origin (lazy init) failed" >&2
      return 1
    fi
    if ! git -C "$HOST_CHECKOUT" checkout --quiet -B "$branch" "origin/HEAD" >&2; then
      echo "runner: ensure_runner_checkout_on_branch: git checkout -B $branch origin/HEAD (lazy init) failed" >&2
      return 1
    fi
    if ! git -C "$HOST_CHECKOUT" reset --quiet --hard "origin/HEAD" >&2; then
      echo "runner: ensure_runner_checkout_on_branch: git reset --hard origin/HEAD (lazy init) failed" >&2
      return 1
    fi
  else
    local parking_rel sync_verdict
    if [ -z "$parking_tip" ]; then
      parking_rel="absent"
    elif [ "$parking_tip" = "$host_tip" ]; then
      parking_rel="equal"
    elif git -C "$HOST_REPO" merge-base --is-ancestor "$parking_tip" "$host_tip" 2>/dev/null; then
      # parking tip is ancestor of host tip → host is strictly ahead
      parking_rel="behind"
    elif git -C "$HOST_REPO" merge-base --is-ancestor "$host_tip" "$parking_tip" 2>/dev/null; then
      # host tip is ancestor of parking tip → parking ref is strictly ahead
      parking_rel="ahead"
    else
      parking_rel="diverged"
    fi

    sync_verdict="$(select_sync_base "$parking_rel")"

    if [ "$sync_verdict" = "host-branch" ]; then
      if ! git -C "$HOST_CHECKOUT" fetch --quiet origin "$branch" >&2; then
        echo "runner: ensure_runner_checkout_on_branch: git fetch origin $branch failed" >&2
        return 1
      fi
      if ! git -C "$HOST_CHECKOUT" checkout --quiet -B "$branch" "origin/$branch" >&2; then
        echo "runner: ensure_runner_checkout_on_branch: git checkout -B $branch failed" >&2
        return 1
      fi
      if ! git -C "$HOST_CHECKOUT" reset --quiet --hard "origin/$branch" >&2; then
        echo "runner: ensure_runner_checkout_on_branch: git reset --hard origin/$branch failed" >&2
        return 1
      fi
    else
      # parking-ref verdict: fetch the parking-ref's objects from host into the
      # runner-checkout (the runner-checkout's origin fetch won't carry them),
      # then sync to the parking-ref tip so successive dispatches chain linearly.
      if ! git -C "$HOST_CHECKOUT" fetch --quiet "$HOST_REPO" \
          "refs/remotes/runner/$branch:refs/remotes/host-parking/$branch" >&2; then
        echo "runner: ensure_runner_checkout_on_branch: fetch parking-ref tip from host failed" >&2
        return 1
      fi
      if ! git -C "$HOST_CHECKOUT" checkout --quiet -B "$branch" "$parking_tip" >&2; then
        echo "runner: ensure_runner_checkout_on_branch: git checkout -B $branch $parking_tip failed" >&2
        return 1
      fi
      if ! git -C "$HOST_CHECKOUT" reset --quiet --hard "$parking_tip" >&2; then
        echo "runner: ensure_runner_checkout_on_branch: git reset --hard $parking_tip failed" >&2
        return 1
      fi
    fi
  fi

  # `reset --hard` scrubs tracked changes but leaves untracked files
  # alone. The dispatch container can drop CWD-relative artifacts (kernel
  # core dumps from a crashed in-container process, stray writes from a
  # confused agent), and any leftover would surface in the implement
  # stage's `git status --porcelain` diagnostic and misattribute prior
  # dispatch leakage to *this* iteration's `/implement`. `-fd` removes
  # untracked files and directories without touching gitignored content
  # (caches, IDE state). The runner-checkout has no legitimate untracked
  # state at this point in the loop, so cleaning is unconditionally safe.
  if ! git -C "$HOST_CHECKOUT" clean --quiet -fd >&2; then
    echo "runner: ensure_runner_checkout_on_branch: git clean -fd failed" >&2
    return 1
  fi
  return 0
}

# Wrapper around `ensure_runner_checkout_on_branch` that picks a failure
# disposition from RUN_MODE:
#
#  - Narrowed modes (`single`, `loop`) — pre-flight and the per-iteration
#    re-sync inside `run_loop` both abort the whole run via `fail_invariant`,
#    producing `preflight-abort: runner-checkout`. Correct: there's exactly
#    one feature in play and a sync failure is terminal.
#  - Drain mode — the per-iteration re-sync inside `run_loop` soft-fails:
#    set RUN_STOP_REASON="fetch-failed" and return 1, so the caller
#    (run_loop) can return non-zero and `drain_one_feature` can map the
#    inner reason to a `skip:fetch-failed` per-feature row and continue to
#    the next feature. (Drain mode's *pre-feature* sync — the direct call
#    from `drain_one_feature` to `ensure_runner_checkout_on_branch` — uses
#    the inner function and never goes through this wrapper.)
ensure_runner_checkout() {
  if ! ensure_runner_checkout_on_branch "$TARGET_FEATURE" >&2; then
    if [ "$RUN_MODE" = "drain" ]; then
      RUN_STOP_REASON="fetch-failed"
      return 1
    fi
    fail_invariant "runner-checkout" \
      "ensure_runner_checkout_on_branch $TARGET_FEATURE failed (rm -rf $HOST_CHECKOUT and re-run to recover)"
  fi
}

# 0. Retry knob sanity. RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS feeds
#    with_transport_retry's budget check `[ "$attempt" -ge "$max" ]`; a
#    non-numeric value makes that test error and evaluate false, so the
#    budget would never trip and a persistent transport crash would retry
#    without bound. The numeric window knobs (issue #75) feed the analogous
#    `[ "$waits" -ge "$max_waits" ]` budget check and the wait-loop bound in
#    with_window_retry, with the same failure mode. Refuse up front instead.
check_retry_knobs() {
  case "$RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS" in
    ''|*[!0-9]*) fail_invariant "retry-knobs" \
      "RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS must be a whole number, got '$RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS'";;
  esac
  case "$RUNNER_WINDOW_RETRY_FALLBACK_WAIT" in
    ''|*[!0-9]*) fail_invariant "retry-knobs" \
      "RUNNER_WINDOW_RETRY_FALLBACK_WAIT must be a whole number, got '$RUNNER_WINDOW_RETRY_FALLBACK_WAIT'";;
  esac
  case "$RUNNER_WINDOW_RETRY_MAX_WAITS" in
    ''|*[!0-9]*) fail_invariant "retry-knobs" \
      "RUNNER_WINDOW_RETRY_MAX_WAITS must be a whole number, got '$RUNNER_WINDOW_RETRY_MAX_WAITS'";;
  esac
}

# 3. Docker daemon responds.
check_docker_daemon() {
  if ! docker info >/dev/null 2>&1; then
    fail_invariant "docker-daemon" \
      "docker info failed; is Docker Desktop running?"
  fi
}

# 4b. Consumer-owned post-implement manifest is present and valid. Resolves
#     all referenced prompts; fails fast before any Dispatch if missing or
#     malformed. Sets RESOLVED_MANIFEST to the tab-delimited label<TAB>path
#     pairs for use by walk_post_implement_steps.
check_manifest() {
  local manifest_path="$HOST_REPO/$RUNNER_MANIFEST_FILE"
  if [ ! -f "$manifest_path" ]; then
    fail_invariant "manifest" \
      "$manifest_path not found — re-run the Formann installer (installer/install.sh) against this repo to seed the default manifest"
  fi
  local manifest_text
  manifest_text="$(cat "$manifest_path")"
  # Redirect resolve_manifest's stderr to stdout so failures are captured
  # in RESOLVED_MANIFEST for the fail_invariant message; on success stdout
  # holds only the valid tab-delimited pairs (stderr is empty).
  if ! RESOLVED_MANIFEST="$(resolve_manifest "$manifest_text" "$HERE/steps" "$HOST_REPO/$RUNNER_CONSUMER_PROMPTS_DIR" 2>&1)"; then
    fail_invariant "manifest" "$RESOLVED_MANIFEST"
  fi
}

# 4. Runner image exists or is built. `build-image.sh` is idempotent.
ensure_image() {
  if ! "$HERE/build-image.sh" >/dev/null; then
    fail_invariant "runner-image" \
      "build-image.sh failed to ensure image $RUNNER_IMAGE_NAME"
  fi
}

# 5. Per-feature mvn cache volume exists. `ensure-mvn-cache.sh` is idempotent.
ensure_mvn_cache() {
  if ! MVN_VOLUME="$("$HERE/ensure-mvn-cache.sh" "$TARGET_FEATURE")"; then
    fail_invariant "mvn-cache" \
      "ensure-mvn-cache.sh failed for feature $TARGET_FEATURE"
  fi
  if [ -z "${MVN_VOLUME:-}" ]; then
    fail_invariant "mvn-cache" \
      "ensure-mvn-cache.sh produced empty volume name"
  fi
}

# 6. Sandbox docker network exists. `setup-network.sh` is idempotent.
ensure_network() {
  if ! NET_NAME="$("$HERE/setup-network.sh")"; then
    fail_invariant "sandbox-network" \
      "setup-network.sh failed to ensure network $RUNNER_NETWORK_NAME"
  fi
  if [ -z "${NET_NAME:-}" ]; then
    fail_invariant "sandbox-network" \
      "setup-network.sh produced empty network name"
  fi
}

# 7. OAuth token retrievable from Keychain. Captured into a shell variable;
#    never echoed, never logged, passed to docker -e only.
retrieve_oauth_token() {
  if ! TOKEN="$("$HERE/retrieve-token.sh")"; then
    fail_invariant "oauth-token" \
      "retrieve-token.sh failed; see its diagnostic above"
  fi
  if [ -z "${TOKEN:-}" ]; then
    fail_invariant "oauth-token" \
      "retrieve-token.sh produced empty token"
  fi
}

# Compose pre-flight. The lock is acquired first so a concurrent run
# refuses immediately rather than racing on idempotent setup steps.
# `resolve_host_repo` ran in main() so the run dir already exists; the
# EXIT trap (`finalize_run`, installed in main()) covers lock release
# alongside summary writing.
preflight() {
  acquire_lock
  check_retry_knobs                      # invariant 0: env knob sanity
  check_discovery                        # invariant 1: tracker-snapshot --list
  ensure_runner_remote                   # invariant 1b: runner remote
  if ! ensure_runner_checkout_exists >&2; then  # invariant 2a (clone-existence)
    fail_invariant "runner-checkout" \
      "ensure_runner_checkout_exists failed (rm -rf $HOST_CHECKOUT and re-run to recover)"
  fi
  # Single-feature / single-issue modes know their target up front, so the
  # CLI-input gate runs here (returns 2 with a `feature-restricted` /
  # `single-dispatch (refused: …)` stop reason). Runner-checkout branch-sync
  # and mvn-cache materialization also happen up front because there's exactly
  # one feature to drain.
  #
  # Drain mode (bare invocation) defers per-feature work into the outer
  # loop: each feature gets its own gate evaluation, lazy branch-sync, and
  # lazy mvn-cache. A feature whose host branch doesn't exist / whose
  # snapshot crashes / whose queue is empty surfaces as a `skipped` SUMMARY
  # row, not a pre-flight abort.
  if [ "$RUN_MODE" != "drain" ]; then
    check_feature_eligibility || return $?
    ensure_runner_checkout               # invariant 2b (branch-sync)
  fi
  check_docker_daemon                    # invariant 3
  ensure_image                           # invariant 4
  check_manifest                         # invariant 4b (post-implement manifest)
  if [ "$RUN_MODE" != "drain" ]; then
    ensure_mvn_cache                     # invariant 5
  fi
  ensure_network                         # invariant 6
  retrieve_oauth_token                   # invariant 7
  # invariant 8 (no-other-runner) was acquired up front via acquire_lock.
}

# === Tracker snapshot ======================================================

# Take a snapshot of the feature's tracker state via the active binding's
# tracker-snapshot script. SNAPSHOT_CHECKOUT_DIR points at the runner-
# checkout; the binding decides what to do with it. local-markdown archives
# `.features/` from that repo's HEAD (committed state, not the working tree)
# — rationale lives in that script's comment block. github-issues ignores
# SNAPSHOT_CHECKOUT_DIR and queries the GitHub API directly. Each binding
# owns its "current state of the world" definition; the wrapper here is
# binding-agnostic.
#
# Capture rc explicitly: command-substitution-into-local-assignment under
# `set -e` does not propagate a non-zero from the inner command, so a
# tracker-snapshot crash would otherwise surface as an empty snapshot
# indistinguishable from "no issues" — and run_loop would report a
# misleading queue-empty stop.
take_snapshot() {
  local feature="$1"
  local rc=0 result
  result="$(SNAPSHOT_CHECKOUT_DIR="$HOST_CHECKOUT" \
    bash "$HOST_REPO/docs/formann/issue-tracker/tracker-snapshot" "$feature")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "runner: tracker-snapshot exited non-zero ($rc) for feature $feature" >&2
    return 1
  fi
  printf '%s\n' "$result"
}

# === Dispatch ==============================================================

# In-flight dispatch state read by the SIGINT/SIGTERM handler. The trap
# only sends SIGTERM to the container; grace + SIGKILL escalation lives
# in `run_dispatch_container` so the trap can return promptly.
RUNNER_INTERRUPTED=0
IN_FLIGHT_CID_FILE=""

handle_signal() {
  RUNNER_INTERRUPTED=1
  # Reap the liveness renderer first — its TERM trap clears the painted
  # line, so the interrupt leaves no half-painted text behind.
  if [ -n "${LIVENESS_PID:-}" ]; then
    kill -TERM "$LIVENESS_PID" 2>/dev/null || true
  fi
  if [ -n "$IN_FLIGHT_CID_FILE" ] && [ -s "$IN_FLIGHT_CID_FILE" ]; then
    local cid
    cid="$(cat "$IN_FLIGHT_CID_FILE" 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      docker kill --signal=SIGTERM "$cid" >/dev/null 2>&1 || true
    fi
  fi
}

# === Liveness renderer spawn/reap ==========================================
#
# The renderer (liveness_render_loop in liveness.sh) is a read-only observer
# of the dispatch's event-stream artifact, painting the liveness line on the
# controlling terminal for the duration of one dispatch attempt. It is
# spawned right after the container and reaped right after it ends — its
# exit status is never consulted (reaped, not waited-on-for-success), and a
# spawn that is skipped (no terminal, disabled) changes nothing downstream.

# Dispatch context the renderer displays. Set by dispatch_one (implement
# stage) and walk_post_implement_steps (each item) before their container
# wrappers run; read by start_liveness_renderer.
LIVENESS_PID=""
RUNNER_LIVENESS_FEATURE=""
RUNNER_LIVENESS_ISSUE=""
RUNNER_LIVENESS_STAGE=""
RUNNER_LIVENESS_STARTED_AT=""

# Spawn the renderer for one dispatch attempt. Silently a no-op when the
# liveness line is disabled or there is no writable controlling terminal
# (fully-detached run) — a missing terminal is never an error. The renderer's
# stdout/stderr are discarded so nothing it emits can reach the runner.log
# capture; it paints /dev/tty directly, which the capture never sees.
#
# Args: $1 = event-stream artifact path ($log_base.stdout.jsonl)
start_liveness_renderer() {
  local stream_file="$1"
  LIVENESS_PID=""
  if [ "${RUNNER_DISABLE_LIVENESS:-0}" = "1" ]; then
    return 0
  fi
  if ! { : >/dev/tty; } 2>/dev/null; then
    return 0
  fi
  liveness_render_loop "$stream_file" \
    "$RUNNER_LIVENESS_FEATURE" "$RUNNER_LIVENESS_ISSUE" \
    "$RUNNER_LIVENESS_STAGE" "$RUNNER_LIVENESS_STARTED_AT" \
    >/dev/null 2>&1 &
  LIVENESS_PID=$!
}

# Reap the in-flight renderer, if any. TERM triggers its clear-the-line
# trap; the wait only collects the dead child (never gates on its status).
stop_liveness_renderer() {
  if [ -z "${LIVENESS_PID:-}" ]; then return 0; fi
  kill -TERM "$LIVENESS_PID" 2>/dev/null || true
  wait "$LIVENESS_PID" 2>/dev/null || true
  LIVENESS_PID=""
}

# Pre-flight-aware INT/TERM handler. Installed before `preflight` so a
# Ctrl-C during image build, mvn cache init, network setup, etc. produces
# a named stop reason in SUMMARY.md rather than falling through to the
# catch-all "unknown" branch.
handle_preflight_signal() {
  RUN_STOP_REASON="interrupted-during-preflight"
  exit 130
}

# Invoke the binding's sandbox-env hook if executable, validate its output,
# and print the accepted KEY=value lines to stdout.
#
# Args: $1 = path to the sandbox-env script on the role surface
#            (typically $HOST_REPO/docs/formann/issue-tracker/sandbox-env)
#
# Stdout: validated KEY=value lines (one per line). Empty if the script is
#         absent or produces no output. Returns 0 on success (including
#         absent script), 1 on script failure or malformed output.
#
# Validation policy: empty lines are silently skipped. Any non-empty line
# that does not match the anchored regex ^[A-Z_][A-Z0-9_]*= is rejected
# with a clear stderr error and causes this function to return 1. The
# policy is fail-hard rather than skip-with-warning because a
# partially-applied env file is more dangerous than a loud abort — the
# container could run with missing credentials and produce wrong results
# silently. The key regex mirrors Docker's own env-var name rules.
collect_binding_env() {
  local script_path="$1"

  # No script on the role surface → no-op. Handles local-markdown and any
  # binding that declares no sandbox prerequisites.
  if [[ ! -x "$script_path" ]]; then
    return 0
  fi

  local raw_output
  raw_output="$("$script_path")" || {
    echo "runner: sandbox-env exited non-zero; aborting dispatch" >&2
    return 1
  }

  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! binding_env_line_valid "$line"; then
      # Never echo $line or any substring of it — a no-`=` line would
      # leak the entire value via `${line%%=*}`, which returns the whole
      # string when the pattern doesn't match. The script's own stderr
      # (already captured into runner.log) is where a forensic key/line
      # diagnostic should come from, not from here.
      echo "runner: sandbox-env emitted malformed line (expected KEY=value with uppercase key)" >&2
      return 1
    fi
    printf '%s\n' "$line"
  done <<<"$raw_output"
}

# `docker run` plumbing shared between the implement dispatch and the
# review-and-gate dispatch. Both stages run in fresh sandbox containers
# with the same image, network, runner-checkout mount, mvn cache mount,
# and OAuth token environment — they differ only in the command they
# hand to `claude`. Splits the dispatch's stdout (the pure event stream) into
# `<base>.stdout.jsonl` and its stderr (diagnostic/crash text) into
# `<base>.stderr.log` — two separate artifacts, not a merged file. Returns the
# docker exit code.
#
# To make Ctrl-C actionable, we run docker in the background with
# `--cidfile` and let the SIGINT/SIGTERM trap (`handle_signal`) read the
# CID and send SIGTERM to the container. After `wait` returns, we
# escalate to SIGKILL if the container is still alive past
# `RUNNER_KILL_GRACE_SECONDS`.
#
# Args: $1 = log_base (the per-dispatch artifact base path; children
#       `.stdout.jsonl` / `.stderr.log` derive from it), $2..$N = command +
#       args to pass after the image.
run_sandbox_container() {
  local log_base="$1"
  shift
  local cid_file
  cid_file="$HOST_RUNNER_STATE/dispatch.cid"
  rm -f "$cid_file"
  IN_FLIGHT_CID_FILE="$cid_file"

  # No `-t` (PTY). Streamed structured events (`--output-format stream-json
  # --verbose`, set by the callers) flush per line over a plain pipe, so the
  # PTY line-buffering workaround the print-mode dispatch needed is obsolete —
  # and dropping the PTY removes the `\r\n` / escape-sequence noise it injected
  # into every saved log (see ADR-0010). stdout is the pure event stream and
  # stderr is diagnostic text; they are split into separate artifacts below.
  # `.formann` is a per-host symlink (untracked) pointing at the Formann
  # framework checkout — `.claude/skills/<name>` symlinks resolve through
  # it. The runner-checkout doesn't carry `.formann` (it's outside the
  # tracked tree), so without this mount every framework-shaped skill is a
  # dangling symlink inside the container and claude reports `Unknown
  # command: /implement` on dispatch. `:ro` because the framework is
  # shared host state — a container should not write to it.
  #
  # `docs/formann` is the consumer-side view onto framework state — a
  # directory of installer-produced relative symlinks pointing into
  # `.formann` (e.g., `issue-tracker -> ../../.formann/bindings/issue-tracker/<impl>`)
  # that encode the binding choices made at install time. Gitignored in the
  # consumer repo, so the runner-checkout doesn't carry it; mounting from
  # host means the container reads the live binding view rather than a
  # stale or absent copy. `:ro` for the same reason as `.formann`.
  #
  # `.claude/{skills,agents,rules}` are overlaid on top of the
  # runner-checkout for the same reason in the inverse direction: for
  # normal consumers the symlinks are tracked and already present in the
  # checkout (the overlay is byte-equivalent), but for Formann
  # self-install the symlinks are gitignored — `git clone` produces a
  # checkout with no `.claude/*` content, so without this overlay the
  # container's claude can't discover framework skills/agents/rules. Each
  # mount is conditional on the host dir existing (matching the
  # installer's `link_rules` "skip if absent" pattern for rules, and
  # natural for skills/agents on a host that hasn't yet self-installed).
  # No other `.claude/` subdir is mounted — `settings.local.json`,
  # `plugins/`, `worktrees/`, `plans/`, `scripts/`, `docs/` carry local
  # Claude Code state the container has no business with.
  local claude_mounts=()
  local _sub
  for _sub in skills agents rules; do
    if [ -d "$HOST_REPO/.claude/$_sub" ]; then
      claude_mounts+=("-v" "$HOST_REPO/.claude/$_sub:$RUNNER_CONTAINER_REPO_PATH/.claude/$_sub:ro")
    fi
  done

  # Collect binding-specific env vars from the role-surface sandbox-env hook.
  # Empty if the binding declares no script (local-markdown, any binding
  # without sandbox prerequisites). Fail-hard on script error or malformed
  # output — see collect_binding_env for the validation policy.
  #
  # binding_env is passed to the container with an inline --env-file <() in the
  # docker command below, exactly like the OAuth and GIT env-files — NOT stored
  # in a variable. A process substitution's fd closes when its creating
  # statement ends, so a deferred `args=(--env-file <(...))` array hands docker
  # a dead fd whose number the inline OAuth <() reuses — silently dropping
  # GH_TOKEN/GH_REPO (the container runs, but gh sees no auth). An empty
  # binding_env yields a blank env-file, which docker ignores.
  local binding_env
  binding_env="$(collect_binding_env "$HOST_REPO/docs/formann/issue-tracker/sandbox-env")" || return 1

  docker run --rm \
    --cidfile "$cid_file" \
    --network "$NET_NAME" \
    -v "$HOST_CHECKOUT:$RUNNER_CONTAINER_REPO_PATH" \
    -v "$HOST_REPO/.formann:$RUNNER_CONTAINER_REPO_PATH/.formann:ro" \
    -v "$HOST_REPO/docs/formann:$RUNNER_CONTAINER_REPO_PATH/docs/formann:ro" \
    ${claude_mounts[@]+"${claude_mounts[@]}"} \
    -v "$MVN_VOLUME:$RUNNER_CONTAINER_M2_PATH" \
    -v "$HOME/.m2/repository:/home/runner/.m2-host:ro" \
    --env-file <(printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN") \
    --env-file <(printf 'GIT_AUTHOR_NAME=%s\nGIT_AUTHOR_EMAIL=%s\nGIT_COMMITTER_NAME=%s\nGIT_COMMITTER_EMAIL=%s\n' \
      "$RUNNER_GIT_USER_NAME" "$RUNNER_GIT_USER_EMAIL" \
      "$RUNNER_GIT_USER_NAME" "$RUNNER_GIT_USER_EMAIL") \
    --env-file <(printf '%s\n' "$binding_env") \
    "$RUNNER_IMAGE_NAME" \
    "$@" \
    >"$log_base.stdout.jsonl" 2>"$log_base.stderr.log" &
  local docker_pid=$!

  # Paint the liveness line on the controlling terminal while the container
  # runs. Per attempt on purpose: each retry attempt's redirect above
  # truncates the event stream, so the renderer's lifetime matches the
  # artifact it tails. No-op when disabled or detached.
  start_liveness_renderer "$log_base.stdout.jsonl"

  # `wait` is interruptible by traps. main() runs with `set -e`, but a
  # signal-interrupted wait exits non-zero; capture rc explicitly.
  local rc=0
  set +e
  wait "$docker_pid"
  rc=$?
  set -e

  if [ "$RUNNER_INTERRUPTED" -eq 1 ] && kill -0 "$docker_pid" 2>/dev/null; then
    # The container received SIGTERM in handle_signal; if it's still
    # alive after the grace window, escalate to SIGKILL on the
    # container, then on the docker-run process for good measure.
    local i=0
    while [ "$i" -lt "$RUNNER_KILL_GRACE_SECONDS" ]; do
      if ! kill -0 "$docker_pid" 2>/dev/null; then break; fi
      sleep 1
      i=$((i + 1))
    done
    if kill -0 "$docker_pid" 2>/dev/null; then
      if [ -s "$cid_file" ]; then
        local cid
        cid="$(cat "$cid_file" 2>/dev/null || true)"
        if [ -n "$cid" ]; then
          docker kill --signal=SIGKILL "$cid" >/dev/null 2>&1 || true
        fi
      fi
      kill -KILL "$docker_pid" 2>/dev/null || true
    fi
    set +e
    wait "$docker_pid" 2>/dev/null
    rc=$?
    set -e
  fi

  # The dispatch is over — reap the renderer (clears its line) before the
  # caller prints anything, so no stale text lingers between dispatches.
  stop_liveness_renderer

  IN_FLIGHT_CID_FILE=""
  rm -f "$cid_file"
  return "$rc"
}

# Window-exhausted gate inside the transport-retry loop (issue #75). A
# rejected usage window arrives dressed as a 429 result event, which
# is_transport_crash would classify as transport — burning the bounded
# backoff budget against a quota that is hours from returning. Checked
# before the transport rung so the accompanying 429 never consumes the
# transport budget; `with_window_retry` owns the wait-and-retry. Always
# false (gate closed) when RUNNER_DISABLE_WINDOW_RETRY=1, restoring the
# pre-#75 transport path.
_window_exhausted_gate() {
  [ "${RUNNER_DISABLE_WINDOW_RETRY:-0}" = "1" ] && return 1
  is_window_exhausted "$1"
}

# Cosmetic label for the runner.log transport-retry line. Reads the same stdout
# event stream (and may read the human-readable result text); it NEVER feeds the
# retry decision — that is is_transport_crash's job alone (issue #71). Assumes
# is_transport_crash already fired. Returns one of: "API Error: 429",
# "API Error: 5xx", "connection-fault[ (<cause>)]", "empty-output",
# "API Error: <status>", or "no-result (exit <n>)".
#
# Args: $1 = stdout event stream; $2 = exit code (for the no-result label).
_transport_crash_class() {
  local stream_file="$1" exit_code="${2:-}"
  if [ ! -s "$stream_file" ] || [ -z "$(tr -d '[:space:]' <"$stream_file" 2>/dev/null)" ]; then
    echo "empty-output"
    return 0
  fi
  local result_line api_status
  result_line="$(_terminal_result_line "$stream_file")"
  if [ -n "$result_line" ]; then
    api_status="$(printf '%s' "$result_line" \
      | jq -r 'if has("api_error_status") then (.api_error_status | tostring) else "absent" end' \
      2>/dev/null || true)"
    case "$api_status" in
      429)         echo "API Error: 429" ;;
      5[0-9][0-9]) echo "API Error: 5xx" ;;
      null|absent)
        local result_text cause
        result_text="$(printf '%s' "$result_line" | jq -r '.result // empty' 2>/dev/null || true)"
        cause="$(printf '%s' "$result_text" | grep -oE '\([A-Za-z]+\)' | tail -n 1 || true)"
        if [ -n "$cause" ]; then echo "connection-fault $cause"; else echo "connection-fault"; fi
        ;;
      *)           echo "API Error: $api_status" ;;
    esac
    return 0
  fi
  echo "no-result (exit ${exit_code:-?})"
}

# Wrap a sandbox-dispatch call with bounded exponential backoff on transport-
# class failures. Calls `dispatch_fn "$log_base" "$@"`. On non-zero exit AND
# `is_transport_crash "$log_base.stdout.jsonl" "$rc"` firing, archives the
# failed attempt's artifacts as `<base>.stdout.jsonl.attempt-<n>` and
# `<base>.stderr.log.attempt-<n>`, sleeps the next backoff from
# RUNNER_TRANSPORT_RETRY_BACKOFFS (1-second poll loop so Ctrl-C exits
# promptly), and retries up to RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS. Detection
# reads the structured result event in the stdout stream, never a log grep.
#
# Stops retrying when: dispatch succeeds; the predicate does not fire;
# RUNNER_DISABLE_TRANSPORT_RETRY=1; budget exhausted; or the runner-checkout's
# HEAD advanced between attempts (defensive guard — implies partial work was
# committed, so retrying would replay /implement over a half-committed state).
#
# Sets TRANSPORT_RETRY_ATTEMPTS (global) to the actual attempt count.
# Returns the final attempt's exit code; the final stream stays at
# `<base>.stdout.jsonl`.
#
# Args: $1=log_base  $2=dispatch_fn  [remaining args forwarded to dispatch_fn]
# Sourceable from bats.
with_transport_retry() {
  local log_base="$1" dispatch_fn="$2"
  shift 2

  local max="$RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS"
  local backoffs="$RUNNER_TRANSPORT_RETRY_BACKOFFS"
  local attempt=0
  local rc=0

  # Capture the runner-checkout HEAD before the first attempt so we can
  # detect whether a dispatch committed partial work between retries.
  local initial_head
  initial_head="$(git -C "${HOST_CHECKOUT:-}" rev-parse HEAD 2>/dev/null || true)"

  while true; do
    attempt=$(( attempt + 1 ))
    rc=0
    "$dispatch_fn" "$log_base" "$@" || rc=$?

    # Exit the retry loop when: success, retry disabled, window-exhausted
    # (the rejected-window 429 is with_window_retry's class, not transport's —
    # checked before the transport rung so it never consumes this budget),
    # not a transport crash, or budget exhausted.
    if [ "$rc" -eq 0 ] \
        || [ "${RUNNER_DISABLE_TRANSPORT_RETRY:-0}" = "1" ] \
        || _window_exhausted_gate "$log_base.stdout.jsonl" \
        || ! is_transport_crash "$log_base.stdout.jsonl" "$rc" \
        || [ "$attempt" -ge "$max" ]; then
      break
    fi

    # Archive this attempt's artifacts before the next attempt overwrites
    # them. TRANSPORT_RETRY_ATTEMPT_OFFSET (set by with_window_retry) keeps
    # the .attempt-<n> numbering continuous across window-wait rounds.
    local archive_n=$(( ${TRANSPORT_RETRY_ATTEMPT_OFFSET:-0} + attempt ))
    cp "$log_base.stdout.jsonl" "${log_base}.stdout.jsonl.attempt-${archive_n}" 2>/dev/null || true
    [ -f "$log_base.stderr.log" ] \
      && cp "$log_base.stderr.log" "${log_base}.stderr.log.attempt-${archive_n}" 2>/dev/null || true

    # Defensive guard: if the runner-checkout advanced between attempts, a
    # previous attempt committed partial work — retrying would replay
    # /implement over a half-committed state.
    if [ -n "$initial_head" ]; then
      local current_head
      current_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"
      if [ "$current_head" != "$initial_head" ]; then
        break
      fi
    fi

    # Select the wait before the next attempt. `attempt` is 1-based and
    # awk fields are 1-based, so attempt=1 picks field 1 (wait before
    # attempt 2), attempt=2 picks field 2 (wait before attempt 3), etc.
    # If the configured list is shorter than max, reuse the last entry so
    # the schedule never runs off the end. The 240 default is reachable
    # only when the list has no entries.
    local backoff
    backoff="$(echo "$backoffs" | awk -v n="$attempt" '{ if (NF > 0 && n > NF) n = NF; print $n }')"
    backoff="${backoff:-240}"

    local crash_class next_attempt
    crash_class="$(_transport_crash_class "${log_base}.stdout.jsonl.attempt-${archive_n}" "$rc")"
    next_attempt=$(( attempt + 1 ))
    echo "[$(now_clock)] runner: transport-crash detected ($crash_class) — retrying in ${backoff}s (attempt $next_attempt of $max)"

    # 1-second poll loop so RUNNER_INTERRUPTED cuts the sleep short — the run's
    # stop reason stays "interrupted", not "dispatch-aborted".
    local elapsed=0
    while [ "$elapsed" -lt "$backoff" ]; do
      if [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ]; then
        TRANSPORT_RETRY_ATTEMPTS=$attempt
        return "$rc"
      fi
      sleep 1
      elapsed=$(( elapsed + 1 ))
    done
    if [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ]; then
      TRANSPORT_RETRY_ATTEMPTS=$attempt
      return "$rc"
    fi
  done

  TRANSPORT_RETRY_ATTEMPTS=$attempt
  return "$rc"
}

# Wrap with_transport_retry with the window-exhausted retry class (issue
# #75). After a failed round whose stream's last parseable rate_limit_event
# has `status:"rejected"`, sleeps until resetsAt + 60s slack (fixed; a past
# resetsAt degrades to the bare 60s) — or RUNNER_WINDOW_RETRY_FALLBACK_WAIT
# when the event carries no resetsAt — then re-dispatches. Window-waits do
# not consume the transport budget: each round re-enters with_transport_retry
# with a fresh attempt counter, while archived artifacts continue the same
# `.attempt-<n>` numbering via TRANSPORT_RETRY_ATTEMPT_OFFSET.
#
# Bounded by RUNNER_WINDOW_RETRY_MAX_WAITS per dispatch; on a further
# rejection past the budget the wrapper gives up and sets
# WINDOW_RETRY_GAVE_UP=1 for the caller's outcome labeling (combined outcome
# `window-exhausted`, abort-flag type `window`). Gives up the same way —
# without waiting — when the runner-checkout HEAD advanced since the first
# round (issue #76): the round committed partial work before dying
# window-rejected, and re-dispatching would replay /implement over a
# half-committed state (the same refusal as with_transport_retry's
# checkout-advance guard). The wait is the
# interruptible 1s-poll pattern: Ctrl-C mid-wait returns the dispatch's exit
# code so the run's stop reason stays "interrupted" and no abort flag is
# written. No liveness renderer runs during the wait — the two static
# progress lines (wait-start, resume) are the operator surface, mirrored
# into runner.log by the existing capture.
#
# Sets TRANSPORT_RETRY_ATTEMPTS to the cumulative attempt count across all
# rounds (the SUMMARY `(N attempts)` input). Returns the final round's exit
# code; the final stream stays at `<base>.stdout.jsonl`.
#
# Args: $1=log_base  $2=dispatch_fn  [remaining args forwarded]
# Sourceable from bats.
with_window_retry() {
  local log_base="$1" dispatch_fn="$2"
  shift 2

  local max_waits="$RUNNER_WINDOW_RETRY_MAX_WAITS"
  local waits=0 rc=0 total_attempts=0
  WINDOW_RETRY_GAVE_UP=0

  # Capture the runner-checkout HEAD before the first round so the
  # checkout-advance guard below can see an advance from any round. The
  # transport wrapper's own guard cannot: each round re-enters
  # with_transport_retry, which captures a fresh baseline, and its
  # window-exhausted gate breaks out before its guard is reached.
  local initial_head
  initial_head="$(git -C "${HOST_CHECKOUT:-}" rev-parse HEAD 2>/dev/null || true)"

  while true; do
    rc=0
    TRANSPORT_RETRY_ATTEMPT_OFFSET="$total_attempts"
    with_transport_retry "$log_base" "$dispatch_fn" "$@" || rc=$?
    TRANSPORT_RETRY_ATTEMPT_OFFSET=0
    total_attempts=$(( total_attempts + ${TRANSPORT_RETRY_ATTEMPTS:-1} ))

    # Exit when: success, window retry disabled, interrupted, or the round
    # did not die window-exhausted.
    if [ "$rc" -eq 0 ] \
        || [ "${RUNNER_DISABLE_WINDOW_RETRY:-0}" = "1" ] \
        || [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ] \
        || ! is_window_exhausted "$log_base.stdout.jsonl"; then
      break
    fi
    # Checkout-advance guard (issue #76), mirroring with_transport_retry's:
    # an advanced runner-checkout HEAD means this round committed partial
    # work before dying window-rejected — waiting out the window and
    # re-dispatching would replay /implement over a half-committed state.
    # Give up through the wait-budget's signal so the outcome labeling
    # (combined outcome `window-exhausted`, abort-flag type `window`) is
    # unchanged: the maintainer reconciles either way.
    if [ -n "$initial_head" ]; then
      local current_head
      current_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"
      if [ "$current_head" != "$initial_head" ]; then
        format_window_giveup_line "$(now_clock)" \
          "$(window_rate_limit_type "$log_base.stdout.jsonl")"
        WINDOW_RETRY_GAVE_UP=1
        break
      fi
    fi

    if [ "$waits" -ge "$max_waits" ]; then
      # A rejection past the wait budget means the quota is structurally
      # insufficient for this dispatch, not a blip — give up.
      WINDOW_RETRY_GAVE_UP=1
      break
    fi
    waits=$(( waits + 1 ))

    # Archive the rejected round's artifacts, continuing the transport
    # wrapper's .attempt-<n> numbering.
    cp "$log_base.stdout.jsonl" "${log_base}.stdout.jsonl.attempt-${total_attempts}" 2>/dev/null || true
    [ -f "$log_base.stderr.log" ] \
      && cp "$log_base.stderr.log" "${log_base}.stderr.log.attempt-${total_attempts}" 2>/dev/null || true

    local resets_at rl_type wait_seconds now
    resets_at="$(window_resets_at "$log_base.stdout.jsonl")"
    rl_type="$(window_rate_limit_type "$log_base.stdout.jsonl")"
    now="$(date +%s)"
    if [ -n "$resets_at" ]; then
      wait_seconds="$(window_wait_seconds "$resets_at" "$now")"
      format_window_wait_line "$(now_clock)" "$rl_type" \
        "$(epoch_clock $(( now + wait_seconds )))" "$wait_seconds" "$waits" "$max_waits"
    else
      wait_seconds="$RUNNER_WINDOW_RETRY_FALLBACK_WAIT"
      format_window_wait_fallback_line "$(now_clock)" "$rl_type" \
        "$wait_seconds" "$waits" "$max_waits"
    fi

    # 1-second poll loop so RUNNER_INTERRUPTED cuts the wait short — the
    # run's stop reason stays "interrupted", not "window-exhausted".
    local elapsed=0
    while [ "$elapsed" -lt "$wait_seconds" ]; do
      if [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ]; then
        TRANSPORT_RETRY_ATTEMPTS="$total_attempts"
        return "$rc"
      fi
      sleep 1
      elapsed=$(( elapsed + 1 ))
    done
    if [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ]; then
      TRANSPORT_RETRY_ATTEMPTS="$total_attempts"
      return "$rc"
    fi
    format_window_resume_line "$(now_clock)"
  done

  TRANSPORT_RETRY_ATTEMPTS="$total_attempts"
  return "$rc"
}

# Implement-dispatch wrapper: hands `claude -p "/implement <ref>"` to the
# sandbox via the transport-retry layer, in streamed structured-event mode.
# Tracker-snapshot delta is the source of truth for the success/failure
# outcome (`classify_outcome` ignores the exit code); the exit code feeds only
# the transport-crash classifier's Rung-2 safety net (`is_transport_crash`).
run_dispatch_container() {
  local ref="$1" log_base="$2"
  local model_args=()
  [ -n "${ARG_MODEL:-}" ] && model_args=(--model "$ARG_MODEL")
  with_window_retry "$log_base" run_sandbox_container \
    claude -p "/implement $ref" --output-format stream-json --verbose --dangerously-skip-permissions \
    "${model_args[@]+"${model_args[@]}"}"
}

# Item-dispatch wrapper: cats the manifest item's prompt, appends the
# canonical issue ref, and hands the result to a fresh `claude -p` in
# the sandbox via the transport-retry layer. Tracker-snapshot delta +
# exit code drive `classify_item_action` in `walk_post_implement_steps`.
run_item_container() {
  local ref="$1" log_base="$2" prompt_path="$3"
  local prompt_text
  prompt_text="$(cat "$prompt_path")"$'\n'"$ref"
  local model_args=()
  [ -n "${ARG_MODEL:-}" ] && model_args=(--model "$ARG_MODEL")
  with_window_retry "$log_base" run_sandbox_container \
    claude -p "$prompt_text" --output-format stream-json --verbose --dangerously-skip-permissions \
    "${model_args[@]+"${model_args[@]}"}"
}

# === Runner remote registration =============================================

# Register (or verify) the `runner` git remote in the host repo. Called from
# pre-flight on every run. Three cases:
#   - Absent          → add the remote pointing at HOST_CHECKOUT.
#   - Present, URL matches HOST_CHECKOUT → no-op.
#   - Present, URL differs  → fail_invariant with the conflicting URL and
#     the recovery recipe; runner aborts pre-flight.
#
# Mutates only $HOST_REPO/.git/config. Never fetches, pushes, or writes refs.
ensure_runner_remote() {
  local current_url
  current_url="$(git -C "$HOST_REPO" remote get-url runner 2>/dev/null || true)"
  if [ -z "$current_url" ]; then
    git -C "$HOST_REPO" remote add runner "$HOST_CHECKOUT"
    return 0
  fi
  if [ "$current_url" = "$HOST_CHECKOUT" ]; then
    return 0
  fi
  fail_invariant "runner-remote" \
    "runner remote exists with URL '$current_url' (expected: '$HOST_CHECKOUT').
Fix with: git remote remove runner
(or: git remote set-url runner $HOST_CHECKOUT)"
}

# === Host fast-forward propagation =========================================

# Publish the feature branch to the per-feature parking ref
# (`refs/remotes/runner/<branch>` on host), then attempt a best-effort
# host fast-forward (`refs/heads/<branch>`).  Does not run `symbolic-ref`
# before the fast-forward attempt; post-refusal classification reads it to
# distinguish HEAD-on-target from non-ff refusal.
#
# Step 1 (fail-fatal): write to parking ref.  On failure: print diagnostic
#   to stderr, clear RUNNER_LAST_PROPAGATION, return 1 (error).
#
# Step 2 (best-effort): fast-forward host's branch ref without
#   --update-head-ok.  Git's own refusal (HEAD-on-target or non-ff) is the
#   parked-only trigger — the runner does not model "am I on-branch?".
#
# On return 0, RUNNER_LAST_PROPAGATION is set to the human-readable indicator
# that ends up in the SUMMARY column and the per-dispatch progress line:
#   'propagated → host'           — both steps succeeded (propagated-to-host)
#   'parked → runner/<branch>'    — step 1 ok, step 2 refused (parked-only)
# and the same indicator is printed to stdout.
#
# On return 1 (error), RUNNER_LAST_PROPAGATION is cleared to ''.
#
# Args: $1 = branch name
propagate_feature() {
  local branch="$1"
  local parking_ref="refs/remotes/runner/${branch}"

  # Step 1: publish to parking ref — fail-fatal. The `+` prefix force-updates
  # the parking ref; it is runner-owned and its semantics are "this is the
  # latest tip the runner produced for <branch>", not "an append-only history".
  # The force-update is the recovery path for the diverged case: when the
  # maintainer pulls runner work and rebases, the next runner dispatch's tip
  # is no longer a descendant of the prior parking-ref tip, and a non-`+`
  # refspec would refuse as non-fast-forward.
  #
  # Git's own stderr is left to flow through so runner.log carries the actual
  # failure cause (permissions, lock contention, FS error, disk full) ahead
  # of the runner's heredoc — diagnostic without re-running the recipe.
  if ! git -C "$HOST_REPO" fetch --quiet "$HOST_CHECKOUT" \
      "+${branch}:${parking_ref}" >&2; then
    cat >&2 <<MSG
runner: propagation error — failed to publish to parking ref '${parking_ref}'.
The dispatched commit lives in the runner-checkout. Recover with:

    git -C $HOST_REPO fetch $HOST_CHECKOUT +${branch}:${parking_ref}

(The runner did NOT push to any remote.)
MSG
    RUNNER_LAST_PROPAGATION=""
    return 1
  fi

  # Step 2: best-effort host fast-forward — no --update-head-ok.
  # Capture stderr so we can surface true errors (lock contention, FS
  # error, etc.) to runner.log without printing the noisy diagnostic on
  # every expected refusal.  `|| rc=$?` keeps set -e happy on non-zero.
  local step2_stderr step2_rc=0
  step2_stderr="$(git -C "$HOST_REPO" fetch --quiet "$HOST_CHECKOUT" \
      "${branch}:${branch}" 2>&1)" || step2_rc=$?
  if [ "$step2_rc" -eq 0 ]; then
    RUNNER_LAST_PROPAGATION="propagated → host"
    printf '[%s] %s\n' "$(now_clock)" "$RUNNER_LAST_PROPAGATION"
  else
    # Two refusal modes are expected and self-evidently safe:
    #   - HEAD-on-target: host has the target branch checked out.
    #   - non-fast-forward: host's branch and the parking ref diverged.
    # Anything else (lock contention, FS error, etc.) is unusual and worth
    # surfacing to runner.log even though the classification stays `parked`
    # — the work is on the parking ref either way. Distinguish via
    # post-conditions rather than parsing git's locale-dependent stderr.
    local host_head host_tip checkout_tip expected_refusal=0
    host_head="$(git -C "$HOST_REPO" symbolic-ref --quiet HEAD 2>/dev/null || true)"
    host_tip="$(git -C "$HOST_REPO" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)"
    checkout_tip="$(git -C "$HOST_CHECKOUT" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)"
    if [ "$host_head" = "refs/heads/${branch}" ]; then
      expected_refusal=1
    elif [ -n "$host_tip" ] && [ -n "$checkout_tip" ] \
        && ! git -C "$HOST_REPO" merge-base --is-ancestor \
            "$host_tip" "$checkout_tip" 2>/dev/null; then
      expected_refusal=1
    fi
    if [ "$expected_refusal" -eq 0 ]; then
      printf 'runner: unexpected step-2 fetch failure for branch %s:\n%s\n' \
        "$branch" "$step2_stderr" >&2
    fi
    RUNNER_LAST_PROPAGATION="parked → runner/${branch}"
    printf '[%s] %s (git pull runner %s)\n' "$(now_clock)" "$RUNNER_LAST_PROPAGATION" "$branch"
  fi
}

# Sweep stale parking refs from the host repo. Called once per run, before
# any tracker query or dispatch. A slug is stale only when TWO reachability
# proofs hold simultaneously:
#
#   (1) The host parking ref's tip commit is reachable from at least one
#       other host ref (excluding the parking ref itself and
#       refs/remotes/runner/HEAD). Proves the parking ref's work is
#       preserved on host.
#
#   (2) The runner-checkout's refs/heads/<slug> tip (if the branch is
#       present) is also reachable from at least one host ref (same
#       exclusions). Proves the source branch carries no commits the host
#       doesn't already have. Without this check, a prior dispatch whose
#       propagate-step failed could leave the source ahead of the parking
#       ref — deleting the source would lose unpropagated commits.
#
# When both proofs hold, the runner-checkout's refs/heads/<slug> is deleted
# first, then host's refs/remotes/runner/<slug>. Source-first ordering
# avoids a race where an interleaved `git fetch runner` (IDE auto-fetch,
# explicit `git fetch --all`, etc.) between the two deletes would restore
# the host parking ref from the surviving source. If the source-side
# delete fails (lock contention, permission denied), the host parking ref
# is NOT deleted either — proceeding alone would silently reintroduce the
# original cluttering bug on the next fetch.
#
# Safety invariant: a ref is deleted only when git proves its tip commit
# is reachable from another host ref AND the corresponding deletion on
# the other side succeeded (or wasn't needed). No commit is ever lost.
#
# Skips refs/remotes/runner/HEAD (the symbolic ref git creates for the
# runner remote — never a parking ref).
# Skips a slug with a warning when the parking ref's tip is unreadable,
# the source-branch tip on the runner-checkout is unreadable, source
# reachability proof (2) fails, or the source-side delete fails. The
# sweep must not abort the run.
# When HOST_CHECKOUT is unset, the source-side proof is skipped and the
# host-only delete runs (test-only path for tests that don't model a
# runner-checkout; production always sets HOST_CHECKOUT).
#
# Side effects:
#   - Deletes runner-checkout refs/heads/<slug> via git update-ref -d.
#   - Deletes host refs/remotes/runner/<slug> via git update-ref -d.
#   - Appends swept parking ref names to RUN_SWEPT_REFS global array.
#   - Logs each deletion to stdout (mirrored into runner.log via tee).
#   - Logs skip-with-warning cases to stderr.
sweep_stale_parking_refs() {
  local ref tip witness slug source_tip source_witness candidate show_rc
  local parking_refs=()

  # Collect all parking refs, excluding HEAD. git for-each-ref lists refs
  # even when their objects are missing; the rev-parse guard below handles
  # unresolvable tips by emitting a warning and continuing.
  # Process substitution avoids a subshell so RUN_SWEPT_REFS persists.
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    [[ "$ref" == "refs/remotes/runner/HEAD" ]] && continue
    parking_refs+=("$ref")
  done < <(git -C "$HOST_REPO" for-each-ref --format='%(refname)' \
    'refs/remotes/runner/' 2>/dev/null)

  [[ "${#parking_refs[@]}" -eq 0 ]] && return 0

  for ref in "${parking_refs[@]}"; do
    # Resolve the parking-ref tip. --verify returns non-zero for a missing
    # or corrupt object; ^{commit} dereferences tag objects.
    tip="$(git -C "$HOST_REPO" rev-parse --verify "${ref}^{commit}" 2>/dev/null)" || {
      printf 'runner: sweep: skipping %s — tip commit unreadable\n' "$ref" >&2
      continue
    }

    # Proof (1): another host ref must contain the parking-ref tip.
    witness=""
    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      [[ "$candidate" == "$ref" ]] && continue
      [[ "$candidate" == "refs/remotes/runner/HEAD" ]] && continue
      witness="$candidate"
      break
    done < <(git -C "$HOST_REPO" for-each-ref --format='%(refname)' \
      --contains "$tip" 2>/dev/null)

    [[ -z "$witness" ]] && continue

    slug="${ref#refs/remotes/runner/}"

    # Proof (2): if the runner-checkout has a source branch for this slug,
    # its tip must be reachable from a host ref too. show-ref exits 0 for
    # a valid ref, 1 for a missing ref, and 128 for a ref entry that exists
    # but whose tip object is unreadable. We treat 0 and 128 alike ("ref
    # entry present"); the rev-parse below distinguishes valid from corrupt
    # and skips the slug with a warning on corrupt. A 1 exit means there's
    # nothing on the source side — the host-only delete is safe.
    # When HOST_CHECKOUT is unset (test-only path; production always sets
    # it), the entire source-side block is skipped.
    if [[ -n "$HOST_CHECKOUT" ]]; then
      # `|| show_rc=$?` makes show-ref a tested command (so its non-zero
      # exit doesn't trip set -e in callers like bats), while still
      # capturing the exit code. show-ref returns 1 specifically for
      # "ref absent"; 0 for a valid ref; 128 for "bad ref" (entry exists
      # but tip object unreadable). Any other rc is unexpected — treat as
      # "ref might exist" and defer to rev-parse below, which either
      # succeeds or skips the slug with the corrupt-tip warning. That's
      # safer than treating unknown rc as "absent" and proceeding to the
      # host-only delete, which could reintroduce the resurrection bug.
      show_rc=0
      git -C "$HOST_CHECKOUT" show-ref --verify --quiet "refs/heads/${slug}" 2>/dev/null \
        || show_rc=$?

      if [[ "$show_rc" -ne 1 ]]; then
        source_tip="$(git -C "$HOST_CHECKOUT" rev-parse --verify \
          "refs/heads/${slug}^{commit}" 2>/dev/null)" || {
          printf 'runner: sweep: skipping %s — runner-checkout refs/heads/%s tip unreadable\n' \
            "$ref" "$slug" >&2
          continue
        }

        source_witness=""
        while IFS= read -r candidate; do
          [[ -z "$candidate" ]] && continue
          [[ "$candidate" == "$ref" ]] && continue
          [[ "$candidate" == "refs/remotes/runner/HEAD" ]] && continue
          source_witness="$candidate"
          break
        done < <(git -C "$HOST_REPO" for-each-ref --format='%(refname)' \
          --contains "$source_tip" 2>/dev/null)

        if [[ -z "$source_witness" ]]; then
          # Source has work not preserved by any host ref — either the
          # tip's object isn't in HOST_REPO's DB (typical when a prior
          # dispatch's propagate-step failed before publishing), or it's
          # in the DB but no host ref reaches it. Sweeping would either
          # lose the unpropagated commits (delete source) or invisibly
          # reintroduce the resurrection bug (delete only the host ref,
          # next fetch restores it from the ahead source). Keep both;
          # the slug self-cleans on the next successful propagate.
          printf 'runner: sweep: keeping %s — runner-checkout refs/heads/%s has work not preserved by any host ref\n' \
            "$ref" "$slug" >&2
          continue
        fi

        # Source-first delete. Errors here (lock contention, permissions,
        # etc.) are NOT swallowed: if the source can't be removed, the host
        # ref must not be removed either — the next fetch would restore it
        # from the surviving source and silently reintroduce the original
        # cluttering bug.
        if ! git -C "$HOST_CHECKOUT" update-ref -d "refs/heads/${slug}" 2>/dev/null; then
          printf 'runner: sweep: skipping %s — failed to delete runner-checkout refs/heads/%s\n' \
            "$ref" "$slug" >&2
          continue
        fi
        printf 'runner: swept runner-checkout source refs/heads/%s (reachable from %s)\n' \
          "$slug" "$source_witness"
      fi
    fi

    # Source is absent, was just deleted, or HOST_CHECKOUT is unset.
    # Remove the host parking ref. update-ref errors surface to stderr.
    git -C "$HOST_REPO" update-ref -d "$ref"
    printf 'runner: swept stale parking ref %s (reachable from %s)\n' "$ref" "$witness"
    RUN_SWEPT_REFS+=("$ref")
  done

  # Skip-with-warning paths above use `continue`, which leaves $? at
  # whatever the failed git call returned. Without an explicit return, a
  # single-ref sweep whose only ref hit a skip path would propagate that
  # non-zero $? to set-e callers — notably the bats harness, which fails
  # the test on any non-zero exit from a direct function call.
  return 0
}

# === Top-level dispatch ====================================================

# Copy any core-dump untracked files from the runner-checkout into the run-
# state directory before the per-iteration sweep removes them.
#
# Args: $1=dirty_list (output of `git status --porcelain`)
#       $2=run_dir  $3=feature  $4=nn
capture_dispatch_core_files() {
  local dirty_list="$1" run_dir="$2" feature="$3" nn="$4"
  [ -z "$dirty_list" ] && return 0

  local line path bn dest_suffix src dest_dir dest
  while IFS= read -r line; do
    [[ "$line" == '?? '* ]] || continue
    path="${line:3}"
    bn="$(basename -- "$path")"
    [[ "$bn" == "core" || "$bn" == core.* ]] || continue
    src="$HOST_CHECKOUT/$path"
    [ -e "$src" ] || continue
    dest_dir="$run_dir/$feature"
    # Use the full relative path (slashes → dashes) to avoid silent overwrites
    # when two core files share the same basename (e.g. "core" at root and
    # "framework/runner/tests/core" in a subdirectory).
    dest_suffix="${path//\//-}"
    dest="$dest_dir/${nn}-core.${dest_suffix}"
    mkdir -p "$dest_dir"
    cp -- "$src" "$dest"
  done <<< "$dirty_list"
}

# Walk the resolved manifest items one by one after a successful implement.
# For each item: dispatch in the sandbox, propagate committed work by commit
# delta, snapshot, classify with classify_item_action, and react.
#
# The walk stops as soon as the issue reaches a terminal state (stop-success)
# or a failure occurs. If the list is exhausted with the issue still at
# in-review, the outcome is a neutral "left-for-human" with no abort flag.
#
# Args:
#   $1  = feature
#   $2  = nn
#   $3  = ref (binding-native)
#   $4  = run_dir
#   $5  = log_dir
#   $6  = log_basename (<NN> — item logs are <NN>-<step>-<label>.log)
#   $7  = post_implement_json
#   $8  = impl_label (in-review|done — used when manifest is empty)
#   $9  = impl_duration (seconds, accumulated into iter_duration)
#   $10 = impl_attempts
#   $11 = resolved_manifest (tab-delimited label<TAB>path, one per line)
#
# Side effects: record_dispatch called exactly once; write_abort_flag on
# gate-failed/review-aborted; RUN_STOP_REASON set on propagation-error or
# runaway-halt (<ref>) (propagation-error wins if a runaway item's commits
# also fail to propagate); RUNNER_LAST_PROPAGATION set by propagate_feature
# calls.
#
# Return: 0 on success (done or left-for-human), 1 on failure.
# Sourceable from bats.
walk_post_implement_steps() {
  local feature="$1" nn="$2" ref="$3"
  local run_dir="$4" log_dir="$5" log_basename="$6"
  local post_implement_json="$7"
  local impl_label="$8" impl_duration="$9" impl_attempts="${10}"
  local resolved_manifest="${11}"

  local total_item_seconds=0
  local total_attempts="$impl_attempts"
  local any_item_ran=0
  local step_idx=0       # walk-position counter (1-based, incremented per item)
  local step_logs=""     # colon-sep list of step-log suffixes accumulated during walk

  while IFS=$'\t' read -r item_label item_path; do
    [ -z "$item_label" ] && continue

    any_item_ran=1
    step_idx=$(( step_idx + 1 ))
    local step_suffix
    step_suffix="$(printf '%02d' "$step_idx")-$item_label"
    if [ -z "$step_logs" ]; then
      step_logs="$step_suffix"
    else
      step_logs="$step_logs:$step_suffix"
    fi
    local item_log_base="$log_dir/$log_basename-$step_suffix"

    # Emit the "starting" progress line for this item.
    local item_start_clock
    item_start_clock="$(now_clock)"
    format_progress_start "$item_start_clock" "$ref" "$item_label"

    # Capture HEAD before dispatch to detect a commit delta.
    local pre_item_head
    pre_item_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"

    local item_started_at
    item_started_at=$(date +%s)

    # Liveness-line context for this walk item (read by start_liveness_renderer).
    RUNNER_LIVENESS_FEATURE="$feature"
    RUNNER_LIVENESS_ISSUE="$nn"
    RUNNER_LIVENESS_STAGE="$item_label"
    RUNNER_LIVENESS_STARTED_AT="$item_started_at"

    local item_rc=0
    run_item_container "$ref" "$item_log_base" "$item_path" || item_rc=$?
    local item_attempts="${TRANSPORT_RETRY_ATTEMPTS:-1}"
    local item_window_gave_up="${WINDOW_RETRY_GAVE_UP:-0}"
    total_attempts="$item_attempts"

    # Extract the agent's closing message into the per-step readable summary.
    extract_result_summary "$item_log_base.stdout.jsonl" >"$item_log_base.summary.md"

    local post_item_head
    post_item_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"

    local item_has_runner_commits=0
    if [ -n "$pre_item_head" ] && [ -n "$post_item_head" ] \
        && [ "$pre_item_head" != "$post_item_head" ]; then
      item_has_runner_commits=1
    fi

    # Transport-crash is decided from the structured result event plus the exit
    # code (is_transport_crash's two-rung contract). The structured verdict is
    # authoritative even on a clean exit, so the call is unconditional.
    local item_transport_crash=false
    if is_transport_crash "$item_log_base.stdout.jsonl" "$item_rc"; then
      item_transport_crash=true
    fi

    # Snapshot failure takes precedence over the transport-crash signal.
    # Park any committed work first so the next lazy-init doesn't wipe it.
    local post_item_json
    if ! post_item_json="$(take_snapshot "$feature")"; then
      local snap_fail_at snap_item_duration snap_iter_duration
      snap_fail_at=$(date +%s)
      snap_item_duration=$(( snap_fail_at - item_started_at ))
      snap_iter_duration=$(( impl_duration + total_item_seconds + snap_item_duration ))
      echo "runner: walk_post_implement_steps: tracker-snapshot failed (post-$item_label) for ref '$ref'" >&2
      if [ "$item_has_runner_commits" -eq 1 ]; then
        if ! propagate_feature "$feature"; then
          local halt_duration
          halt_duration=$(( $(date +%s) - item_started_at + impl_duration + total_item_seconds ))
          RUN_STOP_REASON="propagation-error"
          record_dispatch "$feature" "$nn" "$ref" "FAIL" "$halt_duration" "$step_logs" "$total_attempts"
          return 1
        fi
      fi
      RUN_STOP_REASON="snapshot-failed-mid-dispatch:post-$item_label"
      record_dispatch "$feature" "$nn" "$ref" "FAIL" "$snap_iter_duration" "$step_logs" "$total_attempts"
      return 1
    fi

    local item_ended_at item_duration iter_duration
    item_ended_at=$(date +%s)
    item_duration=$(( item_ended_at - item_started_at ))
    total_item_seconds=$(( total_item_seconds + item_duration ))
    iter_duration=$(( impl_duration + total_item_seconds ))

    # Extract post-item status for classify_item_action.
    local post_item_status
    post_item_status="$(jq -r --arg r "$ref" \
      '(.issues[] | select(.ref == $r) | .status) // empty' <<<"$post_item_json")"

    local item_action
    item_action="$(classify_item_action "$post_item_status" "$item_rc")"

    case "$item_action" in
      stop-success)
        format_progress_outcome "$(now_clock)" "$ref" "$item_label" "clean → done" "$item_duration"
        if [ "$item_has_runner_commits" -eq 1 ]; then
          if ! propagate_feature "$feature"; then
            local halt_duration
            halt_duration=$(( $(date +%s) - item_started_at + impl_duration + total_item_seconds - item_duration ))
            format_progress_outcome "$(now_clock)" "$ref" "$item_label" "halt → gate-failed" "$item_duration"
            record_dispatch "$feature" "$nn" "$ref" "gate-failed" "$halt_duration" "$step_logs" "$total_attempts"
            RUN_STOP_REASON="propagation-error"
            return 1
          fi
        fi
        record_dispatch "$feature" "$nn" "$ref" "done" "$iter_duration" "$step_logs" "$total_attempts"
        return 0
        ;;

      fail)
        # window-exhausted takes precedence over the transport flavour — the
        # rejected window's accompanying 429 still reads as a transport crash.
        local item_combined_label item_progress_label
        if [ "$item_window_gave_up" = "1" ]; then
          item_progress_label="window-exhausted"
          item_combined_label="window-exhausted"
        elif [ "$item_transport_crash" = "true" ]; then
          item_progress_label="review-aborted"
          item_combined_label="review-aborted"
        else
          item_progress_label="gate-failed"
          item_combined_label="gate-failed"
        fi
        format_progress_outcome "$(now_clock)" "$ref" "$item_label" "$item_progress_label" "$item_duration"
        local flag_type="technical"
        [ "$item_transport_crash" = "true" ] && flag_type="transport"
        [ "$item_window_gave_up" = "1" ] && flag_type="window"
        write_abort_flag "$feature" "$nn" "$item_label" "$item_rc" "$item_log_base.stdout.jsonl" "$flag_type"
        if [ "$item_has_runner_commits" -eq 1 ]; then
          if ! propagate_feature "$feature"; then
            local halt_duration
            halt_duration=$(( $(date +%s) - item_started_at + impl_duration + total_item_seconds - item_duration ))
            format_progress_outcome "$(now_clock)" "$ref" "$item_label" "halt → $item_combined_label" "$item_duration"
            record_dispatch "$feature" "$nn" "$ref" "$item_combined_label" "$halt_duration" "$step_logs" "$total_attempts"
            RUN_STOP_REASON="propagation-error"
            return 1
          fi
        fi
        record_dispatch "$feature" "$nn" "$ref" "$item_combined_label" "$iter_duration" "$step_logs" "$total_attempts"
        return 1
        ;;

      terminate-run)
        # The post-implement step pushed the issue back to ready-for-agent
        # (eligible). This is a misconfigured manifest — halt the entire run.
        # Do NOT write an abort flag: the issue is eligible, not stuck.
        format_progress_outcome "$(now_clock)" "$ref" "$item_label" "halt → runaway" "$item_duration"
        if [ "$item_has_runner_commits" -eq 1 ]; then
          if ! propagate_feature "$feature"; then
            local halt_duration
            halt_duration=$(( $(date +%s) - item_started_at + impl_duration + total_item_seconds - item_duration ))
            RUN_STOP_REASON="propagation-error"
            record_dispatch "$feature" "$nn" "$ref" "halt → runaway" "$halt_duration" "$step_logs" "$total_attempts"
            return 1
          fi
        fi
        RUN_STOP_REASON="runaway-halt ($ref)"
        record_dispatch "$feature" "$nn" "$ref" "halt → runaway" "$iter_duration" "$step_logs" "$total_attempts"
        return 1
        ;;

      continue)
        # Issue still at in-review; proceed to the next manifest item.
        # Emit this item's progress line now ("left-for-human" reflects the
        # issue's current state). Only the combined-outcome record_dispatch is
        # deferred to after the loop — that's where we know whether more items
        # followed or this was the last.
        format_progress_outcome "$(now_clock)" "$ref" "$item_label" "left-for-human" "$item_duration"
        if [ "$item_has_runner_commits" -eq 1 ]; then
          if ! propagate_feature "$feature"; then
            local halt_duration
            halt_duration=$(( $(date +%s) - item_started_at + impl_duration + total_item_seconds - item_duration ))
            format_progress_outcome "$(now_clock)" "$ref" "$item_label" "halt → gate-failed" "$item_duration"
            record_dispatch "$feature" "$nn" "$ref" "gate-failed" "$halt_duration" "$step_logs" "$total_attempts"
            RUN_STOP_REASON="propagation-error"
            return 1
          fi
        fi
        ;;
    esac
  done <<< "$resolved_manifest"

  # All manifest items exhausted with the issue still at in-review (or
  # manifest was empty — implement-only run). Either way the issue is
  # intentionally left at in-review for the maintainer; "left-for-human"
  # is the correct combined outcome for both cases (no abort flag).
  # step_logs is empty when no items ran (implement-only); non-empty otherwise.
  record_dispatch "$feature" "$nn" "$ref" "left-for-human" \
    "$(( impl_duration + total_item_seconds ))" "$step_logs" "$total_attempts"
  return 0
}

# Dispatch one issue end-to-end inside the run dir at $3. Consumes a
# (feature, nn) pair — never regex-parses the binding-native ref. The
# binding-native ref is resolved via `binding_native_ref` from the pre-
# dispatch snapshot. Mutates only files under the run dir; classifier
# verdict is derived from snapshots taken in the runner-checkout.
#
# Sets $RUNNER_LAST_PROPAGATION to `propagated → host` or
# `parked → runner/<branch>` on the success path (empty on failure or
# when no propagation occurred). Return code: 0 = success, 1 = failure.
# On a parking-ref publish error, also sets
# RUN_STOP_REASON="propagation-error" so run_loop breaks the loop; a
# post-implement step that pushes the issue back to an eligible state sets
# RUN_STOP_REASON="runaway-halt (<ref>)" (or "propagation-error" if that
# item's runner commits also fail to propagate).
#
# Args: $1=feature  $2=nn  $3=run_dir
dispatch_one() {
  local feature="$1" nn="$2" run_dir="$3"

  local log_dir log_basename
  if [ "$RUN_LOG_LAYOUT" = "nested" ]; then
    log_dir="$run_dir/$feature"
    log_basename="$nn"
    mkdir -p "$log_dir"
  else
    log_dir="$run_dir"
    log_basename="$nn"
    mkdir -p "$run_dir"
  fi
  local log_base="$log_dir/$log_basename"
  local exit_file="$log_base.exit"

  local pre_json post_implement_json
  if ! pre_json="$(take_snapshot "$feature")"; then
    echo "runner: dispatch_one: tracker-snapshot failed (pre stage) for feature '$feature' issue '$nn'" >&2
    RUN_STOP_REASON="snapshot-failed-mid-dispatch:pre"
    record_dispatch "$feature" "$nn" "(unresolved)" "FAIL" 0
    return 1
  fi

  # Resolve the binding-native ref from the pre-snapshot.  The classifier
  # and dispatch container both receive this ref so they query / invoke
  # the correct binding-native identifier. For local-markdown this is
  # `<feature>/NN`; for github-issues it is `#N`.
  local ref
  if ! ref="$(binding_native_ref "$feature" "$nn" "$pre_json")"; then
    echo "runner: dispatch_one: ($feature, $nn) not found in pre-snapshot" >&2
    RUN_STOP_REASON="snapshot-failed-mid-dispatch:pre"
    record_dispatch "$feature" "$nn" "(unresolved)" "FAIL" 0
    return 1
  fi

  # === Implement stage =====================================================
  local started_at start_clock
  started_at=$(date +%s)
  start_clock="$(now_clock)"
  format_progress_start "$start_clock" "$ref" "implement"

  # Liveness-line context for this stage (read by start_liveness_renderer).
  RUNNER_LIVENESS_FEATURE="$feature"
  RUNNER_LIVENESS_ISSUE="$nn"
  RUNNER_LIVENESS_STAGE="implement"
  RUNNER_LIVENESS_STARTED_AT="$started_at"

  # Capture the runner-checkout's HEAD before and after the dispatch.
  # The pre-iteration `ensure_runner_checkout` syncs HEAD to host's
  # branch tip, so any post-dispatch advance means the container
  # committed something. That signal — not the classifier verdict —
  # gates implement-stage propagation: a `/implement` bail leaves status
  # at `ready-for-agent` (classifier=failure) but commits an explanatory
  # `tracker:` comment that must reach the host before the next
  # iteration's reset wipes it.
  local pre_implement_head
  pre_implement_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"

  local impl_rc=0
  run_dispatch_container "$ref" "$log_base" || impl_rc=$?
  local impl_attempts="${TRANSPORT_RETRY_ATTEMPTS:-1}"
  local impl_window_gave_up="${WINDOW_RETRY_GAVE_UP:-0}"
  echo "$impl_rc" > "$exit_file"

  # Extract the agent's closing message into the per-dispatch readable summary.
  extract_result_summary "$log_base.stdout.jsonl" >"$log_base.summary.md"

  local post_implement_head
  post_implement_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"

  # Transport-crash is decided from the structured result event plus the exit
  # code (is_transport_crash's two-rung contract). The structured verdict is
  # authoritative even on a clean exit, so the call is unconditional.
  local impl_transport_crash=false
  if is_transport_crash "$log_base.stdout.jsonl" "$impl_rc"; then
    impl_transport_crash=true
  fi

  # Compute the commit-delta gate before any failure exit: the
  # post-implement snapshot-failure branch below needs it to park the
  # work to the parking ref before bailing, so the next iteration's
  # lazy-init doesn't wipe an unpublished commit.
  local impl_has_runner_commits=0
  if [ -n "$pre_implement_head" ] && [ -n "$post_implement_head" ] \
      && [ "$pre_implement_head" != "$post_implement_head" ]; then
    impl_has_runner_commits=1
  fi

  # Snapshot failure takes precedence over the transport-crash signal: if the
  # post-implement snapshot fails, we cannot determine the issue's state, so we
  # record FAIL and stop. No abort flag is written — the stop-reason already
  # signals a system-level problem to the operator, and re-running the same
  # issue against a broken snapshot would be pointless. Park any committed
  # work to the parking ref first so the next iteration's lazy-init doesn't
  # silently wipe it — whether the snapshot is readable is independent of
  # whether the commit needs to reach host.
  if ! post_implement_json="$(take_snapshot "$feature")"; then
    local snap_fail_at snap_duration
    snap_fail_at=$(date +%s)
    snap_duration=$(( snap_fail_at - started_at ))
    echo "runner: dispatch_one: tracker-snapshot failed (post-implement stage) for ref '$ref'" >&2
    if [ "$impl_has_runner_commits" -eq 1 ]; then
      if ! propagate_feature "$feature"; then
        local halt_duration
        halt_duration=$(( $(date +%s) - started_at ))
        RUN_STOP_REASON="propagation-error"
        record_dispatch "$feature" "$nn" "$ref" "FAIL" "$halt_duration" "" "$impl_attempts"
        return 1
      fi
    fi
    RUN_STOP_REASON="snapshot-failed-mid-dispatch:post-implement"
    record_dispatch "$feature" "$nn" "$ref" "FAIL" "$snap_duration" "" "$impl_attempts"
    return 1
  fi

  local classifier_verdict
  classifier_verdict="$(classify_outcome "$pre_json" "$post_implement_json" "$ref" "$impl_transport_crash")"

  # Diagnostic only — the classifier above already reads committed state,
  # so its verdict matches what would propagate. Surfacing the dirty file
  # list helps the operator see what `/implement` neglected to commit
  # (e.g. a missed `tracker: move … to in-review` commit) when the
  # outcome is unexpectedly `failure`.
  # --untracked-files=all enumerates files inside untracked directories;
  # the default summarises them as a single `?? <dir>/` entry, whose
  # basename is the directory itself — `capture_dispatch_core_files`
  # matches `core | core.*` on basename, so a core dropped inside an
  # untracked subdirectory would never be captured without the flag.
  local dirty
  dirty="$(git -C "$HOST_CHECKOUT" status --porcelain --untracked-files=all)"

  local impl_ended_at impl_duration
  impl_ended_at=$(date +%s)
  impl_duration=$(( impl_ended_at - started_at ))

  # Implement stage outcome label: in-review|done from the post-snapshot
  # on classifier success, window-exhausted when the window-retry wrapper
  # gave up (takes precedence over the transport flavour — the accompanying
  # 429 still reads as a transport crash), dispatch-aborted on transport
  # crash, FAIL otherwise. /implement normally lands at in-review; a
  # maintainer-adjusted brief may land at done.
  local impl_label="FAIL"
  if [ "$classifier_verdict" = "success" ]; then
    local post_status
    post_status="$(jq -r --arg r "$ref" \
      '(.issues[] | select(.ref == $r) | .status) // empty' <<<"$post_implement_json")"
    case "$post_status" in
      in-review|done) impl_label="$post_status" ;;
      *)              impl_label="FAIL" ;;
    esac
  elif [ "$impl_window_gave_up" = "1" ]; then
    impl_label="window-exhausted"
  elif [ "$classifier_verdict" = "dispatch-aborted" ]; then
    impl_label="dispatch-aborted"
  fi

  format_progress_outcome "$(now_clock)" "$ref" "implement" "$impl_label" "$impl_duration"
  if [ -n "$dirty" ]; then
    echo "runner: dispatch left runner-checkout with uncommitted changes:" >&2
    echo "$dirty" | sed 's/^/  /' >&2
  fi
  capture_dispatch_core_files "$dirty" "$run_dir" "$feature" "$nn"

  # Propagate any committed runner-checkout work to the host, regardless
  # of the classifier's verdict. This makes the host repo a faithful
  # record of every dispatch's tracker output — successful in-review
  # flips, comment-only `tracker:` posts on a `/implement` bail, and any
  # future logical-bail status flips. A genuine technical failure
  # (container died before commit) leaves the runner-checkout at host's
  # tip, so this branch is a no-op for it. A parking-ref publish failure
  # (error outcome) halts the loop via RUN_STOP_REASON="propagation-error":
  # the runner-checkout still holds the un-published commits, and the next
  # sync would wipe them if the loop continued.
  if [ "$impl_has_runner_commits" -eq 1 ]; then
    if ! propagate_feature "$feature"; then
      # The original outcome line above already showed the implement-step
      # result (in-review/done). Emit a follow-up `halt → FAIL` line so
      # the operator's terminal record matches the SUMMARY.md row, while
      # preserving the forensic story (implement landed; propagation
      # error) in runner.log.
      local halt_duration
      halt_duration=$(( $(date +%s) - started_at ))
      format_progress_outcome "$(now_clock)" "$ref" "implement" "halt → FAIL" "$halt_duration"
      record_dispatch "$feature" "$nn" "$ref" "FAIL" "$halt_duration" "" "$impl_attempts"
      RUN_STOP_REASON="propagation-error"
      return 1
    fi
  fi
  if [ "$classifier_verdict" != "success" ]; then
    # Write the abort flag only when the post-implement status is still
    # eligible — the genuine "stuck" case where the next iteration would
    # re-pick the same issue. When the status flipped to a non-eligible
    # state (e.g. needs-info from a logical bail), the snapshot's own
    # eligibility filter already excludes it; no flag needed.
    local post_eligible
    post_eligible="$(jq -r --arg r "$ref" \
      '(.issues[] | select(.ref == $r) | .eligible) // "false"' <<<"$post_implement_json")"
    if [ "$post_eligible" = "true" ]; then
      local impl_flag_type="technical"
      [ "$classifier_verdict" = "dispatch-aborted" ] && impl_flag_type="transport"
      [ "$impl_window_gave_up" = "1" ] && impl_flag_type="window"
      write_abort_flag "$feature" "$nn" "implement" "$impl_rc" "$log_base.stdout.jsonl" "$impl_flag_type"
    fi
    local impl_abort_outcome="FAIL"
    [ "$classifier_verdict" = "dispatch-aborted" ] && impl_abort_outcome="dispatch-aborted"
    [ "$impl_window_gave_up" = "1" ] && impl_abort_outcome="window-exhausted"
    record_dispatch "$feature" "$nn" "$ref" "$impl_abort_outcome" "$impl_duration" "" "$impl_attempts"
    return 1
  fi

  # === Post-implement walk =====================================================
  # The runner dispatches eligible AFK refs only — both single-dispatch
  # and loop mode enforce that gate before reaching `dispatch_one`. Every
  # successful AFK implement proceeds to the manifest walk.

  # Guard: a signal in the window between implement-finish and walk-start
  # (while IN_FLIGHT_CID_FILE is empty) sets RUNNER_INTERRUPTED without
  # reaching the first item container. Record what we have and exit cleanly
  # so the loop's top-of-iteration check handles the stop.
  if [ "$RUNNER_INTERRUPTED" -eq 1 ]; then
    record_dispatch "$feature" "$nn" "$ref" "$impl_label" "$impl_duration" "" "$impl_attempts"
    return 0
  fi

  walk_post_implement_steps \
    "$feature" "$nn" "$ref" \
    "$run_dir" "$log_dir" "$log_basename" \
    "$post_implement_json" \
    "$impl_label" "$impl_duration" "$impl_attempts" \
    "$RESOLVED_MANIFEST"
}

# === Run entry points ======================================================

# Single-dispatch entry — refuses any ref the loop's eligibility filter
# would reject, then delegates to `dispatch_one`. Pre-flight has already
# run (including `check_feature_eligibility`, which gates `unknown-feature`);
# ARG_ISSUE_REF is set; RUN_DIR was created in main().
#
# The runner dispatches "eligible AFK refs only" by contract — both modes
# share that gate. The loop enforces it via the snapshot's `eligible`
# flag at selection time; single-dispatch reads the same flag for the
# named ref before calling dispatch_one. On refusal, prints a diagnostic
# naming the reason (HITL type, wrong status, blockers unmet, ref
# missing from feature), sets RUN_STOP_REASON, and returns 2 — the same
# exit code argparse uses for input-validation rejections.
run_single() {
  # Feature-level refusal (unknown-feature) was already enforced by
  # `check_feature_eligibility` in preflight; only the per-ref eligibility
  # gate (HITL, wrong status, blockers, missing) is left to resolve here.
  local snap entry reason detail
  if ! snap="$(take_snapshot "$ISSUE_FEATURE")"; then
    echo "runner: single-dispatch refused: tracker-snapshot failed for feature '$ISSUE_FEATURE'" >&2
    RUN_STOP_REASON="single-dispatch (refused: snapshot-failed)"
    return 2
  fi

  # Look up the issue entry by nn (binding-agnostic) rather than by the
  # portable ref string, so this works for any binding's native ref shape.
  entry="$(jq -c --arg n "$ISSUE_NN" \
    'first(.issues[] | select((.nn | tonumber) == ($n | tonumber))) // empty' <<<"$snap")"
  if [ -z "$entry" ]; then
    reason="missing"
    detail="ref '$ARG_ISSUE_REF' is not present in feature '$ISSUE_FEATURE'"
  else
    local entry_type entry_status entry_eligible unmet_blockers
    entry_type="$(jq -r '.type // empty' <<<"$entry")"
    entry_status="$(jq -r '.status // empty' <<<"$entry")"
    entry_eligible="$(jq -r '.eligible // false' <<<"$entry")"
    if [ "$entry_eligible" = "true" ]; then
      reason=""
    elif [ "$entry_type" != "AFK" ]; then
      reason="HITL"
      detail="ref '$ARG_ISSUE_REF' has type '$entry_type' (runner only dispatches AFK)"
    elif [ "$entry_status" != "ready-for-agent" ]; then
      reason="wrong-status"
      detail="ref '$ARG_ISSUE_REF' status is '$entry_status' (runner only dispatches ready-for-agent)"
    else
      unmet_blockers="$(jq -r '.blocked_by // [] | join(",")' <<<"$entry")"
      reason="blockers-unmet"
      if [ -n "$unmet_blockers" ]; then
        detail="ref '$ARG_ISSUE_REF' has unmet blocker(s): $unmet_blockers"
      else
        detail="ref '$ARG_ISSUE_REF' is ineligible (snapshot reports eligible: false)"
      fi
    fi
  fi

  if [ -n "$reason" ]; then
    echo "runner: single-dispatch refused: $detail" >&2
    RUN_STOP_REASON="single-dispatch (refused: $reason)"
    return 2
  fi

  local rc=0
  dispatch_one "$ISSUE_FEATURE" "$ISSUE_NN" "$RUN_DIR" || rc=$?
  if [ "$rc" -eq 0 ]; then
    RUN_STOP_REASON="single-dispatch (success)"
  else
    RUN_STOP_REASON="single-dispatch (failure)"
  fi
  return "$rc"
}

# Loop entry — drains $TARGET_FEATURE's eligible queue sequentially.
# Eligibility is recomputed every iteration by re-snapshotting the
# runner-checkout's HEAD, so an issue unblocked mid-run by an earlier
# success becomes selectable without restarting the runner. Stop
# conditions: queue empty, Ctrl-C. Per-issue failures log + continue
# (no runner-side comment posted on the issue — the failed `/implement`
# posts its own). RUN_DIR was created in main().
run_loop() {
  # Feature-level refusal (unknown-feature) was already enforced by
  # `check_feature_eligibility` in preflight.
  local iteration=0

  while :; do
    if [ "$RUNNER_INTERRUPTED" -eq 1 ]; then
      echo "[$(now_clock)] runner: interrupted; not starting next iteration"
      RUN_STOP_REASON="interrupted"
      return 0
    fi

    iteration=$((iteration + 1))

    # Fresh snapshot per iteration so newly-unblocked issues become
    # selectable without restarting. `if !` instead of plain assignment
    # because `local snap=$(failing_cmd)` under `set -e` does not
    # propagate the inner non-zero — without this guard a tracker-snapshot
    # crash surfaces as a misleading `queue-empty` stop while the actual
    # cause sits buried in runner.log.
    local snap
    if ! snap="$(take_snapshot "$TARGET_FEATURE")"; then
      echo "[$(now_clock)] runner: tracker-snapshot failed; aborting loop" >&2
      RUN_STOP_REASON="snapshot-failed"
      return 1
    fi

    # Select the first eligible (feature, nn) pair that does not have an abort
    # flag. Iterate through all eligible issues in source order (emitting a
    # skip line with the rm recipe for each aborted one). The abort flag path
    # uses `nn` from the snapshot — never derived from the binding-native ref —
    # so local-markdown and github-issues flags share the same layout.
    local ref="" nn_sel=""
    local abort_feature_dir="$HOST_ABORT_DIR/$TARGET_FEATURE"
    local candidate_ref candidate_nn abort_flag
    while IFS=$'\t' read -r candidate_ref candidate_nn; do
      [ -z "$candidate_ref" ] && continue
      abort_flag="$abort_feature_dir/$candidate_nn"
      if [ -f "$abort_flag" ]; then
        echo "[$(now_clock)] runner: skipping aborted $candidate_ref — rm $abort_flag to resume"
        continue
      fi
      ref="$candidate_ref"
      nn_sel="$candidate_nn"
      break
    done < <(jq -r '.issues[] | select(.eligible == true) | "\(.ref)\t\(.nn)"' <<<"$snap")

    if [ -z "$ref" ]; then
      echo "[$(now_clock)] runner: queue empty — no eligible issues remain in '$TARGET_FEATURE'"
      RUN_STOP_REASON="queue-empty"
      return 0
    fi

    # Re-sync the runner-checkout to host's tip before each dispatch,
    # so any stray uncommitted dirt from a failed prior dispatch never
    # leaks into the next container. In drain mode the wrapper soft-fails
    # (returns 1 with RUN_STOP_REASON="fetch-failed") so a per-feature sync
    # failure becomes a `skip:fetch-failed` row instead of aborting the
    # whole drain; narrowed modes still abort via `fail_invariant` inside
    # the wrapper, so this `|| return 1` branch only fires under drain.
    if ! ensure_runner_checkout; then
      return 1
    fi

    RUNNER_LAST_PROPAGATION=""
    local dispatch_rc=0
    dispatch_one "$TARGET_FEATURE" "$nn_sel" "$RUN_DIR" || dispatch_rc=$?

    # If Ctrl-C arrived during the dispatch, exit immediately.
    if [ "$RUNNER_INTERRUPTED" -eq 1 ]; then
      echo "[$(now_clock)] runner: interrupted during dispatch of $ref; exiting"
      RUN_STOP_REASON="interrupted"
      return 0
    fi

    # Propagation error: the runner-checkout holds un-published commits
    # that the next sync would wipe. Break now so recovery is possible.
    if [ "$RUN_STOP_REASON" = "propagation-error" ]; then
      echo "[$(now_clock)] runner: propagation error — halting loop"
      return 1
    fi

    # Runaway guard: a post-implement step pushed the issue back to an eligible
    # state. Halt immediately to prevent unbounded re-dispatch.
    case "$RUN_STOP_REASON" in
      runaway-halt*)
        echo "[$(now_clock)] runner: runaway guard fired — halting loop"
        return 1 ;;
    esac

    # Make `set -e` happy — dispatch_rc is consumed, not propagated.
    : "$dispatch_rc"
  done
}

# Drain entry — bare invocation. Walks every feature in discovery order,
# evaluating the per-feature gate (fetch-failed, feature-snapshot-failed,
# queue-empty). Features that gate `drain` get the per-issue loop body via
# `run_loop`. Features that gate `skip:<reason>` produce a SUMMARY row and
# the run continues.
#
# Stop reasons (run-level):
#   - `completed`             — every discovery slug considered.
#   - `interrupted`           — Ctrl-C during the outer loop (the in-flight
#                                container, if any, received SIGTERM via the
#                                signal handler; see `handle_signal`).
run_drain() {
  RUN_LOG_LAYOUT="nested"
  local considered=""
  local feature

  while :; do
    if [ "$RUNNER_INTERRUPTED" -eq 1 ]; then
      echo "[$(now_clock)] runner: interrupted; not considering next feature"
      RUN_STOP_REASON="interrupted"
      return 0
    fi

    feature="$(next_eligible_feature "$DISCOVERY_JSON" "$considered" "")"
    if [ -z "$feature" ]; then
      echo "[$(now_clock)] runner: completed — every feature in discovery considered"
      RUN_STOP_REASON="completed"
      return 0
    fi

    drain_one_feature "$feature"
    # Record the considered feature regardless of outcome so the selector
    # advances on the next iteration.
    if [ -z "$considered" ]; then
      considered="$feature"
    else
      considered="$considered"$'\n'"$feature"
    fi

    # Propagation error from any feature's loop halts the entire drain.
    if [ "$RUN_STOP_REASON" = "propagation-error" ]; then
      echo "[$(now_clock)] runner: propagation error halting drain"
      return 1
    fi

    # Runaway guard from any feature's loop halts the entire drain.
    case "$RUN_STOP_REASON" in
      runaway-halt*)
        echo "[$(now_clock)] runner: runaway guard halting drain"
        return 1 ;;
    esac

    if [ "$RUNNER_INTERRUPTED" -eq 1 ]; then
      echo "[$(now_clock)] runner: interrupted during $feature drain; exiting"
      RUN_STOP_REASON="interrupted"
      return 0
    fi
  done
}

# Drain a single feature inside drain mode. Evaluates the per-feature gate,
# records the outcome, and (on drain) runs the per-issue loop body against
# this feature.
drain_one_feature() {
  local feature="$1"

  # Sync the runner-checkout to this feature's branch. fail-soft: a fetch
  # failure for one feature is recorded and the run continues with the next.
  # Missing host branches are handled lazily by ensure_runner_checkout_on_branch.
  if ! ensure_runner_checkout_on_branch "$feature"; then
    echo "[$(now_clock)] runner: skipping $feature — fetch-failed"
    record_feature_outcome "$feature" "skip:fetch-failed"
    return 0
  fi

  # Take the feature's snapshot. Failure here is a `feature-snapshot-failed`
  # row, not a run-level abort — PRD §Per-feature gates.
  local snap
  TARGET_FEATURE="$feature"
  if ! snap="$(take_snapshot "$feature")"; then
    echo "[$(now_clock)] runner: skipping $feature — feature-snapshot-failed"
    record_feature_outcome "$feature" "feature-snapshot-failed"
    return 0
  fi

  # Queue check: ≥1 eligible non-aborted ref. Uses the same predicate as
  # the per-issue loop's selection so the verdict matches what `run_loop`
  # would compute.
  if ! feature_has_dispatchable_ref "$feature" "$snap"; then
    echo "[$(now_clock)] runner: skipping $feature — queue-empty"
    record_feature_outcome "$feature" "skip:queue-empty"
    return 0
  fi

  # Materialize the mvn cache lazily for this feature. A cache miss here
  # is rare (`ensure-mvn-cache.sh` is idempotent and only fails on docker
  # itself), but record the outcome cleanly if it does happen.
  if ! ensure_mvn_cache_for "$feature"; then
    echo "[$(now_clock)] runner: skipping $feature — fetch-failed (mvn-cache)"
    record_feature_outcome "$feature" "skip:fetch-failed"
    return 0
  fi

  # Drain the feature via the per-issue loop, scoped to this feature.
  # Don't record the feature outcome upfront — if run_loop surfaces a
  # mid-feature snapshot crash, we record `feature-snapshot-failed` instead
  # of `drained` so the SUMMARY narrates the failure correctly.
  local saved_stop_reason="$RUN_STOP_REASON"
  RUN_STOP_REASON=""
  set +e
  run_loop
  set -e

  local inner_reason="$RUN_STOP_REASON"
  # The outer drain loop owns the run-level stop reason. Restore whatever
  # was set before we entered the per-feature loop so a mid-drain run_loop
  # stop (queue-empty, snapshot-failed) doesn't leak as the run's final
  # reason. RUNNER_INTERRUPTED is checked by the outer loop via its
  # dedicated global, so the stop-reason wipe is safe.
  RUN_STOP_REASON="$saved_stop_reason"

  case "$inner_reason" in
    propagation-error)
      # Parking-ref publish failed inside this feature's loop. Leak the
      # stop reason through to run_drain — do not record a feature row
      # (the iteration's FAIL row already tells the story) and override
      # the restored saved value so the outer drain sees it.
      RUN_STOP_REASON="propagation-error"
      ;;
    runaway-halt*)
      # Runaway guard fired inside this feature's loop. Leak the stop reason
      # through to run_drain so the outer drain halts immediately.
      RUN_STOP_REASON="$inner_reason"
      ;;
    snapshot-failed)
      # Mid-feature snapshot crash. Brief AC: "A feature whose
      # `tracker-snapshot <slug>` crashes mid-run produces a SUMMARY row
      # `feature-snapshot-failed` and the run continues." Distinct from
      # the pre-loop `feature-snapshot-failed` gate (which catches the
      # crash before any per-issue work landed).
      record_feature_outcome "$feature" "feature-snapshot-failed"
      ;;
    fetch-failed)
      # Per-iteration `ensure_runner_checkout` failure inside the per-issue
      # loop (the wrapper soft-fails in drain mode rather than aborting the
      # whole run via `fail_invariant`). Distinct from the pre-loop sync
      # gate above, which also yields `skip:fetch-failed`.
      record_feature_outcome "$feature" "skip:fetch-failed"
      ;;
    *)
      record_feature_outcome "$feature" "drained"
      ;;
  esac
}

# Per-feature queue-shape probe. Returns 0 if the snapshot has at least
# one eligible ref without an abort flag, 1 otherwise. Mirrors the
# selection logic in `run_loop`'s top-of-iteration block. Uses `nn` from
# the snapshot for abort flag lookup — binding-agnostic.
feature_has_dispatchable_ref() {
  local feature="$1" snap="$2"
  local abort_dir="$HOST_ABORT_DIR/$feature"
  local candidate_ref candidate_nn
  while IFS=$'\t' read -r candidate_ref candidate_nn; do
    [ -z "$candidate_ref" ] && continue
    if [ -f "$abort_dir/$candidate_nn" ]; then
      continue
    fi
    return 0
  done < <(jq -r '.issues[] | select(.eligible == true) | "\(.ref)\t\(.nn)"' <<<"$snap")
  return 1
}

# Lazy mvn-cache materialization for drain mode. Wraps the global helper
# so a per-feature failure can be reported as `skip:fetch-failed` rather
# than aborting the entire run with `preflight-abort: mvn-cache`.
ensure_mvn_cache_for() {
  local feature="$1"
  if ! MVN_VOLUME="$("$HERE/ensure-mvn-cache.sh" "$feature")"; then
    echo "runner: ensure_mvn_cache_for $feature: ensure-mvn-cache.sh failed" >&2
    return 1
  fi
  if [ -z "${MVN_VOLUME:-}" ]; then
    echo "runner: ensure_mvn_cache_for $feature: ensure-mvn-cache.sh produced empty volume name" >&2
    return 1
  fi
  return 0
}

# === Main ==================================================================

main() {
  set -euo pipefail
  parse_args "$@"
  resolve_host_repo
  # Set TARGET_FEATURE and RUN_FEATURE before setup_run_dir so the per-run
  # dir and SUMMARY.md always know the feature context (single/loop only).
  case "$RUN_MODE" in
    single) TARGET_FEATURE="$ISSUE_FEATURE" ;;
    loop)   TARGET_FEATURE="$ARG_FEATURE" ;;
    drain)  TARGET_FEATURE="" ;;
  esac
  RUN_FEATURE="$TARGET_FEATURE"
  setup_run_dir
  start_runner_log_capture
  if [ -n "${ARG_MODEL:-}" ]; then
    echo "[$(now_clock)] model: $ARG_MODEL"
  fi
  # `finalize_run` writes SUMMARY.md, prints the end-of-run table, and
  # releases the lock — see its definition for the pre-flight vs. normal
  # branches. Installed *before* `preflight` so a `fail_invariant` exit
  # still runs the trap.
  trap finalize_run EXIT
  trap handle_preflight_signal INT TERM
  preflight
  trap handle_signal INT TERM
  sweep_stale_parking_refs
  case "$RUN_MODE" in
    single) run_single ;;
    loop)   run_loop ;;
    drain)  run_drain ;;
    *)
      echo "runner: internal error — unknown run mode '$RUN_MODE'" >&2
      exit 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
