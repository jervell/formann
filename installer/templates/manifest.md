# Post-implement steps manifest.
# Each non-blank, non-comment line is a prompt path relative to the prompt roots.
# Resolution searches the consumer root (runner/) first, then the framework root
# (.formann/runner/steps/); the first match wins. Consumer files shadow framework
# prompts of the same relative path.
#
# The step label shown in output is the filename without its .md extension.
# Subfolders are supported (e.g. custom/my-review.md). Paths with .. or a
# leading / are rejected at pre-flight.
#
# The seeded default runs the fused review-and-gate prompt — the same
# behaviour as before this manifest existed. Edit to customise the phase
# or empty this file for implement-only (no automated post-implement step).
#
# To fix obvious bugs automatically before the gate, add the find-and-fix
# building block ahead of review-and-gate (uncomment the line below). It runs
# /code-review --fix over the issue's change-set, commits the fixes, and notes
# what it did, leaving the gate to decide whether the work earns `done`.
# find-and-fix.md
review-and-gate.md
