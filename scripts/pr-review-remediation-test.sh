#!/usr/bin/env bash
# pr-review-remediation-test.sh — Verify re-review remediation guidance.
#
# Run from the repo root:
#   bash scripts/pr-review-remediation-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/pr-review/SKILL.md"
INTENT="${REPO_ROOT}/skills/pr-review/sub-agents/intent-coherence.md"
FAILURES=0

assert_contains() {
  local name="$1" file="$2" expected="$3"
  if grep -qF -- "${expected}" "${file}"; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name} — missing '${expected}' in ${file#"${REPO_ROOT}/"}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains "skill passes remediation candidates" "${SKILL}" \
  "Prior-finding remediation candidates"
assert_contains "skill trusts GitHub provenance" "${SKILL}" \
  "\`app-verified\` (GitHub)"
assert_contains "skill trusts GitLab provenance" "${SKILL}" \
  "\`bot-verified\` (GitLab)"
assert_contains "skill rejects untrusted provenance" "${SKILL}" \
  "Empty, \`none\`, \`unverifiable-*\`, and unknown"
assert_contains "skill provides provenance to sub-agent" "${SKILL}" \
  "Prior review provenance"
assert_contains "skill matches category and file" "${SKILL}" \
  "category and file"
assert_contains "skill preserves unrelated scope checks" "${SKILL}" \
  "unmatched changes remain in"
assert_contains "skill dispatches intent for every re-review delta" "${SKILL}" \
  "always re-qualifies when"
assert_contains "skill gives intent the complete delta" "${SKILL}" \
  "complete incremental diff"
assert_contains "intent exempts direct remediation" "${INTENT}" \
  "matched remediation candidate as scope creep"
assert_contains "intent continues correctness review" "${INTENT}" \
  "correctness and completeness"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi

echo "All PR review remediation tests passed"
