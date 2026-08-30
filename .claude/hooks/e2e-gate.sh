#!/usr/bin/env bash
# PreToolUse gate on Bash: deny `git push` unless the current tracked tree
# has a recorded end-to-end pass. test/e2e-test.sh writes the marker
# (.claude/last-e2e-pass) only when the full e2e suite succeeds; any file
# change after that run invalidates it.
set -euo pipefail

CMD="$(jq -r '.tool_input.command // empty')"

# Only gate commands that actually invoke `git ... push` in one segment.
if ! grep -Eq '\bgit\b[^|;&]*\bpush\b' <<< "${CMD}"; then
  exit 0
fi

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
MARKER="${REPO_ROOT}/.claude/last-e2e-pass"

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

CURRENT="$("${REPO_ROOT}/test/tree-hash.sh")"

if [[ ! -f "${MARKER}" ]]; then
  deny "e2e gate: no end-to-end pass recorded for this tree. Run test/e2e-test.sh <key.pem> <github-owner> to verify the changes, then push."
fi

if [[ "$(cat "${MARKER}")" != "${CURRENT}" ]]; then
  deny "e2e gate: code changed since the last end-to-end pass. Re-run test/e2e-test.sh <key.pem> <github-owner>, then push."
fi

exit 0
