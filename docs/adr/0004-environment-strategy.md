# 4. Separate Terraform state per environment, trunk-based CI/CD

## Status

Accepted

## Context

The project needed a multi-environment story (dev/prod) and a way to keep infrastructure and
application code deployable without long-lived AWS credentials sitting in GitHub, or environments
accidentally overlapping.

Two decisions were bundled together here: how Terraform separates dev from prod, and how CI/CD
gets from a merged PR to running infrastructure.

## Decision

**Separate state per environment, not Terraform workspaces.** `terraform/environments/dev` and
`terraform/environments/prod` are independent root modules, each with its own S3 backend state
key (`dev/terraform.tfstate`, `prod/terraform.tfstate` in the same bootstrap bucket). Workspaces
share a single directory and just swap a workspace suffix - a well-known foot-gun where it's easy
to `apply` against the wrong environment because you forgot which workspace was selected. Separate
root modules make the target environment explicit in the directory you're standing in, at the
cost of some duplication between `dev/main.tf` and `prod/main.tf` (both call the same shared
modules, just with different variable values).

**Trunk-based CI/CD, dev auto-deploys, prod never does.** Every PR runs lint/tests/
`terraform validate` (`.github/workflows/ci.yml`) with no AWS credentials at all. Every merge to
`main` re-runs those checks and then applies to **dev** automatically
(`.github/workflows/deploy-dev.yml`), authenticating via GitHub's OIDC provider to a dedicated IAM
role - no long-lived AWS access keys stored in GitHub. **`prod` has no CI path whatsoever** -
there's no `github_oidc` module call in `terraform/environments/prod/main.tf` at all, so this
isn't just a workflow convention, it's structurally true. Prod is always applied by hand, by a
person, after reviewing a plan (see `docs/deploying.md`).

## Consequences

- Getting the OIDC trust policy right took real iteration - GitHub changes the token's `sub`
  claim format if a job specifies `environment:`, and repos created after 2026-07-15 use an
  immutable `repo:OWNER@ID/REPO@ID:...` subject format instead of the older
  `repo:OWNER/REPO:...` form. The trust policy now accepts both formats defensively (see
  `terraform/modules/github_oidc/main.tf`) rather than assuming one.
- The CI deploy role's permissions are scoped by the `csvuploader-dev*` naming convention rather
  than to exact resource ARNs, since Terraform creates those resources and their ARNs aren't
  known ahead of time. `iam:PassRole` is the one statement kept tightly scoped regardless, since
  it's the classic privilege-escalation vector if left broad. A few AWS APIs (notably
  `logs:DescribeLogGroups`, and API Gateway's `/apikeys` and `/usageplans` paths) don't support
  resource-level scoping the way the rest do and needed their own carve-outs - see
  `terraform/environments/dev/main.tf`.
- Because CI can only ever reach dev, a change that only works in dev (e.g. a Terraform bug that
  happens to be masked by dev's specific resource state) won't be caught until someone applies to
  prod by hand. The manual review step is the intended safety net for this, not an accident.
