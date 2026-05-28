# Per-issue human verification gate

Formann does not block individual issue `done` transitions on human-eyes
verification of `[human]` acceptance criteria. Per-issue `done` is a per-issue
signoff (maintainer's keystroke in HITL, runner-gate's auto-flip in AFK); the
feature-level Archive ritual is the universal final human gate.

## Why this is out of scope

The Implement skill emits each acceptance criterion in the Evidence block with
a tick column: `[x]` for `verified`, `[ ]` for `[human]`. The `[ ]` rows are
visible at a glance inside the same enumeration that already lists every AC,
so there is no need for a parallel "Needs your eyes" subsection.

A per-issue blocking gate at `/triage` Verify (refusing to flip `done` while
any `[ ]` row is unwalked) was considered and rejected for two reasons:

1. **Breaks AFK chaining.** The runner picks the next eligible issue based on
   `Blocked by` references being in state `done`. If the runner-gate can't
   auto-`done` an issue with unwalked `[human]` rows, the entire downstream
   chain stalls until the maintainer walks the row — which defeats the
   runner's purpose.

2. **Two-tier signoff is cleaner.** `done` means "implementation accepted"
   (by the maintainer at HITL Verify, or by the runner-gate at AFK).
   Final feature-level signoff happens at Archive, which walks every
   unwalked `[human]` row across all issues before the dir moves. This keeps
   the runner useful while still ensuring nothing ships unwalked.

A parallel structural surface for `[human]` items ("Needs your eyes"
subsection separate from Evidence) was also considered and rejected: the
unified Evidence block with a tick column gives the same visibility without
duplication or divergence risk.

The `[human]` walk discipline lives in `/triage`'s Verify step (per-issue,
HITL path) and Archive ritual (feature-level, universal). Both post a
per-issue Verification comment recording each walked row's verdict.

## Prior requests

- `afk-runner/112` — "Surface and enforce [human] verification gates on in-review issues" (raised pre-extraction, archived there)
