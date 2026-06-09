# Transport-crash classifier fixtures

Stream-json event captures that exercise `is_transport_crash` and
`_transport_crash_class` against the two-rung contract locked by the
transport-error spike (#70). Each case is a `<name>.stdout.jsonl` (the
dispatch's stdout event stream) plus a `<name>.exit` (the container exit code,
a bare integer — the format the runner writes). stderr is deliberately absent:
the spike proved it carries no transport signal, so the classifier never reads
it and no fixture needs it.

## Real captures (lifted from the spike)

Recorded under `claude --output-format stream-json --verbose` with the PTY
removed, against real fault injection. These are the durable copies of the
spike's `.runner-state/spike-70/artifacts/` captures.

| Fixture | Injected fault | Terminal `result` event | exit | Rung-1 verdict |
|---|---|---|---|---|
| `control` | none (healthy) | `is_error:false` | 0 | success — not a crash |
| `http429` | forced HTTP 429 | `is_error:true`, `api_error_status:429` | 1 | retry |
| `http503` | forced HTTP 503 | `is_error:true`, `api_error_status:503` | 1 | retry |
| `getaddrinfo` | DNS failure | `is_error:true`, `api_error_status:null` | 1 | retry |
| `econnreset` | connection reset | `is_error:true`, `api_error_status:null` | 1 | retry |
| `fetchfailed` | connection refused | `is_error:true`, `api_error_status:null` | 1 | retry |
| `etimedout` | blackholed SYN (bounded) | *(truncated — no result event)* | 137 | Rung 2 |
| `empty` | SIGKILL pre-init | *(0 bytes)* | 137 | Rung 2 |
| `inv-empty` / `inv-real` / `inv-garbage` | 429 with three response bodies | `is_error:true`, `api_error_status:429` | 1 | retry (body-invariant) |

## Synthesized cases (the spike's real captures don't cover these branches)

Structurally faithful to the real captures (same event shape, same field
positions); only the decision-relevant integers/truncation differ. The
body-invariance proof established that `api_error_status` is read off the
status line independent of the body, so a hand-set status is representative.

| Fixture | Purpose | exit |
|---|---|---|
| `http400` | other-4xx → **genuine failure** (a distinction today's regex cannot make; the spike only forced 429/5xx/null) | 1 |
| `truncated-result` | a final `result` line cut mid-object after both keys — strict `jq` fails, the lenient byte-level extraction recovers `429` → retry | 1 |
| `garbage` | non-JSON noise with no recoverable result event — exercises the fail-safe fall-through to Rung 2 | 1 |
