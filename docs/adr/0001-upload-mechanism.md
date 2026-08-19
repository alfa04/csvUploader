# 1. Upload via S3 presigned POST, not direct API Gateway upload

## Status

Accepted

## Context

The API needs to accept CSV file uploads. There are two common ways to do this on API Gateway +
Lambda:

1. **Direct upload**: the client sends the CSV in the body of a `POST` request; API Gateway
   proxies it to a Lambda, which parses it synchronously and returns the result immediately.
2. **S3 presigned upload**: a Lambda issues a short-lived, pre-signed S3 upload URL; the client
   uploads the file directly to S3; an S3 event then triggers a separate Lambda to process it
   asynchronously.

Direct upload is simpler to reason about (one request, one response) but runs into real limits:
API Gateway caps request payloads at 10MB, and a base64-encoded body eats roughly a third of
that further. Large files would also hold a Lambda invocation open synchronously for the full
parse, decreasing throughput under concurrent load.

## Decision

Upload via a **presigned S3 POST**. `POST /uploads` returns a presigned URL and form fields
(scoped to `Content-Type: text/csv` and `content-length-range: 0-10MB`), created by
`upload_handler`. The client uploads directly to S3. An S3 `ObjectCreated` event then invokes
`process_handler` asynchronously to validate, parse, and store the data.

## Consequences

- Upload traffic never touches Lambda - S3 handles it directly, so file size is bounded by S3
  (effectively unlimited) rather than API Gateway/Lambda payload limits.
- Processing is asynchronous: the client gets an `upload_id` immediately but must poll
  `GET /uploads/{upload_id}` to learn the outcome, rather than getting it in the upload response.
  This is a real UX tradeoff, accepted because it's what makes the architecture actually scale.
- Adds one more moving part (the S3 event -> `process_handler` wiring, plus a DLQ for failed
  async invocations - see `terraform/modules/lambda`) compared to a single-Lambda direct-upload
  design.
