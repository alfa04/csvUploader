import json

from shared import repository
from shared.models import UploadStatus
from upload_handler.handler import handler


def _api_event(body: dict | None) -> dict:
    return {
        "httpMethod": "POST",
        "path": "/uploads",
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body) if body is not None else None,
        "isBase64Encoded": False,
    }


def test_upload_creates_pending_record_and_presigned_post(mocked_aws, lambda_context):
    response = handler(_api_event({"filename": "drugs.csv"}), lambda_context)

    assert response["statusCode"] == 201
    body = json.loads(response["body"])
    assert "upload_id" in body
    assert body["upload_fields"]["Content-Type"] == "text/csv"
    assert body["expires_in"] == 300

    upload = repository.get_upload(body["upload_id"])
    assert upload is not None
    assert upload.status == UploadStatus.PENDING
    assert upload.original_filename == "drugs.csv"


def test_upload_defaults_filename_when_missing(mocked_aws, lambda_context):
    response = handler(_api_event(None), lambda_context)

    assert response["statusCode"] == 201
    body = json.loads(response["body"])
    upload = repository.get_upload(body["upload_id"])
    assert upload.original_filename == "upload.csv"


def test_upload_rejects_invalid_json_body(mocked_aws, lambda_context):
    event = _api_event({"filename": "x.csv"})
    event["body"] = "{not-json"

    response = handler(event, lambda_context)
    assert response["statusCode"] == 400


def test_upload_rejects_non_string_filename(mocked_aws, lambda_context):
    response = handler(_api_event({"filename": 123}), lambda_context)
    assert response["statusCode"] == 400
