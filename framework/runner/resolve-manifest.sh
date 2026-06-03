#!/usr/bin/env bash
# resolve-manifest.sh — pure manifest resolver for the AFK runner.
#
# Sourceable. The only exported function is `resolve_manifest`. No globals
# are modified; no I/O beyond the function's own stdin/stdout/stderr.

# resolve_manifest: parse and validate a post-implement step manifest.
#
# Each non-comment, non-blank line must have the form:
#   <label> → <namespace>:<name>
# where the separator is the Unicode right arrow (U+2192), <namespace> is
# either "framework" or "consumer", and <name> is the prompt filename.
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
  local errors=0 line label ref namespace name resolved_path
  # Collect validated output lines; flushed to stdout only if errors == 0.
  local output_buf=""

  while IFS= read -r line; do
    # Strip comment lines (first non-whitespace char is #).
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Strip blank / whitespace-only lines.
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    # Require the → (U+2192) separator.
    if [[ "$line" != *"→"* ]]; then
      printf 'resolve_manifest: malformed entry (no → separator): %s\n' "$line" >&2
      errors=$((errors + 1))
      continue
    fi

    # Split on the first →; trim surrounding whitespace from each part.
    label="$(printf '%s' "${line%%→*}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    ref="$(printf '%s'   "${line#*→}"  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -z "$label" ]; then
      printf 'resolve_manifest: malformed entry (empty label): %s\n' "$line" >&2
      errors=$((errors + 1))
      continue
    fi

    if [ -z "$ref" ]; then
      printf 'resolve_manifest: malformed entry (empty reference): %s\n' "$line" >&2
      errors=$((errors + 1))
      continue
    fi

    # Resolve namespace prefix.
    case "$ref" in
      framework:*)
        namespace="framework"
        name="${ref#framework:}"
        resolved_path="$fw_root/$name"
        ;;
      consumer:*)
        namespace="consumer"
        name="${ref#consumer:}"
        resolved_path="$consumer_root/$name"
        ;;
      *)
        printf 'resolve_manifest: malformed entry (unknown namespace in "%s"): %s\n' "$ref" "$line" >&2
        errors=$((errors + 1))
        continue
        ;;
    esac

    if [ -z "$name" ]; then
      printf 'resolve_manifest: malformed entry (empty prompt name after "%s:"): %s\n' "$namespace" "$line" >&2
      errors=$((errors + 1))
      continue
    fi

    # Existence check.
    if [ ! -f "$resolved_path" ]; then
      printf 'resolve_manifest: unresolved reference "%s": %s not found\n' "$ref" "$resolved_path" >&2
      errors=$((errors + 1))
      continue
    fi

    # Buffer the validated pair.
    output_buf="${output_buf}${label}	${resolved_path}"$'\n'
  done <<< "$manifest_text"

  if [ "$errors" -eq 0 ] && [ -n "$output_buf" ]; then
    printf '%s' "$output_buf"
  fi

  [ "$errors" -eq 0 ]
}
