from decimal import Decimal

from shared.models import DataRecord, RowError, UploadMetadata, UploadStatus


def test_upload_metadata_round_trip():
    upload = UploadMetadata(
        upload_id="abc-123",
        status=UploadStatus.SUCCEEDED,
        original_filename="drugs.csv",
        uploaded_by="cognito-sub-1",
        s3_key="raw/abc-123.csv",
        created_at="2026-01-01T00:00:00+00:00",
        updated_at="2026-01-01T00:00:01+00:00",
        row_count=2,
        valid_row_count=2,
        invalid_row_count=0,
        errors=[],
    )
    restored = UploadMetadata.from_item(upload.to_item())
    assert restored == upload


def test_upload_metadata_response_dict_excludes_s3_key():
    upload = UploadMetadata(
        upload_id="abc-123",
        status=UploadStatus.PENDING,
        original_filename="drugs.csv",
        uploaded_by="cognito-sub-1",
        s3_key="raw/abc-123.csv",
        created_at="t1",
        updated_at="t1",
    )
    response = upload.to_response_dict()
    assert "s3_key" not in response
    assert response["status"] == "pending"
    assert response["uploaded_by"] == "cognito-sub-1"


def test_row_error_round_trip():
    error = RowError(row=3, field="efficacy", message="Value must be numeric.")
    assert RowError.from_dict(error.to_dict()) == error


def test_data_record_round_trip_uses_decimal_for_dynamodb():
    record = DataRecord(
        upload_id="abc-123", row_number=1, drug_name="Aspirin", target="COX-1", efficacy=72.5
    )
    item = record.to_item()
    assert isinstance(item["efficacy"], Decimal)
    assert DataRecord.from_item(item) == record


def test_data_record_response_dict_is_json_friendly():
    record = DataRecord(
        upload_id="abc-123", row_number=1, drug_name="Aspirin", target="COX-1", efficacy=72.5
    )
    response = record.to_response_dict()
    assert response == {
        "row_number": 1,
        "drug_name": "Aspirin",
        "target": "COX-1",
        "efficacy": 72.5,
    }
