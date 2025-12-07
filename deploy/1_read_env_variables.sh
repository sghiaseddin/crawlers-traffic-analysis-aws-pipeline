#!/usr/bin/env bash
#
# 1_read_env_variables.sh
#
# Usage:
#   source deploy/1_read_env_variables.sh
#
# This script:
#   - Loads environment variables from a .env file
#   - Exports them for subsequent deploy scripts
#   - Replaces {project_prefix} placeholders in bucket/key names
#     with the value of PROJECT_PREFIX
#

set -euo pipefail

# Resolve project root as the parent of the deploy directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Allow overriding the env file path via ENV_FILE, otherwise default to PROJECT_ROOT/.env
ENV_FILE="${ENV_FILE:-"${PROJECT_ROOT}/.env"}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: .env file not found at: ${ENV_FILE}" >&2
  return 1 2>/dev/null || exit 1
fi

echo "Loading environment variables from: ${ENV_FILE}"

# Enable automatic export for all variables defined while sourcing the file
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# Basic sanity check
if [[ -z "${PROJECT_PREFIX:-}" ]]; then
  echo "ERROR: PROJECT_PREFIX is not set in ${ENV_FILE}" >&2
  return 1 2>/dev/null || exit 1
fi

# Helper to expand {project_prefix} placeholders in-place
_expand_with_project_prefix() {
  local var_name="$1"
  local current_value="${!var_name-}"

  if [[ -z "${current_value}" ]]; then
    return 0
  fi

  local replaced="${current_value//\{project_prefix\}/${PROJECT_PREFIX}}"
  # Use printf to avoid issues with special characters
  printf -v "${var_name}" '%s' "${replaced}"
  export "${var_name}"
}

# Expand known variables that may use {project_prefix} placeholder
_expand_with_project_prefix "LOG_FETCH_RAW_BUCKET"
_expand_with_project_prefix "LOG_FETCH_PRIVATE_KEY_S3_BUCKET"
_expand_with_project_prefix "LOG_PROCESSING_BUCKET"
_expand_with_project_prefix "LOG_OUTPUT_BUCKET"
_expand_with_project_prefix "LOG_ANALYSIS_LAMBDA_NAME"
_expand_with_project_prefix "LOG_GOACCESS_LAMBDA_NAME"

# Optional: show the resolved key variables for quick visual confirmation
echo "PROJECT_PREFIX                  = ${PROJECT_PREFIX}"
echo "LOG_FETCH_RAW_BUCKET            = ${LOG_FETCH_RAW_BUCKET:-<not set>}"
echo "LOG_FETCH_PRIVATE_KEY_S3_BUCKET = ${LOG_FETCH_PRIVATE_KEY_S3_BUCKET:-<not set>}"
echo "LOG_PROCESSING_BUCKET           = ${LOG_PROCESSING_BUCKET:-<not set>}"
echo "LOG_OUTPUT_BUCKET               = ${LOG_OUTPUT_BUCKET:-<not set>}"
echo "LOG_ANALYSIS_LAMBDA_NAME        = ${LOG_ANALYSIS_LAMBDA_NAME:-<not set>}"
echo "LOG_GOACCESS_LAMBDA_NAME        = ${LOG_GOACCESS_LAMBDA_NAME:-<not set>}"

echo "Environment variables loaded and exported."
