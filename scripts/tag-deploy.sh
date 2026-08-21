#!/usr/bin/env bash
set -euo pipefail

# Moves a "deployed/<env>" git tag to the current commit and pushes it, so anyone can check
# what's actually running in an environment with `git log deployed/<env>..main` (empty output
# means that environment is fully caught up with main; anything else is what's missing).
#
# Run this right after every successful deploy. Dev's deploy workflow
# (.github/workflows/deploy-dev.yml) does it automatically. Prod is applied manually, so run this
# yourself immediately after `terraform apply` succeeds there.

ENV="${1:?Usage: $0 <dev|prod>}"
SHA="$(git rev-parse HEAD)"
TAG="deployed/$ENV"

git tag -f "$TAG" "$SHA"
git push origin "$TAG" --force

echo "Tagged $TAG -> $SHA"
