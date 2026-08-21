# csvUploader

A cloud-based analytics service for ingesting, validating, storing, and retrieving drug discovery
data (drug name, target, efficacy) submitted as CSV files. Built on AWS Lambda, API Gateway, S3,
and DynamoDB, with all infrastructure defined in Terraform.

## Architecture

```
Client
  │ 1. POST /uploads  (Bearer token)
  ▼
API Gateway ──► upload_handler Lambda ──► creates "pending" record in DynamoDB(uploads)
  │                                        returns presigned S3 POST (url + fields, 5 min expiry,
  │                                        content-length-range 0-10MB, content-type=text/csv)
  ▼
Client uploads CSV directly to S3 (raw bucket, key: raw/{upload_id}.csv)
  │
  ▼
S3 ObjectCreated event ──► process_handler Lambda
                              - downloads & validates CSV (structural + per-row)
                              - writes valid rows to DynamoDB(records)
                              - updates DynamoDB(uploads) status + error list
                              - on repeated failure → SQS dead-letter queue

Client
  │ 2. GET /uploads/{id}          (Bearer token) → status_handler Lambda
  │ 3. GET /uploads/{id}/records  (Bearer token) → records_handler Lambda (paginated)
  │ 4. GET /uploads               (Bearer token) → list_handler Lambda (paginated)
  ▼
API Gateway
```

The upload never touches Lambda directly - the client uploads straight to S3 via a presigned
POST, which is what lets this scale past API Gateway's payload limits. That also means
processing is asynchronous: `POST /uploads` returns immediately with an `upload_id`, and the
client polls `GET /uploads/{upload_id}` for the outcome. See [`docs/adr`](docs/adr) for why each
piece of this is shaped the way it is - upload mechanism, database choice, auth strategy,
environment/CI strategy, and validation policy each have their own ADR.

## API

All endpoints require an `Authorization: Bearer <token>` header. Customers sign themselves up -
there's no operator-provisioned secret. Get the pool/client ids for your deployed environment:

```bash
cd terraform/environments/dev
CLIENT_ID=$(AWS_PROFILE=csvuploader terraform output -raw cognito_client_id)
API_URL=$(AWS_PROFILE=csvuploader terraform output -raw api_invoke_url)
REGION=us-east-1
```

