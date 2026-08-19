# 3. API Gateway API keys + usage plan, not Cognito or IAM auth

## Status

Accepted

## Context

The API needs to be protected. Three standard options exist for a Lambda + API Gateway service:

1. **Cognito User Pool + JWT authorizer** - real user identity per request, native API Gateway
   integration, the option most associated with "secure serverless API" in the abstract.
2. **IAM auth (SigV4)** - callers sign requests with AWS credentials; no separate identity store.
3. **API Gateway API keys + usage plan** - a shared secret per client plus built-in
   throttling/quota, enforced by API Gateway itself.

### Cognito

**Pros:** real per-request identity (useful for an `uploaded_by` field or audit trail); almost no
custom authorizer code; supports a full auth lifecycle if this ever becomes user-facing.
**Cons:** most moving parts of the three (User Pool, App Client, token handling); every curl/demo
needs a login step first to obtain a JWT; and - the decisive point here - nothing in this
project's requirements describes user accounts or multi-tenancy. Building an identity system the
spec never asked for is solving a problem we don't have.

### IAM / SigV4

**Pros:** no identity store to build, reuses IAM directly, fine-grained policies possible.
**Cons:** a caller must be an AWS principal and sign every request with SigV4 - there's no way to
just `curl` the API, which matters a lot for a project meant to be demoed live in a code
walkthrough.

### API keys + usage plan

**Pros:** fastest to stand up, comes with request throttling/quota for free (a real production
concern addressed with almost no extra code), and the lowest-friction demo path (`x-api-key`
header, works with any HTTP client).
**Cons:** not real authentication - a shared secret with no identity behind it, no per-caller
audit trail, and revoking one caller means revoking the key for everyone using it.

## Decision

Use **API Gateway API keys + a usage plan** (`api_key_required = true` on each method,
`aws_api_gateway_usage_plan` with configurable rate/burst/quota).

Given there's no real multi-user requirement in the spec, Cognito would add meaningful complexity
in service of a security story nothing here actually calls for. API keys give a genuine,
demonstrable production concern - protecting the backend from abuse via throttling/quota - for a
fraction of the implementation cost, and keep the API trivially easy to exercise from curl or any
HTTP client for the live walkthrough.

## Consequences

- No per-user identity or audit trail. If a future requirement needs to know *who* uploaded a
  file (beyond "some caller with a valid key"), this needs revisiting - Cognito or a similar
  identity provider would become the right answer at that point, not before.
- The API key is a bearer secret: anyone holding it can call the API as "the client." Acceptable
  for a single-consumer service in a sandbox account; would need reconsidering for a
  multi-tenant, externally-facing deployment.
- Throttling/quota limits are tunable Terraform variables per environment (see
  `terraform/modules/api_gateway/variables.tf`), not hardcoded.
