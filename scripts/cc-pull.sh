#!/usr/bin/env bash
# Pull and restore Claude Code session state from a GitHub repo.
#
# Usage:
#   cc-pull.sh [--dry-run] [--rewrite-paths] <project-dir> <state-repo-url>
#
# Options:
#   --dry-run         Show what would be restored without modifying filesystem
#   --rewrite-paths   Rewrite absolute paths in session data to match local project dir.
#                     Use when the project path or username differs between machines.
#                     Example: state was pushed from /home/alice/project, pulling to /home/bob/project
#
# Example:
#   cc-pull.sh /home/ubuntu/test-project git@github.com:user/cc-sync-test-state.git
#   cc-pull.sh --rewrite-paths /home/bob/project git@github.com:user/cc-sync-test-state.git

set -euo pipefail

# ---------- flags ----------
DRY_RUN=false
REWRITE_PATHS=false
while [[ "${1:-}" == --* ]]; do
  case "${1}" in
    --dry-run)       DRY_RUN=true; shift ;;
    --rewrite-paths) REWRITE_PATHS=true; shift ;;
    *) echo "[cc-pull] ERROR: Unknown flag: $1" >&2; exit 1 ;;
  esac
done

PROJECT_DIR="${1:?Usage: cc-pull.sh [--dry-run] [--rewrite-paths] <project-dir> <state-repo-url>}"
STATE_REPO="${2:?Usage: cc-pull.sh [--dry-run] [--rewrite-paths] <project-dir> <state-repo-url>}"

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

# ---------- validate paths ----------
if [[ "${PROJECT_DIR}" != "${SOURCE_PATH}" ]]; then
  if [[ "${REWRITE_PATHS}" == true ]]; then
    log ""
    log "Path mismatch detected — rewrite mode enabled:"
    log "  Source: ${SOURCE_PATH}"
    log "  Target: ${PROJECT_DIR}"

    # Compute source home dir from fullPath in sessions-index.json
    # fullPath looks like: /home/alice/.claude/projects/...
    SRC_CLAUDE_HOME=$(jq -r '.entries[0].fullPath // empty' \
      "${STATE_DIR}/projects/${ENCODED_PATH}/sessions-index.json" 2>/dev/null \
      | sed 's|/.claude/.*||')
    if [[ -z "${SRC_CLAUDE_HOME}" ]]; then
      # Fallback: infer from source_path (take first two path components for /home/user)
      SRC_CLAUDE_HOME=$(echo "${SOURCE_PATH}" | grep -oP '^/home/[^/]+')
    fi

    DST_ENCODED="${PROJECT_DIR//\//-}"
    log "  Source home   : ${SRC_CLAUDE_HOME}"
    log "  Target home   : ${HOME}"
    log "  Source encoded : ${ENCODED_PATH}"
    log "  Target encoded : ${DST_ENCODED}"
  else
    die "Path mismatch!
  Local project dir : ${PROJECT_DIR}
  Source project dir : ${SOURCE_PATH}
Paths must match, or use --rewrite-paths to rewrite session data.
  Example: cc-pull.sh --rewrite-paths ${PROJECT_DIR} ${STATE_REPO}"
  fi
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

# ---------- determine destination encoded path ----------
# When rewriting paths, the destination encoded path differs from source
if [[ "${REWRITE_PATHS}" == true && -n "${DST_ENCODED:-}" ]]; then
  RESTORE_ENCODED="${DST_ENCODED}"
else
  RESTORE_ENCODED="${ENCODED_PATH}"
fi

# ---------- backup existing state ----------
DEST_SESSION_DIR="${CLAUDE_DIR}/projects/${RESTORE_ENCODED}"
if [[ -d "${DEST_SESSION_DIR}" ]]; then
  BACKUP_DIR="${CLAUDE_DIR}/backups/${RESTORE_ENCODED}-$(date +%Y%m%d-%H%M%S)"
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
    # Copy to the destination encoded path (may differ from source when rewriting)
    mkdir -p "${DEST}/${RESTORE_ENCODED}"
    cp -r "${SRC}/${ENCODED_PATH}/"* "${DEST}/${RESTORE_ENCODED}/"
  else
    mkdir -p "${DEST}"
    cp -r "${SRC}/"* "${DEST}/"
  fi

  log "  Restored: ${dir}/"
