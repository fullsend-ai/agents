#!/usr/bin/env bash
set -euo pipefail

version=$(sed -n 's/^version: "\([^"]*\)"/\1/p' .skillsaw.yaml)
workflow_ref=$(sed -n 's/.*stbenjam\/skillsaw@\([0-9a-f]\{40\}\).*/\1/p' .github/workflows/lint.yml)
tag_ref=$(git ls-remote https://github.com/stbenjam/skillsaw.git "refs/tags/v${version}" | awk '{print $1}')

if [[ -z "${version}" || -z "${workflow_ref}" || -z "${tag_ref}" ]]; then
  echo "Unable to resolve the configured skillsaw version or action ref" >&2
  exit 1
fi

if [[ "${workflow_ref}" != "${tag_ref}" ]]; then
  echo "skillsaw action ref ${workflow_ref} does not match v${version} (${tag_ref})" >&2
  exit 1
fi
