# Formann

![Hero](./docs/images/hero.png)

Methodology and tooling for running autonomous coding agents on tracked issues — keeps work moving while you're away from keyboard.

> **Status:** early extraction from a host project; expect churn. See [`CHANGELOG.md`](./CHANGELOG.md).

## What is Formann?

Formann is a set of Claude Code skills (with supporting review agents) that run an issue-driven workflow against your project's tracker — from grilling a fuzzy idea through PRD, issue slicing, triage, and implementation. `/triage` and `/implement` are the automation core: triage moves issues through the state machine, implement takes a single issue end-to-end.

An optional **AFK runner** drains a feature's queue in sandboxed Docker containers, so work continues while you're away from keyboard.

The issue tracker is an abstract role. A **binding** plugs in the concrete tracker; Formann ships with `github-issues` and `local-markdown`.

A consumer adopts Formann by symlinking framework content (skills, agents, lifecycle docs) through a single `.formann` indirection — upgrading is then a `git pull` of this repo. See [ADR-0001](./docs/adr/0001-symlink-based-consumption.md) for why.

Formann runs locally on the developer's machine — no hosted service, no central server. The Dockerfile, bindings, skills, and agents are all editable files in your own project after install; adapt them freely.

## Using Formann (consumer)

Setup mechanics — running the installer, picking bindings, what gets symlinked where — live in [`installer/README.md`](./installer/README.md). Start there.

## Developing Formann (contributor)

Clone this repo and dogfood the installer against the checkout:

```sh
git clone <this-repo> formann
cd formann
./installer/install.sh .
```

The installer detects self-install and gitignores its products, so contributor artifacts don't pollute `main`.

## Dependencies

Consumer:
- `bash` 3.2+ (the macOS default works), `git`.
- Docker — only if you use the AFK runner.

Contributor: everything above plus [`bats`](https://bats-core.readthedocs.io/) 1.x (tested with 1.13) for the installer test suite at `installer/tests/install.bats`.

The runner Dockerfile template (`installer/templates/Dockerfile`) bakes in JDK 25, Maven, Node 20, and the Claude CLI. A consumer edits `runner/Dockerfile` to swap toolchains; your project's own build toolchain is your concern, not Formann's.

## Docs

[`GLOSSARY.md`](./GLOSSARY.md) · [`docs/adr/`](./docs/adr/) · [`docs/formann/`](./docs/formann/) (methodology) · [`framework/bindings/`](./framework/bindings/) · [`CHANGELOG.md`](./CHANGELOG.md) · [`RELEASING.md`](./RELEASING.md)

## License

MIT. See [`LICENSE`](./LICENSE).