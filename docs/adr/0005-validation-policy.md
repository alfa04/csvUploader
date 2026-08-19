# 5. Partial ingest with per-row errors, not all-or-nothing

## Status

Accepted

## Context

The CSV upload has two categories of things that can be wrong with it:

- **Structural problems**: the file isn't UTF-8, has no header, has the wrong columns, is empty,
  or is too large/has too many rows. These make the file impossible to process meaningfully at
  all.
- **Row-level problems**: a given row has an empty `drug_name`, a non-numeric `efficacy`, or
  similar - the file's shape is fine, but individual data points are bad.

The question was whether a row-level problem should fail the *entire* upload (simpler status
model: `succeeded`/`failed`) or be handled per-row (richer model, more forgiving of messy
real-world data).

## Decision

**Structural failures reject the whole file** - nothing is stored, status becomes `failed`, and
the reported error explains the structural problem (e.g. wrong header).

**Row-level failures use partial ingest** - valid rows are stored, invalid rows are skipped and
reported individually as `{row, field, message}`, capped at the first 100 errors to bound the
`uploads` item's size. Status becomes `succeeded` if every row was valid, `partially_succeeded` if
some rows failed, and it's only ever `failed` for a structural problem.

## Consequences

- The status model has four terminal states instead of two
  (`succeeded`/`partially_succeeded`/`failed`, plus the in-flight `pending`/`processing`), which
  is more to document and test but maps honestly onto what actually happened to the data.
- A CSV with one typo'd row doesn't force the uploader to fix and resubmit the whole file - the
  good rows are usable immediately, and the bad ones are pinpointed by row number.
- `GET /uploads/{id}/records` only returns rows once processing has reached a terminal state with
  data (`succeeded` or `partially_succeeded`); a `failed` or still-`processing` upload returns an
  empty `records` array alongside the current `status`, rather than an error - see
  `src/records_handler/handler.py`.
