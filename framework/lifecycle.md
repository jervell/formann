# Feature lifecycle

How an idea becomes shipped, archived work.

## At a glance

Indexed by what you have in front of you:

| You have...                                     | Run...                                | Result                                       |
| ----------------------------------------------- | ------------------------------------- | -------------------------------------------- |
| a thought you can't act on now                  | (capture in the inbox)                | captured for later                           |
| a fuzzy idea                                    | `/grill-with-docs`                    | shared understanding                         |
| a grilled understanding                         | `/to-prd`                             | PRD published                                |
| a PRD                                           | `/to-issues`                          | issues at `needs-triage`                     |
| a `needs-triage` issue                          | `/triage`                             | `ready-for-*` / `needs-info` / `wontfix`     |
| a `ready-for-agent` issue                       | `/implement`                          | issue at `in-review`                         |
| a `ready-for-human` issue                       | (you do it)                           | issue at `in-review`                         |
| an `in-review` issue                            | `/triage`                             | `done` or `ready-for-agent` (rework)         |
| an `in-review` issue you want a second eye on   | (`review-issue` agent)                | findings; no state change                    |
| a feature ready before archive/merge            | (`review-feature` agent)              | findings; no state change                    |
| a feature with all issues terminal              | `/triage` (say "archive `<feature>`") | moved to `.features/.archived/`               |

## Layout

Two scopes. Project-level artifacts accumulate across features; feature-level artifacts come and go.

```
.                              ← project root
├── GLOSSARY.md                ← domain vocabulary (project-level)
├── docs/adr/                  ← architectural decisions (project-level)
├── .inbox.md                  ← captured ideas, deferred (optional, project-level)
├── .inbox/                    ← long-form bodies for inbox entries (optional)
├── .out-of-scope/             ← rejected feature concepts (project-level)
└── .features/
    ├── <feature>/             ← active features
    │   ├── PRD.md             ← spec, no Status
    │   └── issues/NN-*.md     ← work units, with Status / Category / Type
    └── .archived/<feature>/   ← archived features (whole dir moved)
```

Project-level artifacts shape and constrain feature work: `GLOSSARY.md`, `docs/adr/` (architectural decisions), `.out-of-scope/` (rejected concepts). Every pipeline stage reads from them; some stages write to them. Conventions for `GLOSSARY.md` and ADRs live in `docs/formann/domain.md`.

## Inbox (optional)

A pre-lifecycle capture surface for thoughts you can't act on right now — bugs you noticed, tweaks, half-formed ideas. Entries are notes (title + free-form body), not issues. They have no state and aren't visible to triage.

When an entry matures, it leaves the inbox by entering the lifecycle at the appropriate point: a feature-shaped seed kicks off `/grill-with-docs`; a one-off fix becomes a single-issue micro-feature directly. Entries that won't be done are deleted (trivial) or written to `.out-of-scope/` (meaningful rejection).

Opt-in. Projects that don't want it just don't have an `.inbox.md`. See `docs/formann/inbox.md` for the binding.

## Pipeline

**1. Grill** — `/grill-with-docs`
Reads `GLOSSARY.md`, `docs/adr/`. Writes updates to `GLOSSARY.md` as terms resolve; an ADR when a decision is hard to reverse, surprising without context, and a real trade-off.

**2. PRD** — `/to-prd`
Reads grilling context, `GLOSSARY.md`, `docs/adr/`. Writes `.features/<feature>/PRD.md` — problem, solution, user stories, decisions, out-of-scope. Synthesizes the grilling output into a written spec, with light module decomposition confirmed with the maintainer. The grilling carried the substantive design work; this stage records it.

**3. Slice** — `/to-issues`
Reads PRD, `GLOSSARY.md`, `docs/adr/`. Writes one issue per vertical slice at `.features/<feature>/issues/NN-<slug>.md`, each in state `needs-triage`, with a category (`bug` or `enhancement`) and type (`AFK` or `HITL`, provisional).

