# Formann

![Hero](./docs/images/hero.png)

Methodology and tooling for running autonomous coding agents on tracked issues — keeps work moving while you're away from keyboard.

## What is Formann?

Formann is a framework for running `/triage` and `/implement` as Claude Code skills against a markdown-backed issue tracker, with an optional AFK runner that drains a feature's queue in sandboxed containers while you're away from keyboard. A consumer repo adopts Formann by symlinking framework content (skills, agents, lifecycle docs) through a single `.formann` indirection — see [`CONTEXT.md`](./CONTEXT.md) for the vocabulary and [`docs/adr/`](./docs/adr/) for the architectural decisions that shape it. Early extraction from a host project; expect churn.

## Using Formann (consumer)

If your project wants to adopt Formann, the setup mechanics — running the installer, picking bindings, what gets symlinked where — live in [`installer/README.md`](./installer/README.md). Start there.

## Developing Formann (contributor)

To work on Formann itself, clone this repo and dogfood the installer against the checkout:

```sh
git clone <this-repo> formann
cd formann
./installer/install.sh .
```

That self-install gives the checkout the same shape a consumer repo has:

- `.claude/skills/` and `.claude/agents/` resolve framework skills (`/triage`, `/implement`, …) and agents through `.formann`, so Claude Code discovers them like any consumer would.
- `runner/Dockerfile` is scaffolded from the template, so the AFK runner can drain Formann's own `ready-for-agent + AFK` queue from inside Formann.
- `.features/` holds the canonical issue tracker for ongoing Formann work — this PRD and its issues live there.

The installer detects self-install (consumer path resolves to the Formann path) and gitignores its products in a managed block, so the resulting symlinks and `runner/Dockerfile` don't pollute `main`. No extra flags or scripts — `./installer/install.sh .` does the right thing.

## Dependencies

Versions below are "what works today" — not minimum-version guarantees.

### To use Formann (consumer)

- `bash` 3.2+ (the version macOS ships with works).
- `git`.
- Docker — optional, only required for the AFK runner.

The runner Dockerfile template (`installer/templates/Dockerfile`) bakes in JDK 21, Maven, Node 20, and the Claude CLI. Those are container-side, not host-side; a consumer edits `runner/Dockerfile` to swap toolchains for their project.

Your project's own build toolchain (Maven, npm, etc.) is your concern, not Formann's.

### To develop Formann (contributor)

Everything above, plus:

- [`bats`](https://bats-core.readthedocs.io/) 1.x for the installer test suite at `installer/tests/install.bats`. (Tested with bats 1.13.)
