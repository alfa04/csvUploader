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
