from shared import repository
from shared.models import DataRecord, RowError, UploadStatus


def test_create_and_get_upload(mocked_aws):
    upload = repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", "user-1")
    assert upload.status == UploadStatus.PENDING
    assert upload.uploaded_by == "user-1"

    fetched = repository.get_upload("upload-1")
    assert fetched is not None
    assert fetched.upload_id == "upload-1"
    assert fetched.original_filename == "drugs.csv"
    assert fetched.uploaded_by == "user-1"


def test_get_upload_missing_returns_none(mocked_aws):
    assert repository.get_upload("does-not-exist") is None


def test_mark_processing_updates_status(mocked_aws):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", "user-1")
    repository.mark_processing("upload-1")

    fetched = repository.get_upload("upload-1")
    assert fetched.status == UploadStatus.PROCESSING


def test_complete_upload_stores_counts_and_errors(mocked_aws):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", "user-1")
    errors = [RowError(row=2, field="efficacy", message="Value must be numeric.")]
    repository.complete_upload(
        "upload-1",
        row_count=2,
        valid_row_count=1,
        invalid_row_count=1,
        row_errors=errors,
        status=UploadStatus.PARTIALLY_SUCCEEDED,
    )

    fetched = repository.get_upload("upload-1")
    assert fetched.status == UploadStatus.PARTIALLY_SUCCEEDED
    assert fetched.row_count == 2
    assert fetched.invalid_row_count == 1
    assert fetched.errors == errors


def test_put_and_query_records(mocked_aws):
    records = [
        DataRecord(
            upload_id="upload-1", row_number=1, drug_name="Aspirin", target="COX-1", efficacy=72.5
        ),
        DataRecord(
            upload_id="upload-1", row_number=2, drug_name="Ibuprofen", target="COX-2", efficacy=68.0
        ),
    ]
    repository.put_records(records)

    fetched, next_token = repository.query_records("upload-1", limit=10, next_token=None)
    assert next_token is None
    assert [r.row_number for r in fetched] == [1, 2]
    assert fetched[0].drug_name == "Aspirin"


def test_query_records_pagination(mocked_aws):
    records = [
        DataRecord(
            upload_id="upload-1", row_number=i, drug_name=f"Drug{i}", target="T", efficacy=50.0
        )
        for i in range(1, 6)
    ]
    repository.put_records(records)

    page1, token1 = repository.query_records("upload-1", limit=2, next_token=None)
    assert [r.row_number for r in page1] == [1, 2]
    assert token1 is not None

    page2, token2 = repository.query_records("upload-1", limit=2, next_token=token1)
    assert [r.row_number for r in page2] == [3, 4]
    assert token2 is not None

    page3, token3 = repository.query_records("upload-1", limit=2, next_token=token2)
    assert [r.row_number for r in page3] == [5]
    assert token3 is None
