# Releasing Formann

Releases are git tags. The version "lives" in `git tag`; no version string lives in the source tree. `CHANGELOG.md` is the human-readable mirror.

## Between releases

Each behavioural change adds (or updates) an entry under `## [Unreleased]` in `CHANGELOG.md`. The `/commit` skill handles this; manual commits should follow the rules in `~/.claude/skills/commit/CHANGELOG.rules.md`.

## Cutting a release

```sh
bin/release.sh X.Y.Z              # plan, confirm, commit, tag, prompt to push
bin/release.sh X.Y.Z --dry-run    # show planned edits without writing
```

The script refuses unless:
- `X.Y.Z` is well-formed semver
- `vX.Y.Z` doesn't already exist
- HEAD is on `main`
- The working tree is clean
- Local `main` is at or ahead of `origin/main`
- `[Unreleased]` has content

It then:
1. Inserts `## [X.Y.Z] - <today>` under `[Unreleased]` in `CHANGELOG.md`, so the Unreleased content moves under the new heading. `[Unreleased]` is left empty for the next cycle.
2. Commits `release: vX.Y.Z`.
3. Creates annotated tag `vX.Y.Z` (`--cleanup=verbatim`, so Keep-a-Changelog subheadings like `### Added` aren't stripped) with the changelog content as the message body.
4. Prompts before atomically pushing `main` and the tag to `origin`.
5. After the push, if the `gh` CLI is available, creates a GitHub Release with the changelog content as the release notes. If `gh` isn't present (or the call fails), the script writes the notes to a temp file and prints the `gh release create … --notes-file …` command to run manually.

## Choosing the version

SemVer. While the major is `0`, breaking changes bump the **minor**; after `1.0.0`, breaking changes bump the **major**. "Breaking" means a consumer's existing wiring — `.formann` symlink target, binding contract, installer behaviour — stops working without action on their side.

The README's "expect churn" framing applies as long as the major is `0`. The first release is `v0.1.0`; there is no `v0.0.x` history to preserve.