done

# ---------- rewrite paths (Phase 2) ----------
if [[ "${REWRITE_PATHS}" == true && "${PROJECT_DIR}" != "${SOURCE_PATH}" ]]; then
  log ""
  log "Rewriting paths in session data..."

  # Rewrite all text files under the restored directories
  find "${CLAUDE_DIR}" -type f \( -name '*.jsonl' -o -name '*.json' -o -name '*.txt' \) \
    | while read -r f; do
      CHANGED=false

      # 1. Rewrite project path: /home/alice/project → /home/bob/project
      if grep -qF -- "${SOURCE_PATH}" "${f}" 2>/dev/null; then
        sed -i "s|${SOURCE_PATH}|${PROJECT_DIR}|g" "${f}"
        CHANGED=true
      fi

      # 2. Rewrite home directory: /home/alice → /home/bob (for .claude paths)
      if [[ -n "${SRC_CLAUDE_HOME}" && "${SRC_CLAUDE_HOME}" != "${HOME}" ]]; then
        if grep -qF -- "${SRC_CLAUDE_HOME}" "${f}" 2>/dev/null; then
          sed -i "s|${SRC_CLAUDE_HOME}|${HOME}|g" "${f}"
          CHANGED=true
        fi
      fi

      # 3. Rewrite encoded path: -home-alice-project → -home-bob-project
      #    NOTE: grep -qF -- is critical here because encoded paths start with "-"
      if [[ "${ENCODED_PATH}" != "${RESTORE_ENCODED}" ]]; then
        if grep -qF -- "${ENCODED_PATH}" "${f}" 2>/dev/null; then
          sed -i "s|${ENCODED_PATH}|${RESTORE_ENCODED}|g" "${f}"
          CHANGED=true
        fi
      fi

      if [[ "${CHANGED}" == true ]]; then
        log "  Rewrote: $(basename "${f}")"
      fi
    done

  # Verify JSONL is still valid JSON after rewriting
  REWRITE_ERRORS=0
  for jsonl in "${CLAUDE_DIR}/projects/${RESTORE_ENCODED}"/*.jsonl; do
    [[ -f "${jsonl}" ]] || continue
    while IFS= read -r line; do
      if [[ -n "${line}" ]] && ! echo "${line}" | jq -e . > /dev/null 2>&1; then
        REWRITE_ERRORS=$((REWRITE_ERRORS + 1))
      fi
    done < "${jsonl}"
  done
  if [[ ${REWRITE_ERRORS} -gt 0 ]]; then
    log "WARNING: ${REWRITE_ERRORS} JSONL lines became invalid after path rewriting"
  else
    log "  Path rewrite complete — all JSONL lines still valid JSON"
  fi
fi

# ---------- verify ----------
RESTORED_INDEX="${CLAUDE_DIR}/projects/${RESTORE_ENCODED}/sessions-index.json"
if [[ ! -f "${RESTORED_INDEX}" ]]; then
  die "Verification failed: sessions-index.json not found after restore"
fi

if ! jq -e . "${RESTORED_INDEX}" > /dev/null 2>&1; then
  die "Verification failed: sessions-index.json is not valid JSON after restore"
fi

RESTORED_JSONL_COUNT=$(find "${CLAUDE_DIR}/projects/${RESTORE_ENCODED}" -name '*.jsonl' | wc -l)

log ""
log "=== Verification ==="
log "sessions-index.json : OK (valid JSON)"
log "JSONL files restored: ${RESTORED_JSONL_COUNT}"
if [[ "${REWRITE_PATHS}" == true && "${PROJECT_DIR}" != "${SOURCE_PATH}" ]]; then
  log "Path rewrite       : ${SOURCE_PATH} → ${PROJECT_DIR}"
fi
log ""
log "Session restored! Run:"
log "  cd ${PROJECT_DIR} && claude --continue"
