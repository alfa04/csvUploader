# Terraform bootstrap

Creates the remote state backend used by every other Terraform configuration in this repo:

- An S3 bucket (versioned, encrypted, fully private) to hold `.tfstate` files.
- A DynamoDB table for state locking.

## Why this is separate

Every other Terraform root module (`terraform/environments/dev`, `terraform/environments/prod`)
stores its state in the bucket/table created here. This configuration can't use that same remote
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

Note the `state_bucket_name` and `lock_table_name` outputs - they're referenced by each
environment's backend configuration (`terraform/environments/{dev,prod}/backend.tf`).

Re-running `plan`/`apply` later (e.g. after a Terraform or provider upgrade) is safe and
idempotent; it just isn't part of the normal per-environment workflow.
