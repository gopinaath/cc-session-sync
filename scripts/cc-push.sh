#!/usr/bin/env bash
# Push Claude Code session state from the current machine to a GitHub repo.
#
# Usage:
#   cc-push.sh [--dry-run] [--no-scan] <project-dir> <state-repo-url>
#
# Example:
#   cc-push.sh /home/ubuntu/test-project git@github.com:user/cc-sync-test-state.git

set -euo pipefail

# ---------- helpers ----------
log()  { echo "[cc-push] $*"; }
die()  { echo "[cc-push] ERROR: $*" >&2; exit 1; }

# ---------- flags ----------
DRY_RUN=false
NO_SCAN=false
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --no-scan) NO_SCAN=true; shift ;;
    *) die "Unknown flag: $1" ;;
  esac
done

PROJECT_DIR="${1:?Usage: cc-push.sh [--dry-run] [--no-scan] <project-dir> <state-repo-url>}"
STATE_REPO="${2:?Usage: cc-push.sh [--dry-run] [--no-scan] <project-dir> <state-repo-url>}"

CLAUDE_DIR="${HOME}/.claude"

# ---------- validate ----------
[[ -d "${PROJECT_DIR}" ]] || die "Project directory does not exist: ${PROJECT_DIR}"

# Resolve to absolute path
PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"

# Encode the project path the same way Claude Code does: replace / with -
# NOTE: Claude Code keeps the leading dash (e.g. /home/ubuntu/project → -home-ubuntu-project)
ENCODED_PATH="${PROJECT_DIR//\//-}"

SESSION_DIR="${CLAUDE_DIR}/projects/${ENCODED_PATH}"
SESSION_INDEX="${SESSION_DIR}/sessions-index.json"

[[ -f "${SESSION_INDEX}" ]] || die "No sessions-index.json found at ${SESSION_INDEX}"

log "Project directory : ${PROJECT_DIR}"
log "Encoded path      : ${ENCODED_PATH}"
log "Session index     : ${SESSION_INDEX}"

# ---------- read session info ----------
SESSION_COUNT=$(jq '.entries | length' "${SESSION_INDEX}")
LATEST_SESSION=$(jq -r '.entries[-1].sessionId // empty' "${SESSION_INDEX}")
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
  jq -r '.entries[].sessionId // empty' "${SESSION_INDEX}" | while read -r sid; do
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

# ---------- secret scan ----------
if [[ "${NO_SCAN}" == false ]]; then
  log ""
  log "=== Secret Scan ==="

  SECRETS_FOUND=false
  USED_GITLEAKS=false

  if command -v gitleaks &>/dev/null; then
    USED_GITLEAKS=true
    log "Using gitleaks for secret detection..."
    GITLEAKS_REPORT=$(mktemp)

    # Try modern 'dir' subcommand (v8.19.0+), then older 'detect --no-git' (v8.16.x)
    GITLEAKS_RC=0
    gitleaks dir --redact --exit-code 2 \
      --report-format json --report-path "${GITLEAKS_REPORT}" \
      "${STAGING}" >/dev/null 2>&1 || GITLEAKS_RC=$?

    if [[ ${GITLEAKS_RC} -ne 0 && ${GITLEAKS_RC} -ne 2 ]]; then
      # 'dir' subcommand not recognized — try older syntax
      GITLEAKS_RC=0
      gitleaks detect --no-git --redact --exit-code 2 \
        --report-format json --report-path "${GITLEAKS_REPORT}" \
        --source "${STAGING}" >/dev/null 2>&1 || GITLEAKS_RC=$?
    fi

    if [[ ${GITLEAKS_RC} -eq 2 ]]; then
      SECRETS_FOUND=true
      log "WARNING: Potential secrets found in staged files:"
      jq -r '.[] | "\(.File):\(.StartLine): \(.RuleID) — \(.Description)"' "${GITLEAKS_REPORT}" \
        | sed "s|${STAGING}/||" | while IFS= read -r line; do
          log "  ${line}"
        done
    elif [[ ${GITLEAKS_RC} -eq 0 ]]; then
      log "No secrets detected."
    else
      log "WARNING: gitleaks failed (exit ${GITLEAKS_RC}); falling back to grep patterns..."
      USED_GITLEAKS=false
    fi
    rm -f "${GITLEAKS_REPORT}"
  fi

  # Grep fallback (when gitleaks is not installed or crashed)
  if [[ "${USED_GITLEAKS}" == false ]]; then
    if ! command -v gitleaks &>/dev/null; then
      log "gitleaks not found; using built-in grep patterns..."
    fi

    # High-confidence patterns for real secrets
    SCAN_PATTERN='AKIA[0-9A-Z]{16}'
    SCAN_PATTERN+='|ASIA[0-9A-Z]{16}'
    SCAN_PATTERN+='|sk-[a-zA-Z0-9]{20,}'
    SCAN_PATTERN+='|sk-ant-[a-zA-Z0-9-]{20,}'
    SCAN_PATTERN+='|ghp_[A-Za-z0-9]{36}'
    SCAN_PATTERN+='|gho_[A-Za-z0-9]{36}'
    SCAN_PATTERN+='|ghs_[A-Za-z0-9]{36}'
    SCAN_PATTERN+='|github_pat_[A-Za-z0-9_]{22,}'
    SCAN_PATTERN+='|-----BEGIN.*PRIVATE KEY'
    SCAN_PATTERN+='|xoxb-[0-9]{10,}-[0-9]{10,}-[a-zA-Z0-9]{24}'
    SCAN_PATTERN+='|xoxp-[0-9]{10,}-[0-9]{10,}-'
    SCAN_PATTERN+='|[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'

    # Scan staged files — use -o to show only matched text (JSONL lines can be huge)
    SCAN_RESULTS=$(grep -rEon "${SCAN_PATTERN}" "${STAGING}" 2>/dev/null || true)

    # Apply scanignore suppressions if the file exists
    SCANIGNORE="${PROJECT_DIR}/.cc-push-scanignore"
    if [[ -n "${SCAN_RESULTS}" && -f "${SCANIGNORE}" ]]; then
      SCAN_RESULTS=$(echo "${SCAN_RESULTS}" | grep -vFf "${SCANIGNORE}" || true)
    fi

    if [[ -n "${SCAN_RESULTS}" ]]; then
      SECRETS_FOUND=true
      log "WARNING: Potential secrets found in staged files:"
      echo "${SCAN_RESULTS}" | sed "s|${STAGING}/||" | while IFS= read -r line; do
        log "  ${line}"
      done
    else
      log "No secrets detected."
    fi
  fi

  if [[ "${SECRETS_FOUND}" == true ]]; then
    log ""
    log "Push blocked. Review the findings above."
    log "To push anyway:  cc-push.sh --no-scan <project-dir> <state-repo-url>"
    log "To suppress false positives: add patterns to .cc-push-scanignore"
    exit 1
  fi
fi

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
