#!/usr/bin/env bash
# Retrieve the Claude Code OAuth token from macOS Keychain (or libsecret /
# kernel keyring on Linux) by delegating to the vendored retrieve-secret.sh.
#
# Output:
#   stdout — the token, with no trailing newline added beyond what the
#            vendored script emits (a single \n). Captured by callers via
#               TOKEN="$(framework/runner/retrieve-token.sh)"
#            which strips the trailing newline.
#   stderr — diagnostics on failure (missing Keychain entry, etc.). The
#            token is NEVER written to stderr.
#
# Exit codes:
#   0 — token printed
#   1 — Keychain entry missing or unreadable; a how-to-populate hint is
#       printed to stderr.
#   2 — environment problem (vendored script missing, OS unsupported).
#
# Safety:
#   - The token is only ever produced on stdout. No log files, no
#     `set -x` traces (this script does not enable xtrace), no echo to
#     stderr. Callers must capture it into a shell variable and only
#     interpolate it into `docker run -e CLAUDE_CODE_OAUTH_TOKEN=…`.
#   - The vendored script's "Secret not found" error reveals the service
#     and account names but not the secret itself.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

VENDORED="$HERE/retrieve-secret.sh"
if [[ ! -x "$VENDORED" ]]; then
  cat >&2 <<MSG
retrieve-token.sh: vendored helper not found or not executable: $VENDORED
Re-vendor from source (see framework/runner/NOTES.md).
MSG
  exit 2
fi

# Delegate. retrieve-secret.sh prints the token on stdout, errors on stderr.
# Suppress its stderr only in the success path; on failure, show our own
# error + hint and surface the underlying error too.
SERVICE="$RUNNER_OAUTH_KEYCHAIN_SERVICE"
ACCOUNT="$RUNNER_OAUTH_KEYCHAIN_ACCOUNT"

ERR_FILE="$(mktemp -t retrieve-token.XXXXXX)"
trap 'rm -f "$ERR_FILE"' EXIT

rc=0
"$VENDORED" --service "$SERVICE" --account "$ACCOUNT" 2>"$ERR_FILE" || rc=$?

if [[ $rc -ne 0 ]]; then
  cat >&2 <<MSG
retrieve-token.sh: failed to retrieve OAuth token from Keychain
  service: $SERVICE
  account: $ACCOUNT

To populate (one-time, then good for ~1 year):
  1. Run \`claude setup-token\` and copy the token it prints.
  2. Store it in Keychain (no trailing newline):
       security add-generic-password -s "$SERVICE" -a "$ACCOUNT" -w
     and paste the token at the prompt.

Underlying error from retrieve-secret.sh:
MSG
  cat >&2 "$ERR_FILE"
  exit 1
fi
