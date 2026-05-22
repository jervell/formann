# Formann

The framework that lets a maintainer orchestrate autonomous coding agents on tracked issues. Defines the lifecycle, the role surfaces consumed by skills, and the symlink-based shape that consumer repos take when they adopt it.

## Terms

### Framework structure

**Glossary**:
The single vocabulary file at the consumer's root (`GLOSSARY.md`) that defines the project's canonical terms and redirects legacy aliases to their replacements.
_Avoid_: context, CONTEXT.md, context map, ubiquitous language doc

**Formann**:
The framework as a whole — repo, code, docs.
_Avoid_: "the project", "the system"

**Framework content**:
Everything shippable inside Formann's repo at `framework/` — skills, agents, bindings, runner, lifecycle docs.
_Avoid_: "core", "library"

**Consumer**:
A repo that adopts Formann by installing symlinks into a local Formann checkout. Formann itself dogfoods, so it is its own first **Consumer**.
_Avoid_: "client", "user repo", "target repo"

**`.formann`**:
A gitignored symlink at a **Consumer**'s root pointing at the local Formann checkout. The indirection that keeps the consumer's committed symlink graph portable across machines.
_Avoid_: "the link", "Formann mount"

### Lifecycle

**Feature**:
A slug-named work unit: a slug, a branch, one or more issues, and an optional PRD. Two shapes are equally valid:
- **PRD-bearing** — `.features/<slug>/PRD.md` plus issues. The standard path through `/grill-with-docs` → `/to-prd` → `/to-issues`.
- **Standalone** (PRD-less) — `.features/<slug>/issues/` with no `PRD.md`. Created conversationally by asking the agent. Can grow into a multi-issue feature without ever needing a PRD.

The slug is the stable binding-agnostic identifier: it names the feature branch, the local-markdown directory, and the github-issues slug label.
_Avoid_: "feature dir", "mini-feature", "micro-feature"

**Lifecycle**:
The pipeline an idea travels through: inbox → PRD → issues → triage → implement → review → done.

**Skill**:
A Claude Code slash command that advances work along the **Lifecycle** (`/triage`, `/implement`, `/grill-with-docs`, …). Lives at `framework/skills/<name>/`.
_Avoid_: "command", "slash command"

**Agent**:
A Claude Code subagent (e.g., `review-feature`, `review-issue`) — a single-purpose worker invoked from inside a **Skill**. Lives at `framework/agents/<name>.md`.
_Avoid_: Using "agent" to mean "an autonomous run inside the sandbox" — that's a **Dispatch**.

### Bindings

**Role**:
An abstract interface that **Skills** consume. Today: the **issue-tracker role**, defined by seven tracker-operation verbs (publish, fetch, list, get, set-status, archive, comment).
_Avoid_: "interface", "contract"

**Binding**:
A concrete implementation of a **Role**. Today: the **local-markdown binding** of the **issue-tracker role**. Future: a **GitHub-issues binding**. Each **Consumer** picks one **Binding** per **Role**.
_Avoid_: "implementation", "adapter", "plugin"

**Role surface**:
The consumer-side directory (`docs/formann/`) where the chosen **Binding**'s files are exposed via symlinks. **Skills** read paths in the role surface; symlink targets reflect the binding choice.
_Avoid_: "interface directory", "binding mount"

### Runner

**Runner**:
The orchestrator that drains a feature's `ready-for-agent + AFK` queue without maintainer keystrokes. Framework code at `framework/runner/`.

**Dispatch**:
A single autonomous run of `/implement` (or `review-and-gate`) inside a sandbox container, kicked off by the **Runner**. One dispatch per issue.
_Avoid_: "execution", "agent run"

**Dockerfile**:
Consumer-owned. Lives in the **Consumer** repo (not Formann), because container contents are project-specific (toolchain, build commands). The **Installer** scaffolds an initial one.

**Runner-checkout**:
The separate git clone at `.runner-state/checkout/` that the **Runner** mounts into the sandbox container as `/repo`. Distinct from the **Consumer**'s host repo: the **Dispatch** has no access to the host's `.git/`, working tree, or `~/`. The **Parking ref** is where the **Runner-checkout**'s committed work lands on the host side.
_Avoid_: "runner clone", "sandbox repo"

**Parking ref**:
Per-feature ref (`refs/remotes/runner/<feature>`) in the **Consumer**'s repo where the **Runner** publishes every **Dispatch**'s output. The **Runner**'s authoritative chain for the feature; advances linearly in the steady-state on-branch loop and is force-updated when the maintainer pulls and rebases (the next dispatch's tip is no longer a descendant of the prior parking-ref tip). The maintainer pulls from this ref via `git pull runner <feature>` to bring runner work into the local feature branch.
_Avoid_: "shadow branch", "runner branch"

**Runner remote**:
The local git remote named `runner` in the **Consumer**'s repo, pointing at `.runner-state/checkout/`. Registered lazily on the **Runner**'s first invocation. The **Parking ref**s live under this remote (`refs/remotes/runner/<feature>`).
_Avoid_: "runner clone" (that's the **Runner-checkout** at `.runner-state/checkout/`, a separate concept).

### Installer

**Installer**:
An agent-prompt (Skill) inside Formann that wires up a **Consumer**: creates the `.formann` indirection, asks for **Binding** choices, sets up symlinks, scaffolds the **Dockerfile**.
_Avoid_: "setup script" (the prompt may delegate to scripts, but the installer is the prompt)

## Relationships

- **Formann** ships **Framework content**.
- A **Consumer** has a `.formann` symlink to a Formann checkout, plus per-thing symlinks resolving through it.
- A **Role** has one or more **Bindings**; each **Consumer** chooses one **Binding** per **Role**.
- A **Skill** reads files from the **Role surface**, never from a binding's directory directly.
- The **Runner** kicks off **Dispatches**; each **Dispatch** executes one **Skill** invocation in a sandbox.
- The **Installer** creates a **Consumer**'s shape from a clean repo.

## Example dialogue

> **Maintainer:** "I want GitHub Issues support in my project."
> **Domain:** "Write a **GitHub-issues binding** under `framework/bindings/github-issues/`. It must realize the seven **issue-tracker role** verbs. When you re-run the **Installer** with `--binding=github-issues`, your **Consumer**'s **Role surface** repoints at that binding. **Skills** don't change — they read the role surface, which now exposes GitHub-shaped behavior."

## Flagged ambiguities

- "agent" — overloaded between (a) a Claude Code subagent (e.g., `review-feature`) and (b) "the autonomous thing running in the sandbox." Resolved: (a) is **Agent**; (b) is **Dispatch**.
- "target repo" — used in conversation for what is now **Consumer**. Resolved: prefer **Consumer**.
- "docs/agents/" — the pre-Formann name of the **Role surface** in iot. Resolved: renamed to `docs/formann/` post-extraction.
