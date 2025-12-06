import json
import os
import gzip
from urllib.parse import unquote_plus
from typing import Dict, Any

import boto3
from botocore.exceptions import ClientError

from etl_logic import process_gzip_to_csv_bytes

secrets_client = boto3.client("secretsmanager")
s3_client = boto3.client("s3")


def get_config() -> Dict[str, Any]:
    secret_name = os.environ["CONFIG_SECRET_NAME"]
    resp = secrets_client.get_secret_value(SecretId=secret_name)

    if "SecretString" in resp:
        cfg_str = resp["SecretString"]
    else:
        cfg_str = resp["SecretBinary"].decode("utf-8")

    return json.loads(cfg_str)


def derive_output_key(
    input_key: str, prefix: str = "parsed/"
) -> str:
    """
    Turn e.g.
      raw/date=2025-10-31/access.log-2025-10-31.gz
    into
      parsed/date=2025-10-31/access.log-2025-10-31.csv
    """
    # Strip raw/ and replace with parsed/
    # raw/date=.../...gz -> date=.../...gz
    if input_key.startswith("raw/"):
        rest = input_key[len("raw/") :]
    else:
        rest = input_key

    if rest.endswith(".gz"):
        rest = rest[:-3] + ".csv"
    else:
        rest = rest + ".csv"

    if prefix and not prefix.endswith("/"):
        prefix = prefix + "/"

    return prefix + rest


def append_to_aggregated_csv(
    bucket: str,
    key: str,
    csv_bytes: bytes,
) -> None:
    """
    Append CSV rows to a single aggregated CSV in S3.

    - If the aggregated file does not exist, create it with full csv_bytes
      (including header).
    - If it exists, append only the data rows (drop the header line from
      csv_bytes) to the end of the existing object.

    NOTE: This is a simple read-modify-write implementation and is not
    concurrency-safe for very high volumes, but is sufficient for small
    daily ETL loads.
    """
    # csv_bytes include header as first line
    try:
        obj = s3_client.get_object(Bucket=bucket, Key=key)
        existing_body = obj["Body"].read()
        # Decode new CSV, drop first line (header), keep the rest
        text = csv_bytes.decode("utf-8")
        lines = text.splitlines(keepends=True)
        # If there is only a header (or empty), nothing to append
        if len(lines) <= 1:
            new_tail = b""
        else:
            new_tail = "".join(lines[1:]).encode("utf-8")
        combined = existing_body + new_tail
        s3_client.put_object(
            Bucket=bucket,
            Key=key,
            Body=combined,
            ContentType="text/csv",
        )
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code")
        if code in ("NoSuchKey", "404"):
            # Aggregated file does not exist yet: create it with full CSV
            s3_client.put_object(
                Bucket=bucket,
                Key=key,
                Body=csv_bytes,
                ContentType="text/csv",
            )
        else:
            raise


def append_to_aggregated_log(
    bucket: str,
    key: str,
    gz_bytes: bytes,
) -> None:
    """
    Append raw log lines (decompressed from .gz) to a single aggregated
    log file in S3.

    - If the aggregated log file does not exist, create it with the full
      decompressed content.
    - If it exists, append the new decompressed content to the end of the
      existing object.

    NOTE: This is a simple read-modify-write implementation and is not
    concurrency-safe for very high volumes, but is sufficient for small
    daily ETL loads.
    """
    # Decompress .gz bytes to raw log bytes
    try:
        decompressed = gzip.decompress(gz_bytes)
    except OSError:
        # If for some reason the content is not a valid gzip, skip appending
        return

    try:
        obj = s3_client.get_object(Bucket=bucket, Key=key)
        existing_body = obj["Body"].read()
        combined = existing_body + decompressed
        s3_client.put_object(
            Bucket=bucket,
            Key=key,
            Body=combined,
            ContentType="text/plain",
        )
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code")
        if code in ("NoSuchKey", "404"):
            # Aggregated log file does not exist yet: create it
            s3_client.put_object(
                Bucket=bucket,
                Key=key,
                Body=decompressed,
                ContentType="text/plain",
            )
        else:
            raise


def handler(event, context):
    # Load config
    cfg = get_config()

    raw_bucket = cfg["LOG_FETCH_RAW_BUCKET"]
    processing_bucket = cfg.get("LOG_PROCESSING_BUCKET", raw_bucket)
    processing_prefix = cfg.get("LOG_PROCESSING_PREFIX", "parsed")
    aggregated_key = cfg.get("LOG_AGGREGATED_KEY", "aggregated/all_logs.csv")
    aggregated_log_key = cfg.get("LOG_AGGREGATED_LOG_KEY", "aggregated/all_logs.log")

    results = []

    for record in event.get("Records", []):
        s3info = record["s3"]
        bucket = s3info["bucket"]["name"]
        raw_key = s3info["object"]["key"]
        # S3 event keys are URL-encoded (e.g. "date%3D2025-12-04"), so decode them first
        key = unquote_plus(raw_key)

        # If this event isn't from our raw bucket, skip
        if bucket != raw_bucket:
            continue

        print(f"Processing raw log: s3://{bucket}/{key}")

        # 1. Download gzipped log
        obj = s3_client.get_object(Bucket=bucket, Key=key)
        gz_bytes = obj["Body"].read()

        # 2. Run ETL -> CSV bytes
        csv_bytes = process_gzip_to_csv_bytes(gz_bytes)

        # 3. Compute output key
        out_key = derive_output_key(key, prefix=processing_prefix)

        # 4. Upload CSV
        s3_client.put_object(
            Bucket=processing_bucket,
            Key=out_key,
            Body=csv_bytes,
            ContentType="text/csv",
        )

        print(f"Wrote CSV: s3://{processing_bucket}/{out_key}")

        # 5. Append to aggregated CSV (single file for analysis)
        append_to_aggregated_csv(
            bucket=processing_bucket,
            key=aggregated_key,
            csv_bytes=csv_bytes,
        )

        # 6. Append raw log lines to aggregated .log file
        append_to_aggregated_log(
            bucket=processing_bucket,
            key=aggregated_log_key,
            gz_bytes=gz_bytes,
        )

        results.append(
            {
                "input": f"s3://{bucket}/{key}",
                "output": f"s3://{processing_bucket}/{out_key}",
            }
        )

    return {
        "statusCode": 200,
        "body": json.dumps({"processed": results}),
    }