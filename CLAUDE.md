# Formann conventions

Rules for agents (and humans) working in this repo.

## File conventions

- **README.md is for humans.** Never mix machine-readable structures (YAML frontmatter, schema tables) into a README. Machine-readable artifacts get their own files. Keeps human-facing prose unobstructed and keeps tooling deterministic.


## Formann methodology (self-referencing dog-fooding info)

This repo uses the Formann agentic methodology.

### Issue tracker

Issues, PRDs, and triage are described in `docs/formann/issue-tracker/BINDING.md`.

### Inbox

Pre-lifecycle capture for deferred thoughts (bugs, tweaks, half-formed ideas). Optional add-on, described in `docs/formann/inbox.md`.

### Triage labels

Triage states and their meanings are described in `docs/formann/triage-states.md`.

### Domain docs

Domain vocabulary and architectural decisions live in `CONTEXT.md` and `docs/adr/`. See `docs/formann/domain.md` for the domain-doc contract.