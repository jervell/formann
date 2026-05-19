# Formann conventions

Rules for agents (and humans) working in this repo.

## File conventions

- **README.md is for humans.** Never mix machine-readable structures (YAML frontmatter, schema tables) into a README. Machine-readable artifacts get their own files. Keeps human-facing prose unobstructed and keeps tooling deterministic.


## Running bats tests

The verdict is the **exit code**, never stdout. `bats` exits 0 iff every test passed. "The last lines look green" or "mostly passes scrolled by" is not evidence of success.

### Canonical invocation

```sh
bats -p --print-output-on-failure <path>
```

- `-p` (pretty) forces the trailing `N tests, M failures` summary even when stdout is piped. Without it, bats defaults to TAP when stdout is not a TTY and emits **no** summary — the last line of a run with failures can still read `ok N <name>` if the final tests happened to pass.
- `--print-output-on-failure` dumps each failing test's `$output` inline, right under its `not ok` line. A single run gives you both the verdict and the diagnostic context — don't re-run with `-x` or `--verbose-run`, and don't pipe to `grep` / `head` / `tail`. Post-processing strips the summary and can drop failures or their inline diagnostics. If the output is too noisy, narrow the test selection upstream (`-f`, `--filter-status failed`, a single file) instead of trimming the output.

### Pass check — all three must hold

1. **Exit code is 0.** If you piped through `tee`, the exit code is in `${PIPESTATUS[0]}` (bash) or `${pipestatus[1]}` (zsh), not `$?`.
2. **A summary line `N tests, M failures` is present at the bottom**, with `M = 0`.
3. **`N` matches what you asked for.** `bats -p -f '<typo>' …` prints `0 tests, 0 failures` and exits 0. Zero tests run is never a pass — it's a filter that matched nothing.

### Focused re-runs

Don't re-run the full suite while iterating on a fix. Use `--filter-status failed` — it re-runs only the previously-failed tests, and the recorded set updates each run. A focused run proves the fix for the targeted tests; it doesn't prove the suite is green, so do one final full run before claiming suite-wide success.


## Formann methodology (self-referencing dog-fooding info)

This repo uses the Formann agentic methodology.

### Issue tracker

Issues, PRDs, and triage are described in `docs/formann/issue-tracker/BINDING.md`.

### Inbox

Pre-lifecycle capture for deferred thoughts (bugs, tweaks, half-formed ideas). Optional add-on, described in `docs/formann/inbox.md`.

### Triage labels

Triage states and their meanings are described in `docs/formann/triage-states.md`.

### Domain docs

Domain vocabulary and architectural decisions live in `GLOSSARY.md` and `docs/adr/`. See `docs/formann/domain.md` for the domain-doc contract.