# Cognito Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the API Gateway API-key/usage-plan auth model with a Cognito User Pool, enforcing per-customer data isolation, so customers can self-service sign up and no permanent shared secret exists.

**Architecture:** A Cognito User Pool + App Client (no Hosted UI, no client secret) issues JWTs via its public `SignUp`/`ConfirmSignUp`/`InitiateAuth` APIs. API Gateway validates the JWT natively via a `COGNITO_USER_POOLS` authorizer on all 3 methods, replacing `api_key_required`. Every upload is stamped with the caller's Cognito `sub`; `status_handler`/`records_handler` return 404 (not 403) if the caller doesn't own the upload being requested.

**Tech Stack:** Terraform (`hashicorp/aws` ~> 5.0), Python 3.13, `aws-lambda-powertools`, pytest + moto.

**Spec:** [`docs/specs/2026-08-19-cognito-auth-design.md`](../specs/2026-08-19-cognito-auth-design.md)

## Global Constraints

- No Cognito Hosted UI, no social login providers, no MFA enrollment flow (`mfa_configuration = "OFF"`).
- App Client has no client secret (`generate_secret = false`).
- Ownership mismatch and "doesn't exist" must be indistinguishable: both return 404 via the exact same response shape.
- Per-customer usage-plan quota/throttling is intentionally removed; only blanket stage-level throttling remains (`throttle_rate_limit`/`throttle_burst_limit` variables stay, `quota_limit`/`quota_period` go away).
- `terraform fmt -recursive` and `terraform validate` must pass for every Terraform task; `uv run ruff check .` and `uv run pytest` must pass for every Python task. Terraform tasks validate only (`terraform init -backend=false && terraform validate`) - actual `plan`/`apply` against real AWS is run by the user, not as part of these tasks.

---

## Task 1: `uploaded_by` in the data layer

**Files:**
- Modify: `src/shared/models.py` (`UploadMetadata` class)
- Modify: `src/shared/repository.py` (`create_upload`)
- Modify: `tests/unit/test_models.py`
- Modify: `tests/unit/test_repository.py`
- Modify: `tests/unit/test_process_handler.py` (mechanical fixup only - these tests call `repository.create_upload` directly as setup)
- Modify: `tests/unit/test_status_handler.py` (mechanical fixup only)
- Modify: `tests/unit/test_records_handler.py` (mechanical fixup only)

**Interfaces:**
- Produces: `UploadMetadata.uploaded_by: str` field; `UploadMetadata.to_response_dict()` includes `"uploaded_by"`; `repository.create_upload(upload_id: str, original_filename: str, s3_key: str, uploaded_by: str) -> UploadMetadata`.

- [ ] **Step 1: Write the failing test for the model**

In `tests/unit/test_models.py`, update `test_upload_metadata_round_trip` and `test_upload_metadata_response_dict_excludes_s3_key`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/unit/test_models.py -v`
Expected: FAIL with `TypeError: UploadMetadata.__init__() got an unexpected keyword argument 'uploaded_by'`

- [ ] **Step 3: Add `uploaded_by` to `UploadMetadata`**

In `src/shared/models.py`, replace the `UploadMetadata` class body:

```python
@dataclass
class UploadMetadata:
    upload_id: str
    status: UploadStatus
    original_filename: str
    uploaded_by: str
    s3_key: str
    created_at: str
    updated_at: str
    row_count: int = 0
    valid_row_count: int = 0
    invalid_row_count: int = 0
    errors: list[RowError] = field(default_factory=list)

    def to_item(self) -> dict:
        return {
            "upload_id": self.upload_id,
            "status": self.status.value,
            "original_filename": self.original_filename,
            "uploaded_by": self.uploaded_by,
            "s3_key": self.s3_key,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "row_count": self.row_count,
            "valid_row_count": self.valid_row_count,
            "invalid_row_count": self.invalid_row_count,
            "errors": [e.to_dict() for e in self.errors],
        }

    @classmethod
    def from_item(cls, item: dict) -> "UploadMetadata":
        return cls(
            upload_id=item["upload_id"],
            status=UploadStatus(item["status"]),
            original_filename=item["original_filename"],
            uploaded_by=item["uploaded_by"],
            s3_key=item["s3_key"],
            created_at=item["created_at"],
            updated_at=item["updated_at"],
            row_count=int(item.get("row_count", 0)),
            valid_row_count=int(item.get("valid_row_count", 0)),
            invalid_row_count=int(item.get("invalid_row_count", 0)),
            errors=[RowError.from_dict(e) for e in item.get("errors", [])],
        )

    def to_response_dict(self) -> dict:
        """JSON-serializable representation for API responses. Omits s3_key - internal detail."""
        return {
            "upload_id": self.upload_id,
            "status": self.status.value,
            "original_filename": self.original_filename,
            "uploaded_by": self.uploaded_by,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "row_count": self.row_count,
            "valid_row_count": self.valid_row_count,
            "invalid_row_count": self.invalid_row_count,
            "errors": [e.to_dict() for e in self.errors],
        }
```

(Only `UploadMetadata` changes - `RowError` and `DataRecord` above/below it are untouched.)

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/unit/test_models.py -v`
Expected: PASS

- [ ] **Step 5: Write the failing test for the repository**

In `tests/unit/test_repository.py`, update `test_create_and_get_upload`:

