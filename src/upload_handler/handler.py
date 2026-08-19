import json
import uuid

from shared import repository
from shared.auth import caller_sub
from shared.clients import get_s3_client, get_upload_bucket_name
from shared.constants import MAX_FILE_SIZE_BYTES, PRESIGNED_URL_EXPIRY_SECONDS
from shared.http import error_response, json_response
from shared.logging_config import bind_upload_id, logger


@logger.inject_lambda_context(log_event=True)
def handler(event, context):
    body = _parse_body(event)
    if body is None:
        return error_response(400, "Request body must be valid JSON.")

    original_filename = body.get("filename") or "upload.csv"
    if not isinstance(original_filename, str):
        return error_response(400, "'filename' must be a string.")

    upload_id = str(uuid.uuid4())
    s3_key = f"raw/{upload_id}.csv"
    bind_upload_id(upload_id)

    repository.create_upload(upload_id, original_filename, s3_key, caller_sub(event))

    presigned = get_s3_client().generate_presigned_post(
        Bucket=get_upload_bucket_name(),
        Key=s3_key,
        Fields={"Content-Type": "text/csv"},
        Conditions=[
            {"Content-Type": "text/csv"},
            ["content-length-range", 0, MAX_FILE_SIZE_BYTES],
        ],
        ExpiresIn=PRESIGNED_URL_EXPIRY_SECONDS,
    )

    logger.info("Created upload")

    return json_response(
        201,
        {
            "upload_id": upload_id,
            "upload_url": presigned["url"],
            "upload_fields": presigned["fields"],
            "expires_in": PRESIGNED_URL_EXPIRY_SECONDS,
        },
    )


def _parse_body(event: dict) -> dict | None:
    raw_body = event.get("body")
    if raw_body is None or raw_body == "":
        return {}

    if event.get("isBase64Encoded"):
        import base64

        try:
            raw_body = base64.b64decode(raw_body).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return None

    try:
        parsed = json.loads(raw_body)
    except (json.JSONDecodeError, TypeError):
        return None

    return parsed if isinstance(parsed, dict) else None
