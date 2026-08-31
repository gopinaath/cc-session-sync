#!/usr/bin/env bash
# Validate a session restored under a DIFFERENT username via cc-pull.sh --rewrite-paths.
#
# Run this AS THE TARGET USER (e.g. alice), after cc-pull.sh --rewrite-paths,
# and BEFORE anything mutates the restored session (validate-continue.sh runs
# claude --continue, which appends to the transcript — run this script first).
#
# Usage:
#   validate-username-change.sh <project-dir> <source-project-dir>
#
# Example (state pushed from ubuntu@A, restored for alice@B):
#   sudo -u alice -H bash validate-username-change.sh /home/alice/test-project /home/ubuntu/test-project
#
# Checks:
#   1. Session directory exists under the NEW user's encoded path
#   2. No file or directory still uses the SOURCE encoded path
#   3. No stale source project-path references in restored data
#   4. No stale source home-dir references in restored data
#   5. cwd fields in session JSONL point at the new project dir
#   6. JSONL lines are still valid JSON after rewriting

set -euo pipefail

PROJECT_DIR="${1:?Usage: $0 <project-dir> <source-project-dir>}"
SOURCE_PROJECT_DIR="${2:?Usage: $0 <project-dir> <source-project-dir>}"

log()  { echo "[validate-user] $*"; }
pass() { echo "[validate-user] ✓ PASS: $*"; }
fail() { echo "[validate-user] ✗ FAIL: $*"; FAILURES=$((FAILURES + 1)); }

FAILURES=0

PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"

if [[ "${PROJECT_DIR}" == "${SOURCE_PROJECT_DIR}" ]]; then
  echo "[validate-user] ERROR: source and target project dirs are identical — nothing to validate" >&2
  exit 2
fi

# Claude Code encodes project paths keeping the leading dash:
# /home/alice/test-project → -home-alice-test-project
ENCODED_PATH="${PROJECT_DIR//\//-}"
SRC_ENCODED="${SOURCE_PROJECT_DIR//\//-}"
SESSION_DIR="${HOME}/.claude/projects/${ENCODED_PATH}"

# Derive the source home dir (e.g. /home/ubuntu) the same way cc-pull.sh does
SOURCE_HOME="$(echo "${SOURCE_PROJECT_DIR}" | grep -oE '^/(home|Users)/[^/]+' || true)"

log "Target user      : $(whoami) (HOME=${HOME})"
log "Target project   : ${PROJECT_DIR}"
log "Source project   : ${SOURCE_PROJECT_DIR}"
log "Source home      : ${SOURCE_HOME:-<none derived>}"
log "Target encoded   : ${ENCODED_PATH}"
log "Source encoded   : ${SRC_ENCODED}"

# Scan only what cc-pull.sh restores (the rest of ~/.claude may not exist yet)
SCAN_DIRS=()
for d in "projects/${ENCODED_PATH}" file-history tasks todos plans; do
  [[ -d "${HOME}/.claude/${d}" ]] && SCAN_DIRS+=("${HOME}/.claude/${d}")
done

# ---------- Check 1: session dir under the new encoded path ----------
log ""
log "Check 1: session directory exists under new user's encoded path"
if [[ -d "${SESSION_DIR}" ]]; then
  JSONL_COUNT=$(find "${SESSION_DIR}" -maxdepth 1 -name '*.jsonl' | wc -l)
  if [[ ${JSONL_COUNT} -gt 0 ]]; then
    pass "session dir exists with ${JSONL_COUNT} JSONL file(s): ${SESSION_DIR}"
  else
    fail "session dir exists but contains no JSONL files"
  fi
else
  fail "session directory not found at ${SESSION_DIR}"
fi

# ---------- Check 2: no source encoded path in any file/dir name ----------
log "Check 2: no file or directory still uses the source encoded path"
STALE_NAMES=$(find "${HOME}/.claude" -path "*${SRC_ENCODED}*" 2>/dev/null | wc -l)
if [[ ${STALE_NAMES} -eq 0 ]]; then
  pass "no filesystem entries use '${SRC_ENCODED}'"
else
  fail "${STALE_NAMES} filesystem entries still use the source encoded path"
  find "${HOME}/.claude" -path "*${SRC_ENCODED}*" 2>/dev/null | head -5 | sed 's/^/[validate-user]   /'
fi

