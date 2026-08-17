from shared import repository
from shared.constants import MAX_RECORDS_PAGE_SIZE, RECORDS_PAGE_SIZE
from shared.http import error_response, json_response
from shared.logging_config import bind_upload_id, logger
from shared.models import UploadStatus

# Only these statuses have anything in the records table yet.
_STATUSES_WITH_RECORDS = (UploadStatus.SUCCEEDED, UploadStatus.PARTIALLY_SUCCEEDED)


@logger.inject_lambda_context(log_event=True)
def handler(event, context):
    upload_id = (event.get("pathParameters") or {}).get("upload_id")
    if not upload_id:
        return error_response(400, "Missing path parameter 'upload_id'.")

    bind_upload_id(upload_id)
    upload = repository.get_upload(upload_id)
    if upload is None:
        return error_response(404, f"Upload '{upload_id}' not found.")

    query_params = event.get("queryStringParameters") or {}
    limit = _parse_limit(query_params.get("limit"))
    if limit is None:
        return error_response(
            400, f"'limit' must be an integer between 1 and {MAX_RECORDS_PAGE_SIZE}."
        )

    records = []
    next_token = None
    if upload.status in _STATUSES_WITH_RECORDS:
        records, next_token = repository.query_records(
            upload_id, limit=limit, next_token=query_params.get("next_token")
        )

    body = {
        "upload_id": upload_id,
        "status": upload.status.value,
        "records": [r.to_response_dict() for r in records],
    }
    if next_token:
        body["next_token"] = next_token

    return json_response(200, body)


def _parse_limit(raw_limit: str | None) -> int | None:
    if raw_limit is None:
        return RECORDS_PAGE_SIZE
    try:
        value = int(raw_limit)
    except (TypeError, ValueError):
        return None
    if not (0 < value <= MAX_RECORDS_PAGE_SIZE):
        return None
    return value
