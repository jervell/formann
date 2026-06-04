# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-06-04

### Added
- Installer runs each binding's optional install-time setup hook after binding selection. For the `github-issues` binding, the hook seeds the `formann:*` label namespace and prompts for the GH-token macOS Keychain entry when missing. Local-markdown ships no hook; that path is unchanged.
- `build-image.sh --fresh` rebuilds the runner image with every bundled tool — including the Claude CLI — re-resolved to its current published version, instead of reusing the versions baked into the cached image.
- `/improve-codebase-architecture` skill — finds deepening opportunities (shallow modules, leaky seams, hard-to-test interfaces) using the project's `GLOSSARY.md` and `docs/adr/`, then grills a chosen candidate toward a deeper, more testable module. Consumer-side engineering skill alongside `/grill-with-docs`.
- Customizable post-implement phase — the AFK runner's behaviour after `/implement` is now a Consumer-owned ordered list of steps in `runner/manifest.md`, composed from framework-supplied building blocks and/or your own prompts. The installer seeds a default that reproduces the prior review-and-gate behaviour; **existing consumers must re-run `installer/install.sh` once after upgrading**, or the runner refuses to start.

### Changed
- Installer prompts default to the consumer's current binding on re-install; press Enter to keep it.
- Installer suppresses the CLAUDE.md snippet banner when the consumer's root `CLAUDE.md` already contains the snippet verbatim; emits one stderr confirmation line instead.

### Fixed
- **`/implement` no longer marks an operator-attended acceptance criterion as verified** — a criterion whose check can't run in the dispatch environment (Docker-in-Docker, a credential, a manual or operator-attended step), or whose test was skipped, is now classified `[human]` and left for the maintainer instead of ticked off as done.
- **AFK runner dispatches under the github-issues binding no longer run without GitHub auth** — the binding's `GH_TOKEN`/`GH_REPO` env failed to reach the sandbox container, so every dispatch ran but aborted with `gh` unauthenticated.
- **`/triage` no longer fails on sub-issues under the github-issues binding** — Previously refused with a missing-slug error before transitioning to `ready-for-agent`.

## [0.2.0] - 2026-05-27

### Added
- The issue-tracker contract is codified in `framework/bindings/issue-tracker/CONTRACT.md`. Both `github-issues` and `local-markdown` bindings realize the same canonical 13-verb set.
- AFK runner sweeps stale parking refs and their runner-checkout source branches on startup. Both sides are only removed when git proves their tips are reachable from another host ref, so no committed work can be lost.
- `/gist` skill — produce a short plain-English summary of whatever you point it at: the previous response, the conversation, an artifact, or each item in a list. Consumer-side utility skill alongside `/handoff`.
- Sandbox container image bundles `gh` and `bats`, so agents can drive the GitHub issues binding and run framework test suites without installing them first.
- Standalone issues — a Formann feature can be a single slug-named issue with no PRD. Create one conversationally ("create a standalone for slug X about Y"), add follow-ups the same way ("add a follow-up under slug X about ..."), or open an issue in the GitHub web UI with `formann:status:needs-triage` — `/triage` assigns the slug and the rest at the `ready-for-agent` transition.
- AFK runner lazily creates `refs/heads/<slug>` from the host's default branch on first dispatch when the host has no branch for the slug, instead of skipping with `branch-missing`. `/to-prd` still creates branches eagerly for PRD-led features.

### Changed
- Runner renders dispatch durations as `Xs` / `Xm Ys` / `Xh Ym` across the mid-run progress line, the terminal stop table, and SUMMARY.md. On-disk records still use integer seconds.
- Runner reads the consumer's `docs/formann/` view live from the host instead of re-running the installer on every pass to populate it. Fixes a preflight crash on consumers without an `installer/` directory and a drain-mode bug where the runner fell back to the wrong binding between iterations.
- Runner pins the sandbox git commit identity to `Claude <claude@anthropic.com>` so agent commits land with a deterministic author regardless of host git config. Override with `RUNNER_GIT_USER_NAME` / `RUNNER_GIT_USER_EMAIL`.
- `Feature` broadened to any slug-named work unit — PRD-bearing and standalone (PRD-less) features are both first-class.
- `/triage` prompts for a slug and applies `formann:feature` (github-issues binding) before transitioning an issue to `ready-for-agent` or `ready-for-human`, so issues opened in the GitHub web UI become runner-ready.
- The github-issues binding stores blocker relationships as GitHub's native issue dependencies. Blockers now appear in GitHub's sidebar instead of in a `## Blocked by` body section; local-markdown is unaffected.

### Fixed
- AFK runner can invoke `gh` against the host's GitHub repo from inside the sandbox under the github-issues binding. Previously `gh` failed with "remote points to a local path" because the runner-checkout's `origin` was a local mirror.
- AFK runner no longer marks a clean review as `gate-failed` under the github-issues binding. The binding closes the just-reviewed issue on a clean verdict, dropping it from the post-gate snapshot; the classifier now treats that absence as the binding-native `done` signal.
- AFK runner no longer silently loses agent commits when a dispatch ends in a mid-dispatch snapshot failure or a gate-failed / review-aborted verdict — the commit is parked to the host parking ref before the runner bails out, and a lazy-init guard refuses to overwrite a runner-checkout branch with unpublished commits if propagation is ever bypassed.
- Runner captures core-dump files left in untracked subdirectories of the runner-checkout (previously only root-level cores).
- Runner recovers from a dirty runner-checkout working tree before syncing the branch, instead of refusing the checkout. The leaked changes are logged to stderr before being scrubbed.
- AFK runner no longer aborts with a spurious "slug collision" error on the github-issues binding when two or more Formann features are open concurrently.
- AFK runner no longer silently skips every dispatch after a parking-ref sweep leaves the runner-checkout in an unborn-HEAD state — the checkout self-heals before sync.

## [0.1.0] - 2026-05-20

### Added
- Initial release. Methodology and tooling for running autonomous coding agents against tracked issues.
- Issue lifecycle as Claude Code skills: `/triage` for grooming, `/implement` for delivery.
- AFK runner that drains a feature's queue in sandboxed containers, so work continues while you're away from keyboard.
- Pluggable issue tracker via bindings; ships with `github-issues` and `local-markdown`.
- Symlink-based consumer adoption — a project adopts Formann by linking framework content through a single `.formann` indirection.
- Optional inbox for pre-lifecycle capture of deferred thoughts.
