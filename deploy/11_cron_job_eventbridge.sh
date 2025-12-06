#!/usr/bin/env bash
#
# 11_cron_job_eventbridge.sh
#
# Usage:
#   ./deploy/11_cron_job_eventbridge.sh
#
# This script:
#   - Creates or updates a daily EventBridge (CloudWatch Events) rule
#     scheduled at 00:30 UTC
#   - Sets the target to the Node.js fetch-logs Lambda:
#       ${PROJECT_PREFIX}_lambda_fetch_logs_node
#   - Grants EventBridge permission to invoke that Lambda
#   - Tags the EventBridge rule with ProjectPrefix=${PROJECT_PREFIX}
#   - Configures an S3 bucket notification on the raw logs bucket to trigger
#     the ETL Lambda (${PROJECT_PREFIX}_lambda_etl_logs) for new raw/*.gz files
#
# Prereqs:
#   - 1_read_env_variables.sh has been sourced (PROJECT_PREFIX, PROJECT_AWS_REGION, etc.)
#   - 2_read_aws_credential.sh has been sourced (AWS creds in env)
#   - aws CLI is available in PATH
#

set -euo pipefail
# Avoid interactive paging from aws CLI
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Step 11: Configure daily EventBridge rule for fetch-logs Lambda ==="
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

if [[ -z "${PROJECT_PREFIX:-}" ]]; then
  echo "ERROR: PROJECT_PREFIX is not set. Did you source 1_read_env_variables.sh?" >&2
  exit 1
fi

REGION="${PROJECT_AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

LAMBDA_NAME="${PROJECT_PREFIX}_lambda_fetch_logs_node"
RULE_NAME="${PROJECT_PREFIX}_daily_fetch_logs_rule"

RAW_BUCKET="${LOG_FETCH_RAW_BUCKET:-}"
ETL_LAMBDA_NAME="${PROJECT_PREFIX}_lambda_etl_logs"
S3_NOTIFICATION_ID="raw-log-gz-to-etl"

echo "Target AWS Region        : ${REGION}"
echo "Fetch Lambda function    : ${LAMBDA_NAME}"
echo "EventBridge rule         : ${RULE_NAME}"
echo "Raw logs bucket          : ${RAW_BUCKET}"
echo "ETL Lambda function      : ${ETL_LAMBDA_NAME}"
echo

# ---------------------------------------------------------------------------
# Resolve AWS account ID and Lambda ARN
# ---------------------------------------------------------------------------

echo "Resolving AWS account ID..."
ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text --region "${REGION}")" || {
  echo "ERROR: Unable to retrieve AWS account ID." >&2
  exit 1
}

LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${LAMBDA_NAME}"
ETL_LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${ETL_LAMBDA_NAME}"
RULE_ARN="arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/${RULE_NAME}"
RAW_BUCKET_ARN="arn:aws:s3:::${RAW_BUCKET}"

echo "Using Fetch Lambda ARN : ${LAMBDA_ARN}"
echo "ETL Lambda ARN         : ${ETL_LAMBDA_ARN}"
echo "Rule ARN               : ${RULE_ARN}"
echo "Raw bucket ARN         : ${RAW_BUCKET_ARN}"
echo

# ---------------------------------------------------------------------------
# Ensure Lambda exists
# ---------------------------------------------------------------------------

echo "Checking if Lambda function '${LAMBDA_NAME}' exists..."
set +e
aws lambda get-function \
  --region "${REGION}" \
  --function-name "${LAMBDA_NAME}" >/dev/null 2>&1
get_fn_exit=$?
set -e

if [[ "${get_fn_exit}" -ne 0 ]]; then
  echo "ERROR: Lambda function '${LAMBDA_NAME}' does not exist in region ${REGION}." >&2
  echo "       Deploy the fetch-logs Lambda (step 4) before running this script." >&2
  exit 1
fi

if [[ -z "${RAW_BUCKET}" ]]; then
  echo "ERROR: LOG_FETCH_RAW_BUCKET is not set in environment." >&2
  exit 1
fi

echo "Checking if ETL Lambda function '${ETL_LAMBDA_NAME}' exists..."
set +e
aws lambda get-function \
  --region "${REGION}" \
  --function-name "${ETL_LAMBDA_NAME}" >/dev/null 2>&1
etl_fn_exit=$?
set -e

