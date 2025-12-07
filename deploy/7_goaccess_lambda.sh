#!/usr/bin/env bash
#
# 7_goaccess_lambda.sh
#
# Usage:
#   ./deploy/7_goaccess_lambda.sh
#
# This script:
#   - Packages a Lambda layer containing the GoAccess ARM64 binary
#   - Packages the Python Lambda function run_goaccess_arm64.py + goaccess.conf
#   - Creates or updates:
#       * A Lambda layer:  ${PROJECT_PREFIX}_goaccess_arm64_layer
#       * A Lambda func:   ${PROJECT_PREFIX}_lambda_run_goaccess_arm64
#   - Uses runtime python3.12, architecture arm64
#   - Keeps goaccess.conf with the function code (not in the layer)
#
# Prereqs:
#   - Env vars loaded via 1_read_env_variables.sh (PROJECT_PREFIX, PROJECT_AWS_REGION, etc.)
#   - AWS creds loaded via 2_read_aws_credential.sh
#   - aws CLI and zip available
#

set -euo pipefail
# Disable AWS CLI pager
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Step 7: Package GoAccess layer (ARM64) & deploy GoAccess runner Lambda ==="
echo "Script directory : ${SCRIPT_DIR}"
echo "Project root     : ${PROJECT_ROOT}"
echo

# ---------------------------------------------------------------------------
# Requirement checks
# ---------------------------------------------------------------------------

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found." >&2
  exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
  echo "ERROR: zip not found." >&2
  exit 1
fi

if [[ -z "${PROJECT_PREFIX:-}" ]]; then
  echo "ERROR: PROJECT_PREFIX not set. Did you source 1_read_env_variables.sh?" >&2
  exit 1
fi

LAYER_NAME="${PROJECT_PREFIX}_goaccess_arm64_layer"
LAMBDA_NAME="${PROJECT_PREFIX}_lambda_run_goaccess_arm64"
REGION="${PROJECT_AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
ROLE_NAME="${PROJECT_AWS_IAM_ROLE:-LabRole}"

echo "Target AWS Region : ${REGION}"
echo "Layer name        : ${LAYER_NAME}"
echo "Lambda function   : ${LAMBDA_NAME}"
echo "IAM Role name     : ${ROLE_NAME}"
echo

SRC_DIR="${PROJECT_ROOT}/src/lambda_run_goaccess_arm64"
GOACCESS_BIN="${SRC_DIR}/goaccess"
GOACCESS_CONF="${SRC_DIR}/goaccess.conf"
HANDLER_FILE="${SRC_DIR}/run_goaccess_arm64.py"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "ERROR: Source directory missing: ${SRC_DIR}" >&2
  exit 1
fi

if [[ ! -f "${GOACCESS_BIN}" ]]; then
  echo "ERROR: GoAccess binary not found at: ${GOACCESS_BIN}" >&2
  exit 1
fi

if [[ ! -f "${GOACCESS_CONF}" ]]; then
  echo "ERROR: goaccess.conf not found at: ${GOACCESS_CONF}" >&2
  exit 1
fi

if [[ ! -f "${HANDLER_FILE}" ]]; then
  echo "ERROR: run_goaccess_arm64.py not found at: ${HANDLER_FILE}" >&2
  exit 1
fi

BUILD_ROOT="${PROJECT_ROOT}/build"
LAYER_BUILD_DIR="${BUILD_ROOT}/goaccess_layer_arm64"
FUNC_BUILD_DIR="${BUILD_ROOT}/lambda_run_goaccess_arm64"
LAYER_ZIP="${BUILD_ROOT}/${LAYER_NAME}.zip"
FUNC_ZIP="${BUILD_ROOT}/${LAMBDA_NAME}.zip"

mkdir -p "${BUILD_ROOT}"

# ---------------------------------------------------------------------------
# Build Lambda layer (ARM64) with GoAccess binary under bin/goaccess
# ---------------------------------------------------------------------------

echo "Building GoAccess ARM64 layer..."
rm -rf "${LAYER_BUILD_DIR}"
mkdir -p "${LAYER_BUILD_DIR}/bin"

cp "${GOACCESS_BIN}" "${LAYER_BUILD_DIR}/bin/goaccess"
chmod +x "${LAYER_BUILD_DIR}/bin/goaccess"

echo "Creating layer zip: ${LAYER_ZIP}"
pushd "${LAYER_BUILD_DIR}" >/dev/null
zip -r "${LAYER_ZIP}" . >/dev/null
popd >/dev/null

echo "Layer package size:"
du -h "${LAYER_ZIP}" || true
echo

