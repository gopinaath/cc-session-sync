#!/usr/bin/env bash
# End-to-end test: push Claude Code session state from Machine A,
# pull and restore on Machine B, verify --continue works.
#
# Usage:
#   e2e-test.sh <key-file> <github-owner> [stack-name] [region]
#
# Prerequisites:
#   - AWS CLI configured with permissions to create CloudFormation stacks
#   - gh CLI authenticated
#   - SSH key file (.pem) matching the EC2 key pair
#
# This script orchestrates everything from your local machine.

set -euo pipefail

KEY_FILE="${1:?Usage: $0 <key-file> <github-owner> [stack-name] [region]}"
GITHUB_OWNER="${2:?Usage: $0 <key-file> <github-owner> [stack-name] [region]}"
STACK_NAME="${3:-cc-session-sync}"
REGION="${4:-us-east-1}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

PROJECT_REPO="https://github.com/${GITHUB_OWNER}/cc-sync-test-project.git"
STATE_REPO="https://github.com/${GITHUB_OWNER}/cc-sync-test-state.git"
REMOTE_PROJECT_DIR="/home/ubuntu/test-project"

# ---------- helpers ----------
log()      { echo ""; echo "==== $* ===="; echo ""; }
step()     { echo "[e2e] STEP: $*"; }
pass()     { echo "[e2e] ✓ PASS: $*"; }
fail()     { echo "[e2e] ✗ FAIL: $*"; FAILURES=$((FAILURES + 1)); }
ssh_a()    { ssh ${SSH_OPTS} -i "${KEY_FILE}" "ubuntu@${IP_A}" "$@"; }
ssh_b()    { ssh ${SSH_OPTS} -i "${KEY_FILE}" "ubuntu@${IP_B}" "$@"; }
scp_to_a() { scp ${SSH_OPTS} -i "${KEY_FILE}" "$1" "ubuntu@${IP_A}:$2"; }
scp_to_b() { scp ${SSH_OPTS} -i "${KEY_FILE}" "$1" "ubuntu@${IP_B}:$2"; }

FAILURES=0

cleanup() {
  log "CLEANUP"
  if [[ "${SKIP_TEARDOWN:-}" == "1" ]]; then
    echo "SKIP_TEARDOWN=1 — leaving stack '${STACK_NAME}' running."
    echo "  Machine A: ssh -i ${KEY_FILE} ubuntu@${IP_A:-unknown}"
    echo "  Machine B: ssh -i ${KEY_FILE} ubuntu@${IP_B:-unknown}"
    echo "  Tear down: ${PROJECT_ROOT}/infra/teardown.sh ${STACK_NAME} ${REGION}"
  else
    step "Destroying CloudFormation stack..."
    "${PROJECT_ROOT}/infra/teardown.sh" "${STACK_NAME}" "${REGION}" || true
  fi

  echo ""
  if [[ ${FAILURES} -eq 0 ]]; then
    echo "========================================="
    echo "  ALL TESTS PASSED"
    echo "========================================="
  else
    echo "========================================="
    echo "  ${FAILURES} TEST(S) FAILED"
    echo "========================================="
    exit 1
  fi
}
trap cleanup EXIT

# ===================================================
# Step 1: Create GitHub repos
# ===================================================
log "STEP 1: Create GitHub repos"
step "Setting up test repos under ${GITHUB_OWNER}..."
"${PROJECT_ROOT}/scripts/setup-github-repos.sh" "${GITHUB_OWNER}"

# ===================================================
# Step 2: Deploy infrastructure
# ===================================================
log "STEP 2: Deploy CloudFormation stack"

KEY_NAME="$(basename "${KEY_FILE}" .pem)"
"${PROJECT_ROOT}/infra/deploy.sh" "${KEY_NAME}" "${STACK_NAME}" "${REGION}"

# Get instance IPs
IP_A=$(aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --query 'Stacks[0].Outputs[?OutputKey==`MachineAPublicIp`].OutputValue' \
  --output text)

IP_B=$(aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --query 'Stacks[0].Outputs[?OutputKey==`MachineBPublicIp`].OutputValue' \
  --output text)

