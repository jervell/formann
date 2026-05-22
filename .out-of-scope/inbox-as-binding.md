# Inbox as a binding

The inbox is not a binding. It is a framework-level role doc, peer of `lifecycle.md`, `triage-states.md`, and `domain.md` — described in a single file at `framework/inbox.md`, with no per-implementation folder under `framework/bindings/`.

## Why this is out of scope

ADR-0004 classifies `inbox.md` as a framework-level role doc on the consumer's role surface (`docs/formann/`), alongside `lifecycle.md`, `domain.md`, and `triage-states.md`. A binding, by contrast, ships interchangeable implementations of a role behind a fixed `BINDING.md` contract.

The inbox has nothing to abstract:

1. **No interchangeability.** The capture surface is always a markdown file at the project root (`.inbox.md`, plus optional `.inbox/<slug>.md` body files). There is no plausible alternative implementation to swap in that would warrant a contract layer. Treating it as a binding would force a fixed-name `BINDING.md`, an empty verbs list, and an installer ship-list for an inert convention.

2. **No verbs.** Bindings exist because roles invoke verbs (publish issue, fetch tracker snapshot, set status, …) and need a binding-agnostic invocation path. The inbox has no callers in framework code — capture is the maintainer appending a bullet, promote routes out to other lifecycle entry points (`/grill-with-docs`, single-issue feature setup), and drop deletes a bullet. There is nothing for the framework to invoke against a contract.

3. **Convention is the entire spec.** The append/promote/drop mechanics fit on one screen in `framework/inbox.md`. Promoting it to a binding folder would replace a one-pager with two-or-more files (`BINDING.md`, `README.md`, possibly scripts) without adding a degree of freedom.

The `standalone-issues` branch brought `framework/lifecycle.md`, `framework/inbox.md`, and `GLOSSARY.md` in line with ADR-0004 — dropping the residual "the binding" / "Inbox: Local Markdown" framing that had survived the ADR.
