#!/usr/bin/env bash
#
# 5_etl_logs_lambda.sh
#
# Usage:
#   ./deploy/5_etl_logs_lambda.sh
#
# This script:
#   - Packages the Python ETL Lambda from src/lambda_etl_logs
#   - Creates or updates the Lambda function in AWS
#   - Names the function using PROJECT_PREFIX:
#       ${PROJECT_PREFIX}_lambda_etl_logs
#   - Configures runtime Python 3.12, x86_64, timeout 300s
#   - Tags the Lambda with ProjectPrefix=${PROJECT_PREFIX}
#
# Prereqs:
#   - 1_read_env_variables.sh has been sourced (PROJECT_PREFIX, PROJECT_AWS_REGION, etc.)
#   - 2_read_aws_credential.sh has been sourced (AWS creds in env)
#   - aws CLI and zip are available in PATH
#

set -euo pipefail

# Disable AWS CLI pager for this script to avoid interactive 'less' output.
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Step 5: Package & deploy ETL logs Lambda (Python) ==="
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

if ! command -v zip >/dev/null 2>&1; then
  echo "ERROR: zip not found in PATH. Please install zip (e.g. 'sudo apt install zip')." >&2
  exit 1
fi

if [[ -z "${PROJECT_PREFIX:-}" ]]; then
  echo "ERROR: PROJECT_PREFIX is not set. Did you source 1_read_env_variables.sh?" >&2
  exit 1
fi

LAMBDA_NAME="${PROJECT_PREFIX}_lambda_etl_logs"
REGION="${PROJECT_AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"
ROLE_NAME="${PROJECT_AWS_IAM_ROLE:-LabRole}"

echo "Target AWS Region : ${REGION}"
echo "Lambda function   : ${LAMBDA_NAME}"
echo "IAM Role name     : ${ROLE_NAME}"
echo

LAMBDA_SRC_DIR="${PROJECT_ROOT}/src/lambda_etl_logs"
BUILD_ROOT="${PROJECT_ROOT}/build"
BUILD_DIR="${BUILD_ROOT}/lambda_etl_logs"
PACKAGE_FILE="${BUILD_ROOT}/${LAMBDA_NAME}.zip"

if [[ ! -d "${LAMBDA_SRC_DIR}" ]]; then
  echo "ERROR: Lambda source directory not found: ${LAMBDA_SRC_DIR}" >&2
  exit 1
fi

if [[ ! -f "${LAMBDA_SRC_DIR}/etl_lambda.py" ]]; then
  echo "ERROR: etl_lambda.py not found in ${LAMBDA_SRC_DIR}" >&2
  exit 1
fi

if [[ ! -f "${LAMBDA_SRC_DIR}/etl_logic.py" ]]; then
  echo "ERROR: etl_logic.py not found in ${LAMBDA_SRC_DIR}" >&2
  exit 1
fi

mkdir -p "${BUILD_ROOT}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "Copying Lambda source files..."
cp "${LAMBDA_SRC_DIR}/etl_lambda.py" "${BUILD_DIR}/"
cp "${LAMBDA_SRC_DIR}/etl_logic.py" "${BUILD_DIR}/"

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
    --runtime python3.12 \
    --architectures x86_64 \
    --role "${ROLE_ARN}" \
    --handler etl_lambda.handler \
    --timeout 300 \
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
    --runtime python3.12 \
    --architectures x86_64 \
    --role "${ROLE_ARN}" \
    --handler etl_lambda.handler \
    --timeout 300 \
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
echo "ETL logs Lambda deployment complete."
