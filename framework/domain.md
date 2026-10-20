# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root
- **`docs/adr/`** — read ADRs that touch the area you're about to work in
- **The module map of the area** — the `README.md` beside the code you're about to work in (see [Module maps](#module-maps))

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The producer skills create them lazily: `/grill-with-docs` when terms or decisions actually get resolved, `/implement` when a module lands in an area without a map.

The repo keeps a single `GLOSSARY.md` at the root, ADRs under `docs/adr/`, and module maps beside the code they describe.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/grill-with-docs`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_

## Module maps

A module map is the one-page structural description of an area of the code: which modules the area is made of, what each is responsible for, how they interact on the main path, and which structural claims hold between them. It is the `README.md` in the area's root directory — a package, a directory, a crate, whatever the language's unit is — so a reader opening the code finds it, and a map that lies goes stale visibly rather than silently.

The glossary says what a word means; an ADR says why a decision was made; a module map says what is there and how it fits. All three describe the code as it is, never its history.

### Contents

- **Modules** — one entry per module: its name, its responsibility in one or two sentences, and the class, type, or function names a reader looks for. Code names belong here (unlike in a PRD or an agent brief) because the map sits next to the code and changes with it.
- **Primary flow** — the main path through the area as a short numbered sequence or a diagram: who calls whom, in what order, carrying what.
- **Structural claims** — the invariants that hold between modules ("pure: no I/O", "the only writer of X", "never depends on Y"), each with the check that holds it (an architecture test, a lint rule, a script) or `unchecked` when none exists. A claim without a check is a claim the next change can break without noticing; `unchecked` makes that visible.

Leave out line numbers, paths outside the area, and anything a reader gets from the code itself at a glance.

### Who writes it

- `/to-prd` designs a feature's modules — the module table and primary flow the maintainer approves before the PRD is written. That design is the map's source.
- `/implement` lands the design: a slice that adds or changes a module creates or updates the map of that area in the same change, and turns each structural claim it realises into a check.
- `review-issue` and `review-feature` flag a map that no longer describes the code.

Don't create a map for an area you aren't changing.
