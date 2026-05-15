# Symlink-based framework consumption with `.formann` indirection

Consumers adopt Formann by symlinking into a local Formann checkout, not by copying, vendoring, or packaging. A gitignored `.formann` symlink at the consumer's root points at the Formann checkout's `framework/` directory; every committed symlink in the consumer resolves through `.formann` (e.g., `.claude/skills/triage -> ../../.formann/skills/triage`). Pointing `.formann` at `framework/` rather than the Formann repo root keeps Formann's own consumer setup (`.claude/`, `.git/`, `installer/`, top-level `docs/`) outside the consumer's view — `.formann/` exposes only the framework surface. This keeps the consumer's committed symlink graph stable across machines while letting each developer or CI place Formann wherever it lands.

## Considered options

- **Git submodule.** Rejected: adds real friction (`git submodule update --init` on every clone), and files live at `vendor/formann/...` instead of where the consumer's tools expect them (`.claude/skills/...`, `docs/formann/...`). The versioning benefit doesn't outweigh the UX cost for a solo-/close-team scope.
- **Copy/sync** (installer copies Formann content into the consumer). Rejected: loses single-source-of-truth — every framework update requires re-running the installer per consumer, and drift becomes a real bug class.
- **Package distribution** (npm/pip/maven). Rejected: Formann ships prose + shell + skill definitions, not code-shaped artifacts. Package machinery is overkill and forces a publish step Formann doesn't otherwise need.
- **Relative-path symlinks with sibling-clone convention** (`../formann/...` committed directly). Rejected: rigid — breaks if any consumer clones Formann at a non-sibling path. The `.formann` indirection costs one extra hop and buys per-machine flexibility.

## Consequences

- Consumers must run Formann's installer on first setup (and after Formann moves locally) to create `.formann`. CI must recreate it on every fresh checkout — a one-line step, but it must exist.
- The `.formann` indirection adds one symlink hop, but preserves the existing intra-repo precedent (`.claude/skills/triage -> ../../.agents/skills/triage` in iot today is the same shape, intra-repo).
- Framework updates propagate to consumers on `git pull` inside the Formann checkout — no per-consumer action. This is both a feature (always current) and a hazard (breaking changes propagate instantly). Version pinning can be added later when warranted; YAGNI for v0.
- The consumer's committed `.gitignore` must include `/.formann` so the per-machine symlink doesn't drift into git.
