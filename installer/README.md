# Formann installer

Wires a consumer repo to this Formann checkout by creating the `.formann`
indirection symlink and the consumer-side managed symlinks.

## Running the installer

```sh
cd /path/to/formann
./installer/install.sh /path/to/consumer-repo
```

The installer:

1. Creates `.formann → <absolute-path-to-formann>` at the consumer root (gitignored).
2. Prompts per role for which binding to use (one prompt per `framework/bindings/<role>/`).
3. Creates `.claude/skills/<name>`, `.claude/agents/<name>.md`, `.claude/rules/<name>` symlinks.
4. Creates `docs/formann/<role>` folder-symlinks and per-file framework-doc symlinks.
5. Scaffolds `runner/Dockerfile` from `installer/templates/Dockerfile` (once; existing files are left alone).
6. Appends `/.formann` to `.gitignore` (idempotent).
7. Prints a CLAUDE.md snippet to stdout.

Re-running is safe: symlinks with correct targets are left alone; stale symlinks
(wrong target) are overwritten; real files and directories at managed paths are
never clobbered.

### Re-install prompt behavior

On re-install the installer detects the consumer's current binding for each
role from the existing `docs/formann/<role>` symlink and offers it as the
default:

```
Role 'issue-tracker' impls: [local-markdown github-issues]. Current: local-markdown. Pick one [Enter=keep]:
```

- **Press Enter** (or close stdin) to keep the current binding unchanged.
- **Type a different impl name** to switch to it.

If the current binding is stale (the impl was removed from the framework, the
symlink is dangling, or the target path has an unexpected shape), the installer
prints one diagnostic line to stderr naming the stale value and falls back to
the fresh prompt with no default:

```
install.sh: stale binding for 'issue-tracker': 'old-impl' no longer exists in framework
```

When `FORMANN_INSTALL_BINDING_<role>` is set and differs from the detected
current binding, the installer prints a switching notice to stderr and uses the
env-var value:

```
install.sh: switching 'issue-tracker' from local-markdown to github-issues
```

When the env-var matches the current binding, the installer stays silent.

## Non-interactive mode (for scripts and tests)

Set `FORMANN_INSTALL_BINDING_<role>` (dashes replaced by underscores) to bypass
the prompt for a role:

```sh
FORMANN_INSTALL_BINDING_issue_tracker=local-markdown ./installer/install.sh /path/to/consumer
```

The test suite uses this pattern combined with `FORMANN_PATH` (to point the
installer at a synthetic fixture rather than the live framework directory):

```sh
FORMANN_PATH=/tmp/formann-fixture \
FORMANN_INSTALL_BINDING_issue_tracker=local-markdown \
  installer/install.sh /tmp/synthetic-consumer
```

## Running the tests

```sh
# From the formann/ repo root:
bats installer/tests/install.bats
```

Tests spin up a synthetic consumer (`$BATS_TEST_TMPDIR/consumer/`) and a
controlled Formann fixture (`$BATS_TEST_TMPDIR/formann-fixture/`) for each test,
so they are fully isolated and produce no side effects on the working tree.
