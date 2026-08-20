from shared import repository
from shared.auth import caller_sub
from shared.constants import MAX_UPLOADS_PAGE_SIZE, UPLOADS_PAGE_SIZE
from shared.http import error_response, json_response
from shared.logging_config import logger


@logger.inject_lambda_context(log_event=True)
def handler(event, context):
    query_params = event.get("queryStringParameters") or {}
    limit = _parse_limit(query_params.get("limit"))
    if limit is None:
        return error_response(
            400, f"'limit' must be an integer between 1 and {MAX_UPLOADS_PAGE_SIZE}."
        )

    uploads, next_token = repository.query_uploads_by_customer(
        caller_sub(event), limit=limit, next_token=query_params.get("next_token")
    )

    body = {"uploads": [u.to_response_dict() for u in uploads]}
    if next_token:
        body["next_token"] = next_token

    return json_response(200, body)


def _parse_limit(raw_limit: str | None) -> int | None:
    if raw_limit is None:
        return UPLOADS_PAGE_SIZE
    try:
        value = int(raw_limit)
    except (TypeError, ValueError):
        return None
    if not (0 < value <= MAX_UPLOADS_PAGE_SIZE):
        return None
    return value