**4. Triage** — `/triage`
Reads issue, `GLOSSARY.md`, `docs/adr/`, `.out-of-scope/`. Writes updated state / category / type, an outcome-specific comment on the issue, an agent brief on `ready-for-*`, and a `.out-of-scope/` entry on `wontfix` of an enhancement. Resolves open questions in-session — type `HITL` and state `ready-for-human` describe the work, never "triage isn't finished".

**5. Implement** — `/implement`
Agent or human reads the issue, `GLOSSARY.md`, `docs/adr/`. Writes code and tests; a new ADR if implementation surfaces a hard-to-reverse decision. When shipped, sets state to `in-review` and posts a summary comment containing an **Evidence** block that maps each acceptance criterion to how it was demonstrated (test names or quoted command output for `verified` criteria; a one-line ask for `[human]` criteria), with a `[x]`/`[ ]` tick marking the agent's claim per criterion — see `/implement` for the format. HITL issues check in at the gates named in the brief.

**6. Verify** — `/triage`
Maintainer reads the shipped work + the summary's Evidence block. Trusts `[x]` (verified) coverage by default; walks each `[ ]` (`[human]`) row, posts a `### Verification` comment recording the walk, and sets state to `done` (accept) or `ready-for-agent` with rework notes (reject). A missing or unmappable Evidence block is grounds to reject. `done` is the per-issue signoff; final feature-level signoff happens at Archive. The maintainer may invoke the `review-issue` agent beforehand — decision-neutral, console-only, surfaces bug-hunt / intent-check / Evidence-check findings without touching state. Its output is an input to the maintainer's verify decision; `/triage` itself does not call it.

**7. Archive** — `/triage`
The feature-level final human gate. Reads the feature dir; collects every `[ ]` row from each `done` issue's latest Implementation comment that hasn't already been walked in a Verification comment, walks them with the maintainer, posts a per-issue Verification comment recording the verdicts, then moves `.features/<feature>/` to `.features/.archived/<feature>/`. Failed walks move the offending issue back to `ready-for-agent` with rework notes and abort archive. Triggered when every issue is terminal (`done`/`wontfix`) and the maintainer says "archive `<feature>`". The maintainer may invoke the `review-feature` agent before the move — two passes (primary + independent challenger via subagent), decision-neutral, scans the full feature diff for bugs and intent drift. Its output is an input to the maintainer's archive/merge decision; `/triage` itself does not call it.

### Reads and writes

| Stage     | Command            | Reads                                                     | Writes                                                                                              |
| --------- | ------------------ | --------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Grill     | `/grill-with-docs` | `GLOSSARY.md`, `docs/adr/`                                | `GLOSSARY.md` updates; new ADR (when warranted)                                                     |
| PRD       | `/to-prd`          | grilling output, `GLOSSARY.md`, `docs/adr/`               | `.features/<feature>/PRD.md`                                                                         |
| Slice     | `/to-issues`       | PRD, `GLOSSARY.md`, `docs/adr/`                           | `.features/<feature>/issues/NN-*.md` (state `needs-triage`)                                          |
| Triage    | `/triage`          | issue, `GLOSSARY.md`, `docs/adr/`, `.out-of-scope/`       | state / category / type; outcome comment; agent brief on `ready-for-*`; `.out-of-scope/` entry on `wontfix` of an enhancement |
| Implement | `/implement`       | issue, `GLOSSARY.md`, `docs/adr/`                         | code, tests; new ADR (if surfaced); state `in-review`; summary comment with Evidence block          |
| Verify    | `/triage`          | shipped work + summary's Evidence block                   | Verification comment with walked-row verdicts; state `done` or `ready-for-agent` (with rework notes) |
| Archive   | `/triage`          | feature dir + each `done` issue's Evidence block          | per-issue Verification comments for unwalked rows; move `.features/<feature>/` → `.features/.archived/<feature>/` |

## Issue state machine

```
needs-triage ──┬──► ready-for-agent ──► in-review ──► done
               │                              │
               │                              └──► ready-for-agent (rework)
               ├──► ready-for-human ──► in-review ──► done
               ├──► needs-info ──► returns to needs-triage when answered
               └──► wontfix (terminal)
```

