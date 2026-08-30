#!/usr/bin/env bash
# Create a test Claude Code session with known interactions.
#
# Usage:
#   seed-session.sh <project-dir> <project-repo-url>
#
# This script:
#   1. Clones the test project repo to <project-dir>
#   2. Runs Claude Code with a scripted prompt to create a deterministic session
#   3. Verifies session state was created

set -euo pipefail

PROJECT_DIR="${1:?Usage: $0 <project-dir> <project-repo-url>}"
PROJECT_REPO="${2:?Usage: $0 <project-dir> <project-repo-url>}"

log()  { echo "[seed-session] $*"; }
die()  { echo "[seed-session] ERROR: $*" >&2; exit 1; }

# Source claude environment
[[ -f /etc/profile.d/claude-env.sh ]] && source /etc/profile.d/claude-env.sh

# ---------- setup project ----------
if [[ -d "${PROJECT_DIR}" ]]; then
  log "Project directory already exists: ${PROJECT_DIR}"
else
  log "Cloning project repo to ${PROJECT_DIR}..."
  git clone "${PROJECT_REPO}" "${PROJECT_DIR}"
fi

cd "${PROJECT_DIR}"

# Configure git identity (needed for Claude to make commits)
git config user.email "test@cc-session-sync.local"
git config user.name "CC Session Sync Test"

# ---------- create Claude session ----------
log "Creating Claude Code session..."

# Run a scripted prompt that creates a known file
# Using --print (-p) for non-interactive execution
claude -p "Create a file called hello.py that prints 'Hello from $(hostname)' and the current date. Also create a file called NOTES.md with a brief description of what hello.py does." \
  --model "${ANTHROPIC_DEFAULT_SONNET_MODEL:-global.anthropic.claude-sonnet-4-5-20250929-v1:0}" \
  2>&1 | tail -20

log "First prompt complete."

# Send a follow-up to build conversation history
claude --continue -p "Now add a function called 'get_machine_info()' to hello.py that returns a dict with hostname, platform, and python version." \
  --model "${ANTHROPIC_DEFAULT_SONNET_MODEL:-global.anthropic.claude-sonnet-4-5-20250929-v1:0}" \
  2>&1 | tail -20

log "Follow-up prompt complete."

# ---------- verify session was created ----------
# Claude Code encodes the project path with the leading dash kept
# (e.g. /home/ubuntu/project → -home-ubuntu-project)
PROJECT_DIR_ABS="$(cd "${PROJECT_DIR}" && pwd)"
ENCODED_PATH="${PROJECT_DIR_ABS//\//-}"

SESSION_DIR="${HOME}/.claude/projects/${ENCODED_PATH}"
SESSION_INDEX="${SESSION_DIR}/sessions-index.json"

[[ -d "${SESSION_DIR}" ]] || die "No session directory found at ${SESSION_DIR}"

# sessions-index.json was removed in newer Claude Code versions; sessions are
# just <session-id>.jsonl files. Support both layouts.
if [[ -f "${SESSION_INDEX}" ]]; then
  SESSION_COUNT=$(jq 'length' "${SESSION_INDEX}")
  LATEST_SESSION=$(jq -r '.[-1].sessionId // .[-1].id // "unknown"' "${SESSION_INDEX}")
  log "Session index found (old layout)"
else
  SESSION_COUNT=$(find "${SESSION_DIR}" -maxdepth 1 -name '*.jsonl' | wc -l | tr -d ' ')
  LATEST_JSONL=$(ls -t "${SESSION_DIR}"/*.jsonl 2>/dev/null | head -1 || true)
  [[ -n "${LATEST_JSONL}" ]] || die "No session JSONL files found in ${SESSION_DIR}"
  LATEST_SESSION="$(basename "${LATEST_JSONL}" .jsonl)"
  log "No sessions-index.json (new layout) — using JSONL files directly"
fi

log "Session created successfully!"
log "  Sessions: ${SESSION_COUNT}"
log "  Latest:   ${LATEST_SESSION}"

JSONL_FILES=$(find "${SESSION_DIR}" -name '*.jsonl' | wc -l)
log "  JSONL files: ${JSONL_FILES}"

if [[ ${JSONL_FILES} -gt 0 ]]; then
  FIRST_JSONL=$(ls -t "${SESSION_DIR}"/*.jsonl | head -1)
  LINE_COUNT=$(wc -l < "${FIRST_JSONL}")
  log "  Lines in latest session: ${LINE_COUNT}"
fi

# Show what files Claude created
log ""
log "Files in project directory:"
ls -la "${PROJECT_DIR}"

log ""
log "=== Session seeded successfully ==="
