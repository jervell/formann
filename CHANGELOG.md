# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-20

### Added
- Initial release. Methodology and tooling for running autonomous coding agents against tracked issues.
- Issue lifecycle as Claude Code skills: `/triage` for grooming, `/implement` for delivery.
- AFK runner that drains a feature's queue in sandboxed containers, so work continues while you're away from keyboard.
- Pluggable issue tracker via bindings; ships with `github-issues` and `local-markdown`.
- Symlink-based consumer adoption — a project adopts Formann by linking framework content through a single `.formann` indirection.
- Optional inbox for pre-lifecycle capture of deferred thoughts.
