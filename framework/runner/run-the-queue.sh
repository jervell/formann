#!/usr/bin/env bash
# AFK runner.
#
# Usage:
#   run-the-queue.sh                            # drain mode — every active feature
#   run-the-queue.sh --feature <slug>           # loop mode — one feature
#   run-the-queue.sh --issue <feature>/<NN>     # single-dispatch mode
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
#   - `preflight-abort: discovery` — `tracker-snapshot --list` failed.
#
# Stop reasons (narrowed modes):
#   - `queue-empty` / `interrupted` / `snapshot-failed` / `propagation-error`.
#   - `feature-restricted (refused: <reason>)` (--feature).
#   - `single-dispatch (success|failure|refused: <reason>)` (--issue).
#
# Exit codes:
#   0  — drain completed / interrupted; single dispatch succeeded;
#         or loop drained / was interrupted (those treat the stop conditions
#         as 0).
#   1  — single dispatch failed (status didn't flip to in-review/done); or
#         loop mode aborted because tracker-snapshot crashed mid-loop
#         (`snapshot-failed`) or a propagation error halted the loop
#         (`propagation-error`).
#   2  — pre-flight failed; the line printed before exit names which
#         invariant tripped; or refusal (feature-restricted, single-dispatch
#         refused).
#
# The script is also sourceable; pure logic (`classify_outcome`,
# `next_eligible_ref`, `next_eligible_feature`, `classify_gate_outcome`,
# `evaluate_feature_gate`, `format_multi_feature_summary_md`) is exposed for
# the bats suite. `main` only runs when the script is executed directly.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

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
RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS=4
RUNNER_TRANSPORT_RETRY_BACKOFFS="30 90 240"
# When set to 1, the wrapper short-circuits to a single attempt regardless of
# is_transport_crash's verdict — useful for testing and declared-outage
# situations where the operator wants to fail fast.
: "${RUNNER_DISABLE_TRANSPORT_RETRY:=0}"

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

# Classify a gate-dispatch outcome. Inputs:
#   $1 — pre-gate snapshot JSON (post-implement state — issue at in-review)
#   $2 — post-gate snapshot JSON (after the gate session committed)
#   $3 — canonical issue ref
#   $4 — gate dispatch's exit code
#   $5 — transport-crash boolean (default: false); when true, emits
#         `review-aborted` instead of `gate-failed` on nonzero-exit path.
#
# Output (stdout): exactly one of `clean`, `blocked`, `gate-failed`, or
# `review-aborted`.
#
#   clean          — exit 0 AND post.status == done.
#   blocked        — exit 0 AND post.status == in-review (unchanged from pre).
#   gate-failed    — nonzero exit (no transport crash), missing-from-snapshot,
#                    or exit-0 with an off-mission post-status.
#   review-aborted — nonzero exit AND transport-crash == true.
#
# Pure logic — no I/O beyond stdin/stdout. Sourceable from bats.
classify_gate_outcome() {
  local pre_json="$1" post_json="$2" ref="$3" exit_code="$4" transport_crash="${5:-false}"

  # pre.status must be in-review or done — anything else means the gate
  # was dispatched against an issue in an unexpected state (argument-order
  # swap, stale snapshot, etc.).
  local pre_status
  pre_status="$(jq -r --arg r "$ref" \
    '(.issues[] | select(.ref == $r) | .status) // empty' <<<"$pre_json")"
  case "$pre_status" in
    in-review|done) ;;
    *) echo "gate-failed"; return 0 ;;
  esac

  if [ "$exit_code" != "0" ]; then
    [ "$transport_crash" = "true" ] && echo "review-aborted" || echo "gate-failed"
    return 0
  fi

  local post_status
  post_status="$(jq -r --arg r "$ref" \
    '(.issues[] | select(.ref == $r) | .status) // empty' <<<"$post_json")"

  case "$post_status" in
    done)      echo "clean" ;;
    in-review) echo "blocked" ;;
    *)         echo "gate-failed" ;;
  esac
}

