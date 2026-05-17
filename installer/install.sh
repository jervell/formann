#!/usr/bin/env bash
# Formann installer — wires a consumer repo to this Formann checkout.
#
# Usage:
#   cd /path/to/formann
#   ./installer/install.sh <consumer-path>
#
# Set FORMANN_INSTALL_BINDING_<role> (dashes → underscores) to bypass prompts:
#   FORMANN_INSTALL_BINDING_issue_tracker=local-markdown ./installer/install.sh <path>
#
# Set FORMANN_PATH to override auto-detection (used by the test suite).
#
# Self-install: when the consumer path resolves to the Formann checkout itself,
# update_gitignore writes a managed block listing every installer product so
# `git status` stays clean. Otherwise it appends only `/.formann` per ADR-0001.

set -euo pipefail

MANAGED_BLOCK_START='# === Formann self-install (managed by installer — do not edit) ==='
MANAGED_BLOCK_END='# === /Formann self-install ==='

# Runtime artifacts: directories framework code creates inside the consumer
# repo at runtime (not installer products). Listed in the consumer's .gitignore
# alongside installer products so `git status` stays clean after the framework
# runs. Entries are consumer-root-relative with a leading slash.
FRAMEWORK_RUNTIME_ARTIFACTS=(/.runner-state/)

# === Path discovery =========================================================

detect_formann_path() {
  if [ -n "${FORMANN_PATH:-}" ]; then
    (cd "$FORMANN_PATH" && pwd)
    return
  fi
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$script_dir/.." && pwd
}

validate_consumer() {
  local consumer="$1"
  if [ -z "$consumer" ]; then
    echo "usage: install.sh <consumer-path>" >&2
    exit 1
  fi
  if [ ! -d "$consumer" ]; then
    echo "install.sh: consumer path does not exist or is not a directory: $consumer" >&2
    exit 1
  fi
}

is_self_install() {
  [ "$1" -ef "$2" ]
}

# === Role binding selection =================================================

prompt_role_bindings() {
  local formann_path="$1"
  local bindings_dir="$formann_path/framework/bindings"

  ROLE_NAMES=()
  ROLE_IMPLS=()

  for role_dir in "$bindings_dir"/*/; do
    [ -d "$role_dir" ] || continue
    local role
    role="$(basename "$role_dir")"

    local impls=()
    for impl_dir in "$role_dir"*/; do
      [ -d "$impl_dir" ] || continue
      impls+=("$(basename "$impl_dir")")
    done

    if [ "${#impls[@]}" -eq 0 ]; then
      echo "install.sh: no impls found for role '$role', skipping" >&2
      continue
    fi

    local env_var="FORMANN_INSTALL_BINDING_${role//-/_}"
    local chosen

    if [ -n "${!env_var:-}" ]; then
      chosen="${!env_var}"
    else
      local impls_str="${impls[*]}"
      read -r -p "Role '$role' impls: [$impls_str]. Pick one: " chosen
    fi

    local valid=0
    local impl
    for impl in "${impls[@]}"; do
      if [ "$impl" = "$chosen" ]; then
        valid=1
        break
      fi
    done
    if [ "$valid" -eq 0 ]; then
      echo "install.sh: '$chosen' is not a valid impl for role '$role' (available: ${impls[*]})" >&2
      exit 1
    fi

    ROLE_NAMES+=("$role")
    ROLE_IMPLS+=("$chosen")
  done
}

# === Product enumeration ====================================================

