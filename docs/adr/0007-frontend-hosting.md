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
