import base64
import json
from datetime import UTC, datetime

from shared.clients import get_records_table, get_uploads_table
from shared.constants import MAX_STORED_ERRORS
from shared.models import DataRecord, RowError, UploadMetadata, UploadStatus


def _now() -> str:
    return datetime.now(UTC).isoformat()


def create_upload(upload_id: str, original_filename: str, s3_key: str) -> UploadMetadata:
    timestamp = _now()
    upload = UploadMetadata(
        upload_id=upload_id,
        status=UploadStatus.PENDING,
        original_filename=original_filename,
        s3_key=s3_key,
        created_at=timestamp,
        updated_at=timestamp,
    )
    get_uploads_table().put_item(Item=upload.to_item())
    return upload


def get_upload(upload_id: str) -> UploadMetadata | None:
    response = get_uploads_table().get_item(Key={"upload_id": upload_id})
    item = response.get("Item")
    return UploadMetadata.from_item(item) if item is not None else None


def mark_processing(upload_id: str) -> None:
    get_uploads_table().update_item(
        Key={"upload_id": upload_id},
        UpdateExpression="SET #status = :status, updated_at = :updated_at",
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={
            ":status": UploadStatus.PROCESSING.value,
            ":updated_at": _now(),
        },
    )


def complete_upload(
    upload_id: str,
    row_count: int,
    valid_row_count: int,
    invalid_row_count: int,
    row_errors: list[RowError],
    status: UploadStatus,
) -> None:
    get_uploads_table().update_item(
        Key={"upload_id": upload_id},
        UpdateExpression=(
            "SET #status = :status, updated_at = :updated_at, row_count = :row_count, "
            "valid_row_count = :valid_row_count, invalid_row_count = :invalid_row_count, "
            "errors = :errors"
        ),
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={
            ":status": status.value,
            ":updated_at": _now(),
            ":row_count": row_count,
            ":valid_row_count": valid_row_count,
            ":invalid_row_count": invalid_row_count,
            ":errors": [e.to_dict() for e in row_errors[:MAX_STORED_ERRORS]],
        },
    )


def put_records(records: list[DataRecord]) -> None:
    table = get_records_table()
    with table.batch_writer() as batch:
        for record in records:
            batch.put_item(Item=record.to_item())


def query_records(
    upload_id: str, limit: int, next_token: str | None
) -> tuple[list[DataRecord], str | None]:
    table = get_records_table()
    kwargs = {
        "KeyConditionExpression": "upload_id = :upload_id",
        "ExpressionAttributeValues": {":upload_id": upload_id},
        "Limit": limit,
    }
    if next_token:
        kwargs["ExclusiveStartKey"] = _decode_token(next_token)

    response = table.query(**kwargs)
    items = [DataRecord.from_item(item) for item in response.get("Items", [])]
    last_key = response.get("LastEvaluatedKey")
    return items, (_encode_token(last_key) if last_key else None)


def _encode_token(key: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(key, default=str).encode()).decode()


def _decode_token(token: str) -> dict:
    raw = json.loads(base64.urlsafe_b64decode(token.encode()).decode())
    # row_number round-trips through JSON as a string (via _encode_token's default=str);
    # DynamoDB's Number key type requires it back as a real number for ExclusiveStartKey.
    return {"upload_id": raw["upload_id"], "row_number": int(raw["row_number"])}
