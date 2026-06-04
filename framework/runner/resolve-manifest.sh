#!/usr/bin/env bash
# resolve-manifest.sh — pure manifest resolver for the AFK runner.
#
# Sourceable. The only exported function is `resolve_manifest`. No globals
# are modified; no I/O beyond the function's own stdin/stdout/stderr.

# resolve_manifest: parse and validate a post-implement step manifest.
#
# Each non-comment, non-blank line is a path relative to a prompt root.
# Resolution searches the consumer root first, then the framework root;
# the first match wins. Consumer files shadow framework prompts of the
# same relative path. The step label is derived from the filename without
# its `.md` extension.
#
# Validation rules:
#   - Leading `/` is rejected (absolute paths not allowed).
#   - Path segments containing `..` are rejected (no traversal).
#   - A path that resolves in neither root is an unresolved-reference error.
#
# All errors are collected before returning; if any errors are found, no
# output is emitted to stdout and the function exits 1. This ensures the
# caller receives either a complete, valid list or nothing — no partial results.
#
# Args:
#   $1 — manifest_text: the full manifest content (multi-line string)
#   $2 — framework_root: directory containing framework-shipped prompt files
#   $3 — consumer_root:  directory containing the consumer's own prompt files
#
# Stdout: one "<label><TAB><resolved-path>" pair per entry, in manifest order.
#         Empty on an empty (implement-only) manifest.
# Stderr: one diagnostic per validation error.
# Exit:   0 when all entries are valid (including the empty-manifest case);
#         1 when any validation error was found.
resolve_manifest() {
  local manifest_text="$1" fw_root="$2" consumer_root="$3"
  local errors=0 line ref resolved_path label
  # Collect validated output lines; flushed to stdout only if errors == 0.
  local output_buf=""

  while IFS= read -r line; do
    # Strip comment lines (first non-whitespace char is #).
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Strip blank / whitespace-only lines.
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    # Trim leading/trailing whitespace to get the path reference.
    ref="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Validate: no leading /.
    if [[ "$ref" == /* ]]; then
      printf 'resolve_manifest: invalid reference (absolute path not allowed): %s\n' "$ref" >&2
      errors=$((errors + 1))
      continue
    fi

    # Validate: no .. segments (path traversal).
    if [[ "$ref" == ".." ]] || [[ "$ref" == "../"* ]] \
        || [[ "$ref" == *"/.." ]] || [[ "$ref" == *"/../"* ]]; then
      printf 'resolve_manifest: invalid reference (.. segment not allowed): %s\n' "$ref" >&2
      errors=$((errors + 1))
      continue
    fi

    # Resolution: consumer root first, then framework root.
    if [ -f "$consumer_root/$ref" ]; then
      resolved_path="$consumer_root/$ref"
    elif [ -f "$fw_root/$ref" ]; then
      resolved_path="$fw_root/$ref"
    else
      printf 'resolve_manifest: unresolved reference "%s": not found in consumer or framework root\n' "$ref" >&2
      errors=$((errors + 1))
      continue
    fi

    # Label: basename of the path, without the .md extension.
    label="${ref##*/}"
    label="${label%.md}"

    # Buffer the validated pair.
    output_buf="${output_buf}${label}	${resolved_path}"$'\n'
  done <<< "$manifest_text"

  if [ "$errors" -eq 0 ] && [ -n "$output_buf" ]; then
    printf '%s' "$output_buf"
  fi

  [ "$errors" -eq 0 ]
}