Terminal: `done`, `wontfix`. Anything else is in flight. Any state can be set directly via `/triage <#> <state>` (Quick state override).

Type (`AFK` / `HITL`) is orthogonal to state. `HITL + ready-for-agent` is normal — the agent runs the work but gates with the maintainer at decision points named in the brief.

## AFK runner

Automation that drains a feature's `ready-for-agent + AFK` queue while you're away. Built on top of the pipeline — same issues, same state machine — but without the maintainer's keystroke as the bottleneck. Triggered manually: from any local state, run `framework/runner/run-the-queue.sh`. The runner stops when the queue empties or on Ctrl-C.

Each iteration picks the next eligible issue — skipping any with a runner-private abort flag at `.runner-state/aborted/<feature>/<NN>` — and spawns two sandboxed `claude` dispatches in sequence. The first runs `/implement` to ship the work to `in-review`. The second — the **review-and-gate** dispatch — runs an independent `review-issue` pass on the just-shipped commits and either auto-accepts to `done` (clean verdict) or appends the findings as a comment (≥1 Critical finding). HITL issues are not the runner's mandate: they fail the eligibility gate (loop mode skips them; single-dispatch refuses with exit 2) and stay on the maintainer's plate. The runner itself never writes to the tracker — every state change happens inside a dispatched `claude` session.

A `/implement` bail (logical failure: the dispatch posted an explanation and flipped status to `needs-info`) is binding-agnostic: under local-markdown the bail comment and status flip land as a `tracker:` commit in the runner-checkout; under GitHub Issues they land as API calls with no resulting commit. Either way, the runner-checkout's HEAD delta (present or absent) determines whether propagation runs — the propagation gate is the commit delta, not the classifier verdict. The abort flag (`.runner-state/aborted/<feature>/<NN>`) is a runner-internal file, independent of the binding and of whether any commit was produced; it operates the same in both worlds.

When a dispatch fails and leaves an issue stuck (eligible status unchanged, or gate failed), the runner writes an abort flag to prevent re-dispatch across runs. The maintainer `rm`s the flag to re-include the issue after diagnosing and fixing the root cause. See [`runner/README.md`](runner/README.md) for the `ls` / `cat` / `rm` recipe.

### Moving parts

| Piece                                      | Role                                                                                        |
| ------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `framework/runner/run-the-queue.sh`          | Orchestrator. Pre-flight invariants, dispatch loop, outcome classification, host propagation. |
| `$HOST_REPO/runner/Dockerfile`               | Sandbox image — JDK + Maven + git + the `claude` CLI. Non-root user, workdir `/repo`. Entrypoint inlined. |
| `framework/runner/setup-network.sh`          | Custom Docker bridge with RFC1918-deny outbound. Public internet stays open.                 |
| `$HOST_REPO/docs/formann/issue-tracker/tracker-snapshot` | Binding-supplied JSON interface, reached via the role surface. Drives eligibility selection and outcome classification. |
| `framework/runner/review-and-gate.md`        | Prompt for the post-implement gate dispatch — runs `review-issue`, classifies, commits.      |
| `.runner-state/checkout/`                  | Separate git clone; the sandbox mounts this, never the host repo.                            |
| `.runner-state/runs/<ts>/`                 | Per-run logs, per-issue exit codes, end-of-run `SUMMARY.md`.                                 |

### Process flow

```
loop iteration ─► tracker-snapshot ─► first eligible ref
                                          │
                                          ▼
                              implement /implement <ref>  (sandbox container)
                                          │
                                          ▼
                              tracker-snapshot ─► classify ─► fast-forward host
                                          │
                                          ▼
                              review-and-gate <ref>  (sandbox container)
                                          │
                                          ▼
                              tracker-snapshot ─► classify ─► fast-forward host
                                          │
                                          ▼
                              outcome: done | blocked | gate-failed | in-review | FAIL
```

