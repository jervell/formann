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