step "Machine A IP: ${IP_A}"
step "Machine B IP: ${IP_B}"

# Wait for instances to be reachable
step "Waiting for SSH on both machines..."
for ip in "${IP_A}" "${IP_B}"; do
  for i in $(seq 1 30); do
    if ssh ${SSH_OPTS} -i "${KEY_FILE}" "ubuntu@${ip}" "true" 2>/dev/null; then
      break
    fi
    echo "  Waiting for ${ip}... (attempt ${i}/30)"
    sleep 10
  done
done

# Wait for cloud-init to complete
step "Waiting for cloud-init to finish on both machines..."
for ip in "${IP_A}" "${IP_B}"; do
  ssh ${SSH_OPTS} -i "${KEY_FILE}" "ubuntu@${ip}" \
    "cloud-init status --wait" 2>/dev/null || true
done

# ===================================================
# Step 3: Install Claude Code on Machine A
# ===================================================
log "STEP 3: Install Claude Code on Machine A"
scp_to_a "${PROJECT_ROOT}/scripts/install-claude.sh" "/tmp/install-claude.sh"
ssh_a "bash /tmp/install-claude.sh"

# ===================================================
# Step 4: Seed session on Machine A
# ===================================================
log "STEP 4: Seed session on Machine A"
scp_to_a "${SCRIPT_DIR}/seed-session.sh" "/tmp/seed-session.sh"
ssh_a "bash /tmp/seed-session.sh ${REMOTE_PROJECT_DIR} '${PROJECT_REPO}'"

# ===================================================
# Step 5: Push session state from Machine A
# ===================================================
log "STEP 5: Push session state from Machine A"
scp_to_a "${PROJECT_ROOT}/scripts/cc-push.sh" "/tmp/cc-push.sh"
ssh_a "bash /tmp/cc-push.sh ${REMOTE_PROJECT_DIR} '${STATE_REPO}'"

# ===================================================
# Step 6: Install Claude Code on Machine B
# ===================================================
log "STEP 6: Install Claude Code on Machine B"
scp_to_b "${PROJECT_ROOT}/scripts/install-claude.sh" "/tmp/install-claude.sh"
ssh_b "bash /tmp/install-claude.sh"

# ===================================================
# Step 7: Clone project repo on Machine B
# ===================================================
log "STEP 7: Clone project repo on Machine B"
ssh_b "git clone '${PROJECT_REPO}' '${REMOTE_PROJECT_DIR}'"

# ===================================================
# Step 8: Pull session state on Machine B
# ===================================================
log "STEP 8: Pull session state on Machine B"
scp_to_b "${PROJECT_ROOT}/scripts/cc-pull.sh" "/tmp/cc-pull.sh"
ssh_b "bash /tmp/cc-pull.sh ${REMOTE_PROJECT_DIR} '${STATE_REPO}'"

# ===================================================
# Step 9: Validate session on Machine B
# ===================================================
log "STEP 9: Validate session"
scp_to_b "${SCRIPT_DIR}/validate-continue.sh" "/tmp/validate-continue.sh"
ssh_b "bash /tmp/validate-continue.sh ${REMOTE_PROJECT_DIR}"

# ===================================================
# Step 10: Compare session state
# ===================================================
log "STEP 10: Cross-machine comparison"

# Compare session JSONL line counts
ENCODED="home-ubuntu-test-project"
A_LINES=$(ssh_a "wc -l < \$(ls ~/.claude/projects/${ENCODED}/*.jsonl | head -1)" 2>/dev/null || echo "0")
B_LINES=$(ssh_b "wc -l < \$(ls ~/.claude/projects/${ENCODED}/*.jsonl | head -1)" 2>/dev/null || echo "0")

step "Machine A JSONL lines: ${A_LINES}"
step "Machine B JSONL lines: ${B_LINES}"

if [[ "${A_LINES}" == "${B_LINES}" ]] && [[ "${A_LINES}" != "0" ]]; then
  pass "Session JSONL line count matches across machines (${A_LINES} lines)"
else
  fail "Session JSONL line count mismatch: A=${A_LINES} B=${B_LINES}"
fi

log "E2E TEST COMPLETE"
