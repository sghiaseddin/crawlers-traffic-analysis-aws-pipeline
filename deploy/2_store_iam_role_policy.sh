#!/usr/bin/env bash
#
# 2_store_iam_role_policy.sh
#
# Creates or updates the IAM role required for running the entire
# crawlers‑traffic‑analysis pipeline outside AWS Academy.
#
# Requirements:
#   - trust-policy.json and execution-policy.json under src/iam/
#   - PROJECT_PREFIX and PROJECT_AWS_REGION loaded from .env
#   - AWS CLI v2 with valid credentials
#
# This script will:
#   1. Create IAM role with trust policy (Lambda + Glue)
#   2. Attach inline execution policy
#   3. Output the IAM role ARN for use in .env
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IAM_DIR="${PROJECT_ROOT}/src/iam"

ROLE_NAME="${PROJECT_AWS_IAM_ROLE:-}"
REGION="${PROJECT_AWS_REGION:-${AWS_DEFAULT_REGION:-eu-north-1}}"

if [[ -z "${ROLE_NAME}" ]]; then
  echo "ERROR: PROJECT_AWS_IAM_ROLE is not set in environment." >&2
  echo "Make sure .env defines PROJECT_AWS_IAM_ROLE=<your-role-name>." >&2
  exit 1
fi

TRUST_POLICY="${IAM_DIR}/trust-policy.json"
EXEC_POLICY="${IAM_DIR}/execution-policy.json"

if [[ ! -f "${TRUST_POLICY}" ]]; then
  echo "ERROR: Missing trust policy: ${TRUST_POLICY}" >&2
  exit 1
fi

if [[ ! -f "${EXEC_POLICY}" ]]; then
  echo "ERROR: Missing execution policy: ${EXEC_POLICY}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Prepare execution policy by replacing project-prefix placeholder
# ---------------------------------------------------------------------------
TMP_EXEC_POLICY="/tmp/${ROLE_NAME}-exec-policy.json"

if [[ -z "${PROJECT_PREFIX:-}" ]]; then
  echo "ERROR: PROJECT_PREFIX must be set in environment for policy substitution." >&2
  exit 1
fi

echo "Resolving AWS account ID for policy substitution..."
ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text --region "${REGION}")" || {
  echo "ERROR: Unable to retrieve AWS account ID via sts get-caller-identity." >&2
  exit 1
}

echo "Substituting placeholders in execution-policy.json ..."
echo "  - \`project-prefix\`  → ${PROJECT_PREFIX}"
echo "  - YOUR_ACCOUNT_ID     → ${ACCOUNT_ID}"
echo "  - YOUR_REGION         → ${REGION}"

sed -e "s/\`project-prefix\`/${PROJECT_PREFIX}/g" \
    -e "s/YOUR_ACCOUNT_ID/${ACCOUNT_ID}/g" \
    -e "s/YOUR_REGION/${REGION}/g" \
    "${EXEC_POLICY}" > "${TMP_EXEC_POLICY}"

echo "Using temporary execution policy: ${TMP_EXEC_POLICY}"

echo "=== IAM Role Creation / Update ==="
echo "Role name      : ${ROLE_NAME}"
echo "Region         : ${REGION}"
echo "Trust policy   : ${TRUST_POLICY}"
echo "Exec policy    : ${EXEC_POLICY}"
echo

# ---------------------------------------------------------------------------
# Create the IAM role if it does not exist
# ---------------------------------------------------------------------------
set +e
aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1
GET_ROLE_EXIT=$?
set -e

if [[ "${GET_ROLE_EXIT}" -ne 0 ]]; then
  echo "Role does not exist. Creating: ${ROLE_NAME}"
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${TRUST_POLICY}" >/dev/null
  echo "Role created."
else
  echo "Role already exists. Updating trust policy..."
  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document "file://${TRUST_POLICY}" >/dev/null
  echo "Trust policy updated."
fi

echo
# ---------------------------------------------------------------------------
# Attach or update inline execution policy
# ---------------------------------------------------------------------------
POLICY_NAME="${ROLE_NAME}-execution-policy"

echo "Attaching inline execution policy: ${POLICY_NAME}"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "file://${TMP_EXEC_POLICY}" >/dev/null

echo "Execution policy applied."

echo
# ---------------------------------------------------------------------------
# Output the IAM Role ARN
# ---------------------------------------------------------------------------
ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)

echo "IAM Role is ready:"
echo "  ${ROLE_ARN}"
echo

echo "Ensure your .env contains:"
echo "  PROJECT_AWS_IAM_ROLE=${ROLE_NAME}"
echo "  PROJECT_AWS_REGION=${REGION}"
echo
