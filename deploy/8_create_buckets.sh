#!/usr/bin/env bash
#
# 8_create_buckets.sh
#
# Usage:
#   ./deploy/8_create_buckets.sh
#
# This script:
#   - Ensures the core S3 buckets for the pipeline exist:
#       * LOG_FETCH_RAW_BUCKET
#       * LOG_FETCH_PRIVATE_KEY_S3_BUCKET
#       * LOG_PROCESSING_BUCKET
#       * LOG_OUTPUT_BUCKET
#
# Prereqs:
#   - 1_read_env_variables.sh has been sourced (PROJECT_PREFIX, LOG_* vars, PROJECT_AWS_REGION, etc.)
#   - 2_read_aws_credential.sh has been sourced (AWS creds in env)
#   - aws CLI is available in PATH
#

set -euo pipefail
# Disable AWS CLI pager so long outputs don't block in an interactive 'less' session.
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Step 8: Create/verify S3 buckets ==="
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

if [[ -z "${PROJECT_PREFIX:-}" ]]; then
  echo "ERROR: PROJECT_PREFIX is not set. Did you source 1_read_env_variables.sh?" >&2
  exit 1
fi

REGION="${PROJECT_AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

echo "Target AWS Region : ${REGION}"
echo "Project prefix    : ${PROJECT_PREFIX}"
echo

# Helper to ensure a bucket exists and is tagged
ensure_bucket() {
  local bucket_name="$1"
  local label="$2"

  if [[ -z "${bucket_name}" ]]; then
    echo "Skipping ${label}: bucket name is empty/not set." >&2
    return 0
  fi

  echo "Checking bucket (${label}): ${bucket_name}"

  set +e
  aws s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1
  local head_exit=$?
  set -e

  if [[ "${head_exit}" -eq 0 ]]; then
    echo "  -> Bucket already exists."
  else
    echo "  -> Bucket does not exist. Creating..."

    # For us-east-1, do NOT specify CreateBucketConfiguration
    if [[ "${REGION}" == "us-east-1" ]]; then
      if ! aws s3api create-bucket --bucket "${bucket_name}" --region "${REGION}" 2>/tmp/create-bucket.err; then
        echo "WARNING: Failed to create bucket ${bucket_name}. Error:" >&2
        cat /tmp/create-bucket.err >&2 || true
        rm -f /tmp/create-bucket.err || true
        return 1
      fi
    else
      if ! aws s3api create-bucket \
        --bucket "${bucket_name}" \
        --region "${REGION}" \
        --create-bucket-configuration "LocationConstraint=${REGION}" 2>/tmp/create-bucket.err; then
        echo "WARNING: Failed to create bucket ${bucket_name}. Error:" >&2
        cat /tmp/create-bucket.err >&2 || true
        rm -f /tmp/create-bucket.err || true
        return 1
      fi
    fi

    rm -f /tmp/create-bucket.err || true
    echo "  -> Bucket created."
  fi

  echo "  -> Applying ProjectPrefix tag..."
  set +e
  aws s3api put-bucket-tagging \
    --bucket "${bucket_name}" \
    --tagging "TagSet=[{Key=ProjectPrefix,Value=${PROJECT_PREFIX}}]" >/dev/null 2>&1
  local tag_exit=$?
  set -e

  if [[ "${tag_exit}" -ne 0 ]]; then
    echo "WARNING: Failed to tag bucket ${bucket_name} with ProjectPrefix=${PROJECT_PREFIX}" >&2
  else
    echo "  -> Tag applied: ProjectPrefix=${PROJECT_PREFIX}"
  fi

  echo
}

# ---------------------------------------------------------------------------
# Ensure all core buckets exist
# ---------------------------------------------------------------------------

ensure_bucket "${LOG_FETCH_RAW_BUCKET:-}" "Raw access logs bucket (LOG_FETCH_RAW_BUCKET)"
ensure_bucket "${LOG_FETCH_PRIVATE_KEY_S3_BUCKET:-}" "SSH private key bucket (LOG_FETCH_PRIVATE_KEY_S3_BUCKET)"
ensure_bucket "${LOG_PROCESSING_BUCKET:-}" "Processing logs bucket (LOG_PROCESSING_BUCKET)"
ensure_bucket "${LOG_OUTPUT_BUCKET:-}" "Output/report bucket (LOG_OUTPUT_BUCKET)"

echo "S3 bucket verification/creation step complete."
