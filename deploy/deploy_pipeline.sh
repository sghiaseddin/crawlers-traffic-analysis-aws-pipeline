#!/usr/bin/env bash
#
# deploy_pipeline.sh
#
# Orchestrates the deployment of the crawlers traffic analysis pipeline.
#

set -euo pipefail

# Resolve script location and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Crawlers Traffic Analysis – Deployment Orchestrator ==="
echo "Script directory : ${SCRIPT_DIR}"
echo "Project root     : ${PROJECT_ROOT}"
echo

# Simple helper to ask whether to continue, skip, or quit a given step.
prompt_step_action() {
  local step_label="$1"
  local step_desc="$2"

  echo "-----------------------------------------------------------------" >&2
  echo "Step ${step_label}: ${step_desc}" >&2
  echo "What would you like to do?" >&2
  echo "  [c] Continue" >&2
  echo "  [s] Skip this step" >&2
  echo "  [q] Quit deployment" >&2
  echo "-----------------------------------------------------------------" >&2

  while true; do
    read -r -p "Enter choice [c/s/q] (default: c): " choice >&2
    choice="${choice:-c}"
    # Normalize to lowercase
    choice="${choice,,}"
    case "${choice}" in
      c|continue)
        echo "continue"
        return 0
        ;;
      s|skip)
        echo "skip"
        return 0
        ;;
      q|quit)
        echo "quit"
        return 0
        ;;
      *)
        echo "Invalid choice. Please enter 'c', 's', or 'q'." >&2
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 0) Load .env configuration
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/0_read_env_variables.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/0_read_env_variables.sh" >&2
  exit 1
fi

# Source the env loader so that it exports all variables into this shell
# (including expansion of {project_prefix} placeholders).
echo "[0/12] Loading project environment variables from .env ..."
# shellcheck disable=SC1090
source "${PROJECT_ROOT}/deploy/0_read_env_variables.sh"
echo "[0/12] Environment variables loaded."
echo

# ---------------------------------------------------------------------------
# 1) Load AWS credentials for CLI (from local 'credentials' file)
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/1_read_aws_credential.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/1_read_aws_credential.sh" >&2
  exit 1
fi

echo "[1/12] Loading AWS credentials from local credentials file ..."
# shellcheck disable=SC1090
source "${PROJECT_ROOT}/deploy/1_read_aws_credential.sh"
echo "[1/12] AWS credentials loaded."
echo

# ---------------------------------------------------------------------------
# 2) Store IAM role and policy
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/2_store_iam_role_policy.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/2_store_iam_role_policy.sh" >&2
  exit 1
fi

step3_action="$(prompt_step_action "2" "Store IAM role and policy")"

case "${step3_action}" in
  continue)
    echo "[2/12] Store IAM role and policy ..."
    "${PROJECT_ROOT}/deploy/2_store_iam_role_policy.sh"
    echo "[2/12] Store IAM role and policy stored."
    echo
    ;;
  skip)
    echo "[2/12] Skipping IAM role and policy (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 3) Store configuration & naming into AWS Secrets Manager
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/3_store_secrets_namings.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/3_store_secrets_namings.sh" >&2
  exit 1
fi

step3_action="$(prompt_step_action "3" "Store configuration & naming into AWS Secrets Manager")"

case "${step3_action}" in
  continue)
    echo "[3/12] Storing configuration & naming into AWS Secrets Manager ..."
    "${PROJECT_ROOT}/deploy/3_store_secrets_namings.sh"
    echo "[3/12] Secrets & naming stored."
    echo
    ;;
  skip)
    echo "[3/12] Skipping storage of configuration & naming into AWS Secrets Manager (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 4) Package & deploy the Node.js log-fetch Lambda
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/4_fetch_log_lambda.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/4_fetch_log_lambda.sh" >&2
  exit 1
fi

step4_action="$(prompt_step_action "4" "Package & deploy the Node.js log-fetch Lambda")"

case "${step4_action}" in
  continue)
    echo "[4/12] Packaging & deploying Node.js log-fetch Lambda ..."
    "${PROJECT_ROOT}/deploy/4_fetch_log_lambda.sh"
    echo "[4/12] Node.js log-fetch Lambda deployed."
    echo
    ;;
  skip)
    echo "[4/12] Skipping Node.js log-fetch Lambda deployment (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 5) Package & deploy the Python ETL logs Lambda
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/5_etl_logs_lambda.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/5_etl_logs_lambda.sh" >&2
  exit 1
fi

step5_action="$(prompt_step_action "5" "Package & deploy the Python ETL logs Lambda")"

case "${step5_action}" in
  continue)
    echo "[5/12] Packaging & deploying Python ETL logs Lambda ..."
    "${PROJECT_ROOT}/deploy/5_etl_logs_lambda.sh"
    echo "[5/12] Python ETL logs Lambda deployed."
    echo
    ;;
  skip)
    echo "[5/12] Skipping Python ETL logs Lambda deployment (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 6) Package & deploy the Python Analyze Bots Lambda
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/6_analyze_bots_lambda.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/6_analyze_bots_lambda.sh" >&2
  exit 1
fi

step6_action="$(prompt_step_action "6" "Package & deploy the Python Analyze Bots Lambda")"

case "${step6_action}" in
  continue)
    echo "[6/12] Packaging & deploying Python Analyze Bots Lambda ..."
    "${PROJECT_ROOT}/deploy/6_analyze_bots_lambda.sh"
    echo "[6/12] Python Analyze Bots Lambda deployed."
    echo
    ;;
  skip)
    echo "[6/12] Skipping Python Analyze Bots Lambda deployment (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 7) Package & deploy the GoAccess Engine Lambda
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/7_goaccess_lambda.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/7_goaccess_lambda.sh" >&2
  exit 1
