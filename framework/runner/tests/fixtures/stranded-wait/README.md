# stranded-wait fixtures

Dispatch event streams for `is_stranded_wait`.

- `stranded.stdout.jsonl` — the closing message from the 2026-09-11 failure verbatim: the agent backgrounded the test suite, ended its turn to wait for it, and was never resumed. Must classify as stranded.
- `bail.stdout.jsonl` — a legitimate `/implement` bail (post-mortem posted, state set to `needs-info`). Must not classify as stranded.
