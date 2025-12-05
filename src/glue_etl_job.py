import json
import os
from typing import Dict, Any, List

import boto3

from etl_llm_logs import process_gzip_to_csv_bytes

secrets_client = boto3.client("secretsmanager")
s3_client = boto3.client("s3")


def get_config() -> Dict[str, Any]:
    secret_name = os.environ.get("CONFIG_SECRET_NAME", "llm-log-pipeline-config")
    resp = secrets_client.get_secret_value(SecretId=secret_name)

    if "SecretString" in resp:
        cfg_str = resp["SecretString"]
    else:
        cfg_str = resp["SecretBinary"].decode("utf-8")

    return json.loads(cfg_str)


def list_raw_keys_for_last_n_days(cfg: Dict[str, Any], days: int = 1) -> List[str]:
    """
    Simple example: list ALL keys under raw/…
    You can extend this to filter by date prefix or use process_date param.
    """
    raw_bucket = cfg["LOG_FETCH_RAW_BUCKET"]
    prefix = "raw/"

    keys: List[str] = []
    continuation_token = None

    while True:
        kwargs = {"Bucket": raw_bucket, "Prefix": prefix}
        if continuation_token:
            kwargs["ContinuationToken"] = continuation_token

        resp = s3_client.list_objects_v2(**kwargs)
        for obj in resp.get("Contents", []):
            key = obj["Key"]
            if key.endswith(".gz"):
                keys.append(key)

        if resp.get("IsTruncated"):
            continuation_token = resp.get("NextContinuationToken")
        else:
            break

    return keys


def process_one_key(cfg: Dict[str, Any], key: str) -> str:
    raw_bucket = cfg["LOG_FETCH_RAW_BUCKET"]
    processing_bucket = cfg.get("LOG_PROCESSING_BUCKET", raw_bucket)
    processing_prefix = cfg.get("LOG_PROCESSING_PREFIX", "parsed")

    print(f"Processing: s3://{raw_bucket}/{key}")

    obj = s3_client.get_object(Bucket=raw_bucket, Key=key)
    gz_bytes = obj["Body"].read()
    csv_bytes = process_gzip_to_csv_bytes(gz_bytes)

    # Derive output key similar to Lambda ETL
    if key.startswith("raw/"):
        rest = key[len("raw/") :]
    else:
        rest = key

    if rest.endswith(".gz"):
        rest = rest[:-3] + ".csv"
    else:
        rest = rest + ".csv"

    if processing_prefix and not processing_prefix.endswith("/"):
        processing_prefix = processing_prefix + "/"

    out_key = processing_prefix + rest

    s3_client.put_object(
        Bucket=processing_bucket,
        Key=out_key,
        Body=csv_bytes,
        ContentType="text/csv",
    )

    print(f"Written: s3://{processing_bucket}/{out_key}")
    return out_key


def main():
    cfg = get_config()

    # Optionally read a process date or max days from env / args
    max_days = int(os.environ.get("LOG_PROCESSING_MAX_DAYS", "30"))

    keys = list_raw_keys_for_last_n_days(cfg, days=max_days)
    print(f"Found {len(keys)} raw .gz keys")

    for key in keys:
        process_one_key(cfg, key)


if __name__ == "__main__":
    main()