# ---------- Check 3: no stale source project-path references ----------
log "Check 3: no stale source project-path references in restored data"
STALE_PROJ=0
for d in "${SCAN_DIRS[@]}"; do
  # `|| true`: grep exits 1 when nothing matches (the success case) and
  # pipefail would otherwise abort the script under set -e
  STALE_PROJ=$((STALE_PROJ + $(grep -rF -- "${SOURCE_PROJECT_DIR}" "${d}" 2>/dev/null | wc -l || true)))
done
if [[ ${STALE_PROJ} -eq 0 ]]; then
  pass "no references to ${SOURCE_PROJECT_DIR} remain"
else
  fail "${STALE_PROJ} references to ${SOURCE_PROJECT_DIR} remain"
  for d in "${SCAN_DIRS[@]}"; do
    grep -rF -l -- "${SOURCE_PROJECT_DIR}" "${d}" 2>/dev/null | head -3 | sed 's/^/[validate-user]   /'
  done
fi

# ---------- Check 4: no stale source home-dir references ----------
log "Check 4: no stale source home-dir references in restored data"
if [[ -z "${SOURCE_HOME}" ]]; then
  log "  (skipped — could not derive a /home/<user> or /Users/<user> prefix)"
elif [[ "${SOURCE_HOME}" == "${HOME}" ]]; then
  log "  (skipped — source and target homes are identical)"
else
  STALE_HOME=0
  for d in "${SCAN_DIRS[@]}"; do
    STALE_HOME=$((STALE_HOME + $(grep -rF -- "${SOURCE_HOME}/" "${d}" 2>/dev/null | wc -l || true)))
  done
  if [[ ${STALE_HOME} -eq 0 ]]; then
    pass "no references to ${SOURCE_HOME}/ remain"
  else
    fail "${STALE_HOME} references to ${SOURCE_HOME}/ remain"
  fi
fi

# ---------- Check 5: cwd fields point at the new project dir ----------
log "Check 5: cwd fields in session JSONL point at the new project dir"
STALE_CWD=0
NEW_CWD=0
for jsonl in "${SESSION_DIR}"/*.jsonl; do
  [[ -f "${jsonl}" ]] || continue
  STALE_CWD=$((STALE_CWD + $(jq -r 'select(.cwd != null) | .cwd' "${jsonl}" 2>/dev/null | grep -cF -- "${SOURCE_PROJECT_DIR}" || true)))
  NEW_CWD=$((NEW_CWD + $(jq -r 'select(.cwd != null) | .cwd' "${jsonl}" 2>/dev/null | grep -cF -- "${PROJECT_DIR}" || true)))
done
if [[ ${STALE_CWD} -eq 0 && ${NEW_CWD} -gt 0 ]]; then
  pass "cwd rewritten (${NEW_CWD} lines point at ${PROJECT_DIR}, 0 stale)"
elif [[ ${STALE_CWD} -eq 0 && ${NEW_CWD} -eq 0 ]]; then
  fail "no cwd fields found at all — is the session JSONL empty or unexpected format?"
else
  fail "cwd not fully rewritten (${STALE_CWD} stale, ${NEW_CWD} new)"
fi

# ---------- Check 6: JSONL still valid JSON after rewrite ----------
log "Check 6: JSONL lines are valid JSON after rewriting"
for jsonl in "${SESSION_DIR}"/*.jsonl; do
  [[ -f "${jsonl}" ]] || continue
  BASENAME=$(basename "${jsonl}")
  BAD_LINES=0
  TOTAL_LINES=$(wc -l < "${jsonl}")
  while IFS= read -r line; do
    if [[ -n "${line}" ]] && ! echo "${line}" | jq -e . > /dev/null 2>&1; then
      BAD_LINES=$((BAD_LINES + 1))
    fi
  done < "${jsonl}"
  if [[ ${BAD_LINES} -eq 0 ]]; then
    pass "${BASENAME}: all ${TOTAL_LINES} lines valid JSON"
  else
    fail "${BASENAME}: ${BAD_LINES}/${TOTAL_LINES} lines invalid JSON after rewrite"
  fi
done

# ---------- results ----------
log ""
log "=== Username-Change Validation Results ==="
if [[ ${FAILURES} -eq 0 ]]; then
  log "All checks passed!"
  exit 0
else
  log "${FAILURES} check(s) failed."
  exit 1
fi
