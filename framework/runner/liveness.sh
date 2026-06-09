#!/usr/bin/env bash
# liveness.sh — the runner's liveness line: phase deriver, line formatter,
# and renderer loop.
#
# Sourceable, no side effects at source time. `derive_phase`,
# `format_liveness_line`, and `humanize_duration` are pure (no I/O beyond
# stdin/stdout, no globals, no clock — durations are passed in) and covered
# by tests/liveness.bats. `liveness_render_loop` is the orchestration shell
# around them: it owns the tail-the-artifact loop, the timers, and the
# terminal painting, and is exercised by the operator-attended smoke walk
# (it cannot run inside the dispatch container — no controlling terminal).
#
# Two output surfaces must not be conflated (see GLOSSARY.md):
#   - progress lines — per-stage `<stage> → starting/outcome` lines on the
#     runner's stdout, captured into runner.log.
#   - the liveness line — the single transient line this module paints
#     directly to the controlling terminal (`/dev/tty`), bypassing the
#     runner.log capture entirely. It never lands in any saved artifact.
#
# Fault-isolation invariant (governing): everything here is a read-only
# observer of files the dispatch writes. Every failure mode — malformed or
# partial event line, jq failure, missing or unwritable terminal, terminal
# write error — degrades to a missing or partial liveness line and the loop
# continues. Nothing in this module may terminate, delay, or alter a
# dispatch or its classified outcome.

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

