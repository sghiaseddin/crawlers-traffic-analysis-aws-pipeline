import csv
import io
import json
import os
import re
import subprocess
import boto3
from typing import Dict, List, Tuple, Any
import logging
from datetime import datetime, date, timedelta

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client("secretsmanager")
s3 = boto3.client("s3")

def _get_config() -> Dict[str, Any]:
    secret_name = os.environ["CONFIG_SECRET_NAME"]
    resp = secrets_client.get_secret_value(SecretId=secret_name)

    if "SecretString" in resp:
        cfg_str = resp["SecretString"]
    else:
        cfg_str = resp["SecretBinary"].decode("utf-8")

    return json.loads(cfg_str)

GOACCESS_BIN = "/opt/bin/goaccess"
GOACCESS_CONFIG = "goaccess.conf"  # or /opt/goaccess.conf if packaged in the layer

def lambda_handler(event, context):
    # Load configuration from Secrets Manager
    cfg = _get_config()

    processing_bucket = cfg["LOG_PROCESSING_BUCKET"]
    agg_log_key = cfg.get("LOG_AGGREGATED_LOG_KEY", "aggregated/all_logs.log")

    output_bucket = cfg["LOG_OUTPUT_BUCKET"]
    # Prefix under which GoAccess HTML reports are stored, e.g. "goaccess" or "reports/goaccess"
    goaccess_prefix = cfg.get("LOG_GOACCESS_PREFIX", "goaccess")
    if goaccess_prefix and not goaccess_prefix.endswith("/"):
        goaccess_prefix = goaccess_prefix + "/"

    # Determine target date for this report: from event (if provided) or UTC today
    target_date: date | None = None
    if isinstance(event, dict):
        raw_date = event.get("date")
        # Also support API Gateway style queryStringParameters
        qsp = event.get("queryStringParameters") or {}
        if not raw_date and isinstance(qsp, dict):
            raw_date = qsp.get("date")
        if raw_date:
            try:
                target_date = datetime.strptime(raw_date, "%Y-%m-%d").date()
            except ValueError:
                target_date = None
    if target_date is None:
        # Default to yesterday (UTC) as a date object
        target_date = datetime.utcnow().date() - timedelta(days=1)

    target_date_str = target_date.isoformat()

    output_key = f"{goaccess_prefix}goaccess-report-{target_date_str}.html"

    # download log to /tmp
    local_log = "/tmp/all_logs.log"
    local_html = "/tmp/report.html"

    s3.download_file(processing_bucket, agg_log_key, local_log)

    # run goaccess
    cmd = [
        GOACCESS_BIN,
        local_log,
        "--config-file", GOACCESS_CONFIG,
        "--output", local_html,
    ]

    logger.info("Running command: %s", " ".join(cmd))

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True
    )

    logger.info("goaccess stdout: %s", result.stdout)
    logger.error("goaccess stderr: %s", result.stderr)
    logger.info("goaccess return code: %s", result.returncode)

    if result.returncode != 0:
        raise RuntimeError(f"goaccess failed with exit code {result.returncode}")

    # upload HTML
    s3.upload_file(local_html, output_bucket, output_key, ExtraArgs={"ContentType": "text/html"})

    return {
        "statusCode": 200,
        "body": f"Report generated at s3://{output_bucket}/{output_key}",
    }