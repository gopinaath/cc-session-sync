#!/usr/bin/env bash
# Test cases for validating path rewriting (Issue #1: Path mismatch breaks session restore)
#
# These tests create synthetic session data with source paths, run cc-pull.sh
# with path rewriting, and verify all path references are correctly rewritten.
#
# Usage:
#   test-path-rewrite.sh
#
# Prerequisites:
#   - jq installed
#   - cc-pull.sh supports --rewrite-paths (Phase 2 feature)

set -euo pipefail

# ---------- test framework ----------
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log()  { echo "[test-path-rewrite] $*"; }
pass() { echo "[test-path-rewrite] PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[test-path-rewrite] FAIL: $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { echo "[test-path-rewrite] SKIP: $*"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

# ---------- setup ----------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# ---------- constants ----------
# Use paths under WORK_DIR so we don't need root permissions
SRC_USER="alice"
SRC_HOME="${WORK_DIR}/home/${SRC_USER}"
SRC_PROJECT="${SRC_HOME}/myproject"
SRC_ENCODED="${SRC_PROJECT//\//-}"

DST_USER="bob"
DST_HOME="${WORK_DIR}/home/${DST_USER}"
DST_PROJECT="${DST_HOME}/myproject"
DST_ENCODED="${DST_PROJECT//\//-}"

SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
SESSION_ID_2="11111111-2222-3333-4444-555555555555"

STATE_DIR="${WORK_DIR}/state"      # simulated state repo clone
CLAUDE_DIR="${WORK_DIR}/claude"    # simulated ~/.claude on target machine

log "Work dir: ${WORK_DIR}"
log "Source: ${SRC_PROJECT} (user: ${SRC_USER})"
log "Target: ${DST_PROJECT} (user: ${DST_USER})"
log ""

# ---------- helper: create synthetic state repo ----------
create_state_repo() {
  mkdir -p "${STATE_DIR}/projects/${SRC_ENCODED}"

  # -- sessions-index.json (correct {version, entries} format) --
  cat > "${STATE_DIR}/projects/${SRC_ENCODED}/sessions-index.json" << INDEXEOF
{
  "version": 1,
  "entries": [
    {
      "sessionId": "${SESSION_ID}",
      "fullPath": "${SRC_HOME}/.claude/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl",
      "fileMtime": 1773458414000,
      "firstPrompt": "create a hello world script",
      "messageCount": 10,
      "created": "2026-03-14T00:00:00.000Z",
      "modified": "2026-03-14T01:00:00.000Z",
      "gitBranch": "main",
      "projectPath": "${SRC_PROJECT}",
      "isSidechain": false
    },
    {
      "sessionId": "${SESSION_ID_2}",
      "fullPath": "${SRC_HOME}/.claude/projects/${SRC_ENCODED}/${SESSION_ID_2}.jsonl",
      "fileMtime": 1773544814000,
      "firstPrompt": "add unit tests",
      "summary": "Added pytest tests",
      "messageCount": 5,
      "created": "2026-03-15T00:00:00.000Z",
      "modified": "2026-03-15T00:30:00.000Z",
      "gitBranch": "main",
      "projectPath": "${SRC_PROJECT}",
      "isSidechain": false
    }
  ]
}
INDEXEOF

  # -- Session JSONL with various path-bearing fields --
  # Each line is a valid JSON object simulating real JSONL records
  cat > "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl" << 'TEMPLATEEOF'
TEMPLATEEOF

  # Write JSONL lines using jq to ensure valid JSON
  # Line 1: human message with cwd
  jq -cn --arg cwd "${SRC_PROJECT}" \
    '{type:"human", message:{role:"user", content:"create hello.py"}, cwd:$cwd}' \
    >> "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl"

  # Line 2: assistant message with tool use (Write) referencing file_path
  jq -cn --arg cwd "${SRC_PROJECT}" --arg fp "${SRC_PROJECT}/hello.py" \
    '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", name:"Write", input:{file_path:$fp, content:"print(\"hello\")\n"}}]}, cwd:$cwd}' \
    >> "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl"

  # Line 3: tool result with filePath (camelCase variant)
  jq -cn --arg cwd "${SRC_PROJECT}" --arg fp "${SRC_PROJECT}/hello.py" \
    '{type:"tool_result", tool_name:"Write", result:{filePath:$fp, success:true}, cwd:$cwd}' \
    >> "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl"

  # Line 4: assistant message with Bash tool containing path in command
  jq -cn --arg cwd "${SRC_PROJECT}" --arg cmd "python3 ${SRC_PROJECT}/hello.py" \
    '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", name:"Bash", input:{command:$cmd}}]}, cwd:$cwd}' \
    >> "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl"

  # Line 5: tool result with stdout containing paths
  jq -cn --arg cwd "${SRC_PROJECT}" --arg stdout "Running ${SRC_PROJECT}/hello.py\nhello" \
    '{type:"tool_result", tool_name:"Bash", result:{stdout:$stdout, exit_code:0}, cwd:$cwd}' \
    >> "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl"

  # Line 6: assistant message with Read tool referencing file_path
  jq -cn --arg cwd "${SRC_PROJECT}" --arg fp "${SRC_PROJECT}/utils.py" \
    '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", name:"Read", input:{file_path:$fp}}]}, cwd:$cwd}' \
    >> "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl"

  # Line 7: tool result with content containing file listing with paths
  jq -cn --arg cwd "${SRC_PROJECT}" \
    --arg content "${SRC_PROJECT}/hello.py\n${SRC_PROJECT}/utils.py\n${SRC_PROJECT}/README.md" \
    '{type:"tool_result", tool_name:"Bash", result:{stdout:$content, exit_code:0}, cwd:$cwd}' \
    >> "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl"

  # Line 8: tool result with persistedOutputPath (inside .claude dir)
  jq -cn --arg cwd "${SRC_PROJECT}" \
    --arg pop "${SRC_HOME}/.claude/projects/${SRC_ENCODED}/${SESSION_ID}/tool-results/abc123.txt" \
    '{type:"tool_result", tool_name:"Bash", result:{stdout:"long output"}, persistedOutputPath:$pop, cwd:$cwd}' \
    >> "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl"

  # Line 9: assistant text message referencing paths in content string
  jq -cn --arg cwd "${SRC_PROJECT}" \
    --arg content "I created the file at ${SRC_PROJECT}/hello.py and it works." \
    '{type:"assistant", message:{role:"assistant", content:$content}, cwd:$cwd}' \
    >> "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl"

  # Line 10: human message with no path references (control — should not change)
  jq -cn --arg cwd "${SRC_PROJECT}" \
    '{type:"human", message:{role:"user", content:"looks good, thanks!"}, cwd:$cwd}' \
    >> "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}.jsonl"

  # -- Second session JSONL (minimal, for multi-session test) --
  jq -cn --arg cwd "${SRC_PROJECT}" \
    '{type:"human", message:{role:"user", content:"add unit tests"}, cwd:$cwd}' \
    > "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID_2}.jsonl"

  jq -cn --arg cwd "${SRC_PROJECT}" --arg fp "${SRC_PROJECT}/test_hello.py" \
    '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", name:"Write", input:{file_path:$fp, content:"import hello"}}]}, cwd:$cwd}' \
    >> "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID_2}.jsonl"

  # -- Subagent directory --
  mkdir -p "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}/subagents"
  jq -cn --arg cwd "${SRC_PROJECT}" --arg fp "${SRC_PROJECT}/hello.py" \
    '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", name:"Read", input:{file_path:$fp}}]}, cwd:$cwd}' \
    > "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}/subagents/sub1.jsonl"

  # -- Tool results directory --
  mkdir -p "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}/tool-results"
  echo "some cached output from ${SRC_PROJECT}/hello.py" \
    > "${STATE_DIR}/projects/${SRC_ENCODED}/${SESSION_ID}/tool-results/abc123.txt"

  # -- Optional dirs keyed by session ID --
  mkdir -p "${STATE_DIR}/file-history/${SESSION_ID}"
  echo '{"file":"hello.py","path":"'"${SRC_PROJECT}/hello.py"'"}' \
    > "${STATE_DIR}/file-history/${SESSION_ID}/hello.py.json"

  mkdir -p "${STATE_DIR}/tasks/${SESSION_ID}"
  echo '{"task":"create file","cwd":"'"${SRC_PROJECT}"'"}' \
    > "${STATE_DIR}/tasks/${SESSION_ID}/task1.json"

  # -- metadata.json --
  cat > "${STATE_DIR}/metadata.json" << METAEOF
{
  "source_path": "${SRC_PROJECT}",
  "encoded_path": "${SRC_ENCODED}",
  "source_user": "${SRC_USER}",
  "pushed_at": "2026-03-14T00:00:00Z",
  "session_id": "${SESSION_ID_2}",
  "session_count": 2,
  "claude_version": "2.1.76 (Claude Code)"
}
METAEOF

  log "Synthetic state repo created with $(find "${STATE_DIR}" -type f | wc -l) files"
}

# ==========================================================================
# TEST CASES
# ==========================================================================

# ---------- TC1: Encoded directory is renamed ----------
test_encoded_dir_renamed() {
  log ""
  log "--- TC1: Encoded directory is renamed ---"

  if [[ -d "${CLAUDE_DIR}/projects/${DST_ENCODED}" ]]; then
    pass "TC1: Directory renamed from ${SRC_ENCODED} to ${DST_ENCODED}"
  else
    fail "TC1: Expected directory ${CLAUDE_DIR}/projects/${DST_ENCODED} not found"
    if [[ -d "${CLAUDE_DIR}/projects/${SRC_ENCODED}" ]]; then
      log "  Old directory ${SRC_ENCODED} still exists (not renamed)"
    fi
  fi
}

# ---------- TC2: sessions-index.json — fullPath rewritten ----------
test_sessions_index_fullpath() {
  log ""
  log "--- TC2: sessions-index.json fullPath rewritten ---"

  local INDEX="${CLAUDE_DIR}/projects/${DST_ENCODED}/sessions-index.json"
  if [[ ! -f "${INDEX}" ]]; then
    fail "TC2: sessions-index.json not found at expected path"
    return
  fi

  local OLD_REFS
  OLD_REFS=$(jq -r '.entries[].fullPath' "${INDEX}" | grep -c "${SRC_HOME}" || true)
  local NEW_REFS
  NEW_REFS=$(jq -r '.entries[].fullPath' "${INDEX}" | grep -c "${DST_HOME}" || true)

  if [[ ${OLD_REFS} -eq 0 && ${NEW_REFS} -gt 0 ]]; then
    pass "TC2: fullPath rewritten (${NEW_REFS} entries point to ${DST_HOME})"
  else
    fail "TC2: fullPath not rewritten (old refs: ${OLD_REFS}, new refs: ${NEW_REFS})"
    jq -r '.entries[].fullPath' "${INDEX}" | while read -r p; do log "  fullPath: ${p}"; done
  fi
}

# ---------- TC3: sessions-index.json — projectPath rewritten ----------
test_sessions_index_projectpath() {
  log ""
  log "--- TC3: sessions-index.json projectPath rewritten ---"

  local INDEX="${CLAUDE_DIR}/projects/${DST_ENCODED}/sessions-index.json"
  [[ -f "${INDEX}" ]] || { fail "TC3: sessions-index.json not found"; return; }

  local OLD_REFS
  OLD_REFS=$(jq -r '.entries[].projectPath' "${INDEX}" | grep -c "${SRC_PROJECT}" || true)
  local NEW_REFS
  NEW_REFS=$(jq -r '.entries[].projectPath' "${INDEX}" | grep -c "${DST_PROJECT}" || true)

  if [[ ${OLD_REFS} -eq 0 && ${NEW_REFS} -gt 0 ]]; then
    pass "TC3: projectPath rewritten (${NEW_REFS} entries point to ${DST_PROJECT})"
  else
    fail "TC3: projectPath not rewritten (old refs: ${OLD_REFS}, new refs: ${NEW_REFS})"
  fi
}

# ---------- TC4: sessions-index.json — originalPath rewritten (if present) ----------
test_sessions_index_originalpath() {
  log ""
  log "--- TC4: sessions-index.json originalPath rewritten ---"

  local INDEX="${CLAUDE_DIR}/projects/${DST_ENCODED}/sessions-index.json"
  [[ -f "${INDEX}" ]] || { fail "TC4: sessions-index.json not found"; return; }

  local HAS_ORIG
  HAS_ORIG=$(jq 'has("originalPath")' "${INDEX}")
  if [[ "${HAS_ORIG}" == "false" ]]; then
    skip "TC4: No originalPath field in sessions-index.json"
    return
  fi

  local ORIG
  ORIG=$(jq -r '.originalPath' "${INDEX}")
  if [[ "${ORIG}" == "${DST_PROJECT}" ]]; then
    pass "TC4: originalPath rewritten to ${DST_PROJECT}"
  elif [[ "${ORIG}" == "${SRC_PROJECT}" ]]; then
    fail "TC4: originalPath still has source path ${SRC_PROJECT}"
  else
    fail "TC4: originalPath has unexpected value: ${ORIG}"
  fi
}

# ---------- TC5: JSONL — cwd field rewritten in all lines ----------
test_jsonl_cwd() {
  log ""
  log "--- TC5: JSONL cwd field rewritten ---"

  local JSONL="${CLAUDE_DIR}/projects/${DST_ENCODED}/${SESSION_ID}.jsonl"
  [[ -f "${JSONL}" ]] || { fail "TC5: JSONL not found at expected path"; return; }

  local OLD_CWD
  OLD_CWD=$(jq -r 'select(.cwd) | .cwd' "${JSONL}" | grep -c "${SRC_PROJECT}" || true)
  local NEW_CWD
  NEW_CWD=$(jq -r 'select(.cwd) | .cwd' "${JSONL}" | grep -c "${DST_PROJECT}" || true)

  if [[ ${OLD_CWD} -eq 0 && ${NEW_CWD} -gt 0 ]]; then
    pass "TC5: cwd rewritten in all ${NEW_CWD} lines"
  else
    fail "TC5: cwd not fully rewritten (old: ${OLD_CWD}, new: ${NEW_CWD})"
  fi
}

# ---------- TC6: JSONL — file_path (snake_case) rewritten ----------
test_jsonl_file_path() {
  log ""
  log "--- TC6: JSONL file_path rewritten ---"

  local JSONL="${CLAUDE_DIR}/projects/${DST_ENCODED}/${SESSION_ID}.jsonl"
  [[ -f "${JSONL}" ]] || { fail "TC6: JSONL not found"; return; }

  local OLD_FP
  OLD_FP=$(grep -oE "\"file_path\":\s*\"${SRC_PROJECT}[^\"]*\"" "${JSONL}" | wc -l || true)
  local NEW_FP
  NEW_FP=$(grep -oE "\"file_path\":\s*\"${DST_PROJECT}[^\"]*\"" "${JSONL}" | wc -l || true)

  if [[ ${OLD_FP} -eq 0 && ${NEW_FP} -gt 0 ]]; then
    pass "TC6: file_path rewritten (${NEW_FP} occurrences)"
  elif [[ ${OLD_FP} -eq 0 && ${NEW_FP} -eq 0 ]]; then
    skip "TC6: No file_path fields found"
  else
    fail "TC6: file_path not fully rewritten (old: ${OLD_FP}, new: ${NEW_FP})"
  fi
}

# ---------- TC7: JSONL — filePath (camelCase) rewritten ----------
test_jsonl_filepath_camel() {
  log ""
  log "--- TC7: JSONL filePath (camelCase) rewritten ---"

  local JSONL="${CLAUDE_DIR}/projects/${DST_ENCODED}/${SESSION_ID}.jsonl"
  [[ -f "${JSONL}" ]] || { fail "TC7: JSONL not found"; return; }

  local OLD_FP
  OLD_FP=$(grep -oE "\"filePath\":\s*\"${SRC_PROJECT}[^\"]*\"" "${JSONL}" | wc -l || true)
  local NEW_FP
  NEW_FP=$(grep -oE "\"filePath\":\s*\"${DST_PROJECT}[^\"]*\"" "${JSONL}" | wc -l || true)

  if [[ ${OLD_FP} -eq 0 && ${NEW_FP} -gt 0 ]]; then
    pass "TC7: filePath rewritten (${NEW_FP} occurrences)"
  elif [[ ${OLD_FP} -eq 0 && ${NEW_FP} -eq 0 ]]; then
    skip "TC7: No filePath fields found"
  else
    fail "TC7: filePath not fully rewritten (old: ${OLD_FP}, new: ${NEW_FP})"
  fi
}

# ---------- TC8: JSONL — persistedOutputPath rewritten ----------
test_jsonl_persisted_output_path() {
  log ""
  log "--- TC8: JSONL persistedOutputPath rewritten ---"

  local JSONL="${CLAUDE_DIR}/projects/${DST_ENCODED}/${SESSION_ID}.jsonl"
  [[ -f "${JSONL}" ]] || { fail "TC8: JSONL not found"; return; }

  # persistedOutputPath contains the .claude/projects/<encoded>/ path
  local OLD_POP
  OLD_POP=$(jq -r 'select(.persistedOutputPath) | .persistedOutputPath' "${JSONL}" 2>/dev/null | grep -c "${SRC_HOME}" || true)
  local NEW_POP
  NEW_POP=$(jq -r 'select(.persistedOutputPath) | .persistedOutputPath' "${JSONL}" 2>/dev/null | grep -c "${DST_HOME}" || true)

  if [[ ${NEW_POP} -gt 0 ]]; then
    local STILL_OLD
    STILL_OLD=$(jq -r 'select(.persistedOutputPath) | .persistedOutputPath' "${JSONL}" | grep -c "${SRC_HOME}" || true)
    if [[ ${STILL_OLD} -eq 0 ]]; then
      pass "TC8: persistedOutputPath rewritten (${NEW_POP} occurrences)"
    else
      fail "TC8: persistedOutputPath partially rewritten (old: ${STILL_OLD}, new: ${NEW_POP})"
    fi
  else
    local HAS_POP
    HAS_POP=$(jq -r 'select(.persistedOutputPath)' "${JSONL}" | wc -l || true)
    if [[ ${HAS_POP} -eq 0 ]]; then
      skip "TC8: No persistedOutputPath fields found"
    else
      fail "TC8: persistedOutputPath not rewritten"
    fi
  fi
}

# ---------- TC9: JSONL — freeform content paths rewritten ----------
test_jsonl_freeform_content() {
  log ""
  log "--- TC9: JSONL freeform content paths rewritten ---"

  local JSONL="${CLAUDE_DIR}/projects/${DST_ENCODED}/${SESSION_ID}.jsonl"
  [[ -f "${JSONL}" ]] || { fail "TC9: JSONL not found"; return; }

  # Check for any remaining source path references in the entire file
  local OLD_REFS
  OLD_REFS=$(grep -c "${SRC_PROJECT}" "${JSONL}" || true)
  local OLD_HOME_REFS
  OLD_HOME_REFS=$(grep -c "${SRC_HOME}" "${JSONL}" || true)

  if [[ ${OLD_REFS} -eq 0 && ${OLD_HOME_REFS} -eq 0 ]]; then
    pass "TC9: No source path references remain in JSONL (project: 0, home: 0)"
  else
    fail "TC9: Source paths still present (project refs: ${OLD_REFS}, home refs: ${OLD_HOME_REFS})"
    grep "${SRC_PROJECT}\|${SRC_HOME}" "${JSONL}" | head -5 | while read -r line; do
      log "  $(echo "${line}" | cut -c1-120)..."
    done
  fi
}

# ---------- TC10: Subagent JSONL paths rewritten ----------
test_subagent_paths() {
  log ""
  log "--- TC10: Subagent JSONL paths rewritten ---"

  local SUB_DIR="${CLAUDE_DIR}/projects/${DST_ENCODED}/${SESSION_ID}/subagents"
  if [[ ! -d "${SUB_DIR}" ]]; then
    skip "TC10: No subagents directory"
    return
  fi

  local OLD_REFS=0
  for jsonl in "${SUB_DIR}"/*.jsonl; do
    [[ -f "${jsonl}" ]] || continue
    OLD_REFS=$((OLD_REFS + $(grep -c "${SRC_PROJECT}\|${SRC_HOME}" "${jsonl}" || true)))
  done

  if [[ ${OLD_REFS} -eq 0 ]]; then
    pass "TC10: No source paths in subagent JSONL files"
  else
    fail "TC10: ${OLD_REFS} source path references remain in subagent files"
  fi
}

# ---------- TC11: Tool results text files have paths rewritten ----------
test_tool_results_paths() {
  log ""
  log "--- TC11: Tool results paths rewritten ---"

  local TR_DIR="${CLAUDE_DIR}/projects/${DST_ENCODED}/${SESSION_ID}/tool-results"
  if [[ ! -d "${TR_DIR}" ]]; then
    skip "TC11: No tool-results directory"
    return
  fi

  local OLD_REFS=0
  for f in "${TR_DIR}"/*; do
    [[ -f "${f}" ]] || continue
    OLD_REFS=$((OLD_REFS + $(grep -c "${SRC_PROJECT}\|${SRC_HOME}" "${f}" || true)))
  done

  if [[ ${OLD_REFS} -eq 0 ]]; then
    pass "TC11: No source paths in tool-results files"
  else
    fail "TC11: ${OLD_REFS} source path references remain in tool-results"
  fi
}

# ---------- TC12: file-history paths rewritten ----------
test_file_history_paths() {
  log ""
  log "--- TC12: file-history paths rewritten ---"

  local FH_DIR="${CLAUDE_DIR}/file-history/${SESSION_ID}"
  if [[ ! -d "${FH_DIR}" ]]; then
    skip "TC12: No file-history directory for session"
    return
  fi

  local OLD_REFS=0
  for f in "${FH_DIR}"/*; do
    [[ -f "${f}" ]] || continue
    OLD_REFS=$((OLD_REFS + $(grep -c "${SRC_PROJECT}\|${SRC_HOME}" "${f}" || true)))
  done

  if [[ ${OLD_REFS} -eq 0 ]]; then
    pass "TC12: No source paths in file-history"
  else
    fail "TC12: ${OLD_REFS} source path references remain in file-history"
  fi
}

# ---------- TC13: tasks paths rewritten ----------
test_tasks_paths() {
  log ""
  log "--- TC13: tasks directory paths rewritten ---"

  local TASKS_DIR="${CLAUDE_DIR}/tasks/${SESSION_ID}"
  if [[ ! -d "${TASKS_DIR}" ]]; then
    skip "TC13: No tasks directory for session"
    return
  fi

  local OLD_REFS=0
  for f in "${TASKS_DIR}"/*; do
    [[ -f "${f}" ]] || continue
    OLD_REFS=$((OLD_REFS + $(grep -c "${SRC_PROJECT}\|${SRC_HOME}" "${f}" || true)))
  done

  if [[ ${OLD_REFS} -eq 0 ]]; then
    pass "TC13: No source paths in tasks"
  else
    fail "TC13: ${OLD_REFS} source path references remain in tasks"
  fi
}

# ---------- TC14: metadata.json paths rewritten ----------
test_metadata_paths() {
  log ""
  log "--- TC14: metadata.json paths rewritten ---"

  local META="${CLAUDE_DIR}/metadata.json"
  if [[ ! -f "${META}" ]]; then
    # metadata.json might not be copied to ~/.claude, check if it exists
    skip "TC14: No metadata.json in restored state"
    return
  fi

  local SRC_PATH
  SRC_PATH=$(jq -r '.source_path' "${META}")
  local ENC_PATH
  ENC_PATH=$(jq -r '.encoded_path' "${META}")

  if [[ "${SRC_PATH}" == "${DST_PROJECT}" && "${ENC_PATH}" == "${DST_ENCODED}" ]]; then
    pass "TC14: metadata.json paths updated to target"
  else
    fail "TC14: metadata.json not updated (source_path: ${SRC_PATH}, encoded_path: ${ENC_PATH})"
  fi
}

# ---------- TC15: JSONL remains valid JSON after rewriting ----------
test_jsonl_still_valid() {
  log ""
  log "--- TC15: JSONL still valid JSON after rewrite ---"

  local ALL_VALID=true
  for jsonl in "${CLAUDE_DIR}/projects/${DST_ENCODED}"/*.jsonl; do
    [[ -f "${jsonl}" ]] || continue
    local BASENAME
    BASENAME=$(basename "${jsonl}")
    local BAD_LINES=0
    local TOTAL_LINES
    TOTAL_LINES=$(wc -l < "${jsonl}")

    while IFS= read -r line; do
      if [[ -n "${line}" ]] && ! echo "${line}" | jq -e . > /dev/null 2>&1; then
        BAD_LINES=$((BAD_LINES + 1))
      fi
    done < "${jsonl}"

    if [[ ${BAD_LINES} -eq 0 ]]; then
      pass "TC15: ${BASENAME} — all ${TOTAL_LINES} lines valid JSON after rewrite"
    else
      fail "TC15: ${BASENAME} — ${BAD_LINES}/${TOTAL_LINES} lines invalid JSON after rewrite"
      ALL_VALID=false
    fi
  done
}

# ---------- TC16: Second session JSONL also rewritten ----------
test_multi_session_rewrite() {
  log ""
  log "--- TC16: Multiple sessions all rewritten ---"

  local JSONL2="${CLAUDE_DIR}/projects/${DST_ENCODED}/${SESSION_ID_2}.jsonl"
  if [[ ! -f "${JSONL2}" ]]; then
    fail "TC16: Second session JSONL not found"
    return
  fi

  local OLD_REFS
  OLD_REFS=$(grep -c "${SRC_PROJECT}\|${SRC_HOME}" "${JSONL2}" || true)

  if [[ ${OLD_REFS} -eq 0 ]]; then
    pass "TC16: Second session has no source path references"
  else
    fail "TC16: Second session still has ${OLD_REFS} source path references"
  fi
}

# ---------- TC17: Non-path content preserved ----------
test_non_path_content_preserved() {
  log ""
  log "--- TC17: Non-path content preserved (no collateral damage) ---"

  local JSONL="${CLAUDE_DIR}/projects/${DST_ENCODED}/${SESSION_ID}.jsonl"
  [[ -f "${JSONL}" ]] || { fail "TC17: JSONL not found"; return; }

  # The "looks good, thanks!" message should be unchanged
  local PRESERVED
  PRESERVED=$(jq -r 'select(.message.content == "looks good, thanks!") | .message.content' "${JSONL}" | wc -l || true)

  if [[ ${PRESERVED} -gt 0 ]]; then
    pass "TC17: Non-path content preserved unchanged"
  else
    fail "TC17: Non-path content was modified or lost"
  fi
}

# ---------- TC18: No source encoded path in any filename ----------
test_no_source_encoded_in_filenames() {
  log ""
  log "--- TC18: No source encoded path in restored filenames ---"

  local OLD_DIRS
  OLD_DIRS=$(find "${CLAUDE_DIR}" -type d -name "${SRC_ENCODED}" 2>/dev/null | wc -l || true)
  local OLD_FILES
  OLD_FILES=$(find "${CLAUDE_DIR}" -type f -path "*${SRC_ENCODED}*" 2>/dev/null | wc -l || true)

  if [[ ${OLD_DIRS} -eq 0 && ${OLD_FILES} -eq 0 ]]; then
    pass "TC18: No files or directories use source encoded path"
  else
    fail "TC18: Source encoded path still in filesystem (dirs: ${OLD_DIRS}, files: ${OLD_FILES})"
    find "${CLAUDE_DIR}" -path "*${SRC_ENCODED}*" | head -5 | while read -r p; do log "  ${p}"; done
  fi
}

# ==========================================================================
# MAIN
# ==========================================================================

log "========================================="
log "Path Rewrite Test Suite"
log "========================================="

# Step 1: Create synthetic state repo
log ""
log "Setting up synthetic state repo..."
create_state_repo

# Step 2: Create a local git repo from the state dir and run cc-pull.sh --rewrite-paths
log ""
log "Creating local git state repo from synthetic data..."

GIT_STATE="${WORK_DIR}/git-state"
mkdir -p "${GIT_STATE}"
git -C "${GIT_STATE}" init --bare -q

# Create a working copy, commit the state data
GIT_WORK="${WORK_DIR}/git-work"
git clone -q "${GIT_STATE}" "${GIT_WORK}"
cp -r "${STATE_DIR}"/* "${GIT_WORK}/"
git -C "${GIT_WORK}" add -A
git -C "${GIT_WORK}" -c user.name="test" -c user.email="test@test" commit -q -m "state"
git -C "${GIT_WORK}" push -q origin main 2>/dev/null || git -C "${GIT_WORK}" push -q origin master 2>/dev/null

# Create a fake project dir at DST_PROJECT (cc-pull.sh validates it exists)
mkdir -p "${DST_PROJECT}"

# Override HOME so cc-pull.sh restores to our test CLAUDE_DIR
# Find cc-pull.sh: check CC_PULL_SH env var, then sibling scripts/ dir, then /tmp
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CC_PULL="${CC_PULL_SH:-}"
if [[ -z "${CC_PULL}" ]]; then
  if [[ -f "${SCRIPT_DIR}/../scripts/cc-pull.sh" ]]; then
    CC_PULL="${SCRIPT_DIR}/../scripts/cc-pull.sh"
  elif [[ -f "/tmp/cc-pull.sh" ]]; then
    CC_PULL="/tmp/cc-pull.sh"
  else
    echo "ERROR: Cannot find cc-pull.sh. Set CC_PULL_SH env var." >&2
    exit 2
  fi
fi

log "Running: cc-pull.sh --rewrite-paths ${DST_PROJECT} ${GIT_STATE}"
log "  (using ${CC_PULL})"
HOME="${DST_HOME}" \
  bash "${CC_PULL}" --rewrite-paths "${DST_PROJECT}" "${GIT_STATE}"

# Point CLAUDE_DIR to where cc-pull.sh actually restored
CLAUDE_DIR="${DST_HOME}/.claude"

log "Pull with path rewrite complete."

# Step 3: Run all test cases
test_encoded_dir_renamed
test_sessions_index_fullpath
test_sessions_index_projectpath
test_sessions_index_originalpath
test_jsonl_cwd
test_jsonl_file_path
test_jsonl_filepath_camel
test_jsonl_persisted_output_path
test_jsonl_freeform_content
test_subagent_paths
test_tool_results_paths
test_file_history_paths
test_tasks_paths
test_metadata_paths
test_jsonl_still_valid
test_multi_session_rewrite
test_non_path_content_preserved
test_no_source_encoded_in_filenames

# ---------- summary ----------
log ""
log "========================================="
log "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
log "========================================="

if [[ ${FAIL_COUNT} -gt 0 ]]; then
  exit 1
else
  exit 0
fi
