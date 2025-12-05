"""
ETL processor for LLM bot access logs.

Responsibilities:
- Read compressed nginx access logs (.gz)
- Parse each line into structured fields
- Emit a CSV with one row per request

This module is written so it can be:
- Run locally as a CLI script
- Wrapped in an AWS Lambda handler
- Reused inside an AWS Glue / PySpark job (via UDF or plain Python parsing)
"""

import csv
import gzip
import io
import json
import os
import re
from dataclasses import dataclass
from datetime import datetime
from typing import Dict, Iterable, Iterator, List, Optional, Tuple

# ----------------------------
# Log line parsing
# ----------------------------

# We first split on " | " to isolate the main nginx/combined log segment,
# then parse that with a regex. This makes the parsing more robust to
# changes in the trailing extra fields.

MAIN_LOG_REGEX = re.compile(
    r"""
    ^(?P<ip>\S+)\s+
    (?P<host>\S+)\s+
    (?P<ident>\S+)\s+
    \[(?P<time>[^\]]+)\]\s+
    "(?P<method>\S+)\s+
    (?P<path>\S+)\s+
    (?P<protocol>[^"]+)"\s+
    (?P<status>\d+)\s+
    (?P<body_bytes_sent>\S+)\s+
    "(?P<referrer>[^"]*)"\s+
    "(?P<user_agent>[^"]*)"
    """,
    re.VERBOSE,
)

TIME_FORMAT = "%d/%b/%Y:%H:%M:%S %z"


@dataclass
class ParsedLogLine:
    ip: str
    host: str
    ident: str
    ts: datetime
    date: str
    method: str
    path: str
    protocol: str
    status: int
    body_bytes_sent: int
    referrer: str
    user_agent: str
    tls: Optional[str] = None
    time1: Optional[float] = None
    time2: Optional[float] = None
    time3: Optional[float] = None
    cache_status: Optional[str] = None
    extra_5: Optional[str] = None
    extra_6: Optional[str] = None
    extra_7: Optional[str] = None


def parse_log_line(line: str) -> Optional[ParsedLogLine]:
    """
    Parse a single access log line into a ParsedLogLine.

    Returns None if the line cannot be parsed.
    """
    line = line.strip()
    if not line:
        return None

    # Split into main part and trailing metrics, using " | " as separator.
    parts = line.split(" | ")
    main = parts[0]
    tls = parts[1].strip() if len(parts) > 1 else None
    rest_tokens: List[str] = []
    if len(parts) > 2:
        rest_tokens = parts[2].strip().split()

    m = MAIN_LOG_REGEX.match(main)
    if not m:
        return None

    try:
        raw_time = m.group("time")
        ts = datetime.strptime(raw_time, TIME_FORMAT)
        date_str = ts.date().isoformat()
    except Exception:
        # If timestamp parsing fails, we still want to keep the row, but
        # mark ts as None-ish. For simplicity we rethrow for now.
        return None

    status = int(m.group("status"))
    try:
        body_bytes = int(m.group("body_bytes_sent"))
    except ValueError:
        body_bytes = -1

    user_agent = m.group("user_agent")

    # Trailing metrics
    time1 = _safe_float(rest_tokens, 0)
    time2 = _safe_float(rest_tokens, 1)
    time3 = _safe_float(rest_tokens, 2)
    cache_status = _safe_token(rest_tokens, 3)
    extra_5 = _safe_token(rest_tokens, 4)
    extra_6 = _safe_token(rest_tokens, 5)
    extra_7 = _safe_token(rest_tokens, 6)

    return ParsedLogLine(
        ip=m.group("ip"),
        host=m.group("host"),
        ident=m.group("ident"),
        ts=ts,
        date=date_str,
        method=m.group("method"),
        path=m.group("path"),
        protocol=m.group("protocol"),
        status=status,
        body_bytes_sent=body_bytes,
        referrer=m.group("referrer"),
        user_agent=user_agent,
        tls=tls,
        time1=time1,
        time2=time2,
        time3=time3,
        cache_status=cache_status,
        extra_5=extra_5,
        extra_6=extra_6,
        extra_7=extra_7,
    )


