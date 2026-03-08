#!/usr/bin/env bash
# Deploy or update the CC Session Sync CloudFormation stack.
#
# Usage:
#   ./deploy.sh <key-name> [stack-name] [region]
#
# Arguments:
#   key-name    — Name of an existing EC2 key pair
#   stack-name  — CloudFormation stack name (default: cc-session-sync)
#   region      — AWS region (default: us-east-1)
#
# The script auto-detects your public IP for the SSH security group.

set -euo pipefail

KEY_NAME="${1:?Usage: $0 <key-name> [stack-name] [region]}"
STACK_NAME="${2:-cc-session-sync}"
REGION="${3:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/cfn-template.yaml"

# Detect caller's public IP
echo "Detecting public IP..."
MY_IP="$(curl -s https://checkip.amazonaws.com)"
ALLOWED_CIDR="${MY_IP}/32"
echo "  SSH will be allowed from: ${ALLOWED_CIDR}"

echo ""
echo "Deploying stack '${STACK_NAME}' in ${REGION}..."
echo "  Template:      ${TEMPLATE}"
echo "  Key pair:      ${KEY_NAME}"
echo "  Instance type: t3.medium"
echo ""

aws cloudformation deploy \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --template-file "${TEMPLATE}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    KeyName="${KEY_NAME}" \
    AllowedSSHCidr="${ALLOWED_CIDR}" \
  --no-fail-on-empty-changeset

echo ""
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --query 'Stacks[0].Outputs' \
  --output table

echo ""
echo "Waiting for user-data to complete on both machines..."
echo "(Instances need a few minutes after launch for cloud-init to finish)"
