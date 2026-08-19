# 2. DynamoDB for storage

## Status

Accepted

## Context

The service needs to store upload metadata/status and the parsed CSV rows. Three options were
considered:

1. **DynamoDB** - serverless NoSQL, on-demand billing, no networking to configure.
2. **Aurora Serverless v2 (Postgres)** - relational, flexible querying, but Lambda needs either
   VPC networking (NAT gateway cost/complexity) or the RDS Data API.
3. **RDS Postgres (provisioned)** - most familiar tooling, but an always-on instance with VPC +
   connection pooling (e.g. RDS Proxy) needed for Lambda concurrency - the least "serverless" of
   the three, and the most operational surface.

## Decision

Use **DynamoDB**, with two tables:

- `uploads` - PK `upload_id`. Status, counts, and capped error list for one upload.
- `records` - PK `upload_id`, SK `row_number`. The parsed rows for that upload.

This access pattern (fetch/update one upload by id; query all rows for one upload, paginated) is
exactly what DynamoDB's partition/sort-key model is built for, and needs no VPC, connection
pooling, or instance sizing decisions.

## Consequences

- No ad-hoc SQL querying or joins - if a future requirement needs cross-upload analytics (e.g.
  "all records for drug X across every upload"), that needs a new GSI designed up front, not a
  quick query. (We explicitly scoped retrieval to per-upload only for this project - see the
  design discussion in project history - so this hasn't been a constraint in practice.)
- Pay-per-request billing fits the bursty, low-baseline traffic shape of CSV uploads well, with
  no idle-instance cost.
- Point-in-time recovery is enabled on both tables as cheap insurance against accidental data
  loss.
