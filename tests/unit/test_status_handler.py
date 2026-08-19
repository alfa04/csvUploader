import json

from conftest import DEFAULT_SUB, cognito_request_context

from shared import repository
from status_handler.handler import handler


def _api_event(upload_id: str | None, sub: str = DEFAULT_SUB) -> dict:
    return {
        "httpMethod": "GET",
        "path": f"/uploads/{upload_id}",
        "pathParameters": {"upload_id": upload_id} if upload_id else None,
        "requestContext": cognito_request_context(sub),
    }


def test_status_returns_upload_metadata(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", DEFAULT_SUB)

    response = handler(_api_event("upload-1"), lambda_context)

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["upload_id"] == "upload-1"
    assert body["status"] == "pending"
    assert "s3_key" not in body


def test_status_returns_404_for_unknown_upload(mocked_aws, lambda_context):
    response = handler(_api_event("does-not-exist"), lambda_context)
    assert response["statusCode"] == 404


def test_status_returns_400_when_upload_id_missing(mocked_aws, lambda_context):
    response = handler(_api_event(None), lambda_context)
    assert response["statusCode"] == 400


def test_status_returns_404_when_caller_does_not_own_upload(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", "owner-sub")

    response = handler(_api_event("upload-1", sub="different-sub"), lambda_context)

    assert response["statusCode"] == 404