if [[ "${etl_fn_exit}" -ne 0 ]]; then
  echo "ERROR: Lambda function '${ETL_LAMBDA_NAME}' does not exist in region ${REGION}." >&2
  echo "       Deploy the ETL Lambda (step 5) before running this script." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Create or update EventBridge rule
# ---------------------------------------------------------------------------

echo "Creating/updating EventBridge rule '${RULE_NAME}' (daily at 00:30 UTC)..."

SCHEDULE_EXPR="cron(30 0 * * ? *)"

aws events put-rule \
  --region "${REGION}" \
  --name "${RULE_NAME}" \
  --schedule-expression "${SCHEDULE_EXPR}" \
  --state ENABLED \
  --description "Daily trigger at 00:30 UTC for ${LAMBDA_NAME}"

echo "Rule created/updated."
echo

echo "Tagging EventBridge rule with ProjectPrefix=${PROJECT_PREFIX} ..."
aws events tag-resource \
  --region "${REGION}" \
  --resource-arn "${RULE_ARN}" \
  --tags "Key=ProjectPrefix,Value=${PROJECT_PREFIX}" || {
    echo "WARNING: Failed to tag EventBridge rule." >&2
  }

echo

# ---------------------------------------------------------------------------
# Add Lambda target to the rule
# ---------------------------------------------------------------------------

echo "Configuring rule target -> Lambda..."

aws events put-targets \
  --region "${REGION}" \
  --rule "${RULE_NAME}" \
  --targets "Id"="1","Arn"="${LAMBDA_ARN}"

echo "Target configured."
echo

# ---------------------------------------------------------------------------
# Grant EventBridge permission to invoke Lambda
# ---------------------------------------------------------------------------

STATEMENT_ID="${PROJECT_PREFIX}-eventbridge-fetch-permission"

echo "Adding Lambda permission for EventBridge (if not already present)..."

set +e
aws lambda add-permission \
  --region "${REGION}" \
  --function-name "${LAMBDA_NAME}" \
  --statement-id "${STATEMENT_ID}" \
  --action "lambda:InvokeFunction" \
  --principal events.amazonaws.com \
  --source-arn "${RULE_ARN}" >/dev/null 2>&1
add_perm_exit=$?
set -e

if [[ "${add_perm_exit}" -ne 0 ]]; then
  echo "  -> Permission may already exist or add-permission failed; continuing."
else
  echo "  -> Permission added."
fi

echo
echo "Daily EventBridge trigger for fetch-logs Lambda configured."

echo
echo "-----------------------------------------------------------------"
echo "Configuring S3 -> ETL Lambda notification for raw/*.gz ..."
echo "-----------------------------------------------------------------"

# Grant S3 permission to invoke the ETL Lambda
S3_STATEMENT_ID="${PROJECT_PREFIX}-s3-raw-to-etl-permission"

echo "Adding Lambda permission for S3 to invoke ETL Lambda (if not already present)..."

set +e
aws lambda add-permission \
  --region "${REGION}" \
  --function-name "${ETL_LAMBDA_NAME}" \
  --statement-id "${S3_STATEMENT_ID}" \
  --action "lambda:InvokeFunction" \
  --principal s3.amazonaws.com \
  --source-arn "${RAW_BUCKET_ARN}" \
  --source-account "${ACCOUNT_ID}" >/dev/null 2>&1
s3_perm_exit=$?
set -e

if [[ "${s3_perm_exit}" -ne 0 ]]; then
  echo "  -> Permission may already exist or add-permission failed; continuing."
else
  echo "  -> S3 invoke permission added for ETL Lambda."
fi

# Configure bucket notification so that new raw/*.gz objects trigger the ETL Lambda.
# NOTE: This will overwrite any existing notification configuration on the bucket.
NOTIF_CONFIG="$(cat <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "${S3_NOTIFICATION_ID}",
      "LambdaFunctionArn": "${ETL_LAMBDA_ARN}",
      "Events": ["s3:ObjectCreated:Put"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "prefix", "Value": "raw/"},
            {"Name": "suffix", "Value": ".gz"}
          ]
        }
      }
    }
  ]
}
EOF
)"

echo "Applying bucket notification configuration to ${RAW_BUCKET} ..."
aws s3api put-bucket-notification-configuration \
  --bucket "${RAW_BUCKET}" \
  --notification-configuration "${NOTIF_CONFIG}" \
  --region "${REGION}"

echo "S3 bucket notification configured."

echo
echo "Daily EventBridge trigger and S3 -> ETL Lambda notification configured."