def _safe_float(tokens: List[str], idx: int) -> Optional[float]:
    if idx >= len(tokens):
        return None
    try:
        return float(tokens[idx])
    except ValueError:
        return None


def _safe_token(tokens: List[str], idx: int) -> Optional[str]:
    if idx >= len(tokens):
        return None
    return tokens[idx]


# ----------------------------
# ETL helpers
# ----------------------------

CSV_FIELDNAMES = [
    "date",
    "timestamp",
    "ip",
    "host",
    "method",
    "path",
    "protocol",
    "status",
    "body_bytes_sent",
    "referrer",
    "user_agent",
    "tls",
    "time1",
    "time2",
    "time3",
    "cache_status",
    "extra_5",
    "extra_6",
    "extra_7",
]


def parsed_logline_to_row(pl: ParsedLogLine) -> Dict[str, str]:
    """
    Convert a ParsedLogLine into a dict suitable for csv.DictWriter.
    """
    return {
        "date": pl.date,
        "timestamp": pl.ts.isoformat(),
        "ip": pl.ip,
        "host": pl.host,
        "method": pl.method,
        "path": pl.path,
        "protocol": pl.protocol,
        "status": str(pl.status),
        "body_bytes_sent": str(pl.body_bytes_sent),
        "referrer": pl.referrer,
        "user_agent": pl.user_agent,
        "tls": pl.tls or "",
        "time1": "" if pl.time1 is None else f"{pl.time1:.3f}",
        "time2": "" if pl.time2 is None else f"{pl.time2:.3f}",
        "time3": "" if pl.time3 is None else f"{pl.time3:.3f}",
        "cache_status": pl.cache_status or "",
        "extra_5": pl.extra_5 or "",
        "extra_6": pl.extra_6 or "",
        "extra_7": pl.extra_7 or "",
    }


def parse_gzip_stream(gz_bytes: bytes) -> Iterator[ParsedLogLine]:
    """
    Given raw .gz bytes, yield ParsedLogLine objects for each successfully parsed line.
    """
    with gzip.GzipFile(fileobj=io.BytesIO(gz_bytes)) as gz:
        for raw_line in gz:
            try:
                line = raw_line.decode("utf-8", errors="replace")
            except Exception:
                continue

            parsed = parse_log_line(line)
            if parsed is not None:
                yield parsed


def process_gzip_to_csv_bytes(gz_bytes: bytes) -> bytes:
    """
    Process .gz log bytes into CSV bytes.

    This is convenient for AWS Lambda: you can read the gzipped S3 object
    into memory, call this, then upload the CSV bytes back to S3.
    """
    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=CSV_FIELDNAMES)
    writer.writeheader()

    for pl in parse_gzip_stream(gz_bytes):
        writer.writerow(parsed_logline_to_row(pl))

    return output.getvalue().encode("utf-8")


def process_gzip_file_to_csv_file(
    input_gz_path: str,
    output_csv_path: str,
) -> None:
    """
    CLI-friendly helper: read a local .gz file and write a CSV file.
    """
    with open(input_gz_path, "rb") as f_in, open(
        output_csv_path, "w", newline="", encoding="utf-8"
    ) as f_out:
        writer = csv.DictWriter(f_out, fieldnames=CSV_FIELDNAMES)
        writer.writeheader()

        for pl in parse_gzip_stream(f_in.read()):
            writer.writerow(parsed_logline_to_row(pl))


# ----------------------------
# Optional: simple CLI entrypoint
# ----------------------------

def main() -> None:
    """
    Basic CLI usage:

      python -m etl_llm_logs \\
        --input path/to/access.log-2025-10-31.gz \\
        --output path/to/parsed-2025-10-31.csv
    """
    import argparse

    parser = argparse.ArgumentParser(description="ETL for LLM bot access logs")
    parser.add_argument("--input", required=True, help="Path to input .gz log file")
    parser.add_argument("--output", required=True, help="Path to output .csv file")

    args = parser.parse_args()
    process_gzip_file_to_csv_file(args.input, args.output)


if __name__ == "__main__":
    main()
