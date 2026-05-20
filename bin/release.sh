#!/usr/bin/env bash
# release.sh — cut a release of Formann.
#
# Usage:
#   bin/release.sh X.Y.Z              # plan, confirm, commit, tag, prompt to push
#   bin/release.sh X.Y.Z --dry-run    # show planned edits without writing
#
# See RELEASING.md for context.

set -euo pipefail

usage() {
  cat <<EOF
Usage: bin/release.sh X.Y.Z [--dry-run]

Cuts a release: rewrites CHANGELOG.md (moves [Unreleased] content under a new
[X.Y.Z] heading), commits, creates annotated tag vX.Y.Z, prompts to push.

Refuses if: version is malformed, tag exists, HEAD is not on main, working tree
is dirty, or the [Unreleased] section is empty.
EOF
}

VERSION="${1:-}"
MODE="${2:-}"

case "$VERSION" in
  ""|-h|--help) usage; exit 2 ;;
esac

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Refusing: version must be semver X.Y.Z (got: $VERSION)" >&2
  exit 1
fi

if [[ -n "$MODE" && "$MODE" != "--dry-run" ]]; then
  echo "Unknown argument: $MODE" >&2
  usage >&2
  exit 2
fi

TAG="v$VERSION"
DATE="$(date +%Y-%m-%d)"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

CHANGELOG="$REPO_ROOT/CHANGELOG.md"
if [[ ! -f "$CHANGELOG" ]]; then
  echo "Refusing: $CHANGELOG not found" >&2
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Refusing: tag $TAG already exists" >&2
  exit 1
fi

branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
if [[ "$branch" != "main" ]]; then
  echo "Refusing: must be on 'main' (currently on '${branch:-detached HEAD}')" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Refusing: working tree is dirty (commit or stash first)" >&2
  exit 1
fi

# Refuse if local main is behind origin/main — committing on a stale base would
# leave a local release + tag that can't be pushed. Skip when origin isn't
# configured (the push step will surface that case if/when the user opts in).
if git remote get-url origin >/dev/null 2>&1; then
  git fetch origin main --quiet
  if ! git merge-base --is-ancestor refs/remotes/origin/main HEAD; then
    echo "Refusing: local 'main' is behind 'origin/main' (run: git pull --rebase)" >&2
    exit 1
  fi
fi

# Extract the [Unreleased] section's body (everything between `## [Unreleased]`
# and the next `## [` heading, or to EOF).
unreleased="$(awk '
  /^## \[Unreleased\]/ { capturing = 1; next }
  /^## \[/ && capturing { exit }
  capturing { print }
' "$CHANGELOG")"

# Strip the blank line immediately after `## [Unreleased]` so the tag
# annotation, release notes, and dry-run preview don't open with a stray
# empty line. Trailing newlines are already stripped by command substitution.
unreleased="${unreleased#$'\n'}"

if [[ -z "${unreleased//[[:space:]]/}" ]]; then
  echo "Refusing: [Unreleased] section in CHANGELOG.md is empty or missing (nothing to release)" >&2
  exit 1
fi

# Build the new CHANGELOG by inserting `## [X.Y.Z] - DATE` right after the
# `## [Unreleased]` heading. The existing Unreleased content stays in place,
# now sitting under the new version heading.
new_changelog="$(awk -v ver="$VERSION" -v date="$DATE" '
  /^## \[Unreleased\]/ && !done {
    print
    print ""
    print "## [" ver "] - " date
    print ""
    done = 1
    if ((getline nl) > 0 && nl != "") print nl
    next
  }
  { print }
' "$CHANGELOG")"

echo "Planned release: $TAG ($DATE)"
echo
echo "--- CHANGELOG.md diff ---"
diff -u "$CHANGELOG" <(printf '%s\n' "$new_changelog") || true
echo
echo "--- Commit message ---"
echo "release: $TAG"
echo
echo "--- Tag message ($TAG, annotated) ---"
echo "$TAG"
echo
printf '%s\n' "$unreleased"
echo "---"

if [[ "$MODE" == "--dry-run" ]]; then
  echo
  echo "Dry run: no changes made."
  exit 0
fi

echo
read -r -p "Proceed with commit + tag? [y/N] " ans || { echo "Aborted."; exit 1; }
case "$ans" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 1 ;;
esac

printf '%s\n' "$new_changelog" > "$CHANGELOG"
git add "$CHANGELOG"
git commit -m "release: $TAG"

# --cleanup=verbatim preserves Keep-a-Changelog subheadings like `### Added`;
# the default `strip` mode treats lines starting with `#` as comments and
# silently removes them from the stored annotation.
tag_msg="$TAG"$'\n\n'"$unreleased"
git tag -a --cleanup=verbatim "$TAG" -m "$tag_msg"

echo "Committed and tagged $TAG."
echo
read -r -p "Push HEAD + $TAG to origin? [y/N] " ans || { echo "Not pushed. Run: git push --atomic origin main $TAG"; exit 1; }
case "$ans" in
  y|Y|yes|YES)
    # --atomic so main and the tag publish together or not at all; avoids the
    # main-pushed-but-tag-failed split-state.
    git push --atomic origin main "$TAG"
    echo "Pushed."
    # Pass notes inline rather than --notes-from-tag: the tag annotation goes
    # through git's cleanup pipeline, and we want the GitHub Release body to
    # be the exact CHANGELOG content regardless of how that pipeline evolves.
    notes_file="$(mktemp -t "formann-release-$TAG.XXXXXX")"
    printf '%s\n' "$unreleased" > "$notes_file"
    if command -v gh >/dev/null 2>&1; then
      if gh release create "$TAG" --title "$TAG" --notes-file "$notes_file"; then
        echo "Created GitHub Release for $TAG."
        rm -f "$notes_file"
      else
        echo "gh release create failed. Tag is pushed; create the release manually with:"
        echo "  gh release create $TAG --title $TAG --notes-file '$notes_file'"
      fi
    else
      echo "gh CLI not found. To publish a GitHub Release, run:"
      echo "  gh release create $TAG --title $TAG --notes-file '$notes_file'"
    fi
    ;;
  *)
    echo "Not pushed. Run: git push --atomic origin main $TAG"
    ;;
esac
