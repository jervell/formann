# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Sandbox container image bundles `gh` and `bats`, so agents can drive the GitHub issues binding and run framework test suites without installing them first.

### Changed
- Runner renders dispatch durations as `Xs` / `Xm Ys` / `Xh Ym` across the mid-run progress line, the terminal stop table, and SUMMARY.md. On-disk records still use integer seconds.
- Runner applies the consumer's `install.sh` exactly once per `run-the-queue.sh` invocation instead of refreshing it on every dispatch iteration.
- Runner pins the sandbox git commit identity to `Claude <claude@anthropic.com>` so agent commits land with a deterministic author regardless of host git config. Override with `RUNNER_GIT_USER_NAME` / `RUNNER_GIT_USER_EMAIL`.

### Fixed
- Runner captures core-dump files left in untracked subdirectories of the runner-checkout (previously only root-level cores).
- Runner recovers from a dirty runner-checkout working tree before syncing the branch, instead of refusing the checkout. The leaked changes are logged to stderr before being scrubbed.

## [0.1.0] - 2026-05-20

### Added
- Initial release. Methodology and tooling for running autonomous coding agents against tracked issues.
- Issue lifecycle as Claude Code skills: `/triage` for grooming, `/implement` for delivery.
- AFK runner that drains a feature's queue in sandboxed containers, so work continues while you're away from keyboard.
- Pluggable issue tracker via bindings; ships with `github-issues` and `local-markdown`.
- Symlink-based consumer adoption — a project adopts Formann by linking framework content through a single `.formann` indirection.
- Optional inbox for pre-lifecycle capture of deferred thoughts.
