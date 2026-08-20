# Customer Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `GET /uploads` list endpoint (backed by a new DynamoDB GSI) and a React frontend where a customer can sign up, confirm their email, log in, upload a CSV, and see their own upload history with summary stats.

**Architecture:** One new Lambda (`list_handler`) queries a new `uploaded_by`/`created_at` GSI on the existing `uploads` table, exposed as `GET /uploads` behind the existing Cognito authorizer - in both dev and prod, since it's a real API capability, not a frontend-only concern. A new `frontend/` Vite + React + TypeScript app uses `@aws-amplify/ui-react`'s `<Authenticator>` for sign-up/confirm/sign-in against the existing Cognito pool, and a single Dashboard page for the upload flow + history table. The frontend is hosted on a new S3 + CloudFront module, deployed via a new GitHub Actions workflow - **dev only** for this iteration.

**Tech Stack:** Python 3.13 / `aws-lambda-powertools` / pytest+moto (backend, matching existing handlers), Terraform (`hashicorp/aws` ~> 5.0), Vite + React 18 + TypeScript, `aws-amplify` v6 + `@aws-amplify/ui-react` v6 (frontend).

**Spec:** [`docs/specs/2026-08-20-customer-dashboard-design.md`](../specs/2026-08-20-customer-dashboard-design.md)

## Global Constraints

