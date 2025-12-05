import json
import os
from urllib.parse import unquote_plus
from typing import Dict, Any

import boto3

from etl_llm_logs import process_gzip_to_csv_bytes

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


def handler(event, context):
    # Load config
    cfg = get_config()

    raw_bucket = cfg["LOG_FETCH_RAW_BUCKET"]
    processing_bucket = cfg.get("LOG_PROCESSING_BUCKET", raw_bucket)
    processing_prefix = cfg.get("LOG_PROCESSING_PREFIX", "parsed")

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