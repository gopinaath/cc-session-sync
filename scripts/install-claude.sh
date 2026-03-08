#!/usr/bin/env bash
# Install Claude Code on a fresh EC2 Ubuntu instance.
#
# Usage:
#   install-claude.sh
#
# Prerequisites:
#   - Node.js 20+ (installed by cloud-init user-data)
#   - IAM instance profile with Bedrock access (attached by CloudFormation)
#
# This script assumes Bedrock authentication via instance profile.
# The required env vars are set by /etc/profile.d/claude-env.sh from user-data.

set -euo pipefail

log()  { echo "[install-claude] $*"; }
die()  { echo "[install-claude] ERROR: $*" >&2; exit 1; }

# ---------- verify prerequisites ----------
log "Checking prerequisites..."

# Source claude env if not already loaded
if [[ -z "${CLAUDE_CODE_USE_BEDROCK:-}" ]]; then
  if [[ -f /etc/profile.d/claude-env.sh ]]; then
    source /etc/profile.d/claude-env.sh
  fi
fi

# Check Node.js
if ! command -v node &> /dev/null; then
  log "Node.js not found. Attempting install via NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
  sudo apt-get install -y nodejs
fi

NODE_VERSION="$(node --version)"
log "Node.js version: ${NODE_VERSION}"

# Verify Node.js >= 20
MAJOR="${NODE_VERSION#v}"
MAJOR="${MAJOR%%.*}"
if [[ "${MAJOR}" -lt 20 ]]; then
  die "Node.js 20+ required, found ${NODE_VERSION}"
fi

# ---------- install Claude Code ----------
log "Installing Claude Code..."
npm install -g @anthropic-ai/claude-code

# ---------- verify installation ----------
CLAUDE_VERSION="$(claude --version 2>/dev/null || echo 'FAILED')"
if [[ "${CLAUDE_VERSION}" == "FAILED" ]]; then
  die "Claude Code installation failed — 'claude --version' returned error"
fi
log "Claude Code version: ${CLAUDE_VERSION}"

# ---------- verify Bedrock env ----------
log ""
log "Checking Bedrock configuration..."
if [[ "${CLAUDE_CODE_USE_BEDROCK:-}" == "1" ]]; then
  log "  CLAUDE_CODE_USE_BEDROCK=1 ✓"
else
  log "  WARNING: CLAUDE_CODE_USE_BEDROCK not set"
  log "  Source /etc/profile.d/claude-env.sh or set manually"
fi

if [[ -n "${AWS_REGION:-}" ]]; then
  log "  AWS_REGION=${AWS_REGION} ✓"
else
  log "  WARNING: AWS_REGION not set"
fi

# Quick check that instance profile is attached
if curl -s --max-time 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/ | grep -q .; then
  ROLE="$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)"
  log "  IAM role: ${ROLE} ✓"
else
  log "  WARNING: No IAM instance profile detected"
fi

log ""
log "=== Installation Complete ==="
log "Claude Code ${CLAUDE_VERSION} is ready."
log ""
log "Test with:"
log '  claude -p "Say hello"'
