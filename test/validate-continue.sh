#!/usr/bin/env bash
# Validate that a restored Claude Code session can be continued.
#
# Usage:
#   validate-continue.sh <project-dir>
#
# Checks:
#   1. sessions-index.json exists and is valid JSON
#   2. Session JSONL file(s) exist and have content
#   3. claude --continue loads without error
#   4. Conversation history is intact

set -euo pipefail

PROJECT_DIR="${1:?Usage: $0 <project-dir>}"

log()  { echo "[validate] $*"; }
pass() { echo "[validate] ✓ PASS: $*"; }
fail() { echo "[validate] ✗ FAIL: $*"; FAILURES=$((FAILURES + 1)); }

# Source claude environment
[[ -f /etc/profile.d/claude-env.sh ]] && source /etc/profile.d/claude-env.sh

FAILURES=0

# Claude Code encodes the project path with the leading dash kept
# (e.g. /home/ubuntu/project → -home-ubuntu-project)
PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"
ENCODED_PATH="${PROJECT_DIR//\//-}"

SESSION_DIR="${HOME}/.claude/projects/${ENCODED_PATH}"
SESSION_INDEX="${SESSION_DIR}/sessions-index.json"

# ---------- Check 1: session directory ----------
log "Check 1: session directory exists"
if [[ -d "${SESSION_DIR}" ]]; then
  pass "session directory exists: ${SESSION_DIR}"
else
  fail "session directory not found at ${SESSION_DIR}"
fi

# ---------- Check 2: sessions-index.json (old layout only) ----------
# Newer Claude Code versions (2.x) don't write sessions-index.json
log "Check 2: sessions-index.json (if present) is valid JSON"
if [[ -f "${SESSION_INDEX}" ]]; then
  if jq -e . "${SESSION_INDEX}" > /dev/null 2>&1; then
    SESSION_COUNT=$(jq 'length' "${SESSION_INDEX}")
    pass "sessions-index.json is valid JSON (${SESSION_COUNT} sessions)"
  else
    fail "sessions-index.json is not valid JSON"
  fi
else
  pass "no sessions-index.json (new layout) — skipping index checks"
fi

# ---------- Check 3: JSONL files exist ----------
log "Check 3: Session JSONL files exist"
JSONL_COUNT=$(find "${SESSION_DIR}" -name '*.jsonl' 2>/dev/null | wc -l)
if [[ ${JSONL_COUNT} -gt 0 ]]; then
  pass "Found ${JSONL_COUNT} JSONL file(s)"
else
  fail "No JSONL files found in ${SESSION_DIR}"
fi

# ---------- Check 4: JSONL has content ----------
log "Check 4: JSONL files have content"
for jsonl in "${SESSION_DIR}"/*.jsonl; do
  [[ -f "${jsonl}" ]] || continue
  LINE_COUNT=$(wc -l < "${jsonl}")
  BASENAME=$(basename "${jsonl}")
  if [[ ${LINE_COUNT} -gt 0 ]]; then
    pass "${BASENAME}: ${LINE_COUNT} lines"
  else
    fail "${BASENAME}: empty file"
  fi
done

# ---------- Check 5: JSONL lines are valid JSON ----------
log "Check 5: JSONL lines are valid JSON"
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
    pass "${BASENAME}: all ${TOTAL_LINES} lines are valid JSON"
  else
    fail "${BASENAME}: ${BAD_LINES}/${TOTAL_LINES} lines are invalid JSON"
  fi
done

# ---------- Check 6: claude --continue works ----------
log "Check 6: claude --continue loads and can respond"
cd "${PROJECT_DIR}"

# Ask about a detail that exists ONLY in the conversation history: the
# function name from the seed session's follow-up prompt. Machine B's fresh
# clone of the project repo doesn't contain it, so answering correctly
# proves the transcript was restored — not just that files are present.
CONTINUE_OUTPUT=$(claude --continue -p "Earlier in this session I asked you to add a function to hello.py. What was that function called? Reply with only the function name." \
  --model "${ANTHROPIC_DEFAULT_SONNET_MODEL:-global.anthropic.claude-sonnet-4-5-20250929-v1:0}" \
  2>&1) || true

if [[ -n "${CONTINUE_OUTPUT}" ]]; then
  pass "claude --continue produced output"
  log "  Response preview: $(echo "${CONTINUE_OUTPUT}" | head -5)"

  if echo "${CONTINUE_OUTPUT}" | grep -q "get_machine_info"; then
    pass "Response recalls conversation history from the original machine"
  else
    fail "Response does not recall the seeded conversation (expected 'get_machine_info')"
    log "  Full output: ${CONTINUE_OUTPUT}"
  fi
else
  fail "claude --continue produced no output"
fi

# ---------- Results ----------
log ""
log "=== Validation Results ==="
if [[ ${FAILURES} -eq 0 ]]; then
  log "All checks passed!"
  exit 0
else
  log "${FAILURES} check(s) failed."
  exit 1
fi
