# Terraform bootstrap

Creates the remote state backend used by every other Terraform configuration in this repo: an S3
bucket (versioned, encrypted, fully private) to hold `.tfstate` files. State locking uses S3's
native lock-file support (`use_lockfile` in each environment's backend block, Terraform >= 1.10) -
no separate lock table needed.

## Why this is separate

Every other Terraform root module (`terraform/environments/dev`, `terraform/environments/prod`)
stores its state in the bucket created here. This configuration can't use that same remote
backend for itself - it's what creates it - so it intentionally keeps its own state **local**
(`terraform/bootstrap/terraform.tfstate`, gitignored).

## Usage

Run this **once**, manually, before applying any environment:

```bash
cd terraform/bootstrap
terraform init
terraform plan
terraform apply
```

Note the `state_bucket_name` output - it's referenced by each environment's backend
configuration (`terraform/environments/{dev,prod}/versions.tf`).

Re-running `plan`/`apply` later (e.g. after a Terraform or provider upgrade) is safe and
idempotent; it just isn't part of the normal per-environment workflow.
