import pytest

from process_handler.handler import _upload_id_from_key, handler
from shared import repository
from shared.clients import get_s3_client, get_upload_bucket_name
from shared.models import UploadStatus


def _s3_event(bucket: str, key: str) -> dict:
    return {"Records": [{"s3": {"bucket": {"name": bucket}, "object": {"key": key}}}]}


def _upload_csv(upload_id: str, content: bytes) -> str:
    key = f"raw/{upload_id}.csv"
    get_s3_client().put_object(Bucket=get_upload_bucket_name(), Key=key, Body=content)
    return key


def test_upload_id_from_key_strips_prefix_and_suffix():
    assert _upload_id_from_key("raw/1234-5678.csv") == "1234-5678"


def test_process_handler_decodes_url_encoded_key(mocked_aws, lambda_context):
    # S3 event notifications URL-encode object keys (e.g. spaces become '+'); _process_record
    # must unquote the key *before* deriving the upload_id from it, not after.
    upload_id = "upload with spaces"
    repository.create_upload(upload_id, "drugs.csv", f"raw/{upload_id}.csv")
    content = b"drug_name,target,efficacy\nAspirin,COX-1,72.5\n"
    get_s3_client().put_object(
        Bucket=get_upload_bucket_name(), Key=f"raw/{upload_id}.csv", Body=content
    )

    handler(_s3_event(get_upload_bucket_name(), "raw/upload+with+spaces.csv"), lambda_context)

    upload = repository.get_upload(upload_id)
    assert upload.status == UploadStatus.SUCCEEDED


def test_process_handler_stores_valid_rows_and_marks_succeeded(mocked_aws, lambda_context):
    upload_id = "upload-1"
    repository.create_upload(upload_id, "drugs.csv", f"raw/{upload_id}.csv")
    content = b"drug_name,target,efficacy\nAspirin,COX-1,72.5\nIbuprofen,COX-2,68.0\n"
    key = _upload_csv(upload_id, content)

    handler(_s3_event(get_upload_bucket_name(), key), lambda_context)

    upload = repository.get_upload(upload_id)
    assert upload.status == UploadStatus.SUCCEEDED
    assert upload.row_count == 2
    assert upload.valid_row_count == 2
    assert upload.invalid_row_count == 0

    records, _ = repository.query_records(upload_id, limit=10, next_token=None)
    assert [r.drug_name for r in records] == ["Aspirin", "Ibuprofen"]


def test_process_handler_partial_ingest_marks_partially_succeeded(mocked_aws, lambda_context):
    upload_id = "upload-2"
    repository.create_upload(upload_id, "drugs.csv", f"raw/{upload_id}.csv")
    content = b"drug_name,target,efficacy\nAspirin,COX-1,72.5\nIbuprofen,COX-2,not_a_number\n"
    key = _upload_csv(upload_id, content)

    handler(_s3_event(get_upload_bucket_name(), key), lambda_context)

    upload = repository.get_upload(upload_id)
    assert upload.status == UploadStatus.PARTIALLY_SUCCEEDED
    assert upload.valid_row_count == 1
    assert upload.invalid_row_count == 1
    assert upload.errors[0].field == "efficacy"

    records, _ = repository.query_records(upload_id, limit=10, next_token=None)
    assert [r.drug_name for r in records] == ["Aspirin"]


def test_process_handler_structural_failure_marks_failed(mocked_aws, lambda_context):
    upload_id = "upload-3"
    repository.create_upload(upload_id, "drugs.csv", f"raw/{upload_id}.csv")
    content = b"drug_name,efficacy\nAspirin,72.5\n"  # missing the 'target' column
    key = _upload_csv(upload_id, content)

    handler(_s3_event(get_upload_bucket_name(), key), lambda_context)

    upload = repository.get_upload(upload_id)
    assert upload.status == UploadStatus.FAILED
    assert upload.row_count == 0
    assert len(upload.errors) == 1

    records, _ = repository.query_records(upload_id, limit=10, next_token=None)
    assert records == []


def test_process_handler_propagates_error_when_object_missing(mocked_aws, lambda_context):
    upload_id = "upload-4"
    repository.create_upload(upload_id, "drugs.csv", f"raw/{upload_id}.csv")
    # Deliberately no put_object call - the S3 object does not exist.

    with pytest.raises(Exception):  # noqa: B017 - asserting the handler lets S3/Lambda retry+DLQ handle it
        handler(_s3_event(get_upload_bucket_name(), f"raw/{upload_id}.csv"), lambda_context)
