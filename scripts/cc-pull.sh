#!/usr/bin/env bash
# Pull and restore Claude Code session state from a GitHub repo.
#
# Usage:
#   cc-pull.sh <project-dir> <state-repo-url>
#   cc-pull.sh --dry-run <project-dir> <state-repo-url>
#
# Example:
#   cc-pull.sh /home/ubuntu/test-project git@github.com:user/cc-sync-test-state.git

set -euo pipefail

# ---------- flags ----------
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  shift
fi

PROJECT_DIR="${1:?Usage: cc-pull.sh [--dry-run] <project-dir> <state-repo-url>}"
STATE_REPO="${2:?Usage: cc-pull.sh [--dry-run] <project-dir> <state-repo-url>}"

CLAUDE_DIR="${HOME}/.claude"

# ---------- helpers ----------
log()  { echo "[cc-pull] $*"; }
die()  { echo "[cc-pull] ERROR: $*" >&2; exit 1; }

# ---------- validate project dir ----------
[[ -d "${PROJECT_DIR}" ]] || die "Project directory does not exist: ${PROJECT_DIR}
Clone the project repo first, then run cc-pull.sh."

PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"

# ---------- clone state repo ----------
REPO_TMP="$(mktemp -d)"
trap 'rm -rf "${REPO_TMP}"' EXIT

log "Cloning state repo..."
git clone --depth 1 "${STATE_REPO}" "${REPO_TMP}/state"

STATE_DIR="${REPO_TMP}/state"

# ---------- read metadata ----------
[[ -f "${STATE_DIR}/metadata.json" ]] || die "No metadata.json in state repo — was this pushed with cc-push.sh?"

SOURCE_PATH=$(jq -r '.source_path' "${STATE_DIR}/metadata.json")
ENCODED_PATH=$(jq -r '.encoded_path' "${STATE_DIR}/metadata.json")
SESSION_ID=$(jq -r '.session_id' "${STATE_DIR}/metadata.json")
SESSION_COUNT=$(jq -r '.session_count' "${STATE_DIR}/metadata.json")
PUSHED_AT=$(jq -r '.pushed_at' "${STATE_DIR}/metadata.json")
CLAUDE_VERSION=$(jq -r '.claude_version' "${STATE_DIR}/metadata.json")

log "Source path    : ${SOURCE_PATH}"
log "Encoded path   : ${ENCODED_PATH}"
log "Session ID     : ${SESSION_ID}"
log "Session count  : ${SESSION_COUNT}"
log "Pushed at      : ${PUSHED_AT}"
log "Claude version : ${CLAUDE_VERSION}"

# ---------- Phase 1: validate paths match ----------
if [[ "${PROJECT_DIR}" != "${SOURCE_PATH}" ]]; then
  die "Path mismatch!
  Local project dir : ${PROJECT_DIR}
  Source project dir : ${SOURCE_PATH}
Phase 1 requires identical paths on both machines.
Ensure your project is at: ${SOURCE_PATH}"
fi

# ---------- validate session files exist in state repo ----------
SESSION_INDEX="${STATE_DIR}/projects/${ENCODED_PATH}/sessions-index.json"
[[ -f "${SESSION_INDEX}" ]] || die "sessions-index.json not found in state repo at projects/${ENCODED_PATH}/"

if ! jq -e . "${SESSION_INDEX}" > /dev/null 2>&1; then
  die "sessions-index.json is not valid JSON"
fi

# Check that at least one JSONL file exists
JSONL_COUNT=$(find "${STATE_DIR}/projects/${ENCODED_PATH}" -name '*.jsonl' | wc -l)
if [[ ${JSONL_COUNT} -eq 0 ]]; then
  die "No session JSONL files found in state repo"
fi

log "JSONL files    : ${JSONL_COUNT}"

# ---------- summary ----------
log ""
log "=== Pull Summary ==="
log "Will restore to: ${CLAUDE_DIR}/"

# List what will be copied
RESTORE_DIRS=()
for dir in projects file-history tasks todos plans; do
  if [[ -d "${STATE_DIR}/${dir}" ]]; then
    RESTORE_DIRS+=("${dir}")
    log "  ${dir}/"
  fi
done

if [[ "${DRY_RUN}" == true ]]; then
  log ""
  log "[DRY RUN] Files that would be restored:"
  for dir in "${RESTORE_DIRS[@]}"; do
    find "${STATE_DIR}/${dir}" -type f | sed "s|${STATE_DIR}/|  ~/.claude/|"
  done
  log ""
  log "[DRY RUN] No changes made."
  exit 0
fi

# ---------- backup existing state ----------
DEST_SESSION_DIR="${CLAUDE_DIR}/projects/${ENCODED_PATH}"
if [[ -d "${DEST_SESSION_DIR}" ]]; then
  BACKUP_DIR="${CLAUDE_DIR}/backups/${ENCODED_PATH}-$(date +%Y%m%d-%H%M%S)"
  log ""
  log "Backing up existing session state to: ${BACKUP_DIR}"
  mkdir -p "$(dirname "${BACKUP_DIR}")"
  cp -r "${DEST_SESSION_DIR}" "${BACKUP_DIR}"
fi

# ---------- restore files ----------
log ""
log "Restoring session state..."

mkdir -p "${CLAUDE_DIR}"

for dir in "${RESTORE_DIRS[@]}"; do
  SRC="${STATE_DIR}/${dir}"
  DEST="${CLAUDE_DIR}/${dir}"

  if [[ "${dir}" == "projects" ]]; then
    # Only copy the specific encoded-path subdirectory
    mkdir -p "${DEST}/${ENCODED_PATH}"
    cp -r "${SRC}/${ENCODED_PATH}/"* "${DEST}/${ENCODED_PATH}/"
  else
    mkdir -p "${DEST}"
    cp -r "${SRC}/"* "${DEST}/"
  fi

  log "  Restored: ${dir}/"
done

# ---------- verify ----------
RESTORED_INDEX="${CLAUDE_DIR}/projects/${ENCODED_PATH}/sessions-index.json"
if [[ ! -f "${RESTORED_INDEX}" ]]; then
  die "Verification failed: sessions-index.json not found after restore"
fi

if ! jq -e . "${RESTORED_INDEX}" > /dev/null 2>&1; then
  die "Verification failed: sessions-index.json is not valid JSON after restore"
fi

RESTORED_JSONL_COUNT=$(find "${CLAUDE_DIR}/projects/${ENCODED_PATH}" -name '*.jsonl' | wc -l)

log ""
log "=== Verification ==="
log "sessions-index.json : OK (valid JSON)"
log "JSONL files restored: ${RESTORED_JSONL_COUNT}"
log ""
log "Session restored! Run:"
log "  cd ${PROJECT_DIR} && claude --continue"
