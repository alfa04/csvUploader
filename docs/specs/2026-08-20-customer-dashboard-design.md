# Customer dashboard: React frontend + upload history

## Context

The API is fully functional and Cognito-authenticated, but the only way to use it today is
`curl`/the AWS CLI - as the last hour of manual smoke-testing demonstrated, that's real friction
even for the person who built it. The user wants a proper front door: a React app where a
customer can sign up, confirm their email, log in, upload a CSV, and see their own upload history
with some summary stats.

That last part - upload history - exposed a real gap: the API can only look up a single upload by
its exact `upload_id` (`GET /uploads/{id}`). There is no way to ask "show me all of this
customer's uploads," and the `uploads` table's DynamoDB key (`upload_id` only) can't answer that
query efficiently. A dashboard showing "your past uploads" needs this new backend capability
first - it isn't just a frontend project.

Decisions made during brainstorming (see chat), driving scope:

- Dashboard content: a simple table of past uploads (filename, status, row counts, date) plus
  client-side-computed summary counts (total uploads, success rate, total rows). No charting
  library - the data per customer is too small for charts to add real insight yet.
- Environment scope: **dev only** for this iteration. Prod frontend hosting is an explicit
  follow-up, not part of this change.
- The frontend includes the **upload flow itself** (file picker -> presigned POST -> poll status),
  not just a read-only history view - otherwise the dashboard would only ever show data uploaded
  out-of-band via the API directly, which isn't a real end-to-end experience.
- Time-boxed: rough budget discussed was 4-6 hours including the new backend endpoint.

## Decision

Add one new backend capability (`GET /uploads`, backed by a new DynamoDB GSI) and one new
subsystem: a React frontend, using AWS Amplify's *auth library* (not Amplify Hosting) for the
sign-up/confirm/sign-in UI against the existing Cognito pool, hosted on S3 + CloudFront and
deployed via Terraform + GitHub Actions - the same infra-as-code story as the rest of this
project, rather than introducing a second, Amplify-managed deployment paradigm alongside it.

## Backend: `GET /uploads`

- New GSI on the `uploads` DynamoDB table: partition key `uploaded_by`, sort key `created_at`.
  Lets us query "this customer's uploads, newest first" directly instead of scanning the table.
