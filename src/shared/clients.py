import os
from functools import lru_cache

import boto3

from shared.constants import (
    RECORDS_TABLE_NAME_ENV_VAR,
    UPLOAD_BUCKET_NAME_ENV_VAR,
    UPLOADS_TABLE_NAME_ENV_VAR,
)


@lru_cache(maxsize=1)
def get_dynamodb_resource():
    return boto3.resource("dynamodb")


@lru_cache(maxsize=1)
def get_s3_client():
    return boto3.client("s3")


def get_uploads_table():
    return get_dynamodb_resource().Table(os.environ[UPLOADS_TABLE_NAME_ENV_VAR])


def get_records_table():
    return get_dynamodb_resource().Table(os.environ[RECORDS_TABLE_NAME_ENV_VAR])


def get_upload_bucket_name() -> str:
    return os.environ[UPLOAD_BUCKET_NAME_ENV_VAR]
