#!/usr/bin/env bash
# Delete the CC Session Sync CloudFormation stack.
#
# Usage:
#   ./teardown.sh [stack-name] [region]

set -euo pipefail

STACK_NAME="${1:-cc-session-sync}"
REGION="${2:-us-east-1}"

echo "Deleting stack '${STACK_NAME}' in ${REGION}..."

aws cloudformation delete-stack \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}"

echo "Waiting for deletion to complete..."
aws cloudformation wait stack-delete-complete \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}"

echo "Stack '${STACK_NAME}' deleted."
