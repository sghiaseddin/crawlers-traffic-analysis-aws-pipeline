#!/usr/bin/env bash

set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KEYS_DIR="${PROJECT_ROOT}/keys"

echo "=== Step 9: Upload private SSH key to S3 ==="
echo "Project root : ${PROJECT_ROOT}"

# Requirement checks
if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found." >&2
  exit 1
fi

if [[ -z "${LOG_FETCH_PRIVATE_KEY_S3_BUCKET:-}" ]]; then
  echo "ERROR: LOG_FETCH_PRIVATE_KEY_S3_BUCKET is not set." >&2
  exit 1
fi

if [[ -z "${LOG_FETCH_PRIVATE_KEY_S3_KEY:-}" ]]; then
  echo "ERROR: LOG_FETCH_PRIVATE_KEY_S3_KEY is not set (the target object name)." >&2
  exit 1
fi

REGION="${PROJECT_AWS_REGION:-${AWS_DEFAULT_REGION:-eu-north-1}}"
PRIVATE_KEY_FILE="${KEYS_DIR}/${LOG_FETCH_PRIVATE_KEY_S3_KEY}"

if [[ ! -f "${PRIVATE_KEY_FILE}" ]]; then
  echo "ERROR: Private key file not found: ${PRIVATE_KEY_FILE}" >&2
  echo "Ensure your key exists under: ${KEYS_DIR}" >&2
  exit 1
fi

echo "Uploading private key to: s3://${LOG_FETCH_PRIVATE_KEY_S3_BUCKET}/${LOG_FETCH_PRIVATE_KEY_S3_KEY}"
aws s3 cp "${PRIVATE_KEY_FILE}" \
  "s3://${LOG_FETCH_PRIVATE_KEY_S3_BUCKET}/${LOG_FETCH_PRIVATE_KEY_S3_KEY}" \
  --region "${REGION}"

echo "Applying ProjectPrefix tag..."
aws s3api put-object-tagging \
  --bucket "${LOG_FETCH_PRIVATE_KEY_S3_BUCKET}" \
  --key "${LOG_FETCH_PRIVATE_KEY_S3_KEY}" \
  --tagging "TagSet=[{Key=ProjectPrefix,Value=${PROJECT_PREFIX}}]" \
  --region "${REGION}" || {
    echo "WARNING: Failed to apply tag." >&2
  }

echo "Private key upload complete."
