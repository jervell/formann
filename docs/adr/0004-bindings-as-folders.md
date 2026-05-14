# Bindings are folders symlinked into the role surface

Bindings live at `framework/bindings/<role>/<impl>/` (e.g., `framework/bindings/issue-tracker/local-markdown/`). Each binding folder contains a fixed-name contract document `BINDING.md`, any bundled scripts the role calls (e.g., `tracker-snapshot`), and a human `README.md`. On installation, the consumer gets one folder-symlink per chosen binding: `<consumer>/docs/formann/<role> -> ../../.formann/framework/bindings/<role>/<chosen-impl>`. Skills read `docs/formann/<role>/BINDING.md`. The runner invokes bundled scripts via the role surface (`$HOST_REPO/docs/formann/<role>/<script>`) — no binding name appears in framework code. The binding choice is encoded by where the symlink points; there is no per-binding manifest.

## Considered options

- **Per-binding `manifest.yaml`** (the rejected alternative — was the original plan for the extraction). Each binding ships a machine-readable manifest declaring binding name, role, ships list (source → target per artifact), and prerequisites. Rejected: the convention design preserves binding-agnosticism by construction (no framework code knows which binding is in use), and the manifest's "discipline-from-day-one" framing turns out to be infrastructure for its own sake when there's one binding per role. Convention is the simpler contract. If a future binding genuinely needs declarative metadata (multi-role coverage, prerequisite checking), adding a `manifest.yaml` to existing folders is mechanical — no retroactive pain.
- **Copy binding contents into the consumer at install time** instead of symlinking. Rejected for the same reason ADR-0001 rejects the copy approach generally: every framework update would require re-running the installer per consumer.
- **Per-artifact symlinks chosen by manifest** ("docs go to `docs/formann/<role>/`, executables go to `bin/<role>/`"). Rejected: the "docs surface is docs-only" constraint that motivated the split is taste, not function. The runner doesn't care where it invokes a script from; having `tracker-snapshot` co-located with `BINDING.md` under the role surface is cleaner than two split install targets.

## Consequences

- The role surface (`docs/formann/`) holds a mix of per-role subdirectories (folder-symlinks to binding folders) and per-file framework-level role docs (`lifecycle.md`, `inbox.md`, `domain.md`, `triage-states.md`). This shape is binding-agnostic at the consumer side.
- Framework code (installer, skills, runner) is binding-agnostic by construction — none of it reaches into `framework/bindings/<role>/<impl>/` by name. The runner's `tracker-snapshot` invocation uses the role-surface path, not a binding-specific path.
- A binding that wants to declare prerequisites or metadata in the future drops a file into its folder by convention (e.g., `prerequisites.sh`). No schema, no parser, no manifest. New conventions are added when the need is real.
- `BINDING.md` is the fixed contract document name across all bindings of all roles. The role is encoded in the path, so the file name doesn't need to repeat it.