```python
def test_create_and_get_upload(mocked_aws):
    upload = repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", "user-1")
    assert upload.status == UploadStatus.PENDING
    assert upload.uploaded_by == "user-1"

    fetched = repository.get_upload("upload-1")
    assert fetched is not None
    assert fetched.upload_id == "upload-1"
    assert fetched.original_filename == "drugs.csv"
    assert fetched.uploaded_by == "user-1"
```

Update every other `repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv")` call in this same file (in `test_mark_processing_updates_status` and `test_complete_upload_stores_counts_and_errors`) to `repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", "user-1")`.

- [ ] **Step 6: Run test to verify it fails**

Run: `uv run pytest tests/unit/test_repository.py -v`
Expected: FAIL with `TypeError: create_upload() missing 1 required positional argument: 'uploaded_by'`

- [ ] **Step 7: Add `uploaded_by` to `create_upload`**

In `src/shared/repository.py`, replace `create_upload`:

```python
def create_upload(
    upload_id: str, original_filename: str, s3_key: str, uploaded_by: str
) -> UploadMetadata:
    timestamp = _now()
    upload = UploadMetadata(
        upload_id=upload_id,
        status=UploadStatus.PENDING,
        original_filename=original_filename,
        uploaded_by=uploaded_by,
        s3_key=s3_key,
        created_at=timestamp,
        updated_at=timestamp,
    )
    get_uploads_table().put_item(Item=upload.to_item())
    return upload
```

- [ ] **Step 8: Run test to verify it passes**

Run: `uv run pytest tests/unit/test_repository.py -v`
Expected: PASS

- [ ] **Step 9: Fix the other test files' direct `create_upload` calls**

These files call `repository.create_upload` directly as setup for handlers this task doesn't otherwise touch (Tasks 3/4 rework `test_status_handler.py`/`test_records_handler.py` further). Add `"user-1"` as the 4th argument everywhere it's called:

In `tests/unit/test_process_handler.py`, update all 5 calls (in `test_process_handler_decodes_url_encoded_key`, `test_process_handler_stores_valid_rows_and_marks_succeeded`, `test_process_handler_partial_ingest_marks_partially_succeeded`, `test_process_handler_structural_failure_marks_failed`, `test_process_handler_propagates_error_when_object_missing`) from e.g.:

```python
    repository.create_upload(upload_id, "drugs.csv", f"raw/{upload_id}.csv")
```

to:

```python
    repository.create_upload(upload_id, "drugs.csv", f"raw/{upload_id}.csv", "user-1")
```

In `tests/unit/test_status_handler.py`, update the one call in `test_status_returns_upload_metadata`:

```python
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", "user-1")
```

In `tests/unit/test_records_handler.py`, update all 4 calls (in `test_records_returns_empty_while_pending`, `test_records_returns_rows_when_succeeded`, `test_records_pagination_via_next_token`, `test_records_rejects_invalid_limit`, `test_records_rejects_out_of_range_limit` - 5 calls total) the same way.

- [ ] **Step 10: Run the full suite to verify it passes**

Run: `uv run pytest -v`
Expected: PASS (all tests green - this task must not leave anything broken, even in files Tasks 3/4 will touch further)

- [ ] **Step 11: Lint and commit**

```bash
uv run ruff check .
git add src/shared/models.py src/shared/repository.py tests/unit/test_models.py tests/unit/test_repository.py tests/unit/test_process_handler.py tests/unit/test_status_handler.py tests/unit/test_records_handler.py
git commit -m "Add uploaded_by to UploadMetadata and create_upload"
```

---

## Task 2: `upload_handler` stamps caller identity

**Files:**
- Create: `src/shared/auth.py`
- Modify: `src/upload_handler/handler.py`
- Modify: `tests/unit/conftest.py`
- Modify: `tests/unit/test_upload_handler.py`

**Interfaces:**
- Consumes: `repository.create_upload(upload_id, original_filename, s3_key, uploaded_by)` from Task 1.
- Produces: `shared.auth.caller_sub(event: dict) -> str`, reused by Tasks 3 and 4.

- [ ] **Step 1: Add a shared `conftest.py` helper for building an authorized event fragment**

In `tests/unit/conftest.py`, add a constant and helper function (near the top, after the existing constants):

```python
DEFAULT_SUB = "test-caller-sub"


def cognito_request_context(sub: str = DEFAULT_SUB) -> dict:
    return {"authorizer": {"claims": {"sub": sub}}}
```

- [ ] **Step 2: Write the failing test**

In `tests/unit/test_upload_handler.py`, update the `_api_event` helper and the first test:

```python
import json

from conftest import DEFAULT_SUB, cognito_request_context
from shared import repository
from shared.models import UploadStatus
from upload_handler.handler import handler


def _api_event(body: dict | None, sub: str = DEFAULT_SUB) -> dict:
    return {
        "httpMethod": "POST",
        "path": "/uploads",
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body) if body is not None else None,
        "isBase64Encoded": False,
        "requestContext": cognito_request_context(sub),
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
    assert upload.uploaded_by == DEFAULT_SUB
```

Leave the other three tests in this file (`test_upload_defaults_filename_when_missing`, `test_upload_rejects_invalid_json_body`, `test_upload_rejects_non_string_filename`) as-is - they still call `_api_event(...)`, which now works because `sub` defaults to `DEFAULT_SUB`.

- [ ] **Step 3: Run test to verify it fails**

