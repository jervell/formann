# Liveness phase-deriver fixtures

Synthetic single-event `stream-json` lines exercising `derive_phase` in
`liveness.sh`. Each file is one JSONL event, structurally faithful to the
events `claude --output-format stream-json --verbose` emits (same envelope
fields as the real captures under `../transport-crashes/`); only the
content blocks are hand-set to isolate one deriver branch each.

| Fixture | Event shape | Expected phase |
|---|---|---|
| `assistant-tool-use-bash.jsonl` | assistant, `tool_use` Bash with `command` + `description` | `Bash: <command>` |
| `assistant-tool-use-read.jsonl` | assistant, `tool_use` Read with `file_path` | `Read: <file_path>` |
| `assistant-tool-use-task.jsonl` | assistant, `tool_use` Task with `description` only | `Task: <description>` |
| `assistant-tool-use-bare.jsonl` | assistant, `tool_use` with empty `input` | bare tool name |
| `assistant-tool-use-multiline.jsonl` | assistant, Bash `command` containing newlines/tabs | whitespace collapsed to single spaces |
| `assistant-parallel-tool-use.jsonl` | assistant, two `tool_use` blocks | first block wins |
| `assistant-text-only.jsonl` | assistant, text content only | *(no phase change)* |
| `user-tool-result.jsonl` | user, `tool_result` block | `thinking` |
| `user-plain-text.jsonl` | user, plain string content | *(no phase change)* |

The retry/backoff branch is **not** synthesized here: its fixtures are the
real `system/api_retry` captures lifted from `../transport-crashes/`
(`http429`, `http503`, `econnreset`), referenced by line from
`tests/liveness.bats`.
