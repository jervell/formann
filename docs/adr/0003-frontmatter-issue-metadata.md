# YAML frontmatter for issue metadata

Issue metadata (`status`, `category`, `type`) lives in YAML frontmatter at the top of each issue file, parsed by a hand-rolled flat-string-scalars parser in `framework/tracker/serve.py`. The format aligns with the convention every markdown ecosystem already understands; the parser stays minimal because the schema is intentionally narrow.

## Considered options

- **Bespoke `Key: value` block before the first `##`** (the original format). Rejected: nonstandard, required readers to consult `docs/formann/issue-tracker/BINDING.md` to know what they were looking at, and put `# Title` *above* the metadata in an order no markdown tool expects.
- **PyYAML.** Rejected for now: pulls in a real dependency, and would silently accept structures (lists, nested maps, dates) that the schema doesn't support — making future schema drift invisible. The hand-rolled parser fails loudly on anything beyond flat string scalars, which is the correct default for the current schema.
- **Schema expansion alongside the format change** (adding `created`, `assignee`, `labels`, etc.). Rejected: YAGNI. The three existing fields earned their place by use; speculative fields haven't. Add them one at a time when an actual need surfaces.
- **Grace period supporting both formats.** Rejected: ~13 issue files, single-developer repo, no in-flight external consumers. Flag-day migration is the cheaper choice.

## Consequences

- The hand-rolled parser must be replaced when the schema first needs a non-string-scalar field (lists, dates, booleans). At that point, swap to PyYAML.
- Field values that happen to overlap YAML 1.1 reserved words (`yes`, `no`, `on`, `off`, unquoted dates) are not currently a risk — all current values are hyphen-bearing identifiers or uppercase acronyms — but new fields must quote anything that could be coerced.
- Parsing is lenient on semantics (missing fields, unknown keys are silently ignored — triage writes fields incrementally) but strict on syntax (malformed frontmatter blocks fail loudly).
