#!/bin/bash
set -euo pipefail

echo "============================"
echo "   GoAccess Report Runner"
echo "============================"

# ---------- Validate environment ----------
if [[ -z "${PROCESSING_BUCKET:-}" ]]; then
  echo "ERROR: PROCESSING_BUCKET environment variable not set."
  exit 1
fi

if [[ -z "${OUTPUT_BUCKET:-}" ]]; then
  echo "ERROR: OUTPUT_BUCKET environment variable not set."
  exit 1
fi

AGG_LOG_KEY="${AGGREGATED_LOG_KEY:-aggregated/all_logs.log}"
OUTPUT_KEY="${OUTPUT_KEY:-reports/goaccess-report.html}"
CONFIG_FILE="${GOACCESS_CONFIG_FILE:-/app/goaccess.conf}"

echo "PROCESSING_BUCKET = $PROCESSING_BUCKET"
echo "AGG_LOG_KEY       = $AGG_LOG_KEY"
echo "OUTPUT_BUCKET     = $OUTPUT_BUCKET"
echo "OUTPUT_KEY        = $OUTPUT_KEY"
echo "CONFIG_FILE       = $CONFIG_FILE"

# ---------- Prepare workspace ----------
mkdir -p /app/work
LOCAL_LOG="/app/work/all_logs.log"
LOCAL_HTML="/app/work/report.html"

echo "Downloading aggregated log from S3..."
aws s3 cp "s3://$PROCESSING_BUCKET/$AGG_LOG_KEY" "$LOCAL_LOG"

if [[ ! -s "$LOCAL_LOG" ]]; then
  echo "ERROR: Downloaded log file is empty or missing."
  exit 1
fi

echo "Running GoAccess..."
goaccess "$LOCAL_LOG" \
    --config-file="$CONFIG_FILE" \
    --output="$LOCAL_HTML"

if [[ ! -f "$LOCAL_HTML" ]]; then
  echo "ERROR: GoAccess did not generate output HTML."
  exit 1
fi

echo "Uploading HTML report to S3..."
aws s3 cp "$LOCAL_HTML" "s3://$OUTPUT_BUCKET/$OUTPUT_KEY" \
    --content-type "text/html"

echo "Upload complete."
echo "Report available at:"
echo "s3://$OUTPUT_BUCKET/$OUTPUT_KEY"

echo "Done!"