Run: `uv run pytest tests/unit/test_upload_handler.py -v`
Expected: FAIL - `KeyError: 'requestContext'` (the handler doesn't read it yet) or `TypeError: create_upload() missing 1 required positional argument: 'uploaded_by'`

- [ ] **Step 4: Create the shared auth helper**

Create `src/shared/auth.py`:

```python
def caller_sub(event: dict) -> str:
    """The authenticated caller's Cognito user id, as surfaced by API Gateway's
    COGNITO_USER_POOLS authorizer. Always present on an authenticated request - API Gateway
    rejects the request before Lambda runs otherwise, so no defensive handling here.
    """
    return event["requestContext"]["authorizer"]["claims"]["sub"]
```

- [ ] **Step 5: Wire it into `upload_handler`**

In `src/upload_handler/handler.py`, add the import and use it:

```python
import json
import uuid

from shared import repository
from shared.auth import caller_sub
from shared.clients import get_s3_client, get_upload_bucket_name
from shared.constants import MAX_FILE_SIZE_BYTES, PRESIGNED_URL_EXPIRY_SECONDS
from shared.http import error_response, json_response
from shared.logging_config import bind_upload_id, logger


@logger.inject_lambda_context(log_event=True)
def handler(event, context):
    body = _parse_body(event)
    if body is None:
        return error_response(400, "Request body must be valid JSON.")

    original_filename = body.get("filename") or "upload.csv"
    if not isinstance(original_filename, str):
        return error_response(400, "'filename' must be a string.")

    upload_id = str(uuid.uuid4())
    s3_key = f"raw/{upload_id}.csv"
    bind_upload_id(upload_id)

    repository.create_upload(upload_id, original_filename, s3_key, caller_sub(event))
```

(The rest of the function - presigned POST generation and the response - is unchanged. `_parse_body` is unchanged.)

- [ ] **Step 6: Run test to verify it passes**

Run: `uv run pytest tests/unit/test_upload_handler.py -v`
Expected: PASS

- [ ] **Step 7: Run the full suite, lint, and commit**

```bash
uv run pytest -v
uv run ruff check .
git add src/shared/auth.py src/upload_handler/handler.py tests/unit/conftest.py tests/unit/test_upload_handler.py
git commit -m "Stamp uploads with the caller's Cognito identity"
```

---

## Task 3: `status_handler` enforces ownership

**Files:**
- Modify: `src/status_handler/handler.py`
- Modify: `tests/unit/test_status_handler.py`

**Interfaces:**
- Consumes: `shared.auth.caller_sub(event)` from Task 2; `UploadMetadata.uploaded_by` from Task 1.

- [ ] **Step 1: Write the failing tests**

Replace `tests/unit/test_status_handler.py` entirely:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/unit/test_status_handler.py -v`
Expected: FAIL - `test_status_returns_404_when_caller_does_not_own_upload` gets 200, not 404 (no ownership check exists yet)

- [ ] **Step 3: Add the ownership check**

Replace `src/status_handler/handler.py` entirely:

```python
from shared import repository
from shared.auth import caller_sub
from shared.http import error_response, json_response
from shared.logging_config import bind_upload_id, logger


@logger.inject_lambda_context(log_event=True)
def handler(event, context):
    upload_id = (event.get("pathParameters") or {}).get("upload_id")
    if not upload_id:
        return error_response(400, "Missing path parameter 'upload_id'.")

    bind_upload_id(upload_id)
    upload = repository.get_upload(upload_id)
    if upload is None or upload.uploaded_by != caller_sub(event):
        return error_response(404, f"Upload '{upload_id}' not found.")

    return json_response(200, upload.to_response_dict())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/unit/test_status_handler.py -v`
Expected: PASS

- [ ] **Step 5: Run the full suite, lint, and commit**

```bash
uv run pytest -v
uv run ruff check .
git add src/status_handler/handler.py tests/unit/test_status_handler.py
git commit -m "Enforce per-customer ownership in status_handler"
```

---

## Task 4: `records_handler` enforces ownership

**Files:**
- Modify: `src/records_handler/handler.py`
- Modify: `tests/unit/test_records_handler.py`

**Interfaces:**
- Consumes: `shared.auth.caller_sub(event)` from Task 2; `UploadMetadata.uploaded_by` from Task 1.

- [ ] **Step 1: Write the failing tests**

Replace `tests/unit/test_records_handler.py` entirely:

```python
import json

from conftest import DEFAULT_SUB, cognito_request_context
from records_handler.handler import handler
from shared import repository
from shared.models import DataRecord, UploadStatus


def _api_event(upload_id: str | None, query: dict | None = None, sub: str = DEFAULT_SUB) -> dict:
    return {
        "httpMethod": "GET",
        "path": f"/uploads/{upload_id}/records",
        "pathParameters": {"upload_id": upload_id} if upload_id else None,
        "queryStringParameters": query,
        "requestContext": cognito_request_context(sub),
    }


def test_records_returns_empty_while_pending(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", DEFAULT_SUB)

    response = handler(_api_event("upload-1"), lambda_context)

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["status"] == "pending"
    assert body["records"] == []
    assert "next_token" not in body


def test_records_returns_rows_when_succeeded(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", DEFAULT_SUB)
    repository.put_records(
        [DataRecord(upload_id="upload-1", row_number=1, drug_name="Aspirin", target="COX-1", efficacy=72.5)]
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
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", DEFAULT_SUB)
    records = [
        DataRecord(upload_id="upload-1", row_number=i, drug_name=f"Drug{i}", target="T", efficacy=50.0)
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
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", DEFAULT_SUB)

    response = handler(_api_event("upload-1", {"limit": "not-a-number"}), lambda_context)
    assert response["statusCode"] == 400


def test_records_rejects_out_of_range_limit(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", DEFAULT_SUB)

    response = handler(_api_event("upload-1", {"limit": "0"}), lambda_context)
    assert response["statusCode"] == 400


def test_records_returns_404_when_caller_does_not_own_upload(mocked_aws, lambda_context):
    repository.create_upload("upload-1", "drugs.csv", "raw/upload-1.csv", "owner-sub")
    repository.complete_upload(
        "upload-1",
        row_count=0,
        valid_row_count=0,
        invalid_row_count=0,
        row_errors=[],
        status=UploadStatus.SUCCEEDED,
    )

    response = handler(_api_event("upload-1", sub="different-sub"), lambda_context)

    assert response["statusCode"] == 404
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/unit/test_records_handler.py -v`
Expected: FAIL - `test_records_returns_404_when_caller_does_not_own_upload` gets 200, not 404

- [ ] **Step 3: Add the ownership check**

Replace `src/records_handler/handler.py` entirely:

```python
from shared import repository
from shared.auth import caller_sub
from shared.constants import MAX_RECORDS_PAGE_SIZE, RECORDS_PAGE_SIZE
from shared.http import error_response, json_response
from shared.logging_config import bind_upload_id, logger
from shared.models import UploadStatus

# Only these statuses have anything in the records table yet.
_STATUSES_WITH_RECORDS = (UploadStatus.SUCCEEDED, UploadStatus.PARTIALLY_SUCCEEDED)


@logger.inject_lambda_context(log_event=True)
def handler(event, context):
    upload_id = (event.get("pathParameters") or {}).get("upload_id")
    if not upload_id:
        return error_response(400, "Missing path parameter 'upload_id'.")

    bind_upload_id(upload_id)
    upload = repository.get_upload(upload_id)
    if upload is None or upload.uploaded_by != caller_sub(event):
        return error_response(404, f"Upload '{upload_id}' not found.")

    query_params = event.get("queryStringParameters") or {}
    limit = _parse_limit(query_params.get("limit"))
    if limit is None:
        return error_response(
            400, f"'limit' must be an integer between 1 and {MAX_RECORDS_PAGE_SIZE}."
        )

    records = []
    next_token = None
    if upload.status in _STATUSES_WITH_RECORDS:
        records, next_token = repository.query_records(
            upload_id, limit=limit, next_token=query_params.get("next_token")
        )

    body = {
        "upload_id": upload_id,
        "status": upload.status.value,
        "records": [r.to_response_dict() for r in records],
    }
    if next_token:
        body["next_token"] = next_token

    return json_response(200, body)


def _parse_limit(raw_limit: str | None) -> int | None:
    if raw_limit is None:
        return RECORDS_PAGE_SIZE
    try:
        value = int(raw_limit)
    except (TypeError, ValueError):
        return None
    if not (0 < value <= MAX_RECORDS_PAGE_SIZE):
        return None
    return value
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/unit/test_records_handler.py -v`
Expected: PASS

- [ ] **Step 5: Run the full suite, lint, and commit**

```bash
uv run pytest -v
uv run ruff check .
git add src/records_handler/handler.py tests/unit/test_records_handler.py
git commit -m "Enforce per-customer ownership in records_handler"
```

---

## Task 5: Terraform `cognito` module

**Files:**
- Create: `terraform/modules/cognito/variables.tf`
- Create: `terraform/modules/cognito/main.tf`
- Create: `terraform/modules/cognito/outputs.tf`

**Interfaces:**
- Produces: outputs `user_pool_id`, `user_pool_arn`, `client_id`, consumed by Task 6 (via environment wiring in Task 7/8).

- [ ] **Step 1: Write `variables.tf`**

Create `terraform/modules/cognito/variables.tf`:

```hcl
variable "name_prefix" {
  description = "Prefix for the user pool/client names, e.g. csvuploader-dev."
  type        = string
}

variable "password_minimum_length" {
  type    = number
  default = 8
}
```

- [ ] **Step 2: Write `main.tf`**

Create `terraform/modules/cognito/main.tf`:

```hcl
resource "aws_cognito_user_pool" "this" {
  name = "${var.name_prefix}-users"

  alias_attributes         = ["email"]
  auto_verified_attributes = ["email"]

  # Self-service sign-up: customers register themselves, no operator involvement.
  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  password_policy {
    minimum_length    = var.password_minimum_length
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  # "Optional" isn't meaningfully different from "off" without an enrollment flow, which isn't
  # being built - see docs/adr/0006-cognito-auth.md.
  mfa_configuration = "OFF"
}

resource "aws_cognito_user_pool_client" "this" {
  name         = "${var.name_prefix}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  # No client secret: a customer authenticating directly shouldn't have to manage yet another
  # permanent secret alongside their password.
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}
```

- [ ] **Step 3: Write `outputs.tf`**

Create `terraform/modules/cognito/outputs.tf`:

```hcl
output "user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  value = aws_cognito_user_pool.this.arn
}

output "client_id" {
  value = aws_cognito_user_pool_client.this.id
}
```

- [ ] **Step 4: Format and validate**

```bash
cd terraform
terraform fmt -recursive modules/cognito/
cd modules/cognito
terraform init -backend=false
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
cd /mnt/c/Working/csvUploader
git add terraform/modules/cognito/
git commit -m "Add Terraform cognito module"
```

---

## Task 6: `api_gateway` module - Cognito authorizer replacing API key

**Files:**
- Modify: `terraform/modules/api_gateway/variables.tf`
- Modify: `terraform/modules/api_gateway/main.tf`
- Modify: `terraform/modules/api_gateway/outputs.tf`

**Interfaces:**
- Consumes: `cognito_user_pool_arn` (new variable, wired from Task 5's module output in Tasks 7/8).
- Produces: `invoke_url`, `rest_api_id`, `api_name` outputs unchanged; `api_key_value` output removed.

- [ ] **Step 1: Update `variables.tf`**

In `terraform/modules/api_gateway/variables.tf`, remove the `quota_limit` and `quota_period` variables (no longer applicable - usage plans are gone), and add a new variable. The file becomes:

```hcl
variable "environment" {
  type = string
}

variable "upload_handler_function_name" {
  type = string
}

variable "upload_handler_invoke_arn" {
  type = string
}

variable "status_handler_function_name" {
  type = string
}

variable "status_handler_invoke_arn" {
  type = string
}

variable "records_handler_function_name" {
  type = string
}

variable "records_handler_invoke_arn" {
  type = string
}

variable "cognito_user_pool_arn" {
  description = "ARN of the Cognito User Pool that authenticates callers."
  type        = string
}

variable "throttle_rate_limit" {
  description = "Steady-state requests per second allowed (blanket stage-level throttle)."
  type        = number
  default     = 10
}

variable "throttle_burst_limit" {
  description = "Concurrent request burst allowed (blanket stage-level throttle)."
  type        = number
  default     = 20
}

variable "log_retention_days" {
  type    = number
  default = 30
}
```

- [ ] **Step 2: Add the Cognito authorizer and switch method authorization**

In `terraform/modules/api_gateway/main.tf`, add this resource right after the 3 `aws_api_gateway_resource` blocks (after the `records` resource, before the `# --- POST /uploads -> upload_handler ---` comment):

```hcl
resource "aws_api_gateway_authorizer" "cognito" {
  name          = "csvuploader-${var.environment}-cognito"
  rest_api_id   = aws_api_gateway_rest_api.this.id
  type          = "COGNITO_USER_POOLS"
  provider_arns = [var.cognito_user_pool_arn]
}
```

Then update all 3 `aws_api_gateway_method` resources, replacing `authorization = "NONE"` / `api_key_required = true` with the authorizer. `post_uploads` becomes:

```hcl
resource "aws_api_gateway_method" "post_uploads" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.uploads.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}
```

`get_upload_status` becomes:

```hcl
resource "aws_api_gateway_method" "get_upload_status" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.upload_id.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

  request_parameters = {
    "method.request.path.upload_id" = true
  }
}
```

`get_records` becomes:

```hcl
resource "aws_api_gateway_method" "get_records" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.records.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

  request_parameters = {
    "method.request.path.upload_id" = true
  }
}
```

The `aws_api_gateway_integration` and `aws_lambda_permission` resources for all 3 methods are unchanged.

- [ ] **Step 3: Add the authorizer to the deployment trigger**

In `terraform/modules/api_gateway/main.tf`, update the `aws_api_gateway_deployment.this` resource's `triggers` block to include the authorizer, so a change to it also triggers redeployment:

```hcl
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.uploads.id,
      aws_api_gateway_resource.upload_id.id,
      aws_api_gateway_resource.records.id,
      aws_api_gateway_authorizer.cognito.id,
      aws_api_gateway_method.post_uploads.id,
      aws_api_gateway_method.get_upload_status.id,
      aws_api_gateway_method.get_records.id,
      aws_api_gateway_integration.post_uploads.id,
      aws_api_gateway_integration.get_upload_status.id,
      aws_api_gateway_integration.get_records.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

- [ ] **Step 4: Remove the API key / usage plan resources**

In `terraform/modules/api_gateway/main.tf`, delete the entire section from the `# --- API key / usage plan ...` comment through the end of the file (the `aws_api_gateway_api_key.this`, `aws_api_gateway_usage_plan.this`, and `aws_api_gateway_usage_plan_key.this` resources, and the `quota_settings` block inside the usage plan). The file should end after `aws_api_gateway_method_settings.this`, and that resource's `settings` block keeps only the throttling lines (no quota references were in there to begin with, so it's unchanged):

```hcl
resource "aws_api_gateway_method_settings" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    logging_level          = "INFO"
    data_trace_enabled     = false # avoid logging request/response bodies (may contain upload data)
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }
}
```

(This is the last resource in the file now.)

- [ ] **Step 5: Update `outputs.tf`**

Replace `terraform/modules/api_gateway/outputs.tf` entirely (removing `api_key_value`):

```hcl
output "invoke_url" {
  description = "Base URL of the deployed API stage."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "rest_api_id" {
  value = aws_api_gateway_rest_api.this.id
}

output "api_name" {
  value = aws_api_gateway_rest_api.this.name
}
```

- [ ] **Step 6: Format and validate**

This module can't be validated standalone (it has required variables with no defaults and is always used via the environment root modules) - validation happens as part of Task 7/8's environment-level validate. For now, just format:

```bash
cd /mnt/c/Working/csvUploader/terraform
terraform fmt -recursive modules/api_gateway/
```

- [ ] **Step 7: Commit**

```bash
cd /mnt/c/Working/csvUploader
git add terraform/modules/api_gateway/
git commit -m "Replace API key auth with Cognito authorizer in api_gateway module"
```

---

## Task 7: Wire the dev environment

**Files:**
- Modify: `terraform/environments/dev/main.tf`
- Modify: `terraform/environments/dev/variables.tf`
- Modify: `terraform/environments/dev/outputs.tf`

**Interfaces:**
- Consumes: `module.cognito` (Task 5) outputs; `module.api_gateway`'s new `cognito_user_pool_arn` input (Task 6).

- [ ] **Step 1: Remove `quota_limit` from `variables.tf`**

In `terraform/environments/dev/variables.tf`, delete the `quota_limit` variable block:

```hcl
variable "quota_limit" {
  type    = number
  default = 10000
}
```

(Leave every other variable as-is.)

- [ ] **Step 2: Instantiate the cognito module and wire it into api_gateway**

In `terraform/environments/dev/main.tf`, add the cognito module right before the `# --- API Gateway ---` comment:

```hcl
# --- Auth ---

module "cognito" {
  source = "../../modules/cognito"

  name_prefix = local.name_prefix
}

# --- API Gateway ---

module "api_gateway" {
  source = "../../modules/api_gateway"

  environment = var.environment

  upload_handler_function_name  = module.lambda_upload_handler.function_name
  upload_handler_invoke_arn     = module.lambda_upload_handler.invoke_arn
  status_handler_function_name  = module.lambda_status_handler.function_name
  status_handler_invoke_arn     = module.lambda_status_handler.invoke_arn
  records_handler_function_name = module.lambda_records_handler.function_name
  records_handler_invoke_arn    = module.lambda_records_handler.invoke_arn

  cognito_user_pool_arn = module.cognito.user_pool_arn

  throttle_rate_limit  = var.throttle_rate_limit
  throttle_burst_limit = var.throttle_burst_limit
  log_retention_days   = var.log_retention_days
}
```

(This replaces the existing `module "api_gateway"` block - same block, with `cognito_user_pool_arn` added and `quota_limit = var.quota_limit` removed.)

- [ ] **Step 3: Add `cognito-idp` permissions to the CI deploy role policy**

In `terraform/environments/dev/main.tf`, in the `data "aws_iam_policy_document" "github_actions_deploy_permissions"` block, add a new statement (Cognito user pool IDs aren't predictable ahead of creation, same situation as the other AWS-generated-ID resources this policy already handles with prefix scoping - but Cognito ARNs don't embed a human-readable name we control, so this one uses `Condition` on a tag instead). Add this statement right after the `ManageDevResources` statement (before `LogsDescribe`):

```hcl
  statement {
    sid    = "ManageCognito"
    effect = "Allow"
    actions = [
      "cognito-idp:CreateUserPool",
      "cognito-idp:DeleteUserPool",
      "cognito-idp:UpdateUserPool",
      "cognito-idp:DescribeUserPool",
      "cognito-idp:TagResource",
      "cognito-idp:UntagResource",
      "cognito-idp:CreateUserPoolClient",
      "cognito-idp:DeleteUserPoolClient",
      "cognito-idp:UpdateUserPoolClient",
      "cognito-idp:DescribeUserPoolClient",
    ]
    resources = ["*"]
  }
```

(Cognito's `DescribeUserPool`/`CreateUserPool` actions don't support resource-level permissions any narrower than `"*"` - same category of AWS limitation as the `LogsDescribe` statement already in this file. Flagged here rather than discovered via a failed CI run this time, since we've already been through that class of issue once.)

- [ ] **Step 4: Update `outputs.tf`**

Replace `terraform/environments/dev/outputs.tf` entirely:

```hcl
output "api_invoke_url" {
  description = "Base URL of the deployed API. Append /uploads, /uploads/{id}, etc."
  value       = module.api_gateway.invoke_url
}

output "cognito_user_pool_id" {
  description = "Pass as the X-Amz-Target ClientMetadata / pool id for Cognito SignUp/InitiateAuth calls."
  value       = module.cognito.user_pool_id
}

output "cognito_client_id" {
  description = "App client id for Cognito SignUp/InitiateAuth calls."
  value       = module.cognito.client_id
}

output "github_actions_role_arn" {
  description = "Role ARN for the GitHub Actions CI workflow to assume."
  value       = module.github_oidc.role_arn
}

output "dashboard_name" {
  value = module.monitoring.dashboard_name
}
```

- [ ] **Step 5: Format and validate**

```bash
cd /mnt/c/Working/csvUploader/terraform
terraform fmt -recursive environments/dev/
cd environments/dev
terraform init -backend=false
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
cd /mnt/c/Working/csvUploader
git add terraform/environments/dev/
git commit -m "Wire Cognito into the dev environment"
```

---

## Task 8: Wire the prod environment

**Files:**
- Modify: `terraform/environments/prod/main.tf`
- Modify: `terraform/environments/prod/variables.tf`
- Modify: `terraform/environments/prod/outputs.tf`

**Interfaces:**
- Same as Task 7, mirrored for prod. No `github_actions_deploy_permissions` policy exists in prod (CI never touches prod), so no Cognito IAM statement is needed here.

- [ ] **Step 1: Remove `quota_limit` from `variables.tf`**

In `terraform/environments/prod/variables.tf`, delete the `quota_limit` variable block (same as Task 7 Step 1, prod's copy).

- [ ] **Step 2: Instantiate the cognito module and wire it into api_gateway**

In `terraform/environments/prod/main.tf`, apply the same change as Task 7 Step 2: add `module "cognito"` before `# --- API Gateway ---`, and update the `module "api_gateway"` block to add `cognito_user_pool_arn = module.cognito.user_pool_arn` and remove `quota_limit = var.quota_limit`. (Identical to dev's version of this change - prod's `main.tf` has the exact same module structure at this point in the file.)

- [ ] **Step 3: Update `outputs.tf`**

Replace `terraform/environments/prod/outputs.tf` entirely:

```hcl
output "api_invoke_url" {
  description = "Base URL of the deployed API. Append /uploads, /uploads/{id}, etc."
  value       = module.api_gateway.invoke_url
}

output "cognito_user_pool_id" {
  description = "Pass as the X-Amz-Target ClientMetadata / pool id for Cognito SignUp/InitiateAuth calls."
  value       = module.cognito.user_pool_id
}

output "cognito_client_id" {
  description = "App client id for Cognito SignUp/InitiateAuth calls."
  value       = module.cognito.client_id
}

output "dashboard_name" {
  value = module.monitoring.dashboard_name
}
```

- [ ] **Step 4: Format and validate**

```bash
cd /mnt/c/Working/csvUploader/terraform
terraform fmt -recursive environments/prod/
cd environments/prod
terraform init -backend=false
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
cd /mnt/c/Working/csvUploader
git add terraform/environments/prod/
git commit -m "Wire Cognito into the prod environment"
```

---

## Task 9: Update OpenAPI spec and README

**Files:**
- Modify: `docs/openapi.yaml`
- Modify: `README.md`

**Interfaces:** None (documentation only).

- [ ] **Step 1: Update the OpenAPI security scheme**

In `docs/openapi.yaml`, replace the `security:` block near the top:

```yaml
security:
  - CognitoAuth: []
```

Replace the `securitySchemes` block under `components:`:

```yaml
  securitySchemes:
    CognitoAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
      description: >
        Access token from Cognito's InitiateAuth (USER_PASSWORD_AUTH flow), obtained after
        SignUp + ConfirmSignUp. See README.md for the full sign-up/login walkthrough.
```

- [ ] **Step 2: Update the per-endpoint auth-failure responses**

In `docs/openapi.yaml`, every occurrence of:

```yaml
        "403":
          description: Missing or invalid API key.
```

becomes:

```yaml
        "401":
          description: Missing or invalid access token.
```

This applies to all 3 endpoints (`POST /uploads`, `GET /uploads/{upload_id}`, `GET /uploads/{upload_id}/records`).

- [ ] **Step 3: Validate the spec**

```bash
cd /mnt/c/Working/csvUploader
uv run python -c "
import yaml
with open('docs/openapi.yaml') as f:
    spec = yaml.safe_load(f)
print('YAML parses OK')
"
uv run --with openapi-spec-validator python -c "
from openapi_spec_validator import validate
import yaml
with open('docs/openapi.yaml') as f:
    spec = yaml.safe_load(f)
validate(spec)
print('OpenAPI spec is valid')
"
```

Expected: both print their success message.

- [ ] **Step 4: Rewrite the README's API section**

In `README.md`, replace the paragraph and code block under `## API` from `All endpoints require an \`x-api-key\` header...` through the `API_URL=$(...)` code block (i.e., replace these two paragraphs/blocks):

```markdown
All endpoints require an `x-api-key` header. Get a key's value from Terraform after deploying an
environment:

\`\`\`bash
cd terraform/environments/dev
API_KEY=$(AWS_PROFILE=csvuploader terraform output -raw api_key_value)
API_URL=$(AWS_PROFILE=csvuploader terraform output -raw api_invoke_url)
\`\`\`
```

with:

```markdown
All endpoints require an `Authorization: Bearer <token>` header. Customers sign themselves up -
there's no operator-provisioned secret. Get the pool/client ids for your deployed environment:

\`\`\`bash
cd terraform/environments/dev
POOL_ID=$(AWS_PROFILE=csvuploader terraform output -raw cognito_user_pool_id)
CLIENT_ID=$(AWS_PROFILE=csvuploader terraform output -raw cognito_client_id)
API_URL=$(AWS_PROFILE=csvuploader terraform output -raw api_invoke_url)
REGION=us-east-1
\`\`\`

**Sign up, confirm, and log in** (requires `jq` and the AWS CLI, called unauthenticated - these
specific Cognito operations don't need AWS credentials):

\`\`\`bash
aws cognito-idp sign-up --region "$REGION" --client-id "$CLIENT_ID" \\
  --username customer@example.com --password 'SomeStrongPassw0rd' \\
  --user-attributes Name=email,Value=customer@example.com

# Check the inbox for customer@example.com for the verification code, then:
aws cognito-idp confirm-sign-up --region "$REGION" --client-id "$CLIENT_ID" \\
  --username customer@example.com --confirmation-code 123456

AUTH=$(aws cognito-idp initiate-auth --region "$REGION" --client-id "$CLIENT_ID" \\
  --auth-flow USER_PASSWORD_AUTH \\
  --auth-parameters USERNAME=customer@example.com,PASSWORD='SomeStrongPassw0rd')
API_TOKEN=$(echo "$AUTH" | jq -r .AuthenticationResult.AccessToken)
\`\`\`

`$API_TOKEN` is short-lived (~1 hour); re-run `initiate-auth` (or use the returned
`RefreshToken`) to get a new one.
```

- [ ] **Step 5: Update the curl examples to use the new header**

In `README.md`, 3 of the 4 curl examples use the header and need updating: "start an upload", "check status", and "retrieve parsed records". In each, replace `-H "x-api-key: $API_KEY"` with `-H "Authorization: Bearer $API_TOKEN"`. The "upload the file" example (the presigned S3 POST) is unchanged - it never used the API key, since it goes to S3, not the API.

- [ ] **Step 6: Update the design decisions list**

In `README.md`, under `## Design decisions`, the numbered list becomes:

```markdown
1. [Upload via S3 presigned POST](docs/adr/0001-upload-mechanism.md)
2. [DynamoDB for storage](docs/adr/0002-database-choice.md)
3. [API keys over Cognito/IAM (superseded)](docs/adr/0003-auth-choice.md)
4. [Separate state per environment, trunk-based CI/CD](docs/adr/0004-environment-strategy.md)
5. [Partial ingest with per-row errors](docs/adr/0005-validation-policy.md)
6. [Cognito authentication](docs/adr/0006-cognito-auth.md)
```

(Only entry 3's link text and the new entry 6 are different from the current file - entries 1, 2, 4, 5 are unchanged.)

- [ ] **Step 7: Commit**

```bash
cd /mnt/c/Working/csvUploader
git add docs/openapi.yaml README.md
git commit -m "Update OpenAPI spec and README for Cognito auth"
```

---

## Task 10: ADRs

**Files:**
- Modify: `docs/adr/0003-auth-choice.md`
- Create: `docs/adr/0006-cognito-auth.md`

**Interfaces:** None (documentation only).

- [ ] **Step 1: Mark ADR 0003 as superseded**

In `docs/adr/0003-auth-choice.md`, change the `## Status` section:

```markdown
## Status

Superseded by [0006](0006-cognito-auth.md)
```

(Leave the rest of the file untouched - it's a historical record of a decision that was correct given what was known at the time.)

- [ ] **Step 2: Write ADR 0006**

Create `docs/adr/0006-cognito-auth.md`:

```markdown
# 6. Cognito authentication, replacing API keys

## Status

Accepted. Supersedes [0003](0003-auth-choice.md).

## Context

[ADR 0003](0003-auth-choice.md) chose API Gateway API keys because nothing in the original spec
described real user accounts - building an identity system felt like solving a problem that
wasn't there. Two things changed that:

1. Retrieving the key to demonstrate the auth flow leaked it into a chat transcript, requiring a
   rotation - illustrating how easy a permanent shared secret is to mishandle.
2. A direct question - "if I'm a customer, how do I get an API key?" - exposed that there was no
   self-service path at all. Only the AWS account operator could provision a key, manually.

The explicit priority for the redesign: security and ease of use above everything else.

## Decision

Replace API keys with a Cognito User Pool, authenticated via API Gateway's native
`COGNITO_USER_POOLS` authorizer. No Hosted UI - customers call Cognito's public `SignUp` /
`ConfirmSignUp` / `InitiateAuth` operations directly and use the resulting access token as
`Authorization: Bearer <token>`.

Per-customer data isolation is enforced: every upload is stamped with the caller's Cognito `sub`,
and `status_handler`/`records_handler` return 404 (not 403) if the caller doesn't own the upload
they're asking about, so a customer can't distinguish "not yours" from "doesn't exist."

MFA is off (`mfa_configuration = "OFF"`) - "optional" isn't meaningfully different from "off"
without an enrollment flow, which isn't being built. No client secret on the App Client
(`generate_secret = false`) - a client-side secret would just reintroduce the "manage a permanent
secret" problem for the customer.

## Consequences

- **Usage-plan quota/throttling is gone.** It's mechanically tied to API keys and can't
  attribute to a Cognito identity. Replaced with a single blanket stage-level throttle
  protecting the whole API regardless of caller - a real reduction in granularity, accepted in
  favor of not building custom per-user throttling in Lambda for a "nice to have."
- Cognito's built-in email sending handles verification codes at this scale; real production
  volume would need SES instead.
- The CI deploy role needs `cognito-idp:*` actions on `resources = ["*"]` - Cognito doesn't
  support narrower resource-level permissions for pool management actions, the same category of
  AWS limitation `docs/adr/0004-environment-strategy.md` already documents for
  `logs:DescribeLogGroups` and API Gateway's `/apikeys`/`/usageplans` paths.
- No admin/support tooling exists for manually managing customer accounts (e.g. disabling a
  user) - Cognito's own console covers that manually for now.
```

- [ ] **Step 3: Verify the cross-links resolve**

```bash
cd /mnt/c/Working/csvUploader
test -f docs/adr/0003-auth-choice.md && test -f docs/adr/0006-cognito-auth.md && echo "both files exist"
```

- [ ] **Step 4: Commit**

```bash
git add docs/adr/0003-auth-choice.md docs/adr/0006-cognito-auth.md
git commit -m "Add ADR 0006 (Cognito auth), mark ADR 0003 superseded"
```

---

## Note on applying the infrastructure changes

Tasks 5-8 produce validated Terraform code but do not run `plan`/`apply` against real AWS -
consistent with this project's established workflow, that's a separate step run against the
live dev account (`AWS_PROFILE=csvuploader`), reviewed as a plan before anyone applies it. Do
not run `terraform plan`/`apply` with real credentials as part of executing this plan's tasks.
