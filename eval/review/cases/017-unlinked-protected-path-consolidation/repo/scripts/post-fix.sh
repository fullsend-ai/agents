#!/usr/bin/env bash
# Push the fix agent's commits back to the PR branch.
set -euo pipefail

git push origin "HEAD:${PR_BRANCH:?}"
