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

set -euo pipefail

# === Path discovery =========================================================

detect_formann_path() {
  if [ -n "${FORMANN_PATH:-}" ]; then
    echo "$FORMANN_PATH"
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

# === Symlink helpers =========================================================

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

# === Installation steps =====================================================

link_formann() {
  local consumer_path="$1"
  local formann_path="$2"
  make_symlink "$consumer_path/.formann" "$formann_path"
}

link_skills() {
  local consumer_path="$1"
  local formann_path="$2"
  local source_dir="$formann_path/framework/skills"

  if [ ! -d "$source_dir" ]; then
    echo "install.sh: $source_dir not found, skipping skills" >&2
    return 0
  fi
  mkdir -p "$consumer_path/.claude/skills"

  for entry in "$source_dir"/*/; do
    [ -d "$entry" ] || continue
    local name
    name="$(basename "$entry")"
    make_symlink "$consumer_path/.claude/skills/$name" "../../.formann/framework/skills/$name"
  done
}

link_agents() {
  local consumer_path="$1"
  local formann_path="$2"
  local source_dir="$formann_path/framework/agents"

  if [ ! -d "$source_dir" ]; then
    echo "install.sh: $source_dir not found, skipping agents" >&2
    return 0
  fi
  mkdir -p "$consumer_path/.claude/agents"

  for entry in "$source_dir"/*.md; do
    [ -f "$entry" ] || continue
    local name
    name="$(basename "$entry")"
    make_symlink "$consumer_path/.claude/agents/$name" "../../.formann/framework/agents/$name"
  done
}

link_rules() {
  local consumer_path="$1"
  local formann_path="$2"
  local source_dir="$formann_path/framework/rules"

  if [ ! -d "$source_dir" ]; then
    echo "install.sh: $source_dir not found, skipping rules" >&2
    return 0
  fi
  mkdir -p "$consumer_path/.claude/rules"

  for entry in "$source_dir"/*; do
    [ -f "$entry" ] || continue
    local name
    name="$(basename "$entry")"
    make_symlink "$consumer_path/.claude/rules/$name" "../../.formann/framework/rules/$name"
  done
}

link_role_surface() {
  local consumer_path="$1"
  local formann_path="$2"

  mkdir -p "$consumer_path/docs/formann"

  for i in "${!ROLE_NAMES[@]}"; do
    local role="${ROLE_NAMES[$i]}"
    local impl="${ROLE_IMPLS[$i]}"
    make_symlink "$consumer_path/docs/formann/$role" \
      "../../.formann/framework/bindings/$role/$impl"
  done

  local framework_docs=(lifecycle.md inbox.md domain.md triage-states.md afk-runner.md afk-runner-flow.md)
  for doc in "${framework_docs[@]}"; do
    make_symlink "$consumer_path/docs/formann/$doc" "../../.formann/framework/$doc"
  done
}

scaffold_dockerfile() {
  local consumer_path="$1"
  local formann_path="$2"

  mkdir -p "$consumer_path/runner"
  local dest="$consumer_path/runner/Dockerfile"

  if [ ! -e "$dest" ]; then
    cp "$formann_path/installer/templates/Dockerfile" "$dest"
  fi
}

update_gitignore() {
  local consumer_path="$1"
  local gitignore="$consumer_path/.gitignore"

  touch "$gitignore"
  if ! grep -qxF '/.formann' "$gitignore"; then
    echo '/.formann' >> "$gitignore"
  fi
}

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

  link_formann "$consumer_path" "$formann_path"
  link_skills "$consumer_path" "$formann_path"
  link_agents "$consumer_path" "$formann_path"
  link_rules "$consumer_path" "$formann_path"
  link_role_surface "$consumer_path" "$formann_path"
  scaffold_dockerfile "$consumer_path" "$formann_path"
  update_gitignore "$consumer_path"
  print_claude_md_snippet "$formann_path"
}

main "$@"