fi

step7_action="$(prompt_step_action "7" "Package & deploy the GoAccess Engine Lambda")"

case "${step7_action}" in
  continue)
    echo "[7/12] Packaging & deploying GoAccess Engine Lambda ..."
    "${PROJECT_ROOT}/deploy/7_goaccess_lambda.sh"
    echo "[7/12] GoAccess Engine Lambda deployed."
    echo
    ;;
  skip)
    echo "[7/12] Skipping GoAccess Engine Lambda deployment (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 8) Create S3 buckets for the pipeline
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/8_create_buckets.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/8_create_buckets.sh" >&2
  exit 1
fi

step8_action="$(prompt_step_action "8" "Create S3 buckets")"

case "${step8_action}" in
  continue)
    echo "[8/12] Creating S3 buckets ..."
    "${PROJECT_ROOT}/deploy/8_create_buckets.sh"
    echo "[8/12] S3 buckets created."
    echo
    ;;
  skip)
    echo "[8/12] Skipping Create S3 buckets deployment (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 9) Upload private key to the S3 ssh-key-bucket
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/9_upload_private_key.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/9_upload_private_key.sh" >&2
  exit 1
fi

step9_action="$(prompt_step_action "9" "Upload ssh private key to the S3 ssh-key-bucket")"

case "${step9_action}" in
  continue)
    echo "[9/12] Uploading ssh private key ..."
    "${PROJECT_ROOT}/deploy/9_upload_private_key.sh"
    echo "[9/12] ssh private key uploaded."
    echo
    ;;
  skip)
    echo "[9/12] Skipping Upload ssh private key (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac


# ---------------------------------------------------------------------------
# 10) Set database and crawler in Glue
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/10_set_crawler_glue.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/10_set_crawler_glue.sh" >&2
  exit 1
fi

step10_action="$(prompt_step_action "10" "Set database and crawler in the Glue")"

case "${step10_action}" in
  continue)
    echo "[10/12] Setting database and crawler ..."
    "${PROJECT_ROOT}/deploy/10_set_crawler_glue.sh"
    echo "[10/12] Database and crawler has set."
    echo
    ;;
  skip)
    echo "[10/12] Skipping Set database and crawler (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac


# ---------------------------------------------------------------------------
# 11) Set daily cron job in the EventBridge
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/11_cron_job_eventbridge.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/11_cron_job_eventbridge.sh" >&2
  exit 1
fi

step11_action="$(prompt_step_action "11" "Set daily cron job in the EventBridge")"

case "${step11_action}" in
  continue)
    echo "[11/12] Setting daily cron job ..."
    "${PROJECT_ROOT}/deploy/11_cron_job_eventbridge.sh"
    echo "[11/12] Cron job has set."
    echo
    ;;
  skip)
    echo "[11/12] Skipping daily cron job (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac


# ---------------------------------------------------------------------------
# 12) Package and Deploy View Report Node in Lambda Function
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/12_view_report_node_lambda.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/12_view_report_node_lambda.sh" >&2
  exit 1
fi

step12_action="$(prompt_step_action "12" "Set Package and Deploy View Report Node in Lambda Function")"

case "${step12_action}" in
  continue)
    echo "[12/12] Packaging view report node ..."
    "${PROJECT_ROOT}/deploy/12_view_report_node_lambda.sh"
    echo "[12/12] View report node deployed."
    echo
    ;;
  skip)
    echo "[12/12] Skipping view report node (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac


# ---------------------------------------------------------------------------
# Final: Manual trigger of fetch-logs Lambda
# ---------------------------------------------------------------------------

echo "-----------------------------------------------------------------"
read -r -p "Do you want to trigger an initial run of the log-fetch Lambda now? [y/N]: " trigger_choice
trigger_choice="${trigger_choice:-n}"
trigger_choice="${trigger_choice,,}"

if [[ "${trigger_choice}" == "y" || "${trigger_choice}" == "yes" ]]; then
  echo "Triggering ${PROJECT_PREFIX}_lambda_fetch_logs_node once..."

  if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: aws CLI not found. Cannot trigger Lambda." >&2
  else
    REGION="${PROJECT_AWS_REGION:-${AWS_DEFAULT_REGION:-eu-north-1}}"
    FETCH_LAMBDA_NAME="${PROJECT_PREFIX}_lambda_fetch_logs_node"
    INVOKE_OUT="/tmp/log_fetch_invoke.json"

    echo "Using region: ${REGION}"
    echo "Invoking Lambda: ${FETCH_LAMBDA_NAME}"

    set +e
    invoke_status_code="$(aws lambda invoke \
      --region "${REGION}" \
      --function-name "${FETCH_LAMBDA_NAME}" \
      --invocation-type RequestResponse \
      --payload '{}' \
      "${INVOKE_OUT}" \
      --query 'StatusCode' \
      --output text 2>/dev/null)"
    invoke_exit=$?
    set -e

    if [[ "${invoke_exit}" -ne 0 ]]; then
      echo "ERROR: Failed to invoke ${FETCH_LAMBDA_NAME}. Please check AWS CLI output/logs." >&2
    else
      if [[ "${invoke_status_code}" == "200" ]]; then
        echo "Lambda trigger was successful (StatusCode=${invoke_status_code})."
      else
        echo "Lambda trigger completed but returned StatusCode=${invoke_status_code} (expected 200)." >&2
      fi
    fi

    # Optionally remove the payload file to avoid clutter
    rm -f "${INVOKE_OUT}" 2>/dev/null || true
  fi
else
  echo "Skipping manual trigger of the log-fetch Lambda."
fi

echo
echo "Deployment pipeline script finished."