# Map one streamed event line to the dispatch's current phase. Output
# (stdout): the phase label, or empty when the event is irrelevant (init,
# result, text-only assistant turn, plain user text) or unparseable — empty
# means "no phase change" to the renderer. The label doubles as the phase
# identity: the renderer resets its time-in-phase whenever the label changes.
#
# Three phases:
#   - running-tool — an assistant event carrying a tool_use block. Label is
#     the tool name plus a compact detail (command / file_path / pattern /
#     description, first present), whitespace runs collapsed so a multiline
#     command stays a single line. First block wins when a turn launches
#     several tools in parallel.
#   - thinking — a user event carrying a tool_result block: the model has the
#     result and is working out its next turn.
#   - retry/backoff — a `system`/`api_retry` event: the CLI is retrying a
#     transport fault internally and emits no tool events between attempts.
#     Label carries `attempt/max_retries` and a reason (the HTTP status when
#     present, the error token otherwise). The attempt number is part of the
#     identity on purpose: advancing attempts read as liveness (label and
#     timer both move); a frozen attempt with a climbing timer reads as a
#     genuinely wedged retry loop.
#
# Fail-safe: always returns 0; any jq error degrades to empty output.
derive_phase() {
  local event_line="$1"
  printf '%s' "$event_line" | jq -r '
    if .type == "assistant" then
      (first(.message.content[]? | select(.type? == "tool_use")) // null) as $t
      | if $t == null then empty
        else
          (($t.input.command // $t.input.file_path // $t.input.pattern
            // $t.input.description // "")
           | tostring | gsub("[[:space:]]+"; " ")) as $detail
          | if $detail == "" then $t.name else "\($t.name): \($detail)" end
        end
    elif .type == "user" then
      if any(.message.content[]?; .type? == "tool_result")
      then "thinking" else empty end
    elif .type == "system" and .subtype == "api_retry" then
      "retry \(.attempt)/\(.max_retries) (\(
        if .error_status == null then (.error // "unknown")
        else (.error_status | tostring) end))"
    else empty end
  ' 2>/dev/null || true
  return 0
}

# Render the liveness line from its six inputs plus the terminal width.
# Durations are integer seconds, passed in (no clock here). The line is
# truncated to width-1 characters so a long tool label can never reach the
# last column and wrap, which would corrupt the single-line display.
#
# Shape: <feature>/<issue> <stage> <elapsed> | <phase> (<time-in-phase>)
# e.g.:  runner-liveness-line/72 implement 12m 34s | Bash: bats -p framework/runner/tests (1m 2s)
format_liveness_line() {
  local feature="$1" issue="$2" stage="$3" phase="$4"
  local elapsed="$5" phase_seconds="$6" width="$7"
  local line
  line="$(printf '%s/%s %s %s | %s (%s)' "$feature" "$issue" "$stage" \
    "$(humanize_duration "$elapsed")" "$phase" "$(humanize_duration "$phase_seconds")")"
  printf '%s\n' "${line:0:$(( width - 1 ))}"
}

# Renderer loop — runs as a separate background process for the duration of
# one dispatch attempt (spawned/reaped by run-the-queue.sh around the
# `docker run`). Tails the dispatch's event-stream artifact on a one-second
# poll loop and repaints the liveness line in place on the controlling
# terminal every tick, so the time-in-phase climbs even when no event
# arrives. Clears its line on every exit path so nothing lingers between
# dispatches.
#
# Args: $1 = event-stream artifact ($log_base.stdout.jsonl)
#       $2 = feature   $3 = issue (nn)   $4 = stage label
#       $5 = dispatch start (epoch seconds; empty → now)
#       [$6 = terminal path (default /dev/tty; injectable for a smoke probe)]
liveness_render_loop() {
  local stream_file="$1" feature="$2" issue="$3" stage="$4" started_at="$5"
  local tty_path="${6:-/dev/tty}"

  # The spawning runner script runs `set -e`; an observer that dies on the
  # first hiccup would violate the degrade-and-continue invariant.
  set +e

  # `$$` in a backgrounded function still reports the spawning script's PID
  # (bash does not reset it in subshells) — that is the runner, our reaper.
  # If the runner dies without reaping us, exit rather than linger.
  local runner_pid=$$

  local now phase="starting" phase_started_at
  now="$(date +%s)"
  phase_started_at="$now"
  [ -n "$started_at" ] || started_at="$now"

  trap 'exit 0' INT TERM HUP
  # Clear the painted line on any exit so no half-painted text survives
  # the dispatch — to a dead terminal this is a no-op, never an error.
  # shellcheck disable=SC2064 — tty_path is fixed at trap time by design.
  trap "{ printf '\r\033[2K' >'$tty_path'; } 2>/dev/null || true" EXIT

  # The artifact is created by the runner's redirect before the container
  # starts; give it a few ticks anyway, then bow out silently — a missing
  # line is the defined degradation, not an error.
  local tries=0
  until [ -e "$stream_file" ]; do
    tries=$(( tries + 1 ))
    [ "$tries" -ge 5 ] && exit 0
    sleep 1
  done
  exec 3<"$stream_file" || exit 0

  local buf="" chunk="" line new_phase width out elapsed phase_seconds
  while :; do
    kill -0 "$runner_pid" 2>/dev/null || exit 0

    # Drain the complete lines that arrived since the last tick. A read that
    # hits end-of-file returns non-zero but still deposits the partial tail
    # (a line the dispatch hasn't finished writing) in $chunk; keep it as a
    # prefix for the next tick so every line is parsed exactly once, whole.
    chunk=""
    while IFS= read -r chunk <&3; do
      line="$buf$chunk"
      buf=""
      chunk=""
      new_phase="$(derive_phase "$line")"
      if [ -n "$new_phase" ] && [ "$new_phase" != "$phase" ]; then
        phase="$new_phase"
        phase_started_at="$(date +%s)"
      fi
    done
    buf="$buf$chunk"

    now="$(date +%s)"
    elapsed=$(( now - started_at ))
    phase_seconds=$(( now - phase_started_at ))
    width="$(stty size <"$tty_path" 2>/dev/null | awk '{print $2}')"
    case "$width" in (""|*[!0-9]*) width=80 ;; esac
    out="$(format_liveness_line "$feature" "$issue" "$stage" "$phase" \
      "$elapsed" "$phase_seconds" "$width")"
    { printf '\r\033[2K%s' "$out" >"$tty_path"; } 2>/dev/null || true

    sleep 1
  done
}
