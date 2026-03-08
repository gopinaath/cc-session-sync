#!/usr/bin/env bash
# Push Claude Code session state from the current machine to a GitHub repo.
#
# Usage:
#   cc-push.sh <project-dir> <state-repo-url>
#   cc-push.sh --dry-run <project-dir> <state-repo-url>
#
# Example:
#   cc-push.sh /home/ubuntu/test-project git@github.com:user/cc-sync-test-state.git

set -euo pipefail

# ---------- flags ----------
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  shift
fi

PROJECT_DIR="${1:?Usage: cc-push.sh [--dry-run] <project-dir> <state-repo-url>}"
STATE_REPO="${2:?Usage: cc-push.sh [--dry-run] <project-dir> <state-repo-url>}"

CLAUDE_DIR="${HOME}/.claude"

# ---------- helpers ----------
log()  { echo "[cc-push] $*"; }
die()  { echo "[cc-push] ERROR: $*" >&2; exit 1; }

# ---------- validate ----------
[[ -d "${PROJECT_DIR}" ]] || die "Project directory does not exist: ${PROJECT_DIR}"

# Resolve to absolute path
PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"

# Encode the project path the same way Claude Code does: replace / with -
ENCODED_PATH="${PROJECT_DIR//\//-}"
# Strip leading dash
ENCODED_PATH="${ENCODED_PATH#-}"

SESSION_DIR="${CLAUDE_DIR}/projects/${ENCODED_PATH}"
SESSION_INDEX="${SESSION_DIR}/sessions-index.json"

[[ -f "${SESSION_INDEX}" ]] || die "No sessions-index.json found at ${SESSION_INDEX}"

log "Project directory : ${PROJECT_DIR}"
log "Encoded path      : ${ENCODED_PATH}"
log "Session index     : ${SESSION_INDEX}"

# ---------- read session info ----------
SESSION_COUNT=$(jq 'length' "${SESSION_INDEX}")
LATEST_SESSION=$(jq -r '.[-1].sessionId // .[-1].id // empty' "${SESSION_INDEX}")
log "Sessions found    : ${SESSION_COUNT}"
log "Latest session ID : ${LATEST_SESSION}"

# ---------- stage files ----------
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

log "Staging to: ${STAGING}"

# 1. projects/<encoded-path>/ — session index + JSONL files + subdirectories
STAGE_PROJ="${STAGING}/projects/${ENCODED_PATH}"
mkdir -p "${STAGE_PROJ}"

# Copy sessions-index.json
cp "${SESSION_INDEX}" "${STAGE_PROJ}/"

# Copy all session JSONL files
for jsonl in "${SESSION_DIR}"/*.jsonl; do
  [[ -f "${jsonl}" ]] || continue
  # Validate JSONL: every line must be valid JSON
  if ! jq -e . "${jsonl}" > /dev/null 2>&1; then
    # Try line-by-line validation
    BAD_LINES=0
    LINE_NUM=0
    while IFS= read -r line; do
      LINE_NUM=$((LINE_NUM + 1))
      if [[ -n "${line}" ]] && ! echo "${line}" | jq -e . > /dev/null 2>&1; then
        BAD_LINES=$((BAD_LINES + 1))
        log "WARNING: Invalid JSON at ${jsonl}:${LINE_NUM}"
      fi
    done < "${jsonl}"
    if [[ ${BAD_LINES} -gt 0 ]]; then
      log "WARNING: ${jsonl} has ${BAD_LINES} invalid lines — skipping"
      continue
    fi
  fi
  cp "${jsonl}" "${STAGE_PROJ}/"
done

# Copy per-session subdirectories (subagents/, tool-results/)
for session_dir in "${SESSION_DIR}"/*/; do
  [[ -d "${session_dir}" ]] || continue
  dir_name="$(basename "${session_dir}")"
  # Skip non-session dirs
  [[ "${dir_name}" == "memory" ]] && continue
  cp -r "${session_dir}" "${STAGE_PROJ}/${dir_name}"
done

# 2. Optional dirs keyed by session ID
for top_dir in file-history tasks todos; do
  SRC="${CLAUDE_DIR}/${top_dir}"
  [[ -d "${SRC}" ]] || continue
  # Copy directories that match any session ID in our index
  jq -r '.[].sessionId // .[].id // empty' "${SESSION_INDEX}" | while read -r sid; do
    if [[ -d "${SRC}/${sid}" ]]; then
      mkdir -p "${STAGING}/${top_dir}"
      cp -r "${SRC}/${sid}" "${STAGING}/${top_dir}/${sid}"
    fi
  done
done

# 3. Plans (not session-keyed, just copy the whole dir)
if [[ -d "${CLAUDE_DIR}/plans" ]]; then
  cp -r "${CLAUDE_DIR}/plans" "${STAGING}/plans"
fi

# 4. Generate metadata.json
CLAUDE_VERSION="$(claude --version 2>/dev/null || echo 'unknown')"
cat > "${STAGING}/metadata.json" << METAEOF
{
  "source_path": "${PROJECT_DIR}",
  "encoded_path": "${ENCODED_PATH}",
  "source_user": "$(whoami)",
  "pushed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "session_id": "${LATEST_SESSION}",
  "session_count": ${SESSION_COUNT},
  "claude_version": "${CLAUDE_VERSION}"
}
METAEOF

# ---------- summary ----------
FILE_COUNT=$(find "${STAGING}" -type f | wc -l)
TOTAL_SIZE=$(du -sh "${STAGING}" | cut -f1)

log ""
log "=== Push Summary ==="
log "Files to sync : ${FILE_COUNT}"
log "Total size    : ${TOTAL_SIZE}"
log "Sessions      : ${SESSION_COUNT}"
log "Latest session: ${LATEST_SESSION}"

if [[ "${DRY_RUN}" == true ]]; then
  log ""
  log "[DRY RUN] Files that would be pushed:"
  find "${STAGING}" -type f | sed "s|${STAGING}/|  |"
  log ""
  log "[DRY RUN] No changes made."
  exit 0
fi

# ---------- push to git ----------
REPO_TMP="$(mktemp -d)"
trap 'rm -rf "${STAGING}" "${REPO_TMP}"' EXIT

log ""
log "Cloning state repo..."
if git clone --depth 1 "${STATE_REPO}" "${REPO_TMP}/state" 2>/dev/null; then
  log "Existing repo cloned."
else
  # Repo might be empty — clone without depth
  git clone "${STATE_REPO}" "${REPO_TMP}/state"
fi

# Clear old content (except .git) and copy new staging content
find "${REPO_TMP}/state" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
cp -r "${STAGING}"/* "${REPO_TMP}/state/"

cd "${REPO_TMP}/state"
git add -A

if git diff --cached --quiet; then
  log "No changes to push (state is already up to date)."
  exit 0
fi

git commit -m "cc-push: sync session state $(date -u +%Y-%m-%dT%H:%M:%SZ)

project: ${PROJECT_DIR}
session: ${LATEST_SESSION}
files: ${FILE_COUNT}"

git push

log ""
log "Session state pushed successfully!"
log "To restore on another machine:"
log "  cc-pull.sh ${PROJECT_DIR} ${STATE_REPO}"
