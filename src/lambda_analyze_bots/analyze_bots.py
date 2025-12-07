"""
Bot analysis on aggregated CSV logs.

This module:
- Reads the aggregated CSV (all_logs.csv) from the processing bucket
- Uses bot_map.json to classify crawlers/bots by user-agent
- Filters to the last N days (default: 365)
- Aggregates:
    * How frequently these bots access the website (total + daily counts)
    * Which specific crawlers are doing it (bot names)
    * Which pages they are collecting content from (top paths per bot)
    * How this behavior changes over time (per-day time series)
- Writes a JSON report into a separate analysis S3 bucket, with the date
  embedded in the filename (for caching / versioning).

Intended to run as an AWS Lambda with handler: analyze_bots.lambda_handler
"""

import csv
import io
import json
import os
import re
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Dict, List, Tuple, Any

import boto3
from botocore.exceptions import ClientError

# --------------------------------------------------------------------
# Bot map loading and classification
# --------------------------------------------------------------------


@dataclass
class BotPattern:
    name: str
    regex: re.Pattern
    is_llm: bool
    ip_ranges: List[str]


def _bot_map_path() -> str:
    """
    Resolve bot_map.json relative to this file.

    Repo structure:
      bot_map.json
      src/analyze_bots.py
    """
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "bot_map.json"))


def load_bot_patterns(path: str = None) -> List[BotPattern]:
    """
    Load bot patterns from bot_map.json.

    Expected structure per bot:

      "GPTBot": {
        "patterns": [...],
        "ip_ranges": [...],
        "is_llm": true
      }

    Missing fields get reasonable defaults.
    """
    if path is None:
        path = _bot_map_path()

    with open(path, "r", encoding="utf-8") as f:
        raw = json.load(f)

    patterns: List[BotPattern] = []

    for name, spec in raw.items():
        if isinstance(spec, dict):
            pats = spec.get("patterns", [])
            if isinstance(pats, str):
                pats = [pats]
            pats = [str(p) for p in pats]

            ip_ranges = spec.get("ip_ranges", []) or []
            is_llm = bool(spec.get("is_llm", True))
        else:
            # Simple backward-compatible case: treat value as a pattern string
            pats = [str(spec)]
            ip_ranges = []
            is_llm = True

        if not pats:
            # Fallback to bot name as pattern
            pats = [name]

        combined = "|".join(pats)
        regex = re.compile(combined, re.IGNORECASE)

        patterns.append(
            BotPattern(
                name=name,
                regex=regex,
                is_llm=is_llm,
                ip_ranges=ip_ranges,
            )
        )

    return patterns


def classify_user_agent(user_agent: str, bot_patterns: List[BotPattern]) -> Tuple[str, bool, bool]:
    """
    Classify a user-agent string using the compiled bot patterns.

    Returns:
      (bot_name, is_bot, is_llm)

    If no pattern matches, returns ("Unknown", False, False).
    """
    if not user_agent:
        return "Unknown", False, False

    for bp in bot_patterns:
        if bp.regex.search(user_agent):
            return bp.name, True, bp.is_llm

    return "Unknown", False, False


# --------------------------------------------------------------------
# Core aggregation logic
# --------------------------------------------------------------------


