# Installer: per-binding bootstrap hooks

The installer wires symlinks based on the binding choice and does no further setup. Every binding prerequisite gets discovered at runtime as an abort flag the user has to `rm` by hand. Move that to install time.

## Drivers (all hit on 2026-05-18, fresh github-issues cutover)

1. **Repo-side: github-issues label namespace.** The binding ships `bootstrap-labels` for the static `formann:*` namespace; the installer doesn't invoke it. First tracker op that needs a missing label fails.
2. **Host-side: GH token Keychain entry.** The binding's `sandbox-env` reads `formann-gh-token` from macOS Keychain. Installer doesn't prompt, doesn't check. First dispatch aborts with the hint on stderr; user runs `security add-generic-password -s formann-gh-token -a github -w`, removes the flag, retries.
3. **Checkout-side: stale binding wiring after a cutover (dogfood-only).** `docs/formann/issue-tracker` on the host is a gitignored symlink — but only when the installer detects self-install. For real consumers the symlink is committed and git handles propagation to the runner-checkout; nothing to fix. For dogfood, the symlink never enters git, so after a cutover (e.g. local-markdown → github-issues) the runner-checkout is stale and `/implement` falls back to local-markdown layout, can't find the issue, exits 0; the runner classifies snapshot-unchanged as `FAIL`.

## Proposed shape

**One general mechanism (covers drivers 1 & 2):** each binding optionally ships `framework/bindings/<role>/<impl>/setup` next to `sandbox-env`. The installer calls it after `prompt_role_bindings` resolves the impl, if executable. Local-markdown ships nothing → installer no-ops. **Must be idempotent** — the installer is dogfooded as self-install and re-run liberally. For github-issues, `setup` would `gh label list` and create any missing `formann:*` labels via the existing `bootstrap-labels` logic; check Keychain via `security find-generic-password -s formann-gh-token -a github` and prompt to populate via `security add-generic-password ... -w` if missing.

**One small runner self-heal (covers driver 3):** on runner startup, if the host's `docs/formann/issue-tracker` symlink target differs from the checkout's (or doesn't exist in the checkout), re-run the installer's symlink logic against `.runner-state/checkout/`. Self-heals after any binding cutover; no manual step. Doesn't fire for real consumers because their symlink is committed and `git fetch` already propagated it.

## Pointers

- Failing runs that motivated this: `.runner-state/runs/20260518-140141/` (Keychain miss), `.runner-state/runs/20260518-141651/` (stale binding wiring; agent's message in `runner-500-handling/6.log`).
- Installer's binding-choice plumbing: `installer/install.sh:56–106` (`prompt_role_bindings`).
- github-issues binding scripts: `framework/bindings/issue-tracker/github-issues/{sandbox-env,bootstrap-labels,BINDING.md}`.