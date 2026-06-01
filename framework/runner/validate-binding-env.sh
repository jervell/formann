#!/usr/bin/env bash
# Shared binding-env line-shape validator.
# Sourced by run-the-queue.sh (collect_binding_env) and by sandbox-env.bats.
# No executable side effects on source.

# Returns 0 if a single line conforms to the binding-env KEY=value shape rule
# (^[A-Z_][A-Z0-9_]*=), 1 otherwise. Callers are responsible for skipping
# empty lines before calling.
binding_env_line_valid() {
  [[ "$1" =~ ^[A-Z_][A-Z0-9_]*= ]]
}