def analyze_aggregated_csv(
    s3_client,
    processing_bucket: str,
    aggregated_key: str,
    days_back: int = 365,
) -> Dict[str, Any]:
    """
    Read the aggregated CSV from S3, filter to last `days_back` days,
    classify bots, and compute aggregate metrics.

    Returns a dict suitable to be serialized as JSON.
    """
    # Load bot patterns once
    bot_patterns = load_bot_patterns()

    # Date window
    now = datetime.utcnow().date()
    start_date = now - timedelta(days=days_back)

    # Structures:
    #   bot_totals[bot] -> total requests
    #   bot_daily[bot][date] -> count
    #   bot_paths[bot][path] -> count
    bot_totals: Dict[str, int] = defaultdict(int)
    bot_daily: Dict[str, Dict[str, int]] = defaultdict(lambda: defaultdict(int))
    bot_paths: Dict[str, Dict[str, int]] = defaultdict(lambda: defaultdict(int))
    bot_is_llm: Dict[str, bool] = {}

    overall_total = 0
    overall_paths = set()

    try:
        obj = s3_client.get_object(Bucket=processing_bucket, Key=aggregated_key)
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code")
        if code in ("NoSuchKey", "404"):
            # No aggregated CSV yet -> empty report
            return {
                "generated_at": datetime.utcnow().isoformat() + "Z",
                "window": {
                    "from": start_date.isoformat(),
                    "to": now.isoformat(),
                },
                "overall": {
                    "total_requests": 0,
                    "unique_bots": 0,
                    "unique_paths": 0,
                },
                "bots": [],
            }
        raise

    # Stream CSV from S3
    body = obj["Body"]
    text_stream = io.TextIOWrapper(body, encoding="utf-8")
    reader = csv.DictReader(text_stream)

    for row in reader:
        date_str = (row.get("date") or "").strip()
        if not date_str:
            continue

        try:
            row_date = datetime.strptime(date_str, "%Y-%m-%d").date()
        except ValueError:
            # Skip bad dates
            continue

        if row_date < start_date:
            # Older than our analysis window
            continue

        user_agent = (row.get("user_agent") or "").strip()
        path = (row.get("path") or "").strip()
        if not path:
            path = "/"

        bot_name, is_bot, is_llm = classify_user_agent(user_agent, bot_patterns)

        if not is_bot:
            # Skip non-bot traffic for this report
            continue

        bot_totals[bot_name] += 1
        bot_daily[bot_name][date_str] += 1
        bot_paths[bot_name][path] += 1
        bot_is_llm[bot_name] = is_llm

        overall_total += 1
        overall_paths.add(path)

    # Build JSON-friendly structure
    bots_report = []

    for bot_name, total in bot_totals.items():
        daily_dict = bot_daily[bot_name]
        # Convert to sorted list for time-series
        daily_series = [
            {"date": d, "requests": c}
            for d, c in sorted(daily_dict.items())
        ]

        paths_dict = bot_paths[bot_name]
        # Top pages per bot (sorted desc by count)
        top_paths = sorted(
            [{"path": p, "requests": c} for p, c in paths_dict.items()],
            key=lambda x: x["requests"],
            reverse=True,
        )

        bots_report.append(
            {
                "bot_name": bot_name,
                "is_llm": bool(bot_is_llm.get(bot_name, True)),
                "total_requests": total,
                "daily_requests": daily_series,
                "top_paths": top_paths,
            }
        )

    # Sort bots by total requests desc
    bots_report.sort(key=lambda x: x["total_requests"], reverse=True)

    report = {
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "window": {
            "from": start_date.isoformat(),
            "to": now.isoformat(),
        },
        "overall": {
            "total_requests": overall_total,
            "unique_bots": len(bot_totals),
            "unique_paths": len(overall_paths),
        },
        "bots": bots_report,
    }

    return report


# --------------------------------------------------------------------
# Lambda integration
# --------------------------------------------------------------------

secrets_client = boto3.client("secretsmanager")
s3_client = boto3.client("s3")


def _get_config() -> Dict[str, Any]:
    secret_name = os.environ["CONFIG_SECRET_NAME"]
    resp = secrets_client.get_secret_value(SecretId=secret_name)

    if "SecretString" in resp:
        cfg_str = resp["SecretString"]
    else:
        cfg_str = resp["SecretBinary"].decode("utf-8")

    return json.loads(cfg_str)


def handler(event, context):
    """
    AWS Lambda entrypoint for bot analysis.

    Expects in Secrets Manager (llm-log-pipeline-config):
      - LOG_PROCESSING_BUCKET: bucket with aggregated CSV file
      - LOG_AGGREGATED_KEY: key for aggregated CSV (default: aggregated/all_logs.csv)
      - LOG_OUTPUT_BUCKET: bucket where JSON reports are stored
      - LOG_ANALYSIS_PREFIX: prefix for reports (default: reports)
      - LOG_ANALYSIS_DAYS: optional override for analysis window (days), default 365
    """
    cfg = _get_config()

    processing_bucket = cfg["LOG_PROCESSING_BUCKET"]
    aggregated_key = cfg.get("LOG_AGGREGATED_KEY", "aggregated/all_logs.csv")
    analysis_bucket = cfg["LOG_OUTPUT_BUCKET"]
    analysis_prefix = cfg.get("LOG_ANALYSIS_PREFIX", "reports")
    days_back = int(cfg.get("LOG_ANALYSIS_DAYS", "365"))

    if analysis_prefix and not analysis_prefix.endswith("/"):
        analysis_prefix = analysis_prefix + "/"

    # Perform analysis
    report = analyze_aggregated_csv(
        s3_client=s3_client,
        processing_bucket=processing_bucket,
        aggregated_key=aggregated_key,
        days_back=days_back,
    )

    # Build S3 key with current date for caching/versioning
    yesterday_str = (datetime.utcnow().date() - timedelta(days=1)).isoformat()
    out_key = f"{analysis_prefix}bot-report-{yesterday_str}.json"

    # Upload JSON report
    body_bytes = json.dumps(report, indent=2).encode("utf-8")
    s3_client.put_object(
        Bucket=analysis_bucket,
        Key=out_key,
        Body=body_bytes,
        ContentType="application/json",
    )

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "message": "Bot analysis report generated",
                "report_s3_uri": f"s3://{analysis_bucket}/{out_key}",
                "summary": report.get("overall", {}),
            }
        ),
    }