# Detect whether a dispatch log carries a transport-class failure signature.
# Returns exit 0 (true) when the log is empty/whitespace-only or contains a
# recognised transport-failure pattern; exit 1 (false) otherwise.
#
# Transport-class signatures (one pattern per line — complete policy list):
#   API Error: 5[0-9][0-9]<sp>  — Anthropic server-side error (500, 502, 503, …);
#                                  trailing space disambiguates from 5-digit codes
#   API Error: 429<sp>           — rate-limit exhaustion; trailing space as above
#   fetch failed                 — network-layer fetch failure (CLI / npm)
#   ECONNRESET                   — TCP connection reset by peer
#   ETIMEDOUT                    — TCP connection timeout
#   getaddrinfo                  — DNS resolution failure
#   (empty/whitespace-only)      — subprocess crashed before producing any output
#
# Pure — no globals, no I/O beyond the log file. Sourceable from bats.
# NOTE: empty log + nonzero exit is treated as a transport crash. Test stubs
# for non-transport failures must write at least one non-whitespace line to
# the log file; otherwise this predicate will misclassify them.
is_transport_crash() {
  local log_file="$1"
  # Empty or whitespace-only log — subprocess exited before producing output.
  if [ ! -s "$log_file" ] || [ -z "$(tr -d '[:space:]' <"$log_file")" ]; then
    return 0
  fi
  # Signature-based detection. The API Error patterns require a trailing space
  # (matching the claude CLI's exact output format) to avoid false positives on
  # 5-digit or 4-digit status codes (e.g. "API Error: 5009").
  grep -qE \
    'API Error: 5[0-9][0-9] |API Error: 429 |fetch failed|ECONNRESET|ETIMEDOUT|getaddrinfo' \
    "$log_file"
}

