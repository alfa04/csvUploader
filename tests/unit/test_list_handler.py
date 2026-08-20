import json

from conftest import DEFAULT_SUB, cognito_request_context

from list_handler.handler import handler
from shared import repository


def _api_event(query_params: dict | None = None, sub: str = DEFAULT_SUB) -> dict:
    return {
        "httpMethod": "GET",
        "path": "/uploads",
        "queryStringParameters": query_params,
        "requestContext": cognito_request_context(sub),
    }


def test_list_returns_only_the_caller_own_uploads(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "a.csv", "raw/upload-1.csv", DEFAULT_SUB)
    repository.create_upload("upload-2", "b.csv", "raw/upload-2.csv", "someone-else")

    response = handler(_api_event(), lambda_context)

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert [u["upload_id"] for u in body["uploads"]] == ["upload-1"]
    assert "next_token" not in body


def test_list_returns_empty_for_a_customer_with_no_uploads(mocked_aws, lambda_context):
    response = handler(_api_event(), lambda_context)

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["uploads"] == []


def test_list_respects_limit_and_returns_next_token(mocked_aws, lambda_context):
    for i in range(3):
        repository.create_upload(f"upload-{i}", "a.csv", f"raw/upload-{i}.csv", DEFAULT_SUB)

    response = handler(_api_event({"limit": "2"}), lambda_context)

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert len(body["uploads"]) == 2
    assert "next_token" in body


def test_list_returns_400_for_invalid_limit(mocked_aws, lambda_context):
    response = handler(_api_event({"limit": "0"}), lambda_context)
    assert response["statusCode"] == 400

    response = handler(_api_event({"limit": "not-a-number"}), lambda_context)
    assert response["statusCode"] == 400
