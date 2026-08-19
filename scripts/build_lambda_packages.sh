#!/usr/bin/env bash
# Stages Lambda deployment artifacts under build/ for Terraform to zip:
#   build/layer/python/...        - third-party deps shared across all functions (a Lambda layer)
#   build/functions/<name>/...    - each function's own handler package + shared/ code
#
# Terraform's `archive_file` data source zips these directories declaratively (computing the
# hash that triggers redeploys) - this script's only job is to put the right files in place first.
# Run this before any `terraform plan`/`apply` in terraform/environments/{dev,prod}.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
FUNCTIONS=(upload_handler process_handler status_handler records_handler)

echo "==> Cleaning previous build output"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/layer/python" "$BUILD_DIR/functions"

echo "==> Exporting locked runtime dependencies for the shared layer"
uv export --no-dev --no-hashes --format requirements.txt -o "$BUILD_DIR/layer-requirements.txt" \
  --project "$REPO_ROOT"

echo "==> Installing layer dependencies for the Lambda runtime platform (python3.13, manylinux)"
uv pip install \
  --target "$BUILD_DIR/layer/python" \
  --python-platform x86_64-manylinux2014 \
  --python-version 3.13 \
  --no-build \
  -r "$BUILD_DIR/layer-requirements.txt"

echo "==> Staging per-function packages (shared/ + handler package)"
for fn in "${FUNCTIONS[@]}"; do
  dest="$BUILD_DIR/functions/$fn"
  mkdir -p "$dest"
  cp -r "$REPO_ROOT/src/shared" "$dest/shared"
  cp -r "$REPO_ROOT/src/$fn" "$dest/$fn"
  find "$dest" -name "__pycache__" -type d -exec rm -rf {} +
done

echo "==> Done. Staged: $BUILD_DIR/layer/python, ${FUNCTIONS[*]/#/$BUILD_DIR/functions/}"
