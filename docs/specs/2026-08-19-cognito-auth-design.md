# Cognito authentication (replacing API keys)

## Context

The API currently authenticates callers via an API Gateway API key + usage plan (see
[ADR 0003](../adr/0003-auth-choice.md)). That decision was deliberate at the time - nothing in
the original spec described real user accounts, so building an identity system felt like solving
a problem that wasn't there.

Two things changed that calculus:

1. While demonstrating how to retrieve the key, it leaked into a chat transcript and had to be
   rotated - a direct illustration of how a permanent shared secret is easy to mishandle.
2. A direct question - "if I'm a customer, how do I get an API key?" - exposed that there is no
   self-service path at all. Only the AWS account operator, with Terraform/AWS access, can
   provision a key today.

The user's explicit priority for the redesign: **security and ease of use above everything else**.
That, plus the self-service and audit-trail gaps, is enough to justify revisiting ADR 0003.

## Decision

Replace API keys with a **Cognito User Pool**, authenticated via API Gateway's native
`COGNITO_USER_POOLS` authorizer. No Hosted UI - this is a pure API, so customers call Cognito's
public `SignUp` / `ConfirmSignUp` / `InitiateAuth` operations directly (plain HTTPS, no AWS
credentials required for these specific operations) and use the resulting access token as
`Authorization: Bearer <token>` against the CSV API.

Per-customer data isolation is enforced: every upload is stamped with the caller's Cognito `sub`,
and `status_handler`/`records_handler` return **404** (not 403) if the caller doesn't own the
upload they're asking about - a customer can't distinguish "not yours" from "doesn't exist."

ADR 0003 is marked **Superseded by 0006** (kept as-is otherwise - it's a historical record of a
decision that was correct given what was known then). A new ADR 0006 documents this decision and
why the calculus changed.

## Cognito configuration

- **User Pool**: self-service sign-up enabled (`admin_create_user_config.allow_admin_create_user_only = false`),
  auto-verified email attribute, Cognito's built-in email sending for verification codes (fine at
  this scale; would need SES for real production volume - note this in the ADR).
- **Password policy**: minimum 8 characters, require uppercase, lowercase, and a number (Cognito
  defaults are close to this; set explicitly for documentation clarity).
- **MFA**: `mfa_configuration = "OFF"`. "Optional" isn't meaningfully different from "off" without
  an enrollment flow, which isn't being built. Revisit if MFA enrollment ever becomes a real
  requirement.
- **App Client**: `generate_secret = false` (a client-side secret would just reintroduce the
  "manage a permanent secret" problem for the customer). `explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]`.
- New module: `terraform/modules/cognito`, instantiated once per environment (dev, prod - each
  gets its own separate user pool, consistent with the rest of the per-environment isolation).

## API Gateway changes

- Add `aws_api_gateway_authorizer` (`type = "COGNITO_USER_POOLS"`, referencing the User Pool ARN).
- Each of the 3 existing methods: `authorization = "COGNITO_USER_POOLS"` with `authorizer_id` set,
  `api_key_required` removed entirely.
- Remove `aws_api_gateway_api_key`, `aws_api_gateway_usage_plan`, `aws_api_gateway_usage_plan_key`
  and the `api_key_value` output.
- **Trade-off, explicitly accepted**: usage-plan quota/throttling is tied to API keys and can't
  attribute to a Cognito identity. Per-customer rate limiting goes away. Replaced with a single
  blanket stage-level throttle (`aws_api_gateway_method_settings.throttling_rate_limit`/
  `throttling_burst_limit`, already present) protecting the whole API regardless of caller. No
  custom per-user throttling in Lambda - that would be real complexity for a "nice to have" this
  project doesn't need yet.

## Data model & handler changes

- `UploadMetadata` (shared/models.py): add `uploaded_by: str` field, included in
  `to_response_dict()` (it's the caller's own identity being reflected back - not a leak).
- `repository.create_upload(...)`: gains an `uploaded_by` parameter, stored on creation and never
  overwritten by `process_handler`'s later updates.
- `upload_handler`: extract the caller's `sub` from
  `event["requestContext"]["authorizer"]["claims"]["sub"]` (how the COGNITO_USER_POOLS authorizer
  surfaces identity to the Lambda on a REST API), pass it into `create_upload`.
- `status_handler` / `records_handler`: extract the caller's `sub` the same way; if it doesn't
  match the upload's `uploaded_by`, return 404 (reusing the existing "not found" response, not a
  new error shape) rather than continuing to look up/return data.
- `process_handler`: no changes - it doesn't sit behind API Gateway and never touches auth.

## Terraform environment wiring

- `environments/{dev,prod}/main.tf`: instantiate `module.cognito`, pass its user pool ARN into
  `module.api_gateway`.
- Keep `throttle_rate_limit`/`throttle_burst_limit` variables (still used for stage-level
  throttling) but remove `quota_limit`/`quota_period` (usage-plan-only concepts, no longer
  applicable).
- CI deploy role's permissions policy (`github_actions_deploy_permissions` in
  `environments/dev/main.tf`) needs a new statement for `cognito-idp:*` scoped to
  `arn:aws:cognito-idp:*:*:userpool/*` narrowed to this app's pools (Cognito user pool IDs aren't
  predictable ahead of creation the way our other resource names are, so this may need the same
  "scope what we can, accept broader scope where AWS doesn't support narrower" treatment other
  statements in that policy already use - expect this to need the same kind of iteration the
  original CI permissions did).
- New outputs: `cognito_user_pool_id`, `cognito_client_id` (customers/testers need these to call
  Cognito's public auth APIs). Remove `api_key_value`.

## Testing

- Handler tests: replace the bare API-Gateway-event fixtures with ones carrying
  `requestContext.authorizer.claims.sub`, matching what the real Cognito authorizer would inject.
- New tests: `status_handler`/`records_handler` return 404 when the caller's `sub` doesn't match
  the upload's `uploaded_by`; `upload_handler` correctly stamps `uploaded_by` from the caller's
  claims.
- moto's Cognito support can mock the User Pool for any future integration-style tests if needed,
  though the existing unit tests don't need to actually call Cognito - they construct the event
  shape directly, the same way current tests construct `pathParameters` directly rather than
  going through real API Gateway.

## Documentation

- README's API section: replace "get a key from Terraform" with sign-up → confirm → login → use
  token, including runnable `curl` examples against Cognito's public endpoints.
- `docs/openapi.yaml`: security scheme changes from `apiKey` (`x-api-key` header) to
  `http`/`bearer` (`Authorization: Bearer <token>`). Add a 401 response (missing/invalid token) to
  each endpoint; keep 404 as the response for both "doesn't exist" and "exists but isn't yours."
- `docs/adr/0003-auth-choice.md`: status line changes to `Superseded by 0006`.
- `docs/adr/0006-cognito-auth.md` (new): the decision as described above, cross-linking back to
  0003.

## Out of scope for this change

- No Hosted UI, no social login providers, no custom email templates/SES setup.
- No admin/support tooling for manually managing customer accounts (e.g. an admin API to disable
  a user) - Cognito's own console covers that manually for now.
- No change to the "per-upload only" retrieval scope decided earlier in the project - isolation is
  by ownership check, not by adding cross-upload query capability.