- New Lambda `list_handler` (own responsibility, not folded into `upload_handler` - that
  handler's job is "create a pending upload," a list-query is a different concern, matching this
  project's existing one-handler-per-responsibility pattern).
- New API Gateway method: `GET /uploads` (sibling to the existing `POST /uploads` on the same
  resource), same `COGNITO_USER_POOLS` authorizer as the other 3 methods.
- Response shape reuses the existing per-upload fields (`upload_id`, `status`,
  `original_filename`, `row_count`, `valid_row_count`, `invalid_row_count`, `created_at`,
  `updated_at`) - no new schema, just a list of the thing the API already returns one of via
  `GET /uploads/{id}`. Paginated with the same opaque `next_token` convention already used by
  `GET /uploads/{id}/records`.
- `list_handler`'s IAM role needs `dynamodb:Query` scoped to the new GSI's ARN (index ARNs are a
  distinct resource from the table's own ARN and need their own statement/resource entry).

## Frontend structure

New `frontend/` directory at the repo root - Vite + React + TypeScript.

- `src/aws-config.ts` - Amplify config (Cognito pool id, client id, region). These are meant to
  be public (there's no client secret on the app client), so baking them into the built JS bundle
  is fine - no secret material involved.
- `src/App.tsx` - routing; the `<Authenticator>` component (from `@aws-amplify/ui-react`) wraps
  the app, handling sign-up, email-code confirmation, and sign-in entirely on its own.
- `src/pages/Dashboard.tsx` - the one real page: summary counts, the upload table, and the file
  picker/upload control.
- `src/api.ts` - thin fetch wrapper for the 4 endpoints (`POST /uploads`, `GET /uploads`,
  `GET /uploads/{id}`, `GET /uploads/{id}/records`), pulling a fresh ID token from Amplify's
  current session (`fetchAuthSession()`) before each call. Must use the ID token specifically,
  not the access token - the same requirement discovered during dev's manual smoke test (API
  Gateway's `COGNITO_USER_POOLS` authorizer validates the `aud` claim, which only ID tokens
  carry).

## Data flow

1. **Auth**: `<Authenticator>` handles the whole sign-up -> confirm -> sign-in sequence with no
   custom code. Amplify manages token storage and refresh internally once signed in.
2. **Upload**: file picked -> `POST /uploads` -> browser does the multipart form POST directly to
   S3 (identical shape to the manual smoke test) -> poll `GET /uploads/{id}` until a terminal
   status -> refetch the list.
3. **Dashboard load**: on mount (and after any upload reaches a terminal status), call the new
   `GET /uploads` -> render the table plus summary counts computed client-side from that same
   response (no backend aggregation endpoint needed for simple counts/rates).

## Infra & deployment

- New Terraform module `terraform/modules/frontend_hosting`: a private S3 bucket (public access
  blocked, matching the `raw_uploads` bucket's pattern) plus a CloudFront distribution using
  Origin Access Control to read from it. Includes a custom error response mapping 403/404 to
  `/index.html` with a 200 status - required so that a browser refresh on `/dashboard` (a
  client-side route that doesn't exist as an S3 object) doesn't 404.
- Instantiated in `terraform/environments/dev/main.tf` only, per the dev-only decision. New
  outputs: the CloudFront distribution's domain name (the frontend's URL).
- New GitHub Actions workflow, path-filtered to trigger only when files under `frontend/` change
  on push to `main`: installs dependencies, builds the Vite app with the API URL / Cognito
  client id / pool id injected as build-time env vars, uploads `dist/` to the new S3 bucket, and
  invalidates the CloudFront distribution's cache. Reuses/extends the existing GitHub OIDC
  deploy role rather than creating a second one.

## Testing

- Backend: `list_handler` gets the same TDD treatment as the existing handlers - unit tests with
  moto mocking the GSI query, following the patterns already in `tests/unit/`.
- Frontend: **no automated test suite in this iteration.** Given the time-boxing and that the
  higher-risk logic lives in the backend (already well-tested), the acceptance check is manually
  verifying the live dev deployment end-to-end (sign up, confirm, upload, see it appear in the
  list) - the same approach already used to validate the Cognito migration itself. Automated
  frontend tests (Vitest/React Testing Library) are a reasonable later addition, not part of this
  change.
- Error handling: `<Authenticator>` covers Cognito-specific error states (wrong password,
  unconfirmed account, code mismatch, etc.) out of the box. API call failures (list/upload/status)
  get a simple inline "failed to load - retry" state; nothing more elaborate given scope.

## Documentation

- `README.md`: new section covering the frontend - how to run it locally and how it's deployed.
- `docs/openapi.yaml`: add the new `GET /uploads` path (list, paginated), matching the existing
  spec's style and security scheme.
- New ADR documenting the hosting/tooling decision (S3+CloudFront+Terraform over Amplify Hosting;
  Amplify's auth library over hand-rolled Cognito calls) - this is a genuine architectural choice
  in the same vein as the earlier auth-mechanism and upload-mechanism ADRs.

## Out of scope for this change

- **Prod frontend hosting.** Dev only; deploying to prod is a deliberate follow-up once the
  frontend itself is proven out.
- **Automated frontend tests.** Manual verification against the live dev deployment only.
- **Charts/visualizations.** Summary counts and a table only - no charting library.
- **"Load more" / infinite scroll on the upload list.** A single page (a reasonable default limit,
  e.g. 50 most recent) is fetched and shown; deeper pagination UI can follow later if a customer
  ever actually has more than that many uploads.
- **Custom email templates or SES.** Still Cognito's built-in email sending for verification
  codes, unchanged from the original auth migration.
- **Any change to per-upload retrieval scope or isolation logic.** The new endpoint is additive
  (a list view scoped to the caller's own `sub`, same ownership model as the existing endpoints);
  nothing about existing 404-on-mismatch behavior changes.
