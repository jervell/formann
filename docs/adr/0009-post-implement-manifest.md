# Post-implement manifest: fixed invariant, composite walk model, per-Consumer granularity

After a successful `/implement` dispatch, the Runner previously ran one hardcoded fused review-and-gate step. The post-implement phase is now driven by a Consumer-owned manifest (`runner/manifest.md`) — an ordered list of prompt-path entries that the Runner walks sequentially, reacting to the tracker snapshot after each item. The manifest ships exactly like the Dockerfile: the installer copies a framework-provided default into the Consumer's tree once (no-clobber), and from then on there is a single Consumer-owned manifest that the Runner always reads at runtime. There is no separate framework-side default consulted at runtime and no merge.

## Fixed invariant

**Reaching `done` is the only thing that unblocks dependents, and reaching `done` is always a quality judgment.** This invariant is not configurable.

The rejected alternative is speculative downstream execution: allowing a dependent to start while its blocker is only `in-review`, then unwinding if the blocker is later rejected. This would decouple "judged good" from "unblocks downstream," which is the coupling the invariant exists to enforce. Speculative execution is rejected, not deferred.

Customization only changes *how hard the phase tries to earn `done`* — never whether the coupling between "judged good" and "unblocks downstream" holds. A Consumer who replaces the gate takes on the quality responsibility deliberately, just as they own their Dockerfile and their issue briefs.

## Composite ordered-list walk with snapshot-driven stop

The walk model is a plain ordered list; the Runner iterates items, dispatches each, propagates commits, snapshots the tracker, and decides:

- terminal status (`done`/`wontfix`) → stop, success
- `in-review` → continue to next item
- `ready-for-agent` (issue moved backwards) → terminate the whole run (runaway guard)
- Dispatch error or unexpected status → abort flag, record FAIL
- list exhausted with issue still at `in-review` → `left-for-human` (no abort flag)

An empty manifest means implement-only: no post-implement Dispatch runs, the issue stays at `in-review`, and the combined outcome is recorded as `left-for-human` — the same neutral signal as an exhausted non-empty walk. This does not weaken the invariant: dependent chains simply wait until a human promotes the issue to `done`.

The rejected alternative is a graph or conditional engine (branches, loops, typed step nodes). This is rejected because the ordered-list-with-snapshot-driven-stop handles all planned use cases — implement-only, review-only, default, and unrolled iterate — without the overhead of a step typology or conditional syntax. Loop sugar (a "repeat N times" construct) is deferred to a future slice; unrolled repetition is sufficient for now.

## Per-Consumer granularity (per-issue rejected)

The manifest is per-Consumer, not per-issue. Per-issue configuration would force the snapshot contract to carry Binding-specific per-issue config, coupling the Runner's own configuration to the tracker — a Binding-portability leak. Per-issue granularity is rejected on those grounds. Per-feature granularity is deferred (architecture left open by this decision); per-Consumer is sufficient for v1.

## Manifest shipping is an application of ADR-0002

The Consumer owns the manifest file for the same reason they own the Dockerfile (see ADR-0002): the post-implement steps express project-specific quality policy, just as the Dockerfile expresses the project-specific toolchain. The installer scaffolds an initial manifest exactly as it scaffolds the Dockerfile — copied once, never clobbered — and the Consumer edits it from there.

## Manifest format

Each non-blank, non-comment line is a path relative to a prompt root. Resolution searches the consumer root (`runner/`) first, then the framework root (`framework/runner/steps/`); the first match wins, so consumer files shadow framework prompts of the same relative path. The step label is the filename without its `.md` extension. Subfolders are supported; paths with `..` segments or a leading `/` are rejected at pre-flight. Repeated path entries are allowed (the unrolled iterate pattern).

The rejected alternative is the earlier `<label> → <namespace>:<name>` grammar (Unicode arrow separator, explicit `framework:` / `consumer:` namespace prefix, explicit label field). That format is rejected for this slice because it places unnecessary syntax burden on a file intended to be hand-edited: the Unicode arrow is not on any keyboard, the namespace prefix is redundant given consumer-first resolution, and the label almost always matches the filename anyway. Plain paths are the simplest thing that works.

## Consequences

- The `runner/` directory in the Consumer's repo is the fixed host-side consumer-prompt root. Consumer prompts placed here shadow framework prompts of the same relative path. This location is a convention, not a configurable path, and is captured in `RUNNER_CONSUMER_PROMPTS_DIR`.
- The framework's building-block step prompts (`review.md`, `gate.md`, `fix.md`, `review-and-gate.md`) live in `framework/runner/steps/`, the framework root the resolver is pointed at. This keeps the lookup isolated from unrelated framework files in `framework/runner/`.
- The default manifest contains one entry (`review-and-gate.md`) reproducing the original hardcoded gate stage; a Consumer who leaves it as installed gets exactly the prior behaviour.
- Implement-only (empty manifest) is a first-class configuration; its `left-for-human` outcome is indistinguishable from a non-empty walk that exhausted without reaching `done`. Both leave the issue at `in-review` for the maintainer with no abort flag.
- Pre-flight validates the manifest and resolves all references before any Dispatch runs, so configuration errors surface before cost is incurred.