- Backend changes (GSI, `list_handler`, API Gateway route) apply to **both** `dev` and `prod` environments - this is a real API capability, not tied to the frontend's dev-only scope.
- Frontend hosting/deployment is **dev only** this iteration. No prod frontend infra.
- No automated frontend test suite this iteration - manual verification against the live dev deployment is the acceptance check (see spec's Testing section).
- The API must always use the **ID token**, never the access token, for `Authorization: Bearer <token>` - API Gateway's `COGNITO_USER_POOLS` authorizer validates the `aud` claim, which only ID tokens carry.
- No charts/visualizations, no "load more" pagination UI, no custom email templates/SES - all explicitly out of scope per the spec.
- Follow existing patterns exactly: one Lambda per responsibility, one least-privilege IAM role per Lambda, `error_response`/`json_response` from `shared.http`, `caller_sub` from `shared.auth`, opaque base64 `next_token` pagination.

---

### Task 1: Repository support for listing a customer's uploads

**Files:**
- Modify: `src/shared/constants.py`
- Modify: `src/shared/repository.py`
- Modify: `tests/unit/conftest.py`
- Test: `tests/unit/test_repository.py`

**Interfaces:**
- Consumes: `UploadMetadata` (from `shared.models`, unchanged), `get_uploads_table()` (from `shared.clients`, unchanged).
- Produces: `repository.query_uploads_by_customer(uploaded_by: str, limit: int, next_token: str | None) -> tuple[list[UploadMetadata], str | None]` - Task 2's `list_handler` calls this directly.

- [ ] **Step 1: Add new constants**

In `src/shared/constants.py`, add these two lines right after the existing `RECORDS_PAGE_SIZE`/`MAX_RECORDS_PAGE_SIZE` lines:

```python
UPLOADS_PAGE_SIZE = 20
MAX_UPLOADS_PAGE_SIZE = 100
```

- [ ] **Step 2: Add the GSI to the mocked test table**

In `tests/unit/conftest.py`, the `mocked_aws` fixture creates the uploads table with `dynamodb.create_table(...)`. Replace that specific `create_table` call (the one for `UPLOADS_TABLE`) with this version, which adds the GSI moto needs to emulate the query:

```python
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
```

Leave the `RECORDS_TABLE` `create_table` call directly below it untouched.

- [ ] **Step 3: Write the failing tests**

Add to `tests/unit/test_repository.py` (check the existing imports at the top of that file already cover `repository` and `DEFAULT_SUB`/`cognito_request_context` as needed - if `DEFAULT_SUB` isn't already imported there, add `from conftest import DEFAULT_SUB` alongside whatever's already imported):

```python
def test_query_uploads_by_customer_returns_newest_first(mocked_aws):
    repository.create_upload("upload-1", "a.csv", "raw/upload-1.csv", "customer-1")
    repository.create_upload("upload-2", "b.csv", "raw/upload-2.csv", "customer-1")
    repository.create_upload("upload-3", "c.csv", "raw/upload-3.csv", "other-customer")

    uploads, next_token = repository.query_uploads_by_customer(
        "customer-1", limit=10, next_token=None
    )

    assert [u.upload_id for u in uploads] == ["upload-2", "upload-1"]
    assert next_token is None


def test_query_uploads_by_customer_paginates(mocked_aws):
    for i in range(5):
        repository.create_upload(f"upload-{i}", "a.csv", f"raw/upload-{i}.csv", "customer-1")

    page1, token1 = repository.query_uploads_by_customer("customer-1", limit=3, next_token=None)
    assert len(page1) == 3
    assert token1 is not None

    page2, token2 = repository.query_uploads_by_customer(
        "customer-1", limit=3, next_token=token1
    )
    assert len(page2) == 2
    assert token2 is None

    seen_ids = {u.upload_id for u in page1} | {u.upload_id for u in page2}
    assert seen_ids == {f"upload-{i}" for i in range(5)}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `uv run pytest tests/unit/test_repository.py -k query_uploads_by_customer -v`
Expected: FAIL with `AttributeError: module 'shared.repository' has no attribute 'query_uploads_by_customer'`

- [ ] **Step 5: Implement `query_uploads_by_customer`**

In `src/shared/repository.py`, add this function right after `query_records` (before `_encode_token`):

```python
def query_uploads_by_customer(
    uploaded_by: str, limit: int, next_token: str | None
) -> tuple[list[UploadMetadata], str | None]:
    table = get_uploads_table()
    kwargs = {
        "IndexName": "uploaded_by-created_at-index",
        "KeyConditionExpression": "uploaded_by = :uploaded_by",
        "ExpressionAttributeValues": {":uploaded_by": uploaded_by},
        "Limit": limit,
        "ScanIndexForward": False,  # newest created_at first
    }
    if next_token:
        kwargs["ExclusiveStartKey"] = _decode_uploads_token(next_token)

    response = table.query(**kwargs)
    items = [UploadMetadata.from_item(item) for item in response.get("Items", [])]
    last_key = response.get("LastEvaluatedKey")
    return items, (_encode_token(last_key) if last_key else None)


def _decode_uploads_token(token: str) -> dict:
    return json.loads(base64.urlsafe_b64decode(token.encode()).decode())
```

`_encode_token` above it is already generic (`json.dumps(key, default=str)`) and needs no changes - it's reused as-is. `_decode_uploads_token` is separate from the existing `_decode_token` because the GSI's `LastEvaluatedKey` shape (`upload_id`, `uploaded_by`, `created_at`, all strings, no type coercion needed) differs from the records table's (`upload_id`, `row_number` as an int) - reusing `_decode_token` would silently break records pagination if either ever changed independently.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `uv run pytest tests/unit/test_repository.py -v`
Expected: PASS, all tests including the two new ones.

- [ ] **Step 7: Run the full suite and commit**

Run: `uv run pytest -q` (full suite must still pass) and `uv run ruff check .`

```bash
git add src/shared/constants.py src/shared/repository.py tests/unit/conftest.py tests/unit/test_repository.py
git commit -m "Add query_uploads_by_customer backed by a new GSI"
```

---

### Task 2: `list_handler` Lambda

**Files:**
- Create: `src/list_handler/__init__.py`
- Create: `src/list_handler/handler.py`
- Test: `tests/unit/test_list_handler.py`

**Interfaces:**
- Consumes: `repository.query_uploads_by_customer(...)` (Task 1), `caller_sub(event)` (from `shared.auth`, unchanged), `error_response`/`json_response` (from `shared.http`, unchanged), `UPLOADS_PAGE_SIZE`/`MAX_UPLOADS_PAGE_SIZE` (Task 1).
- Produces: `list_handler.handler.handler(event, context)` - Task 4's Terraform wires this as the target of `GET /uploads`.

- [ ] **Step 1: Write the failing tests**

Create `tests/unit/test_list_handler.py`:

```python
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/unit/test_list_handler.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'list_handler'`

- [ ] **Step 3: Implement the handler**

Create `src/list_handler/__init__.py` (empty file, matching every other handler package).

Create `src/list_handler/handler.py`:

```python
from shared import repository
from shared.auth import caller_sub
from shared.constants import MAX_UPLOADS_PAGE_SIZE, UPLOADS_PAGE_SIZE
from shared.http import error_response, json_response
from shared.logging_config import logger


@logger.inject_lambda_context(log_event=True)
def handler(event, context):
    query_params = event.get("queryStringParameters") or {}
    limit = _parse_limit(query_params.get("limit"))
    if limit is None:
        return error_response(
            400, f"'limit' must be an integer between 1 and {MAX_UPLOADS_PAGE_SIZE}."
        )

    uploads, next_token = repository.query_uploads_by_customer(
        caller_sub(event), limit=limit, next_token=query_params.get("next_token")
    )

    body = {"uploads": [u.to_response_dict() for u in uploads]}
    if next_token:
        body["next_token"] = next_token

    return json_response(200, body)


def _parse_limit(raw_limit: str | None) -> int | None:
    if raw_limit is None:
        return UPLOADS_PAGE_SIZE
    try:
        value = int(raw_limit)
    except (TypeError, ValueError):
        return None
    if not (0 < value <= MAX_UPLOADS_PAGE_SIZE):
        return None
    return value
```

This mirrors `records_handler.handler`'s `_parse_limit` exactly (same bounds-checking shape), and `status_handler`'s import/decorator style.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/unit/test_list_handler.py -v`
Expected: PASS, all 4 tests.

- [ ] **Step 5: Run the full suite and commit**

Run: `uv run pytest -q` and `uv run ruff check .`

```bash
git add src/list_handler/ tests/unit/test_list_handler.py
git commit -m "Add list_handler for GET /uploads"
```

---

### Task 3: Terraform - DynamoDB GSI and api_gateway module changes

**Files:**
- Modify: `terraform/modules/dynamodb/main.tf`
- Modify: `terraform/modules/api_gateway/main.tf`
- Modify: `terraform/modules/api_gateway/variables.tf`

**Interfaces:**
- Consumes: nothing new.
- Produces: `module.dynamodb.uploads_table_arn` unchanged in shape but the table now has a GSI at `${uploads_table_arn}/index/uploaded_by-created_at-index` (Task 4's IAM policy references this ARN directly - no new module output needed, matching the existing convention of constructing sub-resource ARNs inline, e.g. `"${module.s3.bucket_arn}/raw/*"`). `api_gateway` module gains two new required variables, `list_handler_function_name` and `list_handler_invoke_arn` (Task 4 passes these in from both environments).

- [ ] **Step 1: Add the GSI to the uploads table**

In `terraform/modules/dynamodb/main.tf`, replace the `aws_dynamodb_table.uploads` resource with:

```hcl
resource "aws_dynamodb_table" "uploads" {
  name         = var.uploads_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "upload_id"

  attribute {
    name = "upload_id"
    type = "S"
  }

  attribute {
    name = "uploaded_by"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  global_secondary_index {
    name            = "uploaded_by-created_at-index"
    hash_key        = "uploaded_by"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }
}
```

Leave `aws_dynamodb_table.records` below it completely unchanged.

- [ ] **Step 2: Add the new API Gateway method for `GET /uploads`**

In `terraform/modules/api_gateway/variables.tf`, add these two variables right after `upload_handler_invoke_arn`:

```hcl
variable "list_handler_function_name" {
  type = string
}

variable "list_handler_invoke_arn" {
  type = string
}
```

In `terraform/modules/api_gateway/main.tf`, add this block right after the `# --- POST /uploads -> upload_handler ---` section (after the `aws_lambda_permission.post_uploads` resource, before the `# --- GET /uploads/{upload_id} -> status_handler ---` comment):

```hcl
# --- GET /uploads -> list_handler ---

resource "aws_api_gateway_method" "list_uploads" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.uploads.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "list_uploads" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.uploads.id
  http_method             = aws_api_gateway_method.list_uploads.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.list_handler_invoke_arn
}

resource "aws_lambda_permission" "list_uploads" {
  statement_id  = "AllowAPIGatewayInvokeListHandler"
  action        = "lambda:InvokeFunction"
  function_name = var.list_handler_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/${aws_api_gateway_method.list_uploads.http_method}${aws_api_gateway_resource.uploads.path}"
}
```

- [ ] **Step 3: Add the new resources to the deployment's redeployment trigger**

In `terraform/modules/api_gateway/main.tf`, in the `aws_api_gateway_deployment.this` resource's `triggers.redeployment` list, add `aws_api_gateway_method.list_uploads.id` and `aws_api_gateway_integration.list_uploads.id` - the full list becomes:

```hcl
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.uploads.id,
      aws_api_gateway_resource.upload_id.id,
      aws_api_gateway_resource.records.id,
      aws_api_gateway_authorizer.cognito.id,
      aws_api_gateway_method.post_uploads.id,
      aws_api_gateway_method.list_uploads.id,
      aws_api_gateway_method.get_upload_status.id,
      aws_api_gateway_method.get_records.id,
      aws_api_gateway_integration.post_uploads.id,
      aws_api_gateway_integration.list_uploads.id,
      aws_api_gateway_integration.get_upload_status.id,
      aws_api_gateway_integration.get_records.id,
    ]))
  }
```

- [ ] **Step 4: Format and validate**

Run: `terraform fmt -recursive terraform/modules/dynamodb terraform/modules/api_gateway`
Run: `cd terraform/modules/dynamodb && terraform init -backend=false && terraform validate && cd -`

(The `api_gateway` module can't be validated standalone - it has no `environments/` root of its own yet with the new variables wired in. Task 4 validates it as part of the full environment.)

- [ ] **Step 5: Commit**

```bash
git add terraform/modules/dynamodb/main.tf terraform/modules/api_gateway/main.tf terraform/modules/api_gateway/variables.tf
git commit -m "Add uploaded_by GSI and GET /uploads route to api_gateway module"
```

---

### Task 4: Wire `list_handler` into dev and prod environments

**Files:**
- Modify: `terraform/environments/dev/main.tf`
- Modify: `terraform/environments/prod/main.tf`
- Modify: `scripts/build_lambda_packages.sh`

**Interfaces:**
- Consumes: `module.dynamodb.uploads_table_arn` (Task 3's GSI lives on this same table), `aws_lambda_layer_version.dependencies` (unchanged), `module.api_gateway`'s new `list_handler_function_name`/`list_handler_invoke_arn` variables (Task 3).
- Produces: nothing new consumed by a later task - this is the last backend infra task.

- [ ] **Step 1: Add `list_handler` to the build script**

In `scripts/build_lambda_packages.sh`, change the `FUNCTIONS` line to:

```bash
FUNCTIONS=(upload_handler process_handler status_handler records_handler list_handler)
```

- [ ] **Step 2: Wire `list_handler`'s IAM role, Lambda function, and API Gateway variables into `terraform/environments/dev/main.tf`**

Add this IAM policy + module block right after the `module "iam_records_handler"` block (before the `# --- Lambda functions ---` comment):

```hcl
data "aws_iam_policy_document" "list_handler_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:Query"]
    resources = ["${module.dynamodb.uploads_table_arn}/index/uploaded_by-created_at-index"]
  }
}

module "iam_list_handler" {
  source = "../../modules/iam"

  function_name      = "${local.name_prefix}-list-handler"
  inline_policy_json = data.aws_iam_policy_document.list_handler_permissions.json
}
```

Add this Lambda module block right after the `module "lambda_records_handler"` block (before the `# --- S3 -> process_handler trigger ---` comment):

```hcl
module "lambda_list_handler" {
  source = "../../modules/lambda"

  function_name      = "${local.name_prefix}-list-handler"
  source_dir         = "${local.build_dir}/functions/list_handler"
  handler            = "list_handler.handler.handler"
  role_arn           = module.iam_list_handler.role_arn
  layer_arns         = [aws_lambda_layer_version.dependencies.arn]
  log_retention_days = var.log_retention_days

  environment_variables = {
    UPLOADS_TABLE_NAME = module.dynamodb.uploads_table_name
  }
}
```

In the `module "api_gateway"` block, add these two lines alongside the other `*_function_name`/`*_invoke_arn` pairs:

```hcl
  list_handler_function_name    = module.lambda_list_handler.function_name
  list_handler_invoke_arn       = module.lambda_list_handler.invoke_arn
```

In the `module "monitoring"` block's `lambda_function_names` map, add:

```hcl
    list-handler    = module.lambda_list_handler.function_name
```

- [ ] **Step 3: Add the new DynamoDB action to dev's CI deploy role**

In `terraform/environments/dev/main.tf`, the `github_actions_deploy_permissions` policy's `"ManageDevResources"` statement already grants `"dynamodb:*"` (a wildcard covering all DynamoDB actions, including the new GSI's creation/query) - no change needed there. Confirm this by re-reading that statement's `actions` list before moving on; if it does NOT contain `"dynamodb:*"`, stop and report back rather than guessing at a narrower fix.

- [ ] **Step 4: Repeat the same wiring in `terraform/environments/prod/main.tf`**

Apply the exact same three additions (IAM policy + `module.iam_list_handler`, `module.lambda_list_handler`, the two new `module.api_gateway` variables, the `monitoring` map entry) to `terraform/environments/prod/main.tf`, in the same relative positions. Prod's `main.tf` has no `github_actions_deploy_permissions`/CI section at all (prod is never CI-applied), so there is nothing else to change there.

- [ ] **Step 5: Format and validate both environments**

```bash
terraform fmt -recursive terraform/environments terraform/modules
cd terraform/environments/dev && terraform init -backend=false -input=false && terraform validate && cd -
cd terraform/environments/prod && terraform init -backend=false -input=false && terraform validate && cd -
```

Expected: both `terraform validate` calls succeed with no errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/build_lambda_packages.sh terraform/environments/dev/main.tf terraform/environments/prod/main.tf
git commit -m "Wire list_handler into dev and prod"
```

---

### Task 5: OpenAPI spec for `GET /uploads`

**Files:**
- Modify: `docs/openapi.yaml`

**Interfaces:**
- Consumes: the `UploadStatus` schema (unchanged, reused per-item).
- Produces: nothing consumed by a later task - documentation only.

- [ ] **Step 1: Add the path**

In `docs/openapi.yaml`, add this new path entry directly above the existing `/uploads:` entry (so `GET /uploads` reads naturally alongside `POST /uploads` under the same `/uploads:` key - merge it into the *same* `/uploads:` block rather than duplicating the key):

```yaml
paths:
  /uploads:
    get:
      summary: List this customer's uploads
      description: >
        Returns this customer's own uploads, newest first. Scoped to the caller's Cognito sub -
        there is no way to list another customer's uploads.
      parameters:
        - name: limit
          in: query
          required: false
          schema:
            type: integer
            minimum: 1
            maximum: 100
            default: 20
          description: Page size. Must be between 1 and 100.
        - name: next_token
          in: query
          required: false
          schema:
            type: string
          description: Opaque pagination cursor from a previous response's next_token.
      responses:
        "200":
          description: A page of this customer's uploads.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/UploadsPage"
        "400":
          description: Invalid limit.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Error"
        "401":
          description: Missing or invalid ID token.
    post:
      summary: Start a CSV upload
```

(The `post:` line and everything below it - the existing `POST /uploads` definition - stays exactly as it is today; only the new `get:` block is inserted above it, and the `/uploads:` key itself must not be duplicated.)

- [ ] **Step 2: Add the `UploadsPage` schema**

Add this new schema to `components/schemas`, right after the existing `UploadStatus` schema and before `Record`:

```yaml
    UploadsPage:
      type: object
      properties:
        uploads:
          type: array
          items:
            $ref: "#/components/schemas/UploadStatus"
        next_token:
          type: string
          description: Present only when another page is available.
      required: [uploads]
```

- [ ] **Step 3: Validate the YAML parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('docs/openapi.yaml'))"`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add docs/openapi.yaml
git commit -m "Document GET /uploads in the OpenAPI spec"
```

---

### Task 6: Frontend scaffold - Vite + React + TypeScript + Amplify Auth

**Files:**
- Create: `frontend/package.json`
- Create: `frontend/tsconfig.json`
- Create: `frontend/tsconfig.node.json`
- Create: `frontend/vite.config.ts`
- Create: `frontend/index.html`
- Create: `frontend/.gitignore`
- Create: `frontend/.env.example`
- Create: `frontend/src/main.tsx`
- Create: `frontend/src/aws-config.ts`
- Create: `frontend/src/App.tsx`
- Create: `frontend/src/vite-env.d.ts`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: an authenticated app shell rendering a placeholder. Task 7 (`api.ts`) and Task 8 (`Dashboard.tsx`) build on this scaffold; `App.tsx` will import `Dashboard` from `./pages/Dashboard` once Task 8 creates it.

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "csvuploader-frontend",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "@aws-amplify/ui-react": "^6.5.0",
    "aws-amplify": "^6.6.0",
    "react": "^18.3.0",
    "react-dom": "^18.3.0"
  },
  "devDependencies": {
    "@types/react": "^18.3.0",
    "@types/react-dom": "^18.3.0",
    "@vitejs/plugin-react": "^4.3.0",
    "typescript": "^5.6.0",
    "vite": "^5.4.0"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true
  },
  "include": ["src"],
  "references": [{ "path": "./tsconfig.node.json" }]
}
```

- [ ] **Step 3: Create `tsconfig.node.json`**

```json
{
  "compilerOptions": {
    "composite": true,
    "skipLibCheck": true,
    "module": "ESNext",
    "moduleResolution": "bundler",
    "allowSyntheticDefaultImports": true
  },
  "include": ["vite.config.ts"]
}
```

- [ ] **Step 4: Create `vite.config.ts`**

```typescript
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
});
```

- [ ] **Step 5: Create `index.html`**

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>csvUploader</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

- [ ] **Step 6: Create `.gitignore`**

```
node_modules/
dist/
.env
.env.local
```

- [ ] **Step 7: Create `.env.example`**

This documents the three build-time variables the app needs; the real `.env` (git-ignored) is created locally from the current dev deployment's Terraform outputs, and CI injects the same three as env vars at build time (Task 13).

```
VITE_API_URL=https://example.execute-api.us-east-1.amazonaws.com/dev
VITE_COGNITO_USER_POOL_ID=us-east-1_XXXXXXXXX
VITE_COGNITO_CLIENT_ID=XXXXXXXXXXXXXXXXXXXXXXXXXX
```

- [ ] **Step 8: Create `src/vite-env.d.ts`**

Vite's own ambient types don't know about our specific `VITE_*` variables by default - this declares them so `import.meta.env.VITE_API_URL` etc. type-check correctly instead of falling back to `any`:

```typescript
/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_API_URL: string;
  readonly VITE_COGNITO_USER_POOL_ID: string;
  readonly VITE_COGNITO_CLIENT_ID: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
```

- [ ] **Step 9: Create `src/aws-config.ts`**

```typescript
import type { ResourcesConfig } from "aws-amplify";

export const amplifyConfig: ResourcesConfig = {
  Auth: {
    Cognito: {
      userPoolId: import.meta.env.VITE_COGNITO_USER_POOL_ID,
      userPoolClientId: import.meta.env.VITE_COGNITO_CLIENT_ID,
    },
  },
};
```

- [ ] **Step 10: Create `src/main.tsx`**

```typescript
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { Amplify } from "aws-amplify";
import { amplifyConfig } from "./aws-config";
import App from "./App";

Amplify.configure(amplifyConfig);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
```

- [ ] **Step 11: Create `src/App.tsx`** (placeholder body - Task 8 replaces the placeholder `<p>` with the real `Dashboard`)

```typescript
import { Authenticator } from "@aws-amplify/ui-react";
import "@aws-amplify/ui-react/styles.css";

export default function App() {
  return (
    <Authenticator>
      {({ signOut, user }) => (
        <main>
          <p>Signed in as {user?.signInDetails?.loginId}</p>
          <button onClick={signOut}>Sign out</button>
        </main>
      )}
    </Authenticator>
  );
}
```

- [ ] **Step 12: Install dependencies and verify it builds**

```bash
cd frontend
npm install
```

Write `.env` directly from the deployed dev environment's real Terraform outputs (do not hand-copy values between terminals - run this from the repo root):

```bash
{
  echo "VITE_API_URL=$(cd terraform/environments/dev && AWS_PROFILE=csvuploader terraform output -raw api_invoke_url)"
  echo "VITE_COGNITO_USER_POOL_ID=$(cd terraform/environments/dev && AWS_PROFILE=csvuploader terraform output -raw cognito_user_pool_id)"
  echo "VITE_COGNITO_CLIENT_ID=$(cd terraform/environments/dev && AWS_PROFILE=csvuploader terraform output -raw cognito_client_id)"
} > frontend/.env
```

Then:

```bash
cd frontend
npm run build
```

Expected: builds cleanly with no TypeScript errors, producing a `frontend/dist/` directory.

- [ ] **Step 13: Manually verify sign-up renders**

```bash
npm run dev
```

Open the printed local URL in a browser. Expected: the Amplify `<Authenticator>`'s sign-in/sign-up form renders (don't need to actually sign up yet - just confirm it renders without console errors). Stop the dev server (Ctrl+C) once confirmed.

- [ ] **Step 14: Commit**

`node_modules/` and `dist/` are git-ignored per Step 6; `.env` (containing your real pool/client IDs - not secret, but environment-specific) is also git-ignored and must NOT be committed. Only `.env.example` (with placeholder values) is tracked.

```bash
git add frontend/package.json frontend/tsconfig.json frontend/tsconfig.node.json frontend/vite.config.ts frontend/index.html frontend/.gitignore frontend/.env.example frontend/src/
git commit -m "Scaffold frontend: Vite + React + TypeScript + Amplify Auth"
```

---

### Task 7: Frontend API wrapper

**Files:**
- Create: `frontend/src/api.ts`

**Interfaces:**
- Consumes: `VITE_API_URL` (Task 6's env setup), Amplify's `fetchAuthSession()` (from the `aws-amplify` package Task 6 installed).
- Produces: `listUploads()`, `startUpload(filename)`, `getUploadStatus(uploadId)`, `getUploadRecords(uploadId)`, and the `UploadSummary`/`PresignedUpload` types - Task 8 (Dashboard/history) and Task 9 (upload flow) both import from this module.

- [ ] **Step 1: Create `src/api.ts`**

```typescript
import { fetchAuthSession } from "aws-amplify/auth";

const API_URL = import.meta.env.VITE_API_URL;

export interface UploadSummary {
  upload_id: string;
  status: "pending" | "processing" | "succeeded" | "partially_succeeded" | "failed";
  original_filename: string;
  created_at: string;
  updated_at: string;
  row_count: number;
  valid_row_count: number;
  invalid_row_count: number;
}

export interface PresignedUpload {
  upload_id: string;
  upload_url: string;
  upload_fields: Record<string, string>;
  expires_in: number;
}

async function authHeaders(): Promise<Record<string, string>> {
  const session = await fetchAuthSession();
  const idToken = session.tokens?.idToken?.toString();
  return { Authorization: `Bearer ${idToken}` };
}

async function apiFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const headers = { ...(await authHeaders()), ...init?.headers };
  const response = await fetch(`${API_URL}${path}`, { ...init, headers });
  if (!response.ok) {
    throw new Error(`Request to ${path} failed with status ${response.status}`);
  }
  return response.json() as Promise<T>;
}

export async function listUploads(): Promise<{ uploads: UploadSummary[] }> {
  return apiFetch<{ uploads: UploadSummary[] }>("/uploads");
}

export async function startUpload(filename: string): Promise<PresignedUpload> {
  return apiFetch<PresignedUpload>("/uploads", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ filename }),
  });
}

export async function getUploadStatus(uploadId: string): Promise<UploadSummary> {
  return apiFetch<UploadSummary>(`/uploads/${uploadId}`);
}

export async function uploadFileToS3(presigned: PresignedUpload, file: File): Promise<void> {
  const formData = new FormData();
  for (const [key, value] of Object.entries(presigned.upload_fields)) {
    formData.append(key, value);
  }
  formData.append("file", file);

  const response = await fetch(presigned.upload_url, { method: "POST", body: formData });
  if (!response.ok) {
    throw new Error(`S3 upload failed with status ${response.status}`);
  }
}
```

`getUploadRecords` was in the original design but nothing in this plan's scope (the dashboard's summary table, per the spec, shows status/row-counts/dates - not the individual parsed rows) actually calls it, so it's deliberately left out here rather than added as dead code. If a later change needs it, add it following the exact same `apiFetch<T>("/uploads/${uploadId}/records")` shape as the other three.

- [ ] **Step 2: Verify it compiles**

```bash
cd frontend
npm run build
```

Expected: builds cleanly (this file has no tests of its own in this iteration, per the spec's "no automated frontend test suite" decision - a clean TypeScript build is the check here).

- [ ] **Step 3: Commit**

```bash
git add frontend/src/api.ts
git commit -m "Add frontend API wrapper for uploads endpoints"
```

---

### Task 8: Dashboard page - summary stats and upload history table

**Files:**
- Create: `frontend/src/pages/Dashboard.tsx`
- Create: `frontend/src/components/SummaryStats.tsx`
- Create: `frontend/src/components/UploadList.tsx`
- Modify: `frontend/src/App.tsx`

**Interfaces:**
- Consumes: `listUploads()`, `UploadSummary` (Task 7).
- Produces: `Dashboard` component, rendered by `App.tsx`. Task 9 (upload flow) adds the file picker into this same `Dashboard.tsx` and calls a `refresh()` function this task defines.

- [ ] **Step 1: Create `src/components/SummaryStats.tsx`**

```typescript
import type { UploadSummary } from "../api";

const TERMINAL_SUCCESS = new Set(["succeeded", "partially_succeeded"]);

export function SummaryStats({ uploads }: { uploads: UploadSummary[] }) {
  const total = uploads.length;
  const terminal = uploads.filter(
    (u) => u.status !== "pending" && u.status !== "processing",
  );
  const successRate =
    terminal.length === 0
      ? null
      : Math.round(
          (terminal.filter((u) => TERMINAL_SUCCESS.has(u.status)).length / terminal.length) * 100,
        );
  const totalRows = uploads.reduce((sum, u) => sum + u.valid_row_count, 0);

  return (
    <div>
      <span>Total uploads: {total}</span>
      {" · "}
      <span>Success rate: {successRate === null ? "n/a" : `${successRate}%`}</span>
      {" · "}
      <span>Rows processed: {totalRows}</span>
    </div>
  );
}
```

- [ ] **Step 2: Create `src/components/UploadList.tsx`**

```typescript
import type { UploadSummary } from "../api";

export function UploadList({ uploads }: { uploads: UploadSummary[] }) {
  if (uploads.length === 0) {
    return <p>No uploads yet.</p>;
  }

  return (
    <table>
      <thead>
        <tr>
          <th>File</th>
          <th>Status</th>
          <th>Rows</th>
          <th>Uploaded</th>
        </tr>
      </thead>
      <tbody>
        {uploads.map((u) => (
          <tr key={u.upload_id}>
            <td>{u.original_filename}</td>
            <td>{u.status}</td>
            <td>{u.valid_row_count}</td>
            <td>{new Date(u.created_at).toLocaleString()}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
```

- [ ] **Step 3: Create `src/pages/Dashboard.tsx`**

```typescript
import { useCallback, useEffect, useState } from "react";
import { listUploads, type UploadSummary } from "../api";
import { SummaryStats } from "../components/SummaryStats";
import { UploadList } from "../components/UploadList";

export function Dashboard({ signOut }: { signOut?: () => void }) {
  const [uploads, setUploads] = useState<UploadSummary[]>([]);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const { uploads: fetched } = await listUploads();
      setUploads(fetched);
      setError(null);
    } catch {
      setError("Failed to load uploads.");
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return (
    <main>
      <button onClick={signOut}>Sign out</button>
      <h1>Your uploads</h1>
      {error && (
        <p>
          {error} <button onClick={refresh}>Retry</button>
        </p>
      )}
      <SummaryStats uploads={uploads} />
      <UploadList uploads={uploads} />
    </main>
  );
}
```

- [ ] **Step 4: Wire `Dashboard` into `App.tsx`**

Replace the placeholder body of `App.tsx` (from Task 6) with:

```typescript
import { Authenticator } from "@aws-amplify/ui-react";
import "@aws-amplify/ui-react/styles.css";
import { Dashboard } from "./pages/Dashboard";

export default function App() {
  return (
    <Authenticator>
      {({ signOut }) => <Dashboard signOut={signOut} />}
    </Authenticator>
  );
}
```

- [ ] **Step 5: Verify it builds and renders**

```bash
cd frontend
npm run build
npm run dev
```

Sign up a real test account (through the running dev server's UI, confirming via the code emailed to you, or via `aws cognito-idp admin-confirm-sign-up` the same way the backend was smoke-tested) and confirm: after signing in, "Your uploads", the summary line, and "No uploads yet." all render with no console errors. Stop the dev server once confirmed.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/pages/ frontend/src/components/ frontend/src/App.tsx
git commit -m "Add dashboard page with summary stats and upload history"
```

---

### Task 9: Upload flow - file picker, presigned POST, status polling

**Files:**
- Create: `frontend/src/components/UploadForm.tsx`
- Modify: `frontend/src/pages/Dashboard.tsx`

**Interfaces:**
- Consumes: `startUpload`, `uploadFileToS3`, `getUploadStatus` (Task 7), `Dashboard`'s `refresh()` (Task 8).
- Produces: nothing consumed by a later task - this is the last frontend feature task.

- [ ] **Step 1: Create `src/components/UploadForm.tsx`**

```typescript
import { useState } from "react";
import { getUploadStatus, startUpload, uploadFileToS3 } from "../api";

const TERMINAL_STATUSES = new Set(["succeeded", "partially_succeeded", "failed"]);
const POLL_INTERVAL_MS = 3000;

export function UploadForm({ onUploadComplete }: { onUploadComplete: () => void }) {
  const [file, setFile] = useState<File | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!file) return;

    setError(null);
    setStatus("starting upload...");
    try {
      const presigned = await startUpload(file.name);
      setStatus("uploading to S3...");
      await uploadFileToS3(presigned, file);
      setStatus("processing...");
      await pollUntilTerminal(presigned.upload_id);
      setStatus(null);
      setFile(null);
      onUploadComplete();
    } catch {
      setError("Upload failed. Please try again.");
      setStatus(null);
    }
  }

  async function pollUntilTerminal(uploadId: string): Promise<void> {
    const result = await getUploadStatus(uploadId);
    if (TERMINAL_STATUSES.has(result.status)) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
    return pollUntilTerminal(uploadId);
  }

  return (
    <form onSubmit={handleSubmit}>
      <input
        type="file"
        accept=".csv,text/csv"
        onChange={(e) => setFile(e.target.files?.[0] ?? null)}
      />
      <button type="submit" disabled={!file || status !== null}>
        Upload
      </button>
      {status && <p>{status}</p>}
      {error && <p>{error}</p>}
    </form>
  );
}
```

- [ ] **Step 2: Wire `UploadForm` into `Dashboard.tsx`**

In `frontend/src/pages/Dashboard.tsx`, add the import and render it between the error message and `<SummaryStats>`:

```typescript
import { UploadForm } from "../components/UploadForm";
```

```typescript
      <UploadForm onUploadComplete={refresh} />
      <SummaryStats uploads={uploads} />
```

- [ ] **Step 3: Verify end-to-end in the browser**

```bash
cd frontend
npm run dev
```

Signed in as your test account: pick a small CSV (e.g. the repo's own `tests/fixtures/valid.csv`), click Upload, and confirm the status text progresses (`starting upload...` -> `uploading to S3...` -> `processing...`) and then the new upload appears in the table with the right row counts, without a page reload. Stop the dev server once confirmed.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/components/UploadForm.tsx frontend/src/pages/Dashboard.tsx
git commit -m "Add upload flow to the dashboard"
```

---

### Task 10: Terraform - frontend hosting module (S3 + CloudFront)

**Files:**
- Create: `terraform/modules/frontend_hosting/main.tf`
- Create: `terraform/modules/frontend_hosting/variables.tf`
- Create: `terraform/modules/frontend_hosting/outputs.tf`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `module.frontend_hosting.bucket_name`, `module.frontend_hosting.cloudfront_domain_name`, `module.frontend_hosting.cloudfront_distribution_id` - Task 11 wires these into `dev`'s environment and Task 12's CI workflow uses the distribution id for cache invalidation.

- [ ] **Step 1: Create `variables.tf`**

```hcl
variable "bucket_name" {
  description = "Name of the S3 bucket serving the built frontend assets."
  type        = string
}
```

- [ ] **Step 2: Create `main.tf`**

```hcl
resource "aws_s3_bucket" "frontend" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.bucket_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "frontend-s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "frontend-s3-origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  # Client-side routing (react-router): a direct browser request to e.g. /dashboard doesn't
  # exist as an S3 object, so S3 returns 403 (BucketOwnerEnforced buckets don't expose a
  # distinct 404 to unauthenticated requests) - rewrite both to index.html with a 200 so the
  # app's own router handles the path instead of the browser showing a raw S3 error.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_iam_policy_document" "frontend_cloudfront_read" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.frontend.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_cloudfront_read.json
}
```

- [ ] **Step 3: Create `outputs.tf`**

```hcl
output "bucket_name" {
  value = aws_s3_bucket.frontend.id
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.frontend.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.frontend.id
}
```

- [ ] **Step 4: Format and validate standalone**

```bash
terraform fmt -recursive terraform/modules/frontend_hosting
cd terraform/modules/frontend_hosting && terraform init -backend=false && terraform validate && cd -
```

- [ ] **Step 5: Commit**

```bash
git add terraform/modules/frontend_hosting/
git commit -m "Add frontend_hosting Terraform module (S3 + CloudFront)"
```

---

### Task 11: Wire `frontend_hosting` into dev

**Files:**
- Modify: `terraform/environments/dev/main.tf`
- Modify: `terraform/environments/dev/outputs.tf`

**Interfaces:**
- Consumes: `module.frontend_hosting` (Task 10).
- Produces: `frontend_url`, `frontend_bucket_name`, `frontend_cloudfront_distribution_id` outputs on `terraform/environments/dev` - Task 12's deploy workflow reads the latter two directly via `terraform output -raw` to sync the build and invalidate the cache.

- [ ] **Step 1: Instantiate the module**

In `terraform/environments/dev/main.tf`, add this block right after the `module "monitoring"` block (before the `# --- CI/CD ---` comment):

```hcl
# --- Frontend hosting (dev only) ---

module "frontend_hosting" {
  source = "../../modules/frontend_hosting"

  bucket_name = "${local.name_prefix}-frontend-${data.aws_caller_identity.current.account_id}"
}
```

- [ ] **Step 2: Add the output**

In `terraform/environments/dev/outputs.tf`, add:

```hcl
output "frontend_url" {
  description = "CloudFront URL serving the dashboard frontend."
  value       = "https://${module.frontend_hosting.cloudfront_domain_name}"
}

output "frontend_bucket_name" {
  description = "S3 bucket the frontend's built assets are synced to."
  value       = module.frontend_hosting.bucket_name
}

output "frontend_cloudfront_distribution_id" {
  description = "CloudFront distribution id, needed to invalidate its cache after a deploy."
  value       = module.frontend_hosting.cloudfront_distribution_id
}
```

- [ ] **Step 3: Grant the CI deploy role permission to manage this new S3 bucket and invalidate CloudFront**

In `terraform/environments/dev/main.tf`, the `"ManageDevResources"` statement's `resources` list already includes `"arn:aws:s3:::csvuploader-dev*"` and `"arn:aws:s3:::csvuploader-dev*/*"` (wildcard-prefixed, so the new frontend bucket - named `csvuploader-dev-frontend-<account-id>` - is already covered) and its `actions` list already includes `"s3:*"` - no S3 change needed.

CloudFront is a new service this policy has never needed before. Add a new statement, right after the existing `"ManageCognito"` statement:

```hcl
  statement {
    sid    = "ManageCloudFront"
    effect = "Allow"
    actions = [
      "cloudfront:CreateDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:UpdateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:TagResource",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
    ]
    resources = ["*"]
  }
```

(CloudFront distribution/OAC ARNs aren't predictable ahead of creation the same way our other resource names are - `resources = ["*"]` here follows the exact same "scope what we can, accept broader scope where AWS doesn't support narrower" pattern already used by `"ManageCognito"` and `"ManageApiGateway"` above it.)

- [ ] **Step 4: Format and validate**

```bash
terraform fmt -recursive terraform/environments/dev
cd terraform/environments/dev && terraform init -backend=false -input=false && terraform validate && cd -
```

- [ ] **Step 5: Commit**

```bash
git add terraform/environments/dev/main.tf terraform/environments/dev/outputs.tf
git commit -m "Wire frontend_hosting into dev"
```

---

### Task 12: GitHub Actions - frontend deploy workflow (dev only)

**Files:**
- Create: `.github/workflows/deploy-frontend-dev.yml`

**Interfaces:**
- Consumes: the existing GitHub OIDC deploy role (`vars.AWS_GITHUB_ACTIONS_ROLE_ARN`, unchanged), `frontend_bucket_name`/`frontend_cloudfront_distribution_id` outputs (Task 11), Task 6's `frontend/package.json` build script.
- Produces: nothing consumed by a later task - this is the last infra/CI task.

- [ ] **Step 1: Create the workflow**

```yaml
name: Deploy Frontend Dev

on:
  push:
    branches: [main]
    paths:
      - "frontend/**"
      - ".github/workflows/deploy-frontend-dev.yml"
  workflow_dispatch: {}

permissions:
  id-token: write # required to request the OIDC token AWS exchanges for credentials
  contents: read

concurrency:
  group: deploy-frontend-dev
  cancel-in-progress: false # queue, don't cancel - never abandon a run mid-deploy

jobs:
  deploy:
    name: Build and deploy frontend to dev
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: "22"

      - name: Install dependencies
        working-directory: frontend
        run: npm ci

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ vars.AWS_GITHUB_ACTIONS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: "1.15.8"

      - name: Read dev environment outputs
        id: tf_outputs
        working-directory: terraform/environments/dev
        run: |
          terraform init -input=false
          echo "api_url=$(terraform output -raw api_invoke_url)" >> "$GITHUB_OUTPUT"
          echo "pool_id=$(terraform output -raw cognito_user_pool_id)" >> "$GITHUB_OUTPUT"
          echo "client_id=$(terraform output -raw cognito_client_id)" >> "$GITHUB_OUTPUT"
          echo "bucket=$(terraform output -raw frontend_bucket_name)" >> "$GITHUB_OUTPUT"
          echo "distribution_id=$(terraform output -raw frontend_cloudfront_distribution_id)" >> "$GITHUB_OUTPUT"

      - name: Build
        working-directory: frontend
        env:
          VITE_API_URL: ${{ steps.tf_outputs.outputs.api_url }}
          VITE_COGNITO_USER_POOL_ID: ${{ steps.tf_outputs.outputs.pool_id }}
          VITE_COGNITO_CLIENT_ID: ${{ steps.tf_outputs.outputs.client_id }}
        run: npm run build

      - name: Upload to S3
        run: aws s3 sync frontend/dist "s3://${{ steps.tf_outputs.outputs.bucket }}" --delete

      - name: Invalidate CloudFront cache
        run: |
          aws cloudfront create-invalidation \
            --distribution-id "${{ steps.tf_outputs.outputs.distribution_id }}" \
            --paths "/*"
```

- [ ] **Step 2: Validate the YAML parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy-frontend-dev.yml'))"
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy-frontend-dev.yml
git commit -m "Add CI workflow to deploy the frontend to dev"
```

---

### Task 13: Documentation - README and ADR

**Files:**
- Modify: `README.md`
- Create: `docs/adr/0007-frontend-hosting.md`

**Interfaces:**
- Consumes: nothing - documentation only, last task in the plan.

- [ ] **Step 1: Add a frontend section to `README.md`**

Add this new `## Frontend` section right after the existing `## Local development` section and before `## Infrastructure`:

```markdown
## Frontend

A React dashboard (`frontend/`) lets a customer sign up, confirm their email, log in, upload a
CSV, and see their own upload history with summary stats - the same Cognito pool and API used
above, with no separate identity system.

Local development:

```bash
cd frontend
npm install
cp .env.example .env
# fill in .env with the real values from `terraform output` in terraform/environments/dev
# (api_invoke_url, cognito_user_pool_id, cognito_client_id)
npm run dev
```

Deployed automatically to dev on merge to `main` (when files under `frontend/` change), via
GitHub Actions - see `.github/workflows/deploy-frontend-dev.yml`. Hosted on S3 + CloudFront,
managed by Terraform (`terraform/modules/frontend_hosting`), dev only for now - see
[ADR 0007](docs/adr/0007-frontend-hosting.md) for why, and for the hosting/auth-library choice.
```

- [ ] **Step 2: Add ADR 0007**

Create `docs/adr/0007-frontend-hosting.md`:

```markdown
# 7. React frontend: Amplify's auth library on S3 + CloudFront, not Amplify Hosting

## Status

Accepted

## Context

The API works well via `curl`/the AWS CLI, but that's real friction for an actual customer -
signing up, confirming an email code, and logging in by hand is not a realistic user experience.
A React frontend adds sign-up/login and a dashboard showing upload history with summary stats.

Building that dashboard exposed a real backend gap along the way: the API could only look up a
single upload by exact id, with no way to list "this customer's uploads" - see the
[design spec](../specs/2026-08-20-customer-dashboard-design.md) for the new `GET /uploads`
endpoint and DynamoDB GSI that closes that gap.

Two decisions specific to the frontend itself needed making: what handles the sign-up/login UI,
and what hosts the built app.

## Decision

**Auth UI**: `@aws-amplify/ui-react`'s `<Authenticator>` component, wired directly to the existing
Cognito User Pool - no Hosted UI, no separate identity system. It handles sign-up, email-code
confirmation, and sign-in with no custom form code, which meaningfully cut the highest-effort part
of this feature down to configuration.

**Hosting**: S3 + CloudFront, managed by Terraform (`terraform/modules/frontend_hosting`) and
deployed via GitHub Actions - not AWS Amplify Hosting. Amplify Hosting bundles its own opinionated
CI/CD, which would mean running two different infra-as-code systems side by side (Terraform for
the backend, Amplify's own config for the frontend). Using only Amplify's *auth library* - not its
hosting service - keeps the "everything is Terraform, dev auto-deploys via GitHub Actions" story
consistent across the whole project.

**Environment scope**: dev only, for this iteration. Prod frontend hosting is an explicit,
deliberate follow-up once the frontend itself is proven out - unlike the backend `GET /uploads`
change, which applies to both environments since it's a real API capability.

## Consequences

- Two infra-as-code systems were explicitly avoided in favor of one (Terraform) - at the cost of
  writing the S3 + CloudFront + Origin Access Control wiring by hand instead of getting it for
  free from a managed hosting product.
- The frontend has no automated test suite this iteration (see the design spec's Testing
  section) - manual verification against the live dev deployment is the acceptance check, the
  same approach already used to validate the Cognito migration itself.
- Prod has no frontend yet. Anyone using the API against prod today still does so via `curl`/the
  AWS CLI, same as before this change.
```

- [ ] **Step 3: Add the new ADR to the README's list**

In `README.md`'s `## Design decisions` list, add a new line 7:

```markdown
7. [Frontend: Amplify auth + S3/CloudFront hosting](docs/adr/0007-frontend-hosting.md)
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/adr/0007-frontend-hosting.md
git commit -m "Document the frontend in README and ADR 0007"
```
