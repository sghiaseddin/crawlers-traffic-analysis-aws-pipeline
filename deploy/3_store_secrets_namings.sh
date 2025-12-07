#!/usr/bin/env bash
#
# 3_store_secrets_namings.sh
#
# Usage:
#   ./deploy/3_store_secrets_namings.sh
#
# This script:
#   - Assumes project env vars are already loaded (1_read_env_variables.sh)
#   - Assumes AWS credentials are already loaded (2_read_aws_credential.sh)
#   - Builds a JSON document from env variables (naming & config)
#   - Creates or updates an AWS Secrets Manager secret:
#       ${PROJECT_PREFIX}-secrets-and-namings
#

set -euo pipefail

# Resolve project root (not strictly needed, but useful for logging)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Step 3: Store configuration & naming in AWS Secrets Manager ==="
echo

# ---------------------------------------------------------------------------
# Requirement checks
# ---------------------------------------------------------------------------

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found in PATH. Please install and configure AWS CLI." >&2
  exit 1
fi

if [[ -z "${PROJECT_PREFIX:-}" ]]; then
  echo "ERROR: PROJECT_PREFIX is not set. Did you source 1_read_env_variables.sh?" >&2
  exit 1
fi

SECRET_NAME="${PROJECT_PREFIX}-secrets-and-namings"
# Prefer PROJECT_AWS_REGION from .env if set; fall back to AWS_DEFAULT_REGION; then default to us-east-1
REGION="${PROJECT_AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

echo "Target AWS Region : ${REGION}"
echo "Secret name       : ${SECRET_NAME}"
echo

# ---------------------------------------------------------------------------
# Helper: JSON escape
# ---------------------------------------------------------------------------
# Minimal JSON string escaper for common characters.
json_escape() {
  local s="${1:-}"
  s=${s//\\/\\\\}  # backslash
  s=${s//\"/\\\"}  # double quote
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "${s}"
}

# Helper: add a field to JSON if the env var is set (non-empty)
# Usage: json_add_field "JSON_STRING" "key" "${ENV_VAR_NAME}"
json_add_field() {
  local json_str="$1"
  local key="$2"
  local var_name="$3"
  local value="${!var_name-}"

  if [[ -z "${value}" ]]; then
    printf '%s' "${json_str}"
    return 0
  fi

  local escaped_val
  escaped_val="$(json_escape "${value}")"

  if [[ "${json_str}" == "{" ]]; then
    printf '{\n  "%s": "%s"' "${key}" "${escaped_val}"
  else
    printf '%s,\n  "%s": "%s"' "${json_str}" "${key}" "${escaped_val}"
  fi
}

# ---------------------------------------------------------------------------
# Build JSON payload from env variables
# ---------------------------------------------------------------------------

echo "Building JSON payload from environment variables..."

json="{"

# Core fetch / SSH / log parameters
json=$(json_add_field "${json}" "LOG_FETCH_SSH_HOST" "LOG_FETCH_SSH_HOST")
json=$(json_add_field "${json}" "LOG_FETCH_SSH_PORT" "LOG_FETCH_SSH_PORT")
json=$(json_add_field "${json}" "LOG_FETCH_SSH_USER" "LOG_FETCH_SSH_USER")
json=$(json_add_field "${json}" "LOG_FETCH_REMOTE_LOG_DIR" "LOG_FETCH_REMOTE_LOG_DIR")
json=$(json_add_field "${json}" "LOG_FETCH_REMOTE_LOG_TEMPLATE" "LOG_FETCH_REMOTE_LOG_TEMPLATE")
json=$(json_add_field "${json}" "LOG_FETCH_DAY_OFFSET" "LOG_FETCH_DAY_OFFSET")
json=$(json_add_field "${json}" "LOG_FETCH_DATE_FORMAT" "LOG_FETCH_DATE_FORMAT")

# Buckets and keys
json=$(json_add_field "${json}" "LOG_FETCH_RAW_BUCKET" "LOG_FETCH_RAW_BUCKET")
json=$(json_add_field "${json}" "LOG_FETCH_PRIVATE_KEY_S3_BUCKET" "LOG_FETCH_PRIVATE_KEY_S3_BUCKET")
json=$(json_add_field "${json}" "LOG_FETCH_PRIVATE_KEY_S3_KEY" "LOG_FETCH_PRIVATE_KEY_S3_KEY")

json=$(json_add_field "${json}" "LOG_PROCESSING_BUCKET" "LOG_PROCESSING_BUCKET")
json=$(json_add_field "${json}" "LOG_PROCESSING_PREFIX" "LOG_PROCESSING_PREFIX")
json=$(json_add_field "${json}" "LOG_AGGREGATED_KEY" "LOG_AGGREGATED_KEY")
json=$(json_add_field "${json}" "LOG_AGGREGATED_LOG_KEY" "LOG_AGGREGATED_LOG_KEY")

json=$(json_add_field "${json}" "LOG_OUTPUT_BUCKET" "LOG_OUTPUT_BUCKET")
json=$(json_add_field "${json}" "LOG_ANALYSIS_PREFIX" "LOG_ANALYSIS_PREFIX")
json=$(json_add_field "${json}" "LOG_ANALYSIS_DAYS" "LOG_ANALYSIS_DAYS")

# Lambda names
json=$(json_add_field "${json}" "LOG_ANALYSIS_LAMBDA_NAME" "LOG_ANALYSIS_LAMBDA_NAME")
json=$(json_add_field "${json}" "LOG_GOACCESS_PREFIX" "LOG_GOACCESS_PREFIX")
json=$(json_add_field "${json}" "LOG_GOACCESS_LAMBDA_NAME" "LOG_GOACCESS_LAMBDA_NAME")

# AWS execution context (from .env / credentials)
json=$(json_add_field "${json}" "PROJECT_AWS_REGION" "PROJECT_AWS_REGION")
json=$(json_add_field "${json}" "PROJECT_AWS_IAM_ROLE" "PROJECT_AWS_IAM_ROLE")

# Project metadata
json=$(json_add_field "${json}" "PROJECT_PREFIX" "PROJECT_PREFIX")

# Close JSON object
json="${json}
}"

echo "JSON payload to store:"
echo "----------------------------------------"
echo "${json}"
echo "----------------------------------------"
echo

# ---------------------------------------------------------------------------
# Create or update the secret in AWS Secrets Manager
# ---------------------------------------------------------------------------

echo "Checking if secret '${SECRET_NAME}' already exists..."

set +e
aws secretsmanager describe-secret \
  --region "${REGION}" \
  --secret-id "${SECRET_NAME}" >/dev/null 2>&1
describe_exit_code=$?
set -e

if [[ "${describe_exit_code}" -ne 0 ]]; then
  echo "Secret does not exist. Creating new secret: ${SECRET_NAME}"
  aws secretsmanager create-secret \
    --region "${REGION}" \
    --name "${SECRET_NAME}" \
    --secret-string "${json}"
  echo "Secret created."
else
  echo "Secret already exists. Updating secret value: ${SECRET_NAME}"
  aws secretsmanager put-secret-value \
    --region "${REGION}" \
    --secret-id "${SECRET_NAME}" \
    --secret-string "${json}"
  echo "Secret updated."
fi

echo
echo "Configuration & naming successfully stored in Secrets Manager."