import boto3
import pytest
from moto import mock_aws

UPLOADS_TABLE = "test-uploads"
RECORDS_TABLE = "test-records"
UPLOAD_BUCKET = "test-upload-bucket"
DEFAULT_SUB = "test-caller-sub"


def cognito_request_context(sub: str = DEFAULT_SUB) -> dict:
    return {"authorizer": {"claims": {"sub": sub}}}


class FakeLambdaContext:
    aws_request_id = "test-request-id"
    function_name = "test-function"
    function_version = "$LATEST"
    invoked_function_arn = "arn:aws:lambda:us-east-1:123456789012:function:test-function"
    memory_limit_in_mb = 128

    def get_remaining_time_in_millis(self) -> int:
        return 30_000


@pytest.fixture
def lambda_context():
    return FakeLambdaContext()


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("UPLOADS_TABLE_NAME", UPLOADS_TABLE)
    monkeypatch.setenv("RECORDS_TABLE_NAME", RECORDS_TABLE)
    monkeypatch.setenv("UPLOAD_BUCKET_NAME", UPLOAD_BUCKET)


@pytest.fixture
def mocked_aws(aws_env):
    from shared import clients

    with mock_aws():
        clients.get_dynamodb_resource.cache_clear()
        clients.get_s3_client.cache_clear()

        dynamodb = boto3.client("dynamodb", region_name="us-east-1")
        dynamodb.create_table(
            TableName=UPLOADS_TABLE,
            KeySchema=[{"AttributeName": "upload_id", "KeyType": "HASH"}],
            AttributeDefinitions=[
                {"AttributeName": "upload_id", "AttributeType": "S"},
                {"AttributeName": "uploaded_by", "AttributeType": "S"},
                {"AttributeName": "created_at", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
            GlobalSecondaryIndexes=[
                {
                    "IndexName": "uploaded_by-created_at-index",
                    "KeySchema": [
                        {"AttributeName": "uploaded_by", "KeyType": "HASH"},
                        {"AttributeName": "created_at", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                }
            ],
        )
        dynamodb.create_table(
            TableName=RECORDS_TABLE,
            KeySchema=[
                {"AttributeName": "upload_id", "KeyType": "HASH"},
                {"AttributeName": "row_number", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "upload_id", "AttributeType": "S"},
                {"AttributeName": "row_number", "AttributeType": "N"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        s3 = boto3.client("s3", region_name="us-east-1")
        s3.create_bucket(Bucket=UPLOAD_BUCKET)

        yield {
            "uploads_table": UPLOADS_TABLE,
            "records_table": RECORDS_TABLE,
            "bucket": UPLOAD_BUCKET,
        }

        clients.get_dynamodb_resource.cache_clear()
        clients.get_s3_client.cache_clear()
