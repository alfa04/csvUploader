# Architecture improvements backlog

Findings from an architecture review focused on **depth** (a lot of behavior behind a small
interface) and **locality** (change, bugs, and knowledge concentrated in one place, not
scattered across callers). Scope was the backend (`src/`) and infrastructure (`terraform/`) -
the frontend hasn't had this pass yet.

None of this is broken today. It's friction and, in one case, a real latent bug - worth working
through deliberately rather than blocking on, or forgetting about.

## Backend (`src/`)

### 1. Give "does this upload belong to the caller?" one home — Strong

`src/status_handler/handler.py:9-16` and `src/records_handler/handler.py:14-21` duplicate the
exact same block: look up the upload, then return 404 (not 403) if the caller's Cognito `sub`
doesn't match `uploaded_by`, so a customer can't distinguish "not yours" from "doesn't exist."
It's copy-pasted, not centralized - a third endpoint could repeat it with a subtly different
order and silently regress the anti-enumeration property, with no test catching it since each
handler only tests its own copy.

**Direction:** one function - e.g. `repository.get_owned_upload(upload_id, sub)` - that both
handlers call. Contained to `src/shared/`; no interface change for callers.

### 2. Own the raw-upload S3 key contract in one place — Strong

`upload_handler` writes to `raw/{upload_id}.csv`; `process_handler` independently reverses that
format to recover the id from the S3 event key. Nothing shares the format between them. Combined
with `repository.mark_processing`/`complete_upload` using `update_item` with no
`ConditionExpression`, a mismatch wouldn't error - it would silently **upsert** a new, incomplete
record, which later crashes `status_handler` with a `KeyError` on an unrelated request, far from
the actual cause.

**Direction:** one module (e.g. `shared/s3_keys.py`) owns `raw_key_for(id)` /
`upload_id_from_raw_key(key)` in both directions; add a conditional check so an unknown id fails
loudly at ingest time instead of corrupting a record. This is the one finding with a real
production risk behind it, not just duplication - **top priority if only one thing gets picked
up from this list.**

### 3. Give every API handler one error-and-response seam — Worth exploring

`upload_handler`, `status_handler`, `records_handler`, and `list_handler` each repeat the same
parse → call → respond shape, and none of them catches an unexpected boto3 `ClientError` - it
propagates raw through API Gateway, bypassing `shared/http.py`'s CORS headers and JSON envelope
for that one failure mode. (`process_handler` deliberately lets exceptions propagate for S3/DLQ
retry - that's a documented, tested choice; the four API handlers have no equivalent decision
recorded anywhere.)

**Direction:** a thin wrapper (e.g. `@api_handler` in `shared/http.py`) around all four
entrypoints that guarantees the response envelope even on an unexpected failure. Real trade-off
worth naming: `http.py`/`auth.py` are currently deliberately shallow utilities; this grows one of
them into a deeper seam every handler must route through - one more thing to learn, in exchange
for one place that owns the guarantee.

### 4. Two small duplicated concepts, no owner — Worth exploring

- `records_handler` and `list_handler` each implement their own `_parse_limit`, identical except
  for which page-size constants they reference.
- `MAX_STORED_ERRORS` is enforced twice - once in `validation.py`, again in
  `repository.complete_upload` - with no test that would catch the two diverging.

**Direction:** one `parse_bounded_int(raw, default, max)` helper in `shared/`; drop the cap from
`validation.py` and let `repository` be the single place that knows about DynamoDB item-size
limits. Cheap, contained, low risk either way.

## Infrastructure (`terraform/`)

### 5. Collapse the CORS preflight quartet with `for_each` — Strong

`terraform/modules/api_gateway/main.tf:155-291` has three CORS `OPTIONS` quartets (method +
integration + method_response + integration_response, ~140 lines) that are structurally
identical except for which resource they attach to and one methods string. This is pure
copy-paste, not Terraform's declarative style forcing it - a textbook `for_each` over a local map
collapses it with zero loss of clarity and zero caller-facing impact.

**Lowest-risk, highest-confidence item in this whole list** - contained entirely inside one
module file.

### 6. One shared composition module for dev and prod — Worth exploring

`terraform/environments/dev/main.tf` and `terraform/environments/prod/main.tf` are byte-identical
across roughly 250 lines - the SQS DLQ, the Lambda dependency layer, all five IAM+Lambda pairs,
the S3 notification wiring, and the `api_gateway`/`monitoring` module calls - including five
inline IAM policy documents with no structural link keeping the two files in sync. The real
differences are exactly three: the raw-uploads bucket's `cors_allowed_origins` (dev only, for the
browser frontend), `cognito.deletion_protection = "ACTIVE"` (prod only), and the dev-only
`frontend_hosting`/`github_oidc` modules.

**Direction:** wrap the identical graph in one shared module, parameterized by those three real
differences. This is compatible with
[ADR 0004](adr/0004-environment-strategy.md) - dev and prod would stay separate root modules with
separate state, just each calling one module instead of seven - and actually closes the gap
between what that ADR describes ("different variable values") and what the code currently does
(zero variation at all).

**Open design question:** whether the dev-only modules (`frontend_hosting`, `github_oidc`) sit
inside the shared module behind a conditional, or stay outside it in `dev/main.tf` - the latter
avoids reintroducing the kind of intra-module environment-branching the "no workspaces" decision
in ADR 0004 was trying to avoid.

**Hard constraint, not optional:** this touches live infrastructure, including the two DynamoDB
tables holding real upload data. Moving resources into a new module changes their Terraform
address (e.g. `module.iam_upload_handler.aws_iam_role.this` →
`module.workload.module.iam_upload_handler.aws_iam_role.this`), which without care reads as
"destroy this, create that" rather than a move - catastrophic for the DynamoDB tables specifically.
Use `moved` blocks (Terraform 1.1+) to declare old→new addresses, and prove a **zero-diff plan**
on dev before ever touching prod.

### 7. Data-driven route wiring in `api_gateway` — Speculative

Adding a route today means touching four places: two new variables on the module
(`<handler>_function_name`/`<handler>_invoke_arn`), a new method/integration/permission triple
inside it, and a new pair of arguments at both `dev/main.tf` and `prod/main.tf`. The `monitoring`
module already solves the same "repeat per function" shape with one `lambda_function_names` map
input.

**Direction:** replace the per-route variable pairs with one `routes` map driven by `for_each`.
**Real trade-off:** routes aren't fully homogeneous (different path resources, two of four need a
path parameter), and today "POST /uploads → upload_handler" is visible at a glance in the module
call - a map trades that away for scalability this project may not need at only 4 routes.
Speculative until a 5th or 6th route makes the current cost concrete.

## Not covered yet

The frontend (`frontend/src/`) hasn't had this pass. Worth a follow-up review on its own once
there's time.
