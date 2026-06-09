# Streamed structured events supersede the PTY buffering workaround; crash detection reads the structured result event

The AFK Runner previously dispatched `claude -p "<prompt>"` in **print mode**, capturing the agent's single closing message. Two consequences followed from that choice, and this decision reverses both: the dispatch ran under a PTY purely to defeat output buffering, and the transport-crash classifier recognised retryable failures by grepping the saved log for error-string signatures. Dispatches now run with `--output-format stream-json --verbose` (no PTY), splitting each dispatch's stdout (a structured-event stream) and stderr (diagnostics) into separate artifacts, and the classifier reads the terminal `result` event's structured fields instead of scraping text.

## Streamed events supersede the PTY

Print mode emits nothing until the process exits, so the dispatch allocated a PTY (`docker run -t`) solely to make `claude` see a TTY and line-buffer its stdout — otherwise a long dispatch produced zero observable output and a hung dispatch was indistinguishable from a slow one. The PTY paid for that observability with a standing cost: it translated every `\n` into `\r\n` and injected terminal escape sequences into every saved log, so the forensic record was permanently noisy.

Streamed structured events flush per line over a plain pipe, so the line-buffering the PTY existed to force now happens for free. The PTY is removed. Dropping it both eliminates the `\r\n`/escape-sequence noise and yields a saved record that is a full event trace — every tool call, tool result, and the terminal `result` event — rather than a single closing blurb. The agent's closing message survives as a readable per-dispatch summary, extracted from the terminal `result` event's `result` text.

The rejected alternative is keeping print mode and the PTY. It is rejected because the live status line this feature is built on (the dependent issue) requires an event stream to tail, and because the PTY's log-noise cost is permanent while its observability benefit is fully replaced by streaming.

## Crash detection reads the structured `result` event, not stderr text

The print-mode classifier grepped the merged log for a fixed set of crash signatures (`API Error: 5xx`/`429`, `fetch failed`, `ECONNRESET`, `ETIMEDOUT`, `getaddrinfo`, empty output). Under streamed events that signal moved. The prerequisite spike (issue #70) injected real transport faults — forced HTTP 429/503, DNS failure, connection reset/refused, blackholed timeout, and pre-init kill — under the target invocation and recorded where each surfaces. The finding is load-bearing and is realised here verbatim:

- Every transport fault surfaces in **one** typed source: the terminal `result` event's `is_error` (bool) and `api_error_status` (int|null). `subtype` stays `"success"` even on error, so the truth is the boolean, not the subtype.
- **stderr carries no API-error detail** for any fault — only entrypoint noise and a generic `exit status <N>`. The dual-source design's planned middle tier ("grep stderr for crash signatures") is therefore **dead weight and is dropped**: there is nothing in stderr to grep, and the case it nominally covered (structured keys gone, prose intact) is fictional under stream-json, where the CLI renders transport errors *into* the structured result event.
- The human-readable error prose moved into the `result` string, is format-inconsistent, and is body-contaminated; it is diagnostic-only and never a detection input.

The classifier is therefore a **two-rung fail-safe ladder**, not the originally-sketched three-source chain:

- **Rung 1 (structured verdict).** `is_error:false` → success. `is_error:true` with `api_error_status` in {429} ∪ {500–599}, or a `null` status (no HTTP response: DNS/connect/reset/timeout), → transport crash, retry. `is_error:true` with any other 4xx → genuine failure (a distinction the old regex could not make). A lenient byte-level extraction of the same two keys handles a truncated final line before falling through.
- **Rung 2 (safety net).** Reached only when no `result` event is recoverable: a nonzero exit (including empty/whitespace stdout) → conservative transport-suspect, retry; a clean exit 0 with no parseable result → indeterminate, defer to the tracker-snapshot delta.

The decision splits the two functions cleanly: `is_transport_crash` makes the retry decision from the structured verdict plus exit/empty only, while `_transport_crash_class` is a cosmetic labeler for the `runner.log` retry line that may read the human-readable `result` string but never feeds the decision. The ladder is fail-safe by construction — any parse or IO surprise degrades to the next rung, and the final rung always yields a defined verdict, never an error that aborts the drain.

This changes only the **detection source**, not the retry policy: the `RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS` budget and the backoff schedule are unchanged. It does change classification at one edge the old detector handled differently: a dispatch that dies with no recoverable `result` event and a nonzero exit (e.g. an OOM kill) is now a conservative transport-suspect (retry) rather than a genuine failure — the spike's locked contract, on the grounds that a process killed before emitting its terminal result is more likely transient than a real verdict.

The rejected alternative is the dual-source design the PRD sketched (structured field → stderr crash-signature text → empty/exit). It is rejected because the spike proved the stderr-text tier contributes nothing under stream-json; keeping it would be untested dead code guarding a fictional case.

## Per-dispatch artifacts

Each dispatch (the implement stage and each post-implement walk step) writes a fixed set under the run dir:

- `<NN>.stdout.jsonl` — the streamed-event trace (the classifier's and summary extraction's input).
- `<NN>.stderr.log` — diagnostics, retained for forensics only; never a detection input.
- `<NN>.summary.md` — the agent's closing message, extracted from the terminal `result` event (the skim-the-outcome artifact the end-of-run SUMMARY links).
- `<NN>.exit` — the container exit code (the classifier's Rung-2 input).

The end-of-run SUMMARY's per-dispatch link points at the readable `.summary.md`; the event trace and diagnostics sit beside it on disk, discoverable by the naming convention documented in `runner/README.md`.
