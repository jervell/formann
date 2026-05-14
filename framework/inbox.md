# Inbox: Local Markdown

The inbox is a pre-lifecycle capture surface for thoughts the maintainer can't act on right now — bugs they noticed, tweaks, half-formed ideas. Entries are notes, not issues. They have no state, no header fields, and don't enter any state machine until they leave the inbox.

The inbox is optional. Projects that don't use one simply have no `.inbox.md` file.

## Conventions

- The inbox lives at the project root, parallel to `CONTEXT.md` and `.out-of-scope/`.
- Short entries are bullets in `.inbox.md`.
- An entry that needs more than one line is a markdown link to a body file at `.inbox/<slug>.md`. Create `.inbox/` lazily — only when the first long entry appears.
- Entries are dated where useful (e.g. `2026-04-18 Dropdown misaligned on mobile`). Optional, not required.
- No `status`, no `category`, no `type`. Order doesn't matter; the inbox is a set, not a queue.

Example `.inbox.md`:

```markdown
# Inbox

- 2026-04-18 Dropdown misaligned on mobile (bug)
- 2026-04-20 Archive button doesn't update mtime (bug)
- 2026-04-22 [Rethink chat polling architecture](.inbox/chat-polling-rethink.md)
```

## Operations

### Capture

Append a bullet to `.inbox.md`. If the entry needs more space than one line, create `.inbox/<slug>.md` with the body and link the bullet to it.

### List

Read `.inbox.md` and the contents of `.inbox/`.

### Promote

When the maintainer is ready to act on an entry, route it to the right lifecycle entry point based on its scope:

- **Feature-shaped seed** — multi-issue scope, real architectural unknowns, needs scoping. Run `/grill-with-docs` with the entry as starting context. Once the feature workspace is set up, delete the entry from `.inbox.md` (and remove its body file from `.inbox/` if any).
- **One-off fix or tweak** — single slice, no PRD warranted. Create a micro-feature directly: `.scratch/<slug>/issues/01-<slug>.md`, no `PRD.md`. Then delete the entry.

The judgment of which path applies belongs to the maintainer. If it's not obvious from the entry, confirm before promoting.

### Drop

When an entry won't be done:

- **Trivially gone** — the concern stopped mattering, or it's already resolved. Delete the bullet.
- **Meaningfully rejected** — write `.out-of-scope/<slug>.md` explaining the reasoning, then delete the bullet. Same format as a triage `wontfix`.

## Committing inbox changes

**Capture does not auto-commit.** It's intentionally lightweight — append a bullet, save, get back to work. Leaving the inbox change uncommitted is fine; the maintainer folds it into the next commit at their discretion, or it gets carried along by the next inbox operation that does commit.

**Promote and drop do commit**, because they touch other parts of the system (feature workspaces, `.out-of-scope/`) where a clean working tree matters. Subject line prefixed with `inbox:` so these commits can be filtered (`git log --grep '^inbox:' --invert-grep`).

- A promote that creates a feature workspace produces two commits: the workspace-setup commit (under the feature's branch) followed by an `inbox:` commit on the inbox-clearing change.
- A drop that writes to `.out-of-scope/` combines both edits into one `inbox:` commit.