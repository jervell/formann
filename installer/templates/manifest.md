# Post-implement steps manifest.
# Each non-blank, non-comment line has the form:
#   <label> → <namespace>:<name>
# where → is the Unicode right arrow (U+2192).
#
# framework: prompts are shipped by Formann (framework/runner/).
# consumer:  prompts live in runner/ alongside this file.
#
# The seeded default runs the fused review-and-gate prompt — the same
# behaviour as before this manifest existed. Edit to customise the phase
# or empty this file for implement-only (no automated post-implement step).
review → framework:review-and-gate.md
