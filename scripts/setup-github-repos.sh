#!/usr/bin/env bash
# Create the two GitHub repos needed for CC session sync testing.
#
# Usage:
#   setup-github-repos.sh [github-owner]
#
# Creates:
#   - cc-sync-test-project  (public)  — test workspace with sample files
#   - cc-sync-test-state    (private) — session state storage

set -euo pipefail

OWNER="${1:-$(gh api user -q .login)}"

log()  { echo "[setup-repos] $*"; }
die()  { echo "[setup-repos] ERROR: $*" >&2; exit 1; }

# Check gh is authenticated
gh auth status > /dev/null 2>&1 || die "GitHub CLI not authenticated. Run: gh auth login"

# ---------- Project repo ----------
log "Creating cc-sync-test-project (public)..."
if gh repo view "${OWNER}/cc-sync-test-project" > /dev/null 2>&1; then
  log "  Already exists — skipping."
else
  gh repo create "${OWNER}/cc-sync-test-project" \
    --public \
    --description "Test project for Claude Code session sync PoC" \
    --clone=false

  # Seed with sample files
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "${TMPDIR}"' EXIT

  cd "${TMPDIR}"
  git init
  git branch -M main

  cat > README.md << 'EOF'
# CC Sync Test Project

Sample project for testing Claude Code session portability.
EOF

  cat > hello.py << 'EOF'
#!/usr/bin/env python3
"""Sample file for session sync testing."""

def greet(name: str) -> str:
    return f"Hello, {name}!"

if __name__ == "__main__":
    import socket
    print(greet(socket.gethostname()))
EOF

  cat > utils.py << 'EOF'
"""Utility functions for testing."""

def add(a: int, b: int) -> int:
    return a + b

def multiply(a: int, b: int) -> int:
    return a * b
EOF

  git add -A
  git commit -m "Initial commit: sample project files"
  git remote add origin "https://github.com/${OWNER}/cc-sync-test-project.git"
  git push -u origin main

  cd -
  log "  Created and seeded with sample files."
fi

PROJECT_URL="https://github.com/${OWNER}/cc-sync-test-project.git"
log "  URL: ${PROJECT_URL}"

# ---------- State repo ----------
log ""
log "Creating cc-sync-test-state (private)..."
if gh repo view "${OWNER}/cc-sync-test-state" > /dev/null 2>&1; then
  log "  Already exists — skipping."
else
  gh repo create "${OWNER}/cc-sync-test-state" \
    --private \
    --description "Claude Code session state for sync PoC (private)" \
    --clone=false

  # Initialize with empty commit so clone works
  TMPDIR2="$(mktemp -d)"
  trap 'rm -rf "${TMPDIR2}"' EXIT

  cd "${TMPDIR2}"
  git init
  git branch -M main
  echo "# CC Session State" > README.md
  echo "Private repo for Claude Code session state sync." >> README.md
  git add README.md
  git commit -m "Initial commit"
  git remote add origin "https://github.com/${OWNER}/cc-sync-test-state.git"
  git push -u origin main

  cd -
  log "  Created."
fi

STATE_URL="https://github.com/${OWNER}/cc-sync-test-state.git"
log "  URL: ${STATE_URL}"

log ""
log "=== Repos Ready ==="
log "Project : ${PROJECT_URL}"
log "State   : ${STATE_URL}"
