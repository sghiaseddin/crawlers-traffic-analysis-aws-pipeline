#!/usr/bin/env bash
#
# 12_view_report_node_lambda.sh
#
# Usage:
#   ./deploy/12_view_report_node_lambda.sh
#
# This script:
#   - Packages the Node.js view-report Lambda from src/lambda_view_report
#   - Installs required runtime dependencies:
#       @aws-sdk/client-secrets-manager
#       @aws-sdk/client-s3
#   - Creates or updates the Lambda function:
#       ${PROJECT_PREFIX}_lambda_view_report_node
#   - Configures a Lambda Function URL (AuthType=NONE) and prints it
#   - Tags the Lambda with ProjectPrefix=${PROJECT_PREFIX}
#
# Prereqs:
#   - 1_read_env_variables.sh has been sourced (PROJECT_PREFIX, PROJECT_AWS_REGION, etc.)
#   - 2_read_aws_credential.sh has been sourced (AWS creds in env)
#   - aws CLI, node, and npm are available in PATH
#

set -euo pipefail

# Disable AWS CLI pager so long outputs don't block in an interactive 'less' session.
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Step 12: Package & deploy view-report Lambda (Node.js) ==="
echo "Script directory : ${SCRIPT_DIR}"
echo "Project root     : ${PROJECT_ROOT}"
echo

# ---------------------------------------------------------------------------
# Pre-flight checks
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

LAMBDA_NAME="${PROJECT_PREFIX}_lambda_view_report_node"
REGION="${PROJECT_AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
ROLE_NAME="${PROJECT_AWS_IAM_ROLE:-LabRole}"

echo "Target AWS Region : ${REGION}"
echo "Lambda function   : ${LAMBDA_NAME}"
echo "IAM Role name     : ${ROLE_NAME}"
echo

LAMBDA_SRC_DIR="${PROJECT_ROOT}/src/lambda_view_report"
BUILD_ROOT="${PROJECT_ROOT}/build"
BUILD_DIR="${BUILD_ROOT}/lambda_view_report"
PACKAGE_FILE="${BUILD_ROOT}/${LAMBDA_NAME}.zip"

if [[ ! -d "${LAMBDA_SRC_DIR}" ]]; then
  echo "ERROR: Lambda source directory not found: ${LAMBDA_SRC_DIR}" >&2
  exit 1
fi

if [[ ! -f "${LAMBDA_SRC_DIR}/index.js" ]]; then
  echo "ERROR: index.js not found in ${LAMBDA_SRC_DIR}" >&2
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
  "name": "lambda-view-report",
  "version": "1.0.0",
  "description": "Lambda view report package",
  "dependencies": {}
}
EOF
fi

# Install required runtime dependencies
echo "Installing required runtime dependencies..."
npm install --production \
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
    --timeout 900 \
    --memory-size 1024 \
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
    --timeout 900 \
    --memory-size 1024 \
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

# ---------------------------------------------------------------------------
# Configure Lambda Function URL (AuthType NONE)
# ---------------------------------------------------------------------------

echo "Ensuring Lambda Function URL exists (AuthType=NONE)..."

set +e
FUNCTION_URL="$(aws lambda get-function-url-config \
  --region "${REGION}" \
  --function-name "${LAMBDA_NAME}" \
  --query 'FunctionUrl' \
  --output text 2>/dev/null)"
get_url_exit=$?
set -e

if [[ "${get_url_exit}" -ne 0 || -z "${FUNCTION_URL:-}" || "${FUNCTION_URL}" == "None" ]]; then
  echo "  -> No existing Function URL found. Creating a new one..."
  FUNCTION_URL="$(aws lambda create-function-url-config \
    --region "${REGION}" \
    --function-name "${LAMBDA_NAME}" \
    --auth-type NONE \
    --query 'FunctionUrl' \
    --output text)"
  echo "  -> Function URL created: ${FUNCTION_URL}"
else
  echo "  -> Existing Function URL found: ${FUNCTION_URL}"
fi

# ---------------------------------------------------------------------------
# Grant public invoke permission for the Function URL (if not already present)
# ---------------------------------------------------------------------------

STATEMENT_ID="${PROJECT_PREFIX}-view-report-func-url-public"

echo "Adding (or validating) public invoke permission for Function URL..."

set +e
aws lambda add-permission \
  --region "${REGION}" \
  --function-name "${LAMBDA_NAME}" \
  --statement-id "${STATEMENT_ID}" \
  --action "lambda:InvokeFunctionUrl" \
  --principal "*" \
  --function-url-auth-type NONE >/dev/null 2>&1
add_perm_exit=$?
set -e

if [[ "${add_perm_exit}" -ne 0 ]]; then
  echo "  -> Permission may already exist or add-permission failed; continuing."
else
  echo "  -> Public invoke permission added."
fi

echo
echo "View-report Lambda deployment complete."
echo "You can access the report UI at:"
echo "  ${FUNCTION_URL}"
echo
