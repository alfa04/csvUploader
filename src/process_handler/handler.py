from urllib.parse import unquote_plus

from shared import repository
from shared.clients import get_s3_client
from shared.logging_config import bind_upload_id, logger
from shared.models import DataRecord, RowError, UploadStatus
from shared.validation import StructuralValidationError, validate_csv


@logger.inject_lambda_context(log_event=True)
def handler(event, context):
    for record in event["Records"]:
        _process_record(record)


def _process_record(record: dict) -> None:
    bucket = record["s3"]["bucket"]["name"]
    key = unquote_plus(record["s3"]["object"]["key"])
    upload_id = _upload_id_from_key(key)

    bind_upload_id(upload_id)
    logger.info("Processing upload", extra={"bucket": bucket, "key": key})

    repository.mark_processing(upload_id)

    content = get_s3_client().get_object(Bucket=bucket, Key=key)["Body"].read()

    try:
        result = validate_csv(content)
    except StructuralValidationError as exc:
        logger.warning("Upload failed structural validation", extra={"reason": str(exc)})
        repository.complete_upload(
            upload_id,
            row_count=0,
            valid_row_count=0,
            invalid_row_count=0,
            row_errors=[RowError(row=0, field="*", message=str(exc))],
            status=UploadStatus.FAILED,
        )
        return

    records = [
        DataRecord(
            upload_id=upload_id,
            row_number=row.row_number,
            drug_name=row.drug_name,
            target=row.target,
            efficacy=row.efficacy,
        )
        for row in result.valid_rows
    ]
    if records:
        repository.put_records(records)

    status = (
        UploadStatus.SUCCEEDED
        if result.invalid_row_count == 0
        else UploadStatus.PARTIALLY_SUCCEEDED
    )
    repository.complete_upload(
        upload_id,
        row_count=result.row_count,
        valid_row_count=len(result.valid_rows),
        invalid_row_count=result.invalid_row_count,
        row_errors=result.row_errors,
        status=status,
    )
    logger.info(
        "Upload processed", extra={"status": status.value, "invalid_rows": result.invalid_row_count}
    )


def _upload_id_from_key(key: str) -> str:
    filename = key.rsplit("/", 1)[-1]
    return filename.removesuffix(".csv")