echo "Resolving AWS account ID..."
ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text --region "${REGION}")" || {
  echo "ERROR: Unable to retrieve AWS account ID." >&2
  exit 1
}

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo "Using IAM Role ARN: ${ROLE_ARN}"
echo

echo "Publishing Lambda layer version for ${LAYER_NAME}..."
LAYER_VERSION_ARN="$(aws lambda publish-layer-version \
  --region "${REGION}" \
  --layer-name "${LAYER_NAME}" \
  --description "GoAccess ARM64 binary layer for ${PROJECT_PREFIX}" \
  --compatible-architectures arm64 \
  --compatible-runtimes python3.12 \
  --zip-file "fileb://${LAYER_ZIP}" \
  --query 'LayerVersionArn' \
  --output text)"

echo "Published layer version ARN: ${LAYER_VERSION_ARN}"
echo

echo "Tagging layer version with ProjectPrefix=${PROJECT_PREFIX} ..."
aws lambda tag-resource \
  --region "${REGION}" \
  --resource "${LAYER_VERSION_ARN}" \
  --tags "ProjectPrefix=${PROJECT_PREFIX}" || {
    echo "WARNING: Failed to tag layer version." >&2
  }

# ---------------------------------------------------------------------------
# Build Lambda function package (handler + goaccess.conf)
# ---------------------------------------------------------------------------

echo "Building GoAccess runner Lambda package..."
rm -rf "${FUNC_BUILD_DIR}"
mkdir -p "${FUNC_BUILD_DIR}"

cp "${HANDLER_FILE}" "${FUNC_BUILD_DIR}/"
cp "${GOACCESS_CONF}" "${FUNC_BUILD_DIR}/"

echo "Creating function zip: ${FUNC_ZIP}"
pushd "${FUNC_BUILD_DIR}" >/dev/null
zip -r "${FUNC_ZIP}" . >/dev/null
popd >/dev/null

echo "Function package size:"
du -h "${FUNC_ZIP}" || true
echo

CONFIG_SECRET_NAME="${PROJECT_PREFIX}-secrets-and-namings"

# ---------------------------------------------------------------------------
# Create or update Lambda function (ARM64)
# ---------------------------------------------------------------------------

echo "Checking if Lambda function '${LAMBDA_NAME}' exists..."
set +e
aws lambda get-function \
  --region "${REGION}" \
  --function-name "${LAMBDA_NAME}" >/dev/null 2>&1
get_fn_exit=$?
set -e

if [[ "${get_fn_exit}" -ne 0 ]]; then
  echo "Lambda does not exist. Creating new one: ${LAMBDA_NAME}"
  aws lambda create-function \
    --region "${REGION}" \
    --function-name "${LAMBDA_NAME}" \
    --runtime python3.12 \
    --architectures arm64 \
    --role "${ROLE_ARN}" \
    --handler run_goaccess_arm64.lambda_handler \
    --timeout 120 \
    --memory-size 1024 \
    --layers "${LAYER_VERSION_ARN}" \
    --environment "Variables={CONFIG_SECRET_NAME=${CONFIG_SECRET_NAME},PROJECT_PREFIX=${PROJECT_PREFIX},PROJECT_AWS_REGION=${REGION}}" \
    --zip-file "fileb://${FUNC_ZIP}"
  echo "Lambda function created."
else
  echo "Lambda exists. Updating code & configuration: ${LAMBDA_NAME}"

  aws lambda update-function-code \
    --region "${REGION}" \
    --function-name "${LAMBDA_NAME}" \
    --zip-file "fileb://${FUNC_ZIP}"

  aws lambda update-function-configuration \
    --region "${REGION}" \
    --function-name "${LAMBDA_NAME}" \
    --runtime python3.12 \
    --architectures arm64 \
    --role "${ROLE_ARN}" \
    --handler run_goaccess_arm64.lambda_handler \
    --timeout 120 \
    --memory-size 1024 \
    --layers "${LAYER_VERSION_ARN}" \
    --environment "Variables={CONFIG_SECRET_NAME=${CONFIG_SECRET_NAME},PROJECT_PREFIX=${PROJECT_PREFIX},PROJECT_AWS_REGION=${REGION}}"

  echo "Lambda function updated."
fi

echo
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${LAMBDA_NAME}"
echo "Tagging Lambda with ProjectPrefix=${PROJECT_PREFIX} ..."
aws lambda tag-resource \
  --region "${REGION}" \
  --resource "${LAMBDA_ARN}" \
  --tags "ProjectPrefix=${PROJECT_PREFIX}" || {
    echo "WARNING: Failed to tag Lambda function." >&2
  }

echo
echo "GoAccess layer & runner Lambda deployment complete."
