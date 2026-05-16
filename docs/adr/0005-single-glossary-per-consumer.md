# Single GLOSSARY.md per consumer; no multi-context shape

`CONTEXT.md` at the Formann repo root is renamed `GLOSSARY.md`, and the inner `## Language` section heading is renamed `## Terms`. `GLOSSARY.md` is now the canonical artifact name for consumer vocabulary files. Simultaneously, the "multi-context" layout (multiple vocabulary files, one per bounded context) is retired before it ships: consumers with multiple subdomains group terms under H3 headings within the single `GLOSSARY.md`, keeping one file at the consumer root.

## Considered options

- **Keep `CONTEXT.md` as the filename.** Rejected: "context" is overloaded — it collides with DDD's "bounded context" and with LLM tooling that uses "context" to mean prompt context. `GLOSSARY.md` is unambiguous and matches the common mental model for a project vocabulary file.
- **Keep multi-context as a supported layout** (one vocabulary file per bounded context subdirectory). Rejected: no consumer has shipped multiple files yet, and a single-file layout with H3 groupings for subdomains is simpler and sufficient. Retiring the shape before anyone adopts it eliminates a divergence risk without migration cost.

## Consequences

- The canonical vocabulary artifact is `GLOSSARY.md` at the consumer root. All Formann documentation, framework skills, and installer scaffolding use that name going forward.
- `context`, `CONTEXT.md`, `context map`, and `ubiquitous language doc` are documented as aliases to avoid; the in-file `Glossary` term entry redirects contributors landing on any of those legacy names.
- Consumers with multiple subdomains are guided to group terms under H3 headings within the single `GLOSSARY.md` — no separate files.
- References to `CONTEXT.md` in existing framework files, skills, and documentation are swept in issue 03.
