import json

from records_handler.handler import handler
from shared import repository
from shared.models import DataRecord, UploadStatus


def _api_event(upload_id: str | None, query: dict | None = None) -> dict:
    return {
        "httpMethod": "GET",
        "path": f"/uploads/{upload_id}/records",
        "pathParameters": {"upload_id": upload_id} if upload_id else None,
        "queryStringParameters": query,
    }


def test_records_returns_empty_while_pending(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv")

    response = handler(_api_event("upload-1"), lambda_context)

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["status"] == "pending"
    assert body["records"] == []
    assert "next_token" not in body


def test_records_returns_rows_when_succeeded(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv")
    repository.put_records(
        [
            DataRecord(
                upload_id="upload-1",
                row_number=1,
                drug_name="Aspirin",
                target="COX-1",
                efficacy=72.5,
            )
        ]
    )
    repository.complete_upload(
        "upload-1",
        row_count=1,
        valid_row_count=1,
        invalid_row_count=0,
        row_errors=[],
        status=UploadStatus.SUCCEEDED,
    )

    response = handler(_api_event("upload-1"), lambda_context)

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["status"] == "succeeded"
    assert body["records"] == [
        {"row_number": 1, "drug_name": "Aspirin", "target": "COX-1", "efficacy": 72.5}
    ]


def test_records_returns_404_for_unknown_upload(mocked_aws, lambda_context):
    response = handler(_api_event("does-not-exist"), lambda_context)
    assert response["statusCode"] == 404


def test_records_returns_400_when_upload_id_missing(mocked_aws, lambda_context):
    response = handler(_api_event(None), lambda_context)
    assert response["statusCode"] == 400


def test_records_pagination_via_next_token(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv")
    records = [
        DataRecord(
            upload_id="upload-1", row_number=i, drug_name=f"Drug{i}", target="T", efficacy=50.0
        )
        for i in range(1, 4)
    ]
    repository.put_records(records)
    repository.complete_upload(
        "upload-1",
        row_count=3,
        valid_row_count=3,
        invalid_row_count=0,
        row_errors=[],
        status=UploadStatus.SUCCEEDED,
    )

    response = handler(_api_event("upload-1", {"limit": "2"}), lambda_context)
    body = json.loads(response["body"])
    assert [r["row_number"] for r in body["records"]] == [1, 2]
    assert "next_token" in body

    response2 = handler(
        _api_event("upload-1", {"limit": "2", "next_token": body["next_token"]}), lambda_context
    )
    body2 = json.loads(response2["body"])
    assert [r["row_number"] for r in body2["records"]] == [3]
    assert "next_token" not in body2


def test_records_rejects_invalid_limit(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv")

    response = handler(_api_event("upload-1", {"limit": "not-a-number"}), lambda_context)
    assert response["statusCode"] == 400


def test_records_rejects_out_of_range_limit(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv")

    response = handler(_api_event("upload-1", {"limit": "0"}), lambda_context)
    assert response["statusCode"] == 400