# Single source of truth for "what does the installer produce".
# Emits one product per line as tab-separated fields:
#   <kind>\t<dest_path>\t<target>
# where <kind> is `symlink` or `copy`, <dest_path> is relative to the consumer
# root (no leading slash), and <target> is the symlink target or the source
# file to copy. Emits warnings to stderr when an optional source dir is absent
# (matches the legacy "skipping <kind>" behaviour).
enumerate_products() {
  local formann_path="$1"

  # Root indirection symlink.
  printf 'symlink\t.formann\t%s\n' "$formann_path/framework"

  local skills_dir="$formann_path/framework/skills"
  if [ -d "$skills_dir" ]; then
    local entry name
    for entry in "$skills_dir"/*/; do
      [ -d "$entry" ] || continue
      name="$(basename "$entry")"
      printf 'symlink\t.claude/skills/%s\t../../.formann/skills/%s\n' "$name" "$name"
    done
  else
    echo "install.sh: $skills_dir not found, skipping skills" >&2
  fi

  local agents_dir="$formann_path/framework/agents"
  if [ -d "$agents_dir" ]; then
    local entry name
    for entry in "$agents_dir"/*.md; do
      [ -f "$entry" ] || continue
      name="$(basename "$entry")"
      printf 'symlink\t.claude/agents/%s\t../../.formann/agents/%s\n' "$name" "$name"
    done
  else
    echo "install.sh: $agents_dir not found, skipping agents" >&2
  fi

  local rules_dir="$formann_path/framework/rules"
  if [ -d "$rules_dir" ]; then
    local entry name
    for entry in "$rules_dir"/*; do
      [ -f "$entry" ] || continue
      name="$(basename "$entry")"
      printf 'symlink\t.claude/rules/%s\t../../.formann/rules/%s\n' "$name" "$name"
    done
  else
    echo "install.sh: $rules_dir not found, skipping rules" >&2
  fi

  local i
  for i in "${!ROLE_NAMES[@]}"; do
    local role="${ROLE_NAMES[$i]}"
    local impl="${ROLE_IMPLS[$i]}"
    printf 'symlink\tdocs/formann/%s\t../../.formann/bindings/%s/%s\n' "$role" "$role" "$impl"
  done

  local framework_docs=(lifecycle.md inbox.md domain.md triage-states.md afk-runner.md afk-runner-flow.md)
  local doc
  for doc in "${framework_docs[@]}"; do
    printf 'symlink\tdocs/formann/%s\t../../.formann/%s\n' "$doc" "$doc"
  done

  printf 'copy\trunner/Dockerfile\t%s\n' "$formann_path/installer/templates/Dockerfile"
}

# === Symlink + copy helpers =================================================

# absent → create; correct target → no-op; wrong target → overwrite;
# real file or directory → leave alone (consumer override).
make_symlink() {
  local dest="$1"
  local link_target="$2"

  if [ -L "$dest" ]; then
    local current
    current="$(readlink "$dest")"
    if [ "$current" = "$link_target" ]; then
      return 0
    fi
    rm "$dest"
    ln -s "$link_target" "$dest"
  elif [ -e "$dest" ]; then
    :
  else
    mkdir -p "$(dirname "$dest")"
    ln -s "$link_target" "$dest"
  fi
}

# Reads enumerated products on stdin and realises each as a symlink or a copy
# under $consumer_path.
install_products() {
  local consumer_path="$1"
  local kind dest target
  while IFS=$'\t' read -r kind dest target; do
    case "$kind" in
      symlink)
        make_symlink "$consumer_path/$dest" "$target"
        ;;
      copy)
        mkdir -p "$(dirname "$consumer_path/$dest")"
        if [ ! -e "$consumer_path/$dest" ]; then
          cp "$target" "$consumer_path/$dest"
        fi
        ;;
      *)
        echo "install.sh: unknown product kind '$kind' (dest=$dest)" >&2
        exit 1
        ;;
    esac
  done
}

# === .gitignore =============================================================

# Reads enumerated products on stdin and writes/refreshes the managed block in
# the consumer's .gitignore. Content outside the marker pair is preserved
# verbatim; content inside is regenerated. If the marker pair is absent, the
# block is appended at the end of the file.
write_managed_block() {
  local consumer_path="$1"
  local gitignore="$consumer_path/.gitignore"

  touch "$gitignore"

  local entries=()
  local kind dest target
  while IFS=$'\t' read -r kind dest target; do
    entries+=("/$dest")
  done
  local artifact
  for artifact in "${FRAMEWORK_RUNTIME_ARTIFACTS[@]}"; do
    entries+=("$artifact")
  done

  local has_block=0
  if grep -qxF "$MANAGED_BLOCK_START" "$gitignore" \
     && grep -qxF "$MANAGED_BLOCK_END" "$gitignore"; then
    has_block=1
  fi

  if [ "$has_block" -eq 1 ]; then
    local tmpfile
    tmpfile="$(mktemp)"
    local inside=0 line e
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "$MANAGED_BLOCK_START" ]; then
        printf '%s\n' "$MANAGED_BLOCK_START" >> "$tmpfile"
        for e in "${entries[@]}"; do
          printf '%s\n' "$e" >> "$tmpfile"
        done
        inside=1
        continue
      fi
      if [ "$line" = "$MANAGED_BLOCK_END" ]; then
        printf '%s\n' "$MANAGED_BLOCK_END" >> "$tmpfile"
        inside=0
        continue
      fi
      if [ "$inside" -eq 0 ]; then
        printf '%s\n' "$line" >> "$tmpfile"
      fi
    done < "$gitignore"
    mv "$tmpfile" "$gitignore"
    return
  fi

  if [ -s "$gitignore" ] && [ -n "$(tail -c1 "$gitignore")" ]; then
    printf '\n' >> "$gitignore"
  fi
  {
    printf '%s\n' "$MANAGED_BLOCK_START"
    local e
    for e in "${entries[@]}"; do
      printf '%s\n' "$e"
    done
    printf '%s\n' "$MANAGED_BLOCK_END"
  } >> "$gitignore"
}

update_gitignore() {
  local consumer_path="$1"
  local self_install="$2"
  local products="${3:-}"
  local gitignore="$consumer_path/.gitignore"

  if [ "$self_install" -eq 1 ]; then
    write_managed_block "$consumer_path" <<< "$products"
    return
  fi

  touch "$gitignore"
  if ! grep -qxF '/.formann' "$gitignore"; then
    echo '/.formann' >> "$gitignore"
  fi
  local artifact
  for artifact in "${FRAMEWORK_RUNTIME_ARTIFACTS[@]}"; do
    if ! grep -qxF "$artifact" "$gitignore"; then
      echo "$artifact" >> "$gitignore"
    fi
  done
}

# === CLAUDE.md snippet =======================================================

print_claude_md_snippet() {
  local formann_path="$1"
  printf '\n'
  printf '══════════════════════════════════════════════════════════\n'
  printf '  Paste the following into your CLAUDE.md:\n'
  printf '══════════════════════════════════════════════════════════\n'
  cat "$formann_path/installer/templates/claude-md-snippet.md"
  printf '══════════════════════════════════════════════════════════\n'
}

# === Main ===================================================================

main() {
  local consumer_path="${1:-}"

  validate_consumer "$consumer_path"
  consumer_path="$(cd "$consumer_path" && pwd)"

  local formann_path
  formann_path="$(detect_formann_path)"

  prompt_role_bindings "$formann_path"

  local self_install=0
  if is_self_install "$consumer_path" "$formann_path"; then
    self_install=1
  fi

  local products
  products="$(enumerate_products "$formann_path")"

  install_products "$consumer_path" <<< "$products"
  update_gitignore "$consumer_path" "$self_install" "$products"
  print_claude_md_snippet "$formann_path"
}

main "$@"
