## Formann

This repo uses the [Formann](https://github.com/arne/formann) agentic methodology framework.
Framework content is symlinked through `.formann/` into `.claude/skills/`, `.claude/agents/`,
`.claude/rules/`, and `docs/formann/`.

### Issue tracker

Issues and PRDs live as markdown files in `.scratch/`. The binding contract is at
`docs/formann/issue-tracker/BINDING.md`. Lifecycle and triage rules are at
`docs/formann/lifecycle.md`.

### Inbox

Pre-lifecycle deferred thoughts live in `.inbox.md`. See `docs/formann/inbox.md`
for conventions.

### Triage labels

State vocabulary (`needs-triage`, `ready-for-agent`, `in-review`, `done`, etc.) is
defined in `docs/formann/triage-states.md`.

### Domain docs

Domain vocabulary and architectural decisions live in `CONTEXT.md` and `docs/adr/`.
See `docs/formann/domain.md` for the domain-doc contract.
