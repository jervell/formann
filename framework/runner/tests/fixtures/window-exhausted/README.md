# Window-exhausted classifier fixtures

Stream-json event captures that exercise the window-exhausted retry class
(issue #75): `is_window_exhausted`, `window_resets_at`,
`window_rate_limit_type`, and `with_window_retry`. Each case is a
`<name>.stdout.jsonl` (the dispatch's stdout event stream) plus a
`<name>.exit` (the container exit code, a bare integer — the format the
runner writes).

The shapes mirror the streams observed in runs 20260610-080748 and
20260610-092557 (CLI 2.1.132, claude-code#57096): an exhausted five-hour
window does not refuse at startup — the dispatch runs ~400ms and emits a
well-formed stream (`init` → `rate_limit_event` with `status:"rejected"` →
synthetic assistant message with `error:"rate_limit"` → terminal `result`
with `is_error:true, api_error_status:429`), then exits 1. Identifying
fields (session ids, uuids) are synthesized; decision-relevant fields are
faithful to the observed captures.

| Fixture | `rate_limit_event` content | Terminal `result` event | exit | Verdict |
|---|---|---|---|---|
| `rejected` | `status:"rejected"`, `resetsAt:1781017200`, `rateLimitType:"five_hour"` | `is_error:true`, `api_error_status:429` | 1 | window-exhausted → wait until `resetsAt`+60s |
| `rejected-no-resetsat` | `status:"rejected"`, no `resetsAt` key | `is_error:true`, `api_error_status:429` | 1 | window-exhausted → fallback wait |
| `rejected-corrupt` | a `rate_limit_event` injected mid-NDJSON-line (claude-code#49640, unparseable — skipped) plus a parseable `status:"rejected"` event | `is_error:true`, `api_error_status:429` | 1 | window-exhausted — corrupt line skipped, parseable event detected |
| `allowed` | `status:"allowed"` only | `is_error:true`, `api_error_status:500` | 1 | NOT window-exhausted — stays transport-class |
| `rejected-then-allowed` | `status:"rejected"` followed by `status:"allowed"` | `is_error:true`, `api_error_status:500` | 1 | NOT window-exhausted — the *last* parseable event wins |
