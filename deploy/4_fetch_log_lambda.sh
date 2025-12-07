#!/usr/bin/env bash
#
# 4_fetch_log_lambda.sh
#
# Usage:
#   ./deploy/4_fetch_log_lambda.sh
#
# This script:
#   - Packages the Node.js log-fetch Lambda from src/lambda_fetch_logs_node
#   - Creates or updates the Lambda function in AWS
#   - Names the function using PROJECT_PREFIX:
#       ${PROJECT_PREFIX}_lambda_fetch_logs_node
#
# Prereqs:
#   - 1_read_env_variables.sh has been sourced (PROJECT_PREFIX, PROJECT_AWS_REGION, etc.)
#   - 2_read_aws_credential.sh has been sourced (AWS creds in env)
#   - aws CLI, node, and npm are available in PATH
#

set -euo pipefail

# Disable AWS CLI pager for this script to avoid interactive 'less' output.
# export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Step 4: Package & deploy log-fetch Lambda (Node.js) ==="
echo "Script directory : ${SCRIPT_DIR}"
echo "Project root     : ${PROJECT_ROOT}"
echo

# ---------------------------------------------------------------------------
# Requirement checks
# ---------------------------------------------------------------------------

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found in PATH. Please install AWS CLI." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node (Node.js) not found in PATH. Please install Node.js." >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: npm not found in PATH. Please install Node.js/npm." >&2
  exit 1
fi

if [[ -z "${PROJECT_PREFIX:-}" ]]; then
  echo "ERROR: PROJECT_PREFIX is not set. Did you source 1_read_env_variables.sh?" >&2
  exit 1
fi

LAMBDA_NAME="${PROJECT_PREFIX}_lambda_fetch_logs_node"
REGION="${PROJECT_AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
ROLE_NAME="${PROJECT_AWS_IAM_ROLE:-LabRole}"

echo "Target AWS Region : ${REGION}"
echo "Lambda function   : ${LAMBDA_NAME}"
echo "IAM Role name     : ${ROLE_NAME}"
echo

LAMBDA_SRC_DIR="${PROJECT_ROOT}/src/lambda_fetch_logs_node"
BUILD_ROOT="${PROJECT_ROOT}/build"
BUILD_DIR="${BUILD_ROOT}/lambda_fetch_logs_node"
PACKAGE_FILE="${BUILD_ROOT}/${LAMBDA_NAME}.zip"

if [[ ! -d "${LAMBDA_SRC_DIR}" ]]; then
  echo "ERROR: Lambda source directory not found: ${LAMBDA_SRC_DIR}" >&2
  exit 1
fi

mkdir -p "${BUILD_ROOT}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "Copying Lambda source files..."
cp "${LAMBDA_SRC_DIR}/index.js" "${BUILD_DIR}/"

if [[ -f "${LAMBDA_SRC_DIR}/package.json" ]]; then
  cp "${LAMBDA_SRC_DIR}/package.json" "${BUILD_DIR}/"
fi

if [[ -f "${LAMBDA_SRC_DIR}/package-lock.json" ]]; then
  cp "${LAMBDA_SRC_DIR}/package-lock.json" "${BUILD_DIR}/"
fi

echo "Installing Node.js dependencies (production only)..."
pushd "${BUILD_DIR}" >/dev/null

# Ensure a package.json exists (Lambda requires node_modules structure)
if [[ ! -f "package.json" ]]; then
  echo "No package.json found. Creating a minimal one..."
  cat > package.json <<'EOF'
{
  "name": "lambda-fetch-logs",
  "version": "1.0.0",
  "description": "Lambda fetch logs package",
  "dependencies": {}
}
EOF
fi

# Install required runtime dependencies
echo "Installing required runtime dependencies..."
npm install --production \
  ssh2-sftp-client \
  @aws-sdk/client-secrets-manager \
  @aws-sdk/client-s3

popd >/dev/null

echo "Creating deployment package: ${PACKAGE_FILE}"
pushd "${BUILD_DIR}" >/dev/null
zip -r "${PACKAGE_FILE}" . >/dev/null
popd >/dev/null

echo "Deployment package size:"
du -h "${PACKAGE_FILE}" || true
echo

echo "Resolving AWS account ID..."
ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text --region "${REGION}")" || {
  echo "ERROR: Unable to determine AWS account ID via sts get-caller-identity." >&2
  exit 1
}

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo "Using IAM Role ARN: ${ROLE_ARN}"
echo

CONFIG_SECRET_NAME="${PROJECT_PREFIX}-secrets-and-namings"

echo "Checking if Lambda function '${LAMBDA_NAME}' exists..."
set +e
aws lambda get-function \
  --region "${REGION}" \
  --function-name "${LAMBDA_NAME}" >/dev/null 2>&1
get_fn_exit=$?
set -e

if [[ "${get_fn_exit}" -ne 0 ]]; then
  echo "Lambda function does not exist. Creating new function: ${LAMBDA_NAME}"
  aws lambda create-function \
    --region "${REGION}" \
    --function-name "${LAMBDA_NAME}" \
    --runtime nodejs20.x \
    --role "${ROLE_ARN}" \
    --handler index.handler \
    --timeout 120 \
    --memory-size 512 \
    --environment "Variables={CONFIG_SECRET_NAME=${CONFIG_SECRET_NAME},PROJECT_PREFIX=${PROJECT_PREFIX},PROJECT_AWS_REGION=${REGION}}" \
    --zip-file "fileb://${PACKAGE_FILE}"
  echo "Lambda function created."
else
  echo "Lambda function exists. Updating function code & configuration: ${LAMBDA_NAME}"

  aws lambda update-function-code \
    --region "${REGION}" \
    --function-name "${LAMBDA_NAME}" \
    --zip-file "fileb://${PACKAGE_FILE}"

  aws lambda update-function-configuration \
    --region "${REGION}" \
    --function-name "${LAMBDA_NAME}" \
    --runtime nodejs20.x \
    --role "${ROLE_ARN}" \
    --handler index.handler \
    --timeout 120 \
    --memory-size 512 \
    --environment "Variables={CONFIG_SECRET_NAME=${CONFIG_SECRET_NAME},PROJECT_PREFIX=${PROJECT_PREFIX},PROJECT_AWS_REGION=${REGION}}"

  echo "Lambda function updated."
fi

echo
echo "Tagging Lambda function with ProjectPrefix=${PROJECT_PREFIX} ..."
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${LAMBDA_NAME}"
aws lambda tag-resource \
  --region "${REGION}" \
  --resource "${LAMBDA_ARN}" \
  --tags "ProjectPrefix=${PROJECT_PREFIX}" || {
    echo "WARNING: Failed to tag Lambda function. Continuing anyway." >&2
  }

echo
echo "Log-fetch Lambda deployment complete."
