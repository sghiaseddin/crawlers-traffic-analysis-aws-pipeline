#!/usr/bin/env bash
#
# deploy_pipeline.sh
#
# Orchestrates the deployment of the crawlers traffic analysis pipeline.
#
# High-level steps:
#   1) Load project .env configuration (bucket names, prefixes, lambda names, etc.)
#   2) Load AWS credentials for CLI operations
#   3) Store env-derived configuration into AWS Secrets Manager
#   4) Package & deploy the Node.js log-fetch Lambda
#   5) (Future) Create S3 buckets, remaining Lambdas, triggers, etc.
#
# NOTE:
#   This script is intended to be executed directly:
#       ./deploy/deploy_pipeline.sh
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
# 1) Load .env configuration
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/1_read_env_variables.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/1_read_env_variables.sh" >&2
  exit 1
fi

# Source the env loader so that it exports all variables into this shell
# (including expansion of {project_prefix} placeholders).
echo "[1/4] Loading project environment variables from .env ..."
# shellcheck disable=SC1090
source "${PROJECT_ROOT}/deploy/1_read_env_variables.sh"
echo "[1/4] Environment variables loaded."
echo

# ---------------------------------------------------------------------------
# 2) Load AWS credentials for CLI (from local 'credentials' file)
# ---------------------------------------------------------------------------

if [[ ! -f "${PROJECT_ROOT}/deploy/2_read_aws_credential.sh" ]]; then
  echo "ERROR: Missing helper script: deploy/2_read_aws_credential.sh" >&2
  exit 1
fi

echo "[2/4] Loading AWS credentials from local credentials file ..."
# shellcheck disable=SC1090
source "${PROJECT_ROOT}/deploy/2_read_aws_credential.sh"
echo "[2/4] AWS credentials loaded."
echo

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
    echo "[3/4] Storing configuration & naming into AWS Secrets Manager ..."
    "${PROJECT_ROOT}/deploy/3_store_secrets_namings.sh"
    echo "[3/4] Secrets & naming stored."
    echo
    ;;
  skip)
    echo "[3/4] Skipping storage of configuration & naming into AWS Secrets Manager (per user choice)."
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
    echo "[4/4] Packaging & deploying Node.js log-fetch Lambda ..."
    "${PROJECT_ROOT}/deploy/4_fetch_log_lambda.sh"
    echo "[4/4] Node.js log-fetch Lambda deployed."
    echo
    ;;
  skip)
    echo "[4/4] Skipping Node.js log-fetch Lambda deployment (per user choice)."
    echo
    ;;
  quit)
    echo "User chose to quit deployment. Exiting."
    exit 0
    ;;
esac

echo "Deployment orchestrator finished steps 1–4."
echo "Next steps (future scripts):"
echo "  - deploy/5_deploy_lambdas.sh          # package & deploy remaining Lambda functions"
echo "  - deploy/6_configure_triggers.sh      # S3, EventBridge, and other triggers"
echo
