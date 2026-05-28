# Vendored bats helpers

These are plain copies (not git submodules) of the upstream bats helpers, so the
test suite is self-contained — `bats installer/tests/` works on a fresh
checkout without any extra git or npm steps.

## bats-support

- Repo: https://github.com/bats-core/bats-support
- Commit: `0954abb9925cad550424cebca2b99255d4eabe96`
- License: MIT (`bats-support/LICENSE`)

## bats-assert

- Repo: https://github.com/bats-core/bats-assert
- Commit: `697471b7a89d3ab38571f38c6c7c4b460d1f5e35`
- License: MIT (`bats-assert/LICENSE`)

## Updating

To refresh either helper:

1. `git clone --depth 1 <repo>` into a scratch directory.
2. Copy `LICENSE`, `README.md`, `load.bash`, and `src/` over the existing copy.
3. Update the commit SHA above.
