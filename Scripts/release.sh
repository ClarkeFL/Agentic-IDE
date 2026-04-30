#!/usr/bin/env bash
# Cut a release without leaving the current branch.
#
# Usage: ./Scripts/release.sh 1.3.4
#        ./Scripts/release.sh v1.3.4
#
# Tags origin/main with the given version and pushes the tag, which fires
# .github/workflows/release.yml. Stays on whatever branch you're on (usually
# dev). Assumes the release PR has already been merged into main.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <version>   e.g. $0 1.3.4" >&2
  exit 64
fi

VERSION="${1#v}"
TAG="v${VERSION}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be MAJOR.MINOR.PATCH (got '$1')" >&2
  exit 64
fi

git fetch origin main --tags

if git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists locally" >&2
  exit 1
fi
if git ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG"; then
  echo "error: tag $TAG already exists on origin" >&2
  exit 1
fi

git tag "$TAG" origin/main
git push origin "$TAG"

echo
echo "Pushed $TAG → release.yml will build it now."
echo "Watch with: gh run watch \$(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId') --exit-status"
