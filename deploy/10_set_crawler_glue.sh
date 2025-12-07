#!/usr/bin/env bash
#
# 10_set_crawler_glue.sh
#
# Usage:
#   ./deploy/10_set_crawler_glue.sh
#
# This script:
#   - Ensures an AWS Glue Database exists for the project
#   - Ensures an AWS Glue Crawler exists targeting the processed CSVs in:
#       s3://${LOG_PROCESSING_BUCKET}/${LOG_PROCESSING_PREFIX}
#   - Names them using PROJECT_PREFIX:
#       Database: ${PROJECT_PREFIX}_logs_db
#       Crawler : ${PROJECT_PREFIX}_logs_crawler
#   - Uses IAM role PROJECT_AWS_IAM_ROLE (e.g. LabRole) for the crawler
#   - Tags resources with ProjectPrefix=${PROJECT_PREFIX}
#
# Prereqs:
#   - 1_read_env_variables.sh has been sourced (PROJECT_PREFIX, LOG_PROCESSING_BUCKET, LOG_PROCESSING_PREFIX, PROJECT_AWS_REGION, etc.)
#   - 2_read_aws_credential.sh has been sourced (AWS creds in env)
#   - aws CLI is available in PATH
#

set -euo pipefail
# Avoid interactive paging from aws CLI
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Step 10: Configure AWS Glue Database & Crawler ==="
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

if [[ -z "${LOG_PROCESSING_BUCKET:-}" ]]; then
  echo "ERROR: LOG_PROCESSING_BUCKET is not set in environment." >&2
  exit 1
fi

REGION="${PROJECT_AWS_REGION:-${AWS_DEFAULT_REGION:-eu-north-1}}"
ROLE_NAME="${PROJECT_AWS_IAM_ROLE:-LabRole}"

echo "Target AWS Region : ${REGION}"
echo "Glue IAM Role     : ${ROLE_NAME}"
echo

# Normalize processing prefix and build S3 path
prefix="${LOG_PROCESSING_PREFIX:-}"
# remove leading slash if any
prefix="${prefix#/}"
# ensure trailing slash if not empty
if [[ -n "${prefix}" && "${prefix}" != */ ]]; then
  prefix="${prefix}/"
fi

S3_TARGET_PATH="s3://${LOG_PROCESSING_BUCKET}/${prefix}"

echo "Glue S3 target path: ${S3_TARGET_PATH}"
echo

GLUE_DB_NAME="${PROJECT_PREFIX}_logs_db"
GLUE_CRAWLER_NAME="${PROJECT_PREFIX}_logs_crawler"

# ---------------------------------------------------------------------------
# Resolve AWS Account ID and IAM Role ARN
# ---------------------------------------------------------------------------

echo "Resolving AWS account ID..."
ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text --region "${REGION}")" || {
  echo "ERROR: Unable to retrieve AWS account ID." >&2
  exit 1
}

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo "Using Glue IAM Role ARN: ${ROLE_ARN}"
echo

# ---------------------------------------------------------------------------
# Ensure Glue Database exists
# ---------------------------------------------------------------------------

echo "Checking Glue Database: ${GLUE_DB_NAME}"
set +e
aws glue get-database \
  --region "${REGION}" \
  --name "${GLUE_DB_NAME}" >/dev/null 2>&1
get_db_exit=$?
set -e

if [[ "${get_db_exit}" -ne 0 ]]; then
  echo "  -> Database does not exist. Creating..."
  aws glue create-database \
    --region "${REGION}" \
    --database-input "Name=${GLUE_DB_NAME},Description=Logs database for ${PROJECT_PREFIX} crawlers traffic pipeline" \
    --tags "ProjectPrefix=${PROJECT_PREFIX}"
  echo "  -> Database created."
else
  echo "  -> Database already exists."
fi

echo

# ---------------------------------------------------------------------------
# Ensure Glue Crawler exists
# ---------------------------------------------------------------------------

echo "Checking Glue Crawler: ${GLUE_CRAWLER_NAME}"
set +e
aws glue get-crawler \
  --region "${REGION}" \
  --name "${GLUE_CRAWLER_NAME}" >/dev/null 2>&1
get_crawler_exit=$?
set -e

CRAWLER_TARGETS_JSON="S3Targets=[{Path=\"${S3_TARGET_PATH}\"}]"

if [[ "${get_crawler_exit}" -ne 0 ]]; then
  echo "  -> Crawler does not exist. Creating..."

  aws glue create-crawler \
    --region "${REGION}" \
    --name "${GLUE_CRAWLER_NAME}" \
    --role "${ROLE_ARN}" \
    --database-name "${GLUE_DB_NAME}" \
    --targets "${CRAWLER_TARGETS_JSON}" \
    --table-prefix "${PROJECT_PREFIX}_" \
    --description "Crawler for processed access logs (CSV) for ${PROJECT_PREFIX}" \
    --tags "ProjectPrefix=${PROJECT_PREFIX}"

  echo "  -> Crawler created."
else
  echo "  -> Crawler already exists. Updating configuration (role, targets, db, table prefix)..."

  aws glue update-crawler \
    --region "${REGION}" \
    --name "${GLUE_CRAWLER_NAME}" \
    --role "${ROLE_ARN}" \
    --database-name "${GLUE_DB_NAME}" \
    --targets "${CRAWLER_TARGETS_JSON}" \
    --table-prefix "${PROJECT_PREFIX}_"

  echo "  -> Crawler updated."
fi

echo
echo "Glue Database & Crawler configuration complete."