**Sign up, confirm, and log in** (requires `jq` and the AWS CLI, called unauthenticated - these
specific Cognito operations don't need AWS credentials):

```bash
aws cognito-idp sign-up --region "$REGION" --client-id "$CLIENT_ID" \
  --username customer@example.com --password 'SomeStrongPassw0rd' \
  --user-attributes Name=email,Value=customer@example.com

# Check the inbox for customer@example.com for the verification code, then:
aws cognito-idp confirm-sign-up --region "$REGION" --client-id "$CLIENT_ID" \
  --username customer@example.com --confirmation-code 123456

AUTH=$(aws cognito-idp initiate-auth --region "$REGION" --client-id "$CLIENT_ID" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=customer@example.com,PASSWORD='SomeStrongPassw0rd')
API_TOKEN=$(echo "$AUTH" | jq -r .AuthenticationResult.IdToken)
```

Use the **ID token**, not the access token - API Gateway's `COGNITO_USER_POOLS` authorizer
validates the token's `aud` claim, which access tokens don't carry (they carry `client_id`
instead), so an access token is rejected outright regardless of its expiry.

`$API_TOKEN` is short-lived (~1 hour); re-run `initiate-auth` (or use the returned
`RefreshToken`) to get a new one.

Full contract: [`docs/openapi.yaml`](docs/openapi.yaml).

**Start an upload** (requires `jq`):

```bash
RESPONSE=$(curl -s -X POST "$API_URL/uploads" \
  -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
  -d '{"filename": "drugs.csv"}')
UPLOAD_ID=$(echo "$RESPONSE" | jq -r .upload_id)
echo "$RESPONSE"
# {"upload_id": "...", "upload_url": "...", "upload_fields": {...}, "expires_in": 300}
```

**Upload the file** to the returned presigned POST - the `file` field must come last:

```bash
curl -s -X POST "$(echo "$RESPONSE" | jq -r .upload_url)" \
  $(echo "$RESPONSE" | jq -r '.upload_fields | to_entries[] | "-F \(.key)=\(.value)"') \
  -F "file=@drugs.csv;type=text/csv"
```

**Check status** (poll until `status` is no longer `pending`/`processing`):

```bash
curl -s "$API_URL/uploads/$UPLOAD_ID" -H "Authorization: Bearer $API_TOKEN"
# {"upload_id": "...", "status": "succeeded", "row_count": 3, "valid_row_count": 3,
#  "invalid_row_count": 0, "errors": [], ...}
```

**Retrieve parsed records:**

```bash
curl -s "$API_URL/uploads/$UPLOAD_ID/records" -H "Authorization: Bearer $API_TOKEN"
# {"upload_id": "...", "status": "succeeded",
#  "records": [{"row_number": 1, "drug_name": "Aspirin", "target": "COX-1", "efficacy": 72.5}, ...]}
```

**List your uploads** (newest first, paginated):

```bash
curl -s "$API_URL/uploads" -H "Authorization: Bearer $API_TOKEN"
# {"uploads": [{"upload_id": "...", "status": "succeeded", "original_filename": "drugs.csv",
#  "row_count": 3, "valid_row_count": 3, "invalid_row_count": 0, ...}, ...],
#  "next_token": "..."}
```

### CSV format

Header row must contain exactly `drug_name`, `target`, `efficacy` (case/whitespace-insensitive).
`drug_name` and `target` are required, non-empty, ≤255 characters. `efficacy` is required and
must be numeric, 0-100. Rows failing these checks are skipped and reported individually rather
than failing the whole upload - see
[`docs/adr/0005-validation-policy.md`](docs/adr/0005-validation-policy.md).

## Local development

```bash
uv sync                # install dependencies
uv run pytest          # run the test suite (52 tests, moto-mocked AWS)
uv run ruff check .    # lint
```

Handlers live under `src/<name>_handler/`, sharing common code from `src/shared/` (validation,
models, DynamoDB/S3 clients, logging). Tests live under `tests/unit/`, with fixture CSVs in
`tests/fixtures/`.

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
Find the deployed URL with `terraform output -raw frontend_url` in `terraform/environments/dev`.

## Infrastructure

Infrastructure is managed with Terraform under `terraform/`:

- `terraform/bootstrap` - one-time setup of the remote state backend (S3 bucket, using S3's native
  lock-file support for state locking) and the account-wide API Gateway CloudWatch logging role.
  Applied manually, once, before anything else.
- `terraform/modules` - reusable modules (S3, DynamoDB, Lambda, API Gateway, IAM, monitoring,
  GitHub OIDC).
- `terraform/environments/{dev,prod}` - per-environment root configurations, each with its own
  Terraform state.

Before any `terraform plan`/`apply`, stage the Lambda deployment artifacts:

```bash
./scripts/build_lambda_packages.sh
```

Dev deploys automatically on merge to `main` via GitHub Actions (OIDC, no long-lived AWS
credentials). Prod is always applied by hand. See [`docs/deploying.md`](docs/deploying.md) for
the full CI/CD setup and the manual prod deploy steps.

## Design decisions

Architecture Decision Records live in [`docs/adr`](docs/adr):

1. [Upload via S3 presigned POST](docs/adr/0001-upload-mechanism.md)
2. [DynamoDB for storage](docs/adr/0002-database-choice.md)
3. [API keys over Cognito/IAM (superseded)](docs/adr/0003-auth-choice.md)
4. [Separate state per environment, trunk-based CI/CD](docs/adr/0004-environment-strategy.md)
5. [Partial ingest with per-row errors](docs/adr/0005-validation-policy.md)
6. [Cognito authentication](docs/adr/0006-cognito-auth.md)
7. [Frontend: Amplify auth + S3/CloudFront hosting](docs/adr/0007-frontend-hosting.md)
