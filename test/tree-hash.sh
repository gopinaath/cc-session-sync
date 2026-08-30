#!/usr/bin/env bash
# Print a content hash of the tracked working tree. This identifies exactly
# the code an e2e run tested, independent of commits or staging state, so
# the same value before and after `git commit` with no file changes.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Build a throwaway index from the working tree (respects .gitignore) so the
# real index and staging area are untouched.
TMP_INDEX="$(mktemp)"
trap 'rm -f "${TMP_INDEX}"' EXIT
cp "$(git rev-parse --git-path index)" "${TMP_INDEX}"
GIT_INDEX_FILE="${TMP_INDEX}" git add -A
GIT_INDEX_FILE="${TMP_INDEX}" git write-tree
