# Deploying

## How CI/CD works

- **Every PR** (`.github/workflows/ci.yml`): lints and tests the Python code, and runs
  `terraform fmt -check` + `terraform validate` (no AWS credentials involved - see below).
- **Every merge to `main`** (`.github/workflows/deploy-dev.yml`): re-runs lint/tests, builds the
  Lambda packages, then runs `terraform plan` + `terraform apply` against **dev**, automatically.
- **`prod` is never touched by CI.** It's always applied by hand - see below.

### Why PRs don't get AWS credentials

The GitHub OIDC deploy role's trust policy (`terraform/modules/github_oidc`) only allows the
`main` branch ref to assume it. A PR workflow runs against the PR's branch, not `main`, so it
can never authenticate as that role - this is deliberate, not an oversight. PR checks are
consequently limited to `terraform validate` (via `terraform init -backend=false`, which
downloads providers/modules but never touches remote state), rather than a live `terraform plan`.

### One-time GitHub repo setup

`deploy-dev.yml` needs the deploy role's ARN as a repository **variable** (not a secret - an IAM
role ARN isn't confidential, only the temporary credentials AWS hands back for it are, and GitHub
never sees those in plaintext):

1. Repo **Settings** → **Secrets and variables** → **Actions** → **Variables** tab → **New
   repository variable**.
2. Name: `AWS_GITHUB_ACTIONS_ROLE_ARN`.
3. Value: the `github_actions_role_arn` output from `terraform/environments/dev`:
   ```bash
   cd terraform/environments/dev
   AWS_PROFILE=csvuploader terraform output -raw github_actions_role_arn
   ```

## Deploying to prod (manual, always)

Prod is applied by hand, following the same "prepare a plan, review it, then apply" flow used
for dev throughout this project:

```bash
# 1. Build the Lambda packages (staged fresh from current source + the locked dependency versions)
./scripts/build_lambda_packages.sh

# 2. Review the plan
cd terraform/environments/prod
AWS_PROFILE=csvuploader terraform init -input=false
AWS_PROFILE=csvuploader terraform plan -input=false -out=prod.tfplan

# 3. Apply only after reviewing the plan output above
AWS_PROFILE=csvuploader terraform apply "prod.tfplan"

# 4. Record that this commit is now what's running in prod
./scripts/tag-deploy.sh prod
```

There's no `github_oidc` module instantiated in `terraform/environments/prod/main.tf` at all - CI
has no path to prod, by construction, not just by convention.

## Checking what's actually deployed where

Every successful deploy moves a `deployed/<env>` git tag to the commit that was actually applied -
`deployed/dev` automatically (the last step of `deploy-dev.yml`), `deployed/prod` manually (step 4
above). To see whether an environment is caught up with `main`:

```bash
git fetch --tags
git log deployed/prod..main --oneline   # empty output = prod is fully caught up
```

Anything printed is a commit that's merged but not yet applied to that environment.

This is git history, separate from (but consistent with) the `GitCommit` tag Terraform puts on
each Lambda function - that one answers "what commit is *this specific function* running" from
the AWS side, checkable directly without touching git at all:

```bash
aws lambda get-function --function-name csvuploader-dev-list-handler \
  --profile csvuploader --region us-east-1 --query 'Tags'
```
