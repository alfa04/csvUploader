# csvUploader

A cloud-based analytics service for ingesting, validating, storing, and retrieving drug discovery
data (drug name, target, efficacy) submitted as CSV files. Built on AWS Lambda, API Gateway, S3,
and DynamoDB, with all infrastructure defined in Terraform.

> **Status:** work in progress. This README will be filled in as each milestone lands (see
> `docs/adr/` for the design decisions behind the architecture).

## Architecture

_TODO: architecture diagram + description (Milestone 8)._

## API

_TODO: endpoint reference + curl examples (Milestone 8). See `docs/openapi.yaml` once written._

## Local development

_TODO: dev setup instructions (Milestone 8)._

```bash
uv sync          # install dependencies
uv run pytest    # run the test suite
uv run ruff check .
```

## Infrastructure

Infrastructure is managed with Terraform under `terraform/`:

- `terraform/bootstrap` — one-time setup of the remote state backend (S3 bucket + DynamoDB lock
  table). Applied manually, once, before anything else.
- `terraform/modules` — reusable modules (S3, DynamoDB, Lambda, API Gateway, IAM, monitoring,
  GitHub OIDC).
- `terraform/environments/{dev,prod}` — per-environment root configurations, each with its own
  Terraform state.

See `docs/adr/` for why the architecture is shaped this way.

## Design decisions

Architecture Decision Records live in [`docs/adr`](docs/adr), covering the upload mechanism,
database choice, authentication strategy, environment strategy, and validation policy.
