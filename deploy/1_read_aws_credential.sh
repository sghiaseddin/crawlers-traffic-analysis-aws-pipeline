#!/usr/bin/env bash
#
# 2_read_aws_credential.sh
#
# Usage:
#   source deploy/2_read_aws_credential.sh
#
# This script loads AWS CLI credentials from a local 'credentials' file
# located in the project root directory.
#
# Supported format (same as ~/.aws/credentials but simplified):
#   AWS_ACCESS_KEY_ID=...
#   AWS_SECRET_ACCESS_KEY=...
#   AWS_DEFAULT_REGION=...
#

set -euo pipefail

# Determine project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CRED_FILE="${PROJECT_ROOT}/credentials"

if [[ ! -f "${CRED_FILE}" ]]; then
  echo "ERROR: AWS credentials file not found at: ${CRED_FILE}" >&2
  return 1 2>/dev/null || exit 1
fi

echo "Loading AWS credentials from: ${CRED_FILE}"

# If the file looks like an AWS shared-credentials file ([default] section),
# parse it; otherwise treat it as a simple KEY=VALUE shell file.
if grep -q '^\[default\]' "${CRED_FILE}"; then
  # Parse [default] profile in INI format
  AWS_ACCESS_KEY_ID="$(awk -F'=' '
    BEGIN { in_default=0 }
    /^\[default\]/ { in_default=1; next }
    /^\[/ { in_default=0 }
    in_default && $1 ~ /aws_access_key_id/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
      print $2;
      exit;
    }
  ' "${CRED_FILE}")"

  AWS_SECRET_ACCESS_KEY="$(awk -F'=' '
    BEGIN { in_default=0 }
    /^\[default\]/ { in_default=1; next }
    /^\[/ { in_default=0 }
    in_default && $1 ~ /aws_secret_access_key/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
      print $2;
      exit;
    }
  ' "${CRED_FILE}")"

  AWS_SESSION_TOKEN="$(awk -F'=' '
    BEGIN { in_default=0 }
    /^\[default\]/ { in_default=1; next }
    /^\[/ { in_default=0 }
    in_default && $1 ~ /aws_session_token/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
      print $2;
      exit;
    }
  ' "${CRED_FILE}")"

  AWS_DEFAULT_REGION="$(awk -F'=' '
    BEGIN { in_default=0 }
    /^\[default\]/ { in_default=1; next }
    /^\[/ { in_default=0 }
    in_default && ($1 ~ /region/ || $1 ~ /aws_region/) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
      print $2;
      exit;
    }
  ' "${CRED_FILE}")"

  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
    export AWS_SESSION_TOKEN
  fi
  if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    export AWS_DEFAULT_REGION
  fi
else
  # Simple KEY=VALUE format; source it directly
  set -a
  # shellcheck disable=SC1090
  source "${CRED_FILE}"
  set +a
fi

# Basic validation
if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  echo "ERROR: AWS_ACCESS_KEY_ID not set" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "ERROR: AWS_SECRET_ACCESS_KEY not set" >&2
  return 1 2>/dev/null || exit 1
fi

echo "AWS credentials loaded successfully."