Both dispatches run in fresh sandbox containers with bypass permissions; the trust boundary is the Docker isolation, not per-tool allowlists. Successful work fast-forwards onto the host's branch immediately. The runner never pushes to a remote — the maintainer keeps full control over what reaches GitHub.

See [`afk-runner.md`](afk-runner.md) for the architecture, binding contract, outcome classifiers, and pre-flight invariants. Operator-facing reference (sandbox primitives, OAuth setup, smoke test) lives at [`runner/README.md`](runner/README.md).

## Design principles

**Implementation lives in bindings.** Binding docs (`docs/formann/issue-tracker/BINDING.md`, `docs/formann/inbox.md`) are where the system meets a concrete implementation. They define where things live, how references resolve, and what implementation-specific actions like "set up a feature workspace" or "promote an inbox entry" mean mechanically. Each binding covers one lifecycle role: feature work in flight (PRDs + issues + workspace), pre-lifecycle capture (inbox), etc.

**Core and optional bindings.** Some bindings are core — every project has them (the issue tracker, domain). Others are optional add-ons a project adopts when it wants the capability (inbox today; potentially more later). The core pipeline runs without the optional bindings.

**Skills speak abstractly.** The producer and consumer skills (`/to-prd`, `/to-issues`, `/triage`, `/implement`) describe what they do in implementation-agnostic terms — "publish the PRD", "create an issue", "set up the feature workspace". The agent connects those abstract instructions to concrete actions via the relevant binding.

**Swap by replacing the binding.** Migrating one role's implementation (e.g., from local-markdown to GitHub Issues) means rewriting that binding. Skills, agent briefs, and the AFK runner don't change. The pipeline and state machine don't change. Only the binding rewires.

**Convention before mechanism.** Where possible, conventions (feature branches named with the feature slug; PRDs are synthesis of grilling, not reviewed; state `done` is the per-issue signoff; Archive is the feature-final maintainer signoff) encode the model. Mechanism follows.

## Document map

- **`framework/lifecycle.md`** — this doc. Human-readable description of how the system fits together: pipeline, state machine, design principles.
- **`framework/afk-runner.md`** — architecture and process flow of the AFK runner. Companion to `runner/README.md` (which is the operator-facing reference).
- **`framework/afk-runner-flow.md`** — flowchart-style diagram of `run-the-queue.sh`: inputs, process steps, decision points, outputs.
- **`docs/formann/issue-tracker/BINDING.md`** — issue-tracker binding (core). Implementation-specific facts for PRDs, issues, and the feature workspace.
- **`docs/formann/inbox.md`** — inbox binding (optional). Implementation-specific facts for pre-lifecycle capture.
- **`docs/formann/triage-states.md`** — triage state vocabulary glossary.
- **`docs/formann/domain.md`** — domain documentation conventions (`GLOSSARY.md`, `docs/adr/`).
- **`framework/skills/`** — operational instructions for agents:
  - `to-prd/SKILL.md` — produce a PRD from grilling.
  - `to-issues/SKILL.md` — slice a PRD or parent issue into vertical-slice issues.
  - `triage/SKILL.md` — move issues through the state machine.
  - `triage/AGENT-BRIEF.md` — how to write the agent brief comment posted on `ready-for-*`.
  - `triage/OUT-OF-SCOPE.md` — how the `.out-of-scope/` knowledge base works.
  - `implement/SKILL.md` — implement a single issue end-to-end.
- **`framework/agents/`** — review aids (decision-neutral, console-only — never mutate state):
  - `review-issue.md` — single-issue review supporting verify. Single-pass; invoke inline as a subagent (e.g. `@"review-issue (agent)"`).
  - `review-feature.md` — two-pass whole-feature review supporting archive/merge. Spawns a challenger via the `Agent` tool, which only works from a top-level session, so launch it as its own Claude Code session (e.g. `claude --agent review-feature`).
- **`CLAUDE.md`** — agent entry point. Signposts the operational docs (`issue-tracker.md`, `triage-labels.md`, `domain.md`); does not link to this doc, which is intentionally meta and not loaded on every agent session.
