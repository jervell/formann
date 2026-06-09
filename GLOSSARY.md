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
- **PRD-bearing** — the feature has a PRD. The standard path through `/grill-with-docs` → `/to-prd` → `/to-issues`.
- **Standalone** (PRD-less) — no PRD. Created conversationally by asking the agent. Can grow into a multi-issue feature without ever needing a PRD.

The slug is the stable identifier across bindings: it names the feature branch and groups the feature's issues under whichever **Binding** the consumer has chosen.
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
An abstract interface that **Skills** consume. Today: the **issue-tracker role**, defined by its tracker-operation verbs (see each binding's `BINDING.md` for the canonical list).
_Avoid_: "interface", "contract"

**Binding**:
A concrete implementation of a **Role**. Today: the **local-markdown binding** and the **GitHub-issues binding**, both realizing the **issue-tracker role**. Each **Consumer** picks one **Binding** per **Role**.
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

**Post-implement phase**:
The ordered sequence of **Dispatch**es the **Runner** executes after a successful `/implement`. Driven by a **Consumer**-owned manifest (`runner/manifest.md`) resolved at pre-flight; each manifest line is a prompt path resolved against the consumer root (`runner/`) first, then the framework root (`framework/runner/steps/`). The step label is the filename without its `.md` extension. The **Runner** walks the manifest one item at a time: dispatch → propagate → snapshot → classify → react. The default manifest contains exactly one entry (`review-and-gate.md`) running the fused `review-and-gate` prompt, reproducing the original hardcoded gate stage. An issue left at `in-review` after all items are exhausted is recorded as `left-for-human` (no abort flag). A **Dispatch** error in any item writes an abort flag keyed by the item's label.
_Avoid_: "gate stage", "review phase" (those describe specific prompts, not the configurable walk structure)

**Building-block step**:
A single-purpose framework-shipped prompt in `framework/runner/steps/` that does exactly one thing in the **Post-implement phase**: `review.md` (runs the independent review, posts severity-tagged findings comment, no state change), `gate.md` (reads the latest findings comment, promotes to `done` only when no Critical findings, no new review), or `fix.md` (reads the latest findings comment and commits changes, no state change, no comment). Compose them in a manifest to get different workflows: `[review.md]` for review-without-gate, `[review.md, gate.md]` to reuse the framework gate with a separate review, or the unrolled iterate pattern (`[review-and-gate.md, fix.md, review-and-gate.md, …]`) to loop until clean.
_Avoid_: "step", "prompt" (ambiguous — these are specifically the decomposed single-purpose variants, not the fused `review-and-gate`)

**Review↔gate contract**:
The handoff convention between a review step and a gate step: the review posts a comment containing severity markers (`🔴 Critical` / `🟡 Important` / `🟢 Minor`), and the gate reads the **latest** such comment and thresholds on `🔴 Critical`. Because the steps are separate **Dispatch**es with no shared stdout or filesystem, the tracker comment is the sole channel. Any review that emits the convention interoperates with the framework `gate` prompt; a custom review that cannot emit it ships its own gate.
_Avoid_: "review contract", "findings format" (the contract is specifically the severity-marker convention in the posted comment)

**Progress line**:
A per-stage line on the **Runner**'s stdout — `[HH:MM:SS] <ref> <stage> → starting`, then `→ <outcome> (<duration>)` — captured into `runner.log` by the tee capture. The durable per-stage record of a run; between a stage's two progress lines this channel is silent for the whole **Dispatch**.
_Avoid_: conflating with the **Liveness line** (that one never reaches any saved log)

**Liveness line**:
The single transient line the **Runner** paints in place on the controlling terminal while a **Dispatch** is in flight: `<feature>/<NN> <stage> <elapsed> | <phase> (<time-in-phase>)`. Derived by tailing the dispatch's event-stream artifact and repainted every second, so time-in-phase climbs even when no event arrives. A changing **Dispatch phase** with a resetting timer reads as healthy; a frozen phase with a climbing timer reads as stuck. Painted directly to `/dev/tty`, bypassing the `runner.log` capture — it never lands in any saved artifact, stays off a redirected stdout, and is silently absent when there is no controlling terminal (detached run). Cleared when the dispatch ends. Informs only; never acts.
_Avoid_: "status line"; "spinner" (there is no spinner — the event cadence is bursty, so time-in-phase is the liveness truth)

**Dispatch phase**:
What an in-flight **Dispatch** is doing right now, derived from the latest relevant streamed event. Exactly three: **running-tool** (an assistant event carrying a tool-use block; labeled with the tool name and its target), **thinking** (a tool-result event; the model is working out its next turn), and **retry/backoff** (a `system`/`api_retry` event; the CLI is retrying a transport fault internally, the label carries attempt/max and a reason, and each new attempt is a phase change so the time-in-phase resets).
_Avoid_: "state", "activity" (the **Liveness line** renders a phase)

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
- "docs/agents/" — the pre-Formann name of the **Role surface**. Resolved: renamed to `docs/formann/`.
- "observer" — overloaded between (a) the operator glancing at the live terminal (the **Liveness line**'s audience) and (b) the renderer process, a read-only observer of the artifacts a **Dispatch** writes. Resolved: unqualified "observer" means (a), the operator; (b) is always named "the renderer".