# Per-feature gate evaluator. Pure function — no I/O beyond stdin/stdout.
# Sourceable from bats. The outer drain loop calls the side-effecting
# helpers (fetch, snapshot, queue-shape inspection) and hands their
# verdicts to this function, which decides drain vs skip:<reason>.
#
# Verdict priority (top wins; matches the loop's short-circuit order):
#   fetch-failed > feature-snapshot-failed > queue-empty > drain.
#
# Signature: evaluate_feature_gate <slug> \
#                                  [snapshot_status] [queue_status] \
#                                  [fetch_status]
#
# Defaults encode the optimistic verdict (snapshot_status=ok,
# queue_status=nonempty, fetch_status=ok).
evaluate_feature_gate() {
  local slug="$1"
  local snapshot_status="${2:-ok}"
  local queue_status="${3:-nonempty}"
  local fetch_status="${4:-ok}"

  if [ "$fetch_status" = "failed" ]; then
    echo "skip:fetch-failed"
    return 0
  fi
  if [ "$snapshot_status" = "failed" ]; then
    echo "skip:feature-snapshot-failed"
    return 0
  fi
  if [ "$queue_status" = "empty" ]; then
    echo "skip:queue-empty"
    return 0
  fi
  echo "drain"
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

# === Output formatters (pure) ==============================================
#
# These take inputs and emit text — no I/O beyond stdin/stdout, no globals.
# Exercised by tests/run-the-queue.bats; pinned by AC because the operator
# reads them live during a run and again after the fact in SUMMARY.md.
#
# Each iteration emits per-stage progress lines. AFK iterations produce
# four lines (implement starting/outcome, review starting/outcome); HITL
# iterations produce two (implement only — gate is skipped). When a
# parking-ref publish fails after a stage, a follow-up `halt → <recorded
# outcome>` line is emitted so the operator's terminal record matches
# the SUMMARY.md row.
#
# Stage names: `implement` for the /implement dispatch, `review` for the
# post-implement review-and-gate dispatch.
#
# Outcome label vocabulary by stage:
#   implement: in-review | done | dispatch-aborted | FAIL | halt → FAIL
#   review:    clean → done | blocked | review-aborted | gate-failed | halt → gate-failed
#
# Combined per-iteration outcome (used in the end-of-run table and
# SUMMARY.md row): `done | blocked | gate-failed | review-aborted | dispatch-aborted | in-review | FAIL`.
#   done             — AFK + clean review
#   blocked          — AFK + Critical-finding review
#   gate-failed      — AFK + gate dispatch errored or off-mission
#   review-aborted   — AFK + gate subprocess transport-crashed (empty/5xx/429/network log)
#   dispatch-aborted — implement subprocess transport-crashed
#   in-review        — HITL (gate skipped)
#   FAIL             — implement-stage failure (classifier, propagation, container)

# Convert integer seconds to a human-friendly string.
# Rules: <60 → Xs; 60..3599 → Xm Ys; ≥3600 → Xh Ym (seconds dropped).
humanize_duration() {
  local s="$1"
  if [ "$s" -lt 60 ]; then
    printf '%ss\n' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%sm %ss\n' "$((s / 60))" "$((s % 60))"
  else
    printf '%sh %sm\n' "$((s / 3600))" "$(( (s % 3600) / 60 ))"
  fi
}

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
# Reads `feature|nn|ref|outcome|duration|review_present|attempt_count|propagation`
# records on stdin (fields past `outcome` are optional — when `review_present`
# is `y`, the row's logs cell adds a `<NN>-review.log` link alongside `<NN>.log`;
# `propagation` is the indicator string from `propagate_feature` —
# `propagated → host`, `parked → runner/<branch>`, or empty). The
# `propagation` column shows the indicator verbatim, or `-` when empty.
# An end-of-run "## Unpulled parked work" section follows the table whenever
# any dispatch parked; it is omitted entirely when no dispatch parked.
# `end_state` is the verb used in the run line — "ended" or "interrupted".
format_summary_md() {
  local feature="$1" ts="$2" start_clock="$3" end_clock="$4" end_state="$5" stop_reason="$6"
  # Capture once so the table awk and the parked-work aggregator both see the
  # same records without the caller having to materialize them twice.
  local records
  records="$(cat)"
  printf '# AFK runner — %s\n\n' "$feature"
  printf -- '- Run: %s (started %s, %s %s)\n' "$ts" "$start_clock" "$end_state" "$end_clock"
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
      logs = sprintf("[%s.log](%s.log)", nn, nn);
      if (review == "y") {
        logs = logs " [" nn "-review.log](" nn "-review.log)";
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
# `review_present` is `y` when the iteration produced a `<ref>-review.log`
# alongside `<ref>.log`. `propagation` is the indicator string from
# `propagate_feature` — `propagated → host`, `parked → runner/<branch>`,
# or empty. Log paths in multi-feature mode embed the feature segment of the
# ref (`<feature>/<NN>.log`) so per-issue artifacts don't collide across
# features that share `<NN>`. The `propagation` column shows the indicator
# verbatim, or `-` when empty; an end-of-run "## Unpulled parked work"
# section follows when any dispatch parked, and is omitted entirely when no
# dispatch parked.
format_multi_feature_summary_md() {
  local ts="$1" start_clock="$2" end_clock="$3" end_state="$4" stop_reason="$5"
  # Capture once so the per-feature renderer and `format_parked_ledger` both
  # see the same records.
  local records
  records="$(cat)"
  printf '# AFK runner — multi-feature drain\n\n'
  printf -- '- Run: %s (started %s, %s %s)\n' "$ts" "$start_clock" "$end_state" "$end_clock"
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
      logs = sprintf("[%s/%s.log](%s/%s.log)", feature, nn, feature, nn);
      if (review == "y") {
        logs = logs " [" feature "/" nn "-review.log](" feature "/" nn "-review.log)";
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
#   type: technical|transport
#   dispatch: implement|gate
#   at: <ISO-8601 UTC>
#   exit: <container exit code>
#   log: <repo-relative path to dispatch log>
#
# `type` distinguishes transport-class failures (API 5xx/429, network errors,
# empty log) from genuine technical failures (model error, bad brief, etc.).
#
# Args: $1=feature  $2=nn  $3=dispatch(implement|gate)  $4=exit_code  $5=log_file
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
# Per-issue log layout. `flat` (default — single-feature / single-issue
# modes) writes <run-dir>/<NN>.log; `nested` (drain mode) writes
# <run-dir>/<feature>/<NN>.log so per-issue artifacts don't collide
# when multiple features share an <NN>. dispatch_one reads this.
RUN_LOG_LAYOUT="flat"
RUNNER_TEE_PID=""
RUNNER_LOG_FIFO=""
RUNNER_LAST_PROPAGATION=""   # 'propagated → host' | 'parked → runner/<branch>' | '' (set by propagate_feature)
DISCOVERY_JSON=""     # populated by check_discovery pre-flight invariant

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

# Append a `feature|nn|ref|label|duration|review_present|attempt_count|propagation`
# record to RUN_DISPATCHES. `label` is the iteration's combined outcome — one of
# `done | blocked | gate-failed | review-aborted | dispatch-aborted | in-review | FAIL`.
# `review_present` is `y` when the iteration produced a `<NN>-review.log`.
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
          "$end_state" "$stop_reason" >"$RUN_DIR/SUMMARY.md"
      else
        print_dispatch_records | format_summary_md \
          "$RUN_FEATURE" "$RUN_TS" "$RUN_START_CLOCK" "$end_clock" \
          "$end_state" "$stop_reason" >"$RUN_DIR/SUMMARY.md"
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
      -h|--help)
        sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# 1b. Feature eligibility — TARGET_FEATURE must appear in DISCOVERY_JSON.
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

# Re-apply the host's installer products to the runner-checkout. Walks
# `<host>/docs/formann/*` for role-binding symlinks, derives a
# `FORMANN_INSTALL_BINDING_<role>` env-var bypass per role, and invokes
# `installer/install.sh <checkout>` non-interactively so the checkout
# ends up with the same binding wiring the host has selected.
#
# Why: the host's installer products are gitignored when the installer
# detects self-install (consumer path is the formann source path), so
# `docs/formann/issue-tracker` and the framework-doc symlinks never enter
# git history. A fresh runner-checkout clone therefore lacks them, and
# the dispatch agent falls back to whichever binding it can find on disk
# (typically local-markdown) — regardless of what the host has selected.
# Called from preflight exactly once per run-the-queue.sh invocation,
# after ensure_runner_checkout_exists guarantees the directory is present.
#
# Idempotent: the installer's own contract requires it. The installer's
# products are gitignored, so the per-iteration `git clean -fd` inside
# ensure_runner_checkout_on_branch leaves them in place — they persist
# across the entire pass without a second install call.
refresh_runner_checkout_install_products() {
  local host_repo="$1"
  local checkout="$2"
  local role_link role impl
  local env_args=()
  for role_link in "$host_repo"/docs/formann/*; do
    [ -L "$role_link" ] || continue
    role="$(basename "$role_link")"
    impl="$(basename "$(readlink "$role_link")")"
    env_args+=("FORMANN_INSTALL_BINDING_${role//-/_}=$impl")
  done
  # Drop the installer's stdout — it carries the interactive UX block
  # ("Paste the following into your CLAUDE.md", etc.) which is irrelevant
  # during a runner pass. Stderr (real warnings, errors) flows through.
  if ! env ${env_args[@]+"${env_args[@]}"} "$host_repo/installer/install.sh" "$checkout" >/dev/null; then
    echo "runner: installer refresh against $checkout failed" >&2
    return 1
  fi
}

# 2a. Runner-checkout directory is present (clones from host if absent).
#     Branch-agnostic: only the clone lives here; branch-switching is in
#     ensure_runner_checkout_on_branch below. Called from preflight
#     unconditionally so the clone fires at most once per pass, before any
#     branch-sync or installer refresh.
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
    # Neither the host branch nor a parking ref exists yet — this is the first
    # dispatch for a slug whose branch was never pre-created on host. Initialize
    # the runner-checkout's branch from refs/heads/main (hardcoded; dynamic
    # default-branch detection is out of scope). The first propagation's existing
    # `<slug>:<slug>` fetch refspec is create-on-missing, so it will create
    # refs/heads/<slug> on host from the runner's commits.
    if ! git -C "$HOST_CHECKOUT" fetch --quiet origin main >&2; then
      echo "runner: ensure_runner_checkout_on_branch: git fetch origin main (lazy init) failed" >&2
      return 1
    fi
    if ! git -C "$HOST_CHECKOUT" checkout --quiet -B "$branch" "origin/main" >&2; then
      echo "runner: ensure_runner_checkout_on_branch: git checkout -B $branch origin/main (lazy init) failed" >&2
      return 1
    fi
    if ! git -C "$HOST_CHECKOUT" reset --quiet --hard "origin/main" >&2; then
      echo "runner: ensure_runner_checkout_on_branch: git reset --hard origin/main (lazy init) failed" >&2
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
  # core dumps from a crashed in-computer process, stray writes from a
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

# 4. Docker daemon responds.
check_docker_daemon() {
  if ! docker info >/dev/null 2>&1; then
    fail_invariant "docker-daemon" \
      "docker info failed; is Docker Desktop running?"
  fi
}

# 5b. Gate prompt file exists. The post-implement review-and-gate dispatch
#     reads this prompt at dispatch time, appends the issue ref, and hands
#     the result to a fresh `claude -p` invocation. Slots in the framework-
#     artifact pre-flight cluster, between the image and the per-feature
#     mvn cache.
check_gate_prompt() {
  GATE_PROMPT_PATH="$HERE/$RUNNER_GATE_PROMPT_FILE"
  if [ ! -f "$GATE_PROMPT_PATH" ]; then
    fail_invariant "gate-prompt" \
      "$GATE_PROMPT_PATH not found"
  fi
}

# 5. Runner image exists or is built. `build-image.sh` is idempotent.
ensure_image() {
  if ! "$HERE/build-image.sh" >/dev/null; then
    fail_invariant "runner-image" \
      "build-image.sh failed to ensure image $RUNNER_IMAGE_NAME"
  fi
}

# 6. Per-feature mvn cache volume exists. `ensure-mvn-cache.sh` is idempotent.
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

# 7. Sandbox docker network exists. `setup-network.sh` is idempotent.
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

# 8. OAuth token retrievable from Keychain. Captured into a shell variable;
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
  check_discovery                        # invariant 1: tracker-snapshot --list
  ensure_runner_remote                   # invariant 1b: runner remote
  # Checkout-exists and installer-refresh are unconditional for all run
  # modes — install.sh fires exactly once per pass regardless of how
  # many features or iterations the pass processes.
  if ! ensure_runner_checkout_exists >&2; then
    fail_invariant "runner-checkout" \
      "ensure_runner_checkout_exists failed (rm -rf $HOST_CHECKOUT and re-run to recover)"
  fi
  if ! refresh_runner_checkout_install_products "$HOST_REPO" "$HOST_CHECKOUT"; then
    fail_invariant "runner-checkout" \
      "installer refresh against $HOST_CHECKOUT failed"
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
    ensure_runner_checkout               # invariant 2 (branch-sync)
  fi
  check_docker_daemon                    # invariant 3
  ensure_image                           # invariant 4
  check_gate_prompt                      # invariant 4b (gate prompt)
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
  if [ -n "$IN_FLIGHT_CID_FILE" ] && [ -s "$IN_FLIGHT_CID_FILE" ]; then
    local cid
    cid="$(cat "$IN_FLIGHT_CID_FILE" 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      docker kill --signal=SIGTERM "$cid" >/dev/null 2>&1 || true
    fi
  fi
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
    if [[ ! "$line" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
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
# hand to `claude`. Captures dispatch stdout+stderr to $log_file. Returns
# the docker exit code.
#
# To make Ctrl-C actionable, we run docker in the background with
# `--cidfile` and let the SIGINT/SIGTERM trap (`handle_signal`) read the
# CID and send SIGTERM to the container. After `wait` returns, we
# escalate to SIGKILL if the container is still alive past
# `RUNNER_KILL_GRACE_SECONDS`.
#
# Args: $1 = log_file, $2..$N = command + args to pass after the image.
run_sandbox_container() {
  local log_file="$1"
  shift
  local cid_file
  cid_file="$HOST_RUNNER_STATE/dispatch.cid"
  rm -f "$cid_file"
  IN_FLIGHT_CID_FILE="$cid_file"

  # `-t` allocates a PTY so claude sees a TTY and line-buffers stdout
  # instead of full-buffering. Without it, the dispatch produces zero
  # observable output for the duration of the run (claude only flushes
  # at process exit), making `tail -f <log>` useless and a hung
  # dispatch indistinguishable from a slow one. Side effect: PTY
  # translates `\n` to `\r\n` in the log file; cat/grep/tail handle it
  # transparently.
  # `.formann` is a per-host symlink (untracked) pointing at the Formann
  # framework checkout — `.claude/skills/<name>` symlinks resolve through
  # it. The runner-checkout doesn't carry `.formann` (it's outside the
  # tracked tree), so without this mount every framework-shaped skill is a
  # dangling symlink inside the container and claude reports `Unknown
  # command: /implement` on dispatch. `:ro` because the framework is
  # shared host state — a container should not write to it.
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
  # No-op if the binding declares no script (local-markdown, any binding
  # without sandbox prerequisites). Fail-hard on script error or malformed
  # output — see collect_binding_env for the validation policy.
  local binding_env
  binding_env="$(collect_binding_env "$HOST_REPO/docs/formann/issue-tracker/sandbox-env")" || return 1
  local binding_env_args=()
  if [[ -n "$binding_env" ]]; then
    binding_env_args=(--env-file <(printf '%s\n' "$binding_env"))
  fi

  docker run --rm -t \
    --cidfile "$cid_file" \
    --network "$NET_NAME" \
    -v "$HOST_CHECKOUT:$RUNNER_CONTAINER_REPO_PATH" \
    -v "$HOST_REPO/.formann:$RUNNER_CONTAINER_REPO_PATH/.formann:ro" \
    ${claude_mounts[@]+"${claude_mounts[@]}"} \
    -v "$MVN_VOLUME:$RUNNER_CONTAINER_M2_PATH" \
    --env-file <(printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN") \
    --env-file <(printf 'GIT_AUTHOR_NAME=%s\nGIT_AUTHOR_EMAIL=%s\nGIT_COMMITTER_NAME=%s\nGIT_COMMITTER_EMAIL=%s\n' \
      "$RUNNER_GIT_USER_NAME" "$RUNNER_GIT_USER_EMAIL" \
      "$RUNNER_GIT_USER_NAME" "$RUNNER_GIT_USER_EMAIL") \
    ${binding_env_args[@]+"${binding_env_args[@]}"} \
    "$RUNNER_IMAGE_NAME" \
    "$@" \
    >"$log_file" 2>&1 &
  local docker_pid=$!

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

  IN_FLIGHT_CID_FILE=""
  rm -f "$cid_file"
  return "$rc"
}

# Classify the transport-crash type from a log file for use in runner.log
# retry lines. Returns one of: "API Error: 5xx", "API Error: 429",
# "network-timeout", or "empty-log". Assumes is_transport_crash already fired.
_transport_crash_class() {
  local log_file="$1"
  if [ ! -s "$log_file" ] || [ -z "$(tr -d '[:space:]' <"$log_file")" ]; then
    echo "empty-log"
  elif grep -qE 'API Error: 429 ' "$log_file"; then
    echo "API Error: 429"
  elif grep -qE 'API Error: 5[0-9][0-9] ' "$log_file"; then
    echo "API Error: 5xx"
  else
    echo "network-timeout"
  fi
}

# Wrap a sandbox-dispatch call with bounded exponential backoff on transport-
# class failures. Calls `dispatch_fn "$log_file" "$@"`. On non-zero exit AND
# `is_transport_crash "$log_file"` firing, archives the failed log as
# `<log_file>.attempt-<n>`, sleeps the next backoff from
# RUNNER_TRANSPORT_RETRY_BACKOFFS (1-second poll loop so Ctrl-C exits
# promptly), and retries up to RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS.
#
# Stops retrying when: dispatch succeeds; the predicate does not fire;
# RUNNER_DISABLE_TRANSPORT_RETRY=1; budget exhausted; or the runner-checkout's
# HEAD advanced between attempts (defensive guard — implies partial work was
# committed, so retrying would replay /implement over a half-committed state).
#
# Sets TRANSPORT_RETRY_ATTEMPTS (global) to the actual attempt count.
# Returns the final attempt's exit code; the final log stays at `$log_file`.
#
# Args: $1=log_file  $2=dispatch_fn  [remaining args forwarded to dispatch_fn]
# Sourceable from bats.
with_transport_retry() {
  local log_file="$1" dispatch_fn="$2"
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
    "$dispatch_fn" "$log_file" "$@" || rc=$?

    # Exit the retry loop when: success, retry disabled, not a transport crash,
    # or budget exhausted.
    if [ "$rc" -eq 0 ] \
        || [ "${RUNNER_DISABLE_TRANSPORT_RETRY:-0}" = "1" ] \
        || ! is_transport_crash "$log_file" \
        || [ "$attempt" -ge "$max" ]; then
      break
    fi

    # Archive this attempt's log before the next attempt overwrites it.
    cp "$log_file" "${log_file}.attempt-${attempt}"

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
    # If the configured list is shorter than max, fall back to the final
    # default backoff so the schedule never runs off the end.
    local backoff
    backoff="$(echo "$backoffs" | awk -v n="$attempt" '{print $n}')"
    backoff="${backoff:-240}"

    local crash_class next_attempt
    crash_class="$(_transport_crash_class "${log_file}.attempt-${attempt}")"
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

# Implement-dispatch wrapper: hands `claude -p "/implement <ref>"` to
# the sandbox via the transport-retry layer. Tracker-snapshot delta is the
# source of truth for outcome classification — exit code is captured for
# forensics only.
run_dispatch_container() {
  local ref="$1" log_file="$2"
  with_transport_retry "$log_file" run_sandbox_container \
    claude -p "/implement $ref" --dangerously-skip-permissions
}

# Gate-dispatch wrapper: cats the gate prompt, appends the canonical
# issue ref, and hands the result to a fresh `claude -p` in the sandbox
# via the transport-retry layer. Tracker-snapshot delta + exit code drive
# `classify_gate_outcome`.
run_gate_container() {
  local ref="$1" log_file="$2"
  local prompt_text
  prompt_text="$(cat "$GATE_PROMPT_PATH")"$'\n'"$ref"
  with_transport_retry "$log_file" run_sandbox_container \
    claude -p "$prompt_text" --dangerously-skip-permissions
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
# RUN_STOP_REASON="propagation-error" so run_loop breaks the loop.
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
  local log_file="$log_dir/$log_basename.log"
  local exit_file="$log_dir/$log_basename.exit"
  local review_log_file="$log_dir/$log_basename-review.log"

  local pre_json post_implement_json post_gate_json
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
  run_dispatch_container "$ref" "$log_file" || impl_rc=$?
  local impl_attempts="${TRANSPORT_RETRY_ATTEMPTS:-1}"
  echo "$impl_rc" > "$exit_file"

  local post_implement_head
  post_implement_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"

  local impl_transport_crash=false
  if [ "$impl_rc" != "0" ] && is_transport_crash "$log_file"; then
    impl_transport_crash=true
  fi

  # Snapshot failure takes precedence over the transport-crash signal: if the
  # post-implement snapshot fails, we cannot determine the issue's state, so we
  # record FAIL and stop. No abort flag is written — the stop-reason already
  # signals a system-level problem to the operator, and re-running the same
  # issue against a broken snapshot would be pointless.
  if ! post_implement_json="$(take_snapshot "$feature")"; then
    local snap_fail_at snap_duration
    snap_fail_at=$(date +%s)
    snap_duration=$(( snap_fail_at - started_at ))
    echo "runner: dispatch_one: tracker-snapshot failed (post-implement stage) for ref '$ref'" >&2
    RUN_STOP_REASON="snapshot-failed-mid-dispatch:post-implement"
    record_dispatch "$feature" "$nn" "$ref" "FAIL" "$snap_duration" "" "$impl_attempts"
    return 1
  fi

  local classifier_verdict
  classifier_verdict="$(classify_outcome "$pre_json" "$post_implement_json" "$ref" "$impl_transport_crash")"

  local impl_has_runner_commits=0
  if [ -n "$pre_implement_head" ] && [ -n "$post_implement_head" ] \
      && [ "$pre_implement_head" != "$post_implement_head" ]; then
    impl_has_runner_commits=1
  fi

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
  # on classifier success, dispatch-aborted on transport crash, FAIL otherwise.
  # /implement normally lands at in-review; HITL or maintainer-adjusted briefs
  # may land at done.
  local impl_label="FAIL"
  if [ "$classifier_verdict" = "success" ]; then
    local post_status
    post_status="$(jq -r --arg r "$ref" \
      '(.issues[] | select(.ref == $r) | .status) // empty' <<<"$post_implement_json")"
    case "$post_status" in
      in-review|done) impl_label="$post_status" ;;
      *)              impl_label="FAIL" ;;
    esac
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
      write_abort_flag "$feature" "$nn" "implement" "$impl_rc" "$log_file" "$impl_flag_type"
    fi
    local impl_abort_outcome="FAIL"
    [ "$classifier_verdict" = "dispatch-aborted" ] && impl_abort_outcome="dispatch-aborted"
    record_dispatch "$feature" "$nn" "$ref" "$impl_abort_outcome" "$impl_duration" "" "$impl_attempts"
    return 1
  fi

  # === Gate decision =======================================================
  # The runner dispatches eligible AFK refs only — both single-dispatch
  # and loop mode enforce that gate before reaching `dispatch_one`. Every
  # successful AFK implement proceeds to the review-and-gate dispatch.

  # Guard: a signal in the window between implement-finish and gate-start
  # (while IN_FLIGHT_CID_FILE is empty) sets RUNNER_INTERRUPTED without
  # reaching the gate container. Record what we have and exit cleanly so
  # the loop's top-of-iteration check handles the stop.
  if [ "$RUNNER_INTERRUPTED" -eq 1 ]; then
    record_dispatch "$feature" "$nn" "$ref" "$impl_label" "$impl_duration" "" "$impl_attempts"
    return 0
  fi

  # === Review-and-gate stage ==============================================
  local gate_start_clock
  gate_start_clock="$(now_clock)"
  format_progress_start "$gate_start_clock" "$ref" "review"

  # Capture the runner-checkout's HEAD around the gate dispatch on the same
  # principle as the implement stage above: the post-gate advance signals
  # whether the gate produced commits. Under local-markdown the gate prompt
  # contracts to commit on clean and blocked alike, so HEAD advances and the
  # post-gate propagation fires. Under github-issues the gate's comment and
  # set-state land as API calls, HEAD is unchanged, and there is no commit
  # to publish — gating on the delta keeps us from publishing a no-op to the
  # parking ref and (when the maintainer is on the target branch) from
  # recording a misleading `parked → runner/<feature>` ledger entry.
  local pre_gate_head
  pre_gate_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"

  local gate_started_at
  gate_started_at=$(date +%s)
  local gate_rc=0
  run_gate_container "$ref" "$review_log_file" || gate_rc=$?
  local gate_attempts="${TRANSPORT_RETRY_ATTEMPTS:-1}"

  local post_gate_head
  post_gate_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"

  local gate_has_runner_commits=0
  if [ -n "$pre_gate_head" ] && [ -n "$post_gate_head" ] \
      && [ "$pre_gate_head" != "$post_gate_head" ]; then
    gate_has_runner_commits=1
  fi

  local gate_transport_crash=false
  if [ "$gate_rc" != "0" ] && is_transport_crash "$review_log_file"; then
    gate_transport_crash=true
  fi

  # As on the implement path: snapshot failure takes precedence over the
  # transport-crash signal captured in gate_transport_crash. No abort flag.
  if ! post_gate_json="$(take_snapshot "$feature")"; then
    local snap_fail_at snap_gate_duration snap_iter_duration
    snap_fail_at=$(date +%s)
    snap_gate_duration=$(( snap_fail_at - gate_started_at ))
    snap_iter_duration=$(( impl_duration + snap_gate_duration ))
    echo "runner: dispatch_one: tracker-snapshot failed (post-gate stage) for ref '$ref'" >&2
    RUN_STOP_REASON="snapshot-failed-mid-dispatch:post-gate"
    record_dispatch "$feature" "$nn" "$ref" "FAIL" "$snap_iter_duration" "y" "$gate_attempts"
    return 1
  fi

  local gate_ended_at gate_duration iter_duration
  gate_ended_at=$(date +%s)
  gate_duration=$(( gate_ended_at - gate_started_at ))
  iter_duration=$(( impl_duration + gate_duration ))

  local gate_verdict
  gate_verdict="$(classify_gate_outcome "$post_implement_json" "$post_gate_json" "$ref" "$gate_rc" "$gate_transport_crash")"

  local review_label combined_label
  case "$gate_verdict" in
    clean)
      review_label="clean → done"
      combined_label="done"
      ;;
    blocked)
      review_label="blocked"
      combined_label="blocked"
      ;;
    review-aborted)
      review_label="review-aborted"
      combined_label="review-aborted"
      ;;
    *)
      review_label="gate-failed"
      combined_label="gate-failed"
      ;;
  esac

  format_progress_outcome "$(now_clock)" "$ref" "review" "$review_label" "$gate_duration"

  if [ "$gate_verdict" = "gate-failed" ] || [ "$gate_verdict" = "review-aborted" ]; then
    local gate_flag_type="technical"
    [ "$gate_verdict" = "review-aborted" ] && gate_flag_type="transport"
    write_abort_flag "$feature" "$nn" "gate" "$gate_rc" "$review_log_file" "$gate_flag_type"
    record_dispatch "$feature" "$nn" "$ref" "$combined_label" "$iter_duration" "y" "$gate_attempts"
    return 1
  fi

  # Propagate the gate's commit to the host — same commit-delta gate as the
  # implement stage. Under local-markdown the gate prompt contracts to
  # commit on clean and blocked alike, so the branch advances and this
  # fires; under github-issues the gate's tracker mutations are API calls
  # producing no commit, the branch tip is unchanged, and this is a no-op.
  # The classifier itself only checks exit code and status delta, so the
  # local-markdown commit invariant is a prompt-level concern, not enforced
  # here. A parking-ref publish failure (error) halts the loop — same as
  # the implement-stage path above.
  if [ "$gate_has_runner_commits" -eq 1 ]; then
    if ! propagate_feature "$feature"; then
      # As in the implement stage: the review outcome line above already
      # showed the gate verdict (clean → done / blocked). Emit a follow-up
      # `halt → gate-failed` line so the visible record matches the
      # SUMMARY.md row.
      local gate_halt_duration iter_halt_duration
      gate_halt_duration=$(( $(date +%s) - gate_started_at ))
      iter_halt_duration=$(( impl_duration + gate_halt_duration ))
      format_progress_outcome "$(now_clock)" "$ref" "review" "halt → gate-failed" "$gate_halt_duration"
      record_dispatch "$feature" "$nn" "$ref" "gate-failed" "$iter_halt_duration" "y" "$gate_attempts"
      RUN_STOP_REASON="propagation-error"
      return 1
    fi
  fi

  record_dispatch "$feature" "$nn" "$ref" "$combined_label" "$iter_duration" "y" "$gate_attempts"
  return 0
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
  # `finalize_run` writes SUMMARY.md, prints the end-of-run table, and
  # releases the lock — see its definition for the pre-flight vs. normal
  # branches. Installed *before* `preflight` so a `fail_invariant` exit
  # still runs the trap.
  trap finalize_run EXIT
  trap handle_preflight_signal INT TERM
  preflight
  trap handle_signal INT TERM
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
