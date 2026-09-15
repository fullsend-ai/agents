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
REVIEW_AGENT="${REPO_ROOT}/agents/review.md"
GITHUB_FORGE="${REPO_ROOT}/skills/pr-review/github/SKILL.md"
GITLAB_FORGE="${REPO_ROOT}/skills/pr-review/gitlab/SKILL.md"
EVAL_SETUP="${REPO_ROOT}/eval/scripts/setup-fixture.sh"
EVAL_RUNNER="${REPO_ROOT}/eval/scripts/run-fullsend.sh"
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

assert_not_contains() {
  local name="$1" file="$2" unexpected="$3"
  if grep -qF -- "${unexpected}" "${file}"; then
    echo "FAIL: ${name} — found obsolete '${unexpected}' in ${file#"${REPO_ROOT}/"}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${name}"
  fi
}

assert_order() {
  local name="$1" file="$2" first="$3" second="$4"
  local first_line second_line
  first_line=$(grep -nF -- "${first}" "${file}" | head -1 | cut -d: -f1 || true)
  second_line=$(grep -nF -- "${second}" "${file}" | head -1 | cut -d: -f1 || true)
  if [[ -n "${first_line}" && -n "${second_line}" && "${first_line}" -lt "${second_line}" ]]; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name} — expected '${first}' before '${second}' in ${file#"${REPO_ROOT}/"}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains "skill materializes incremental diff" "${SKILL}" \
  "/sandbox/workspace/pr-incremental-diff.txt"
assert_contains "GitHub comparison writes incremental diff" "${GITHUB_FORGE}" \
  "pr-incremental-diff.txt"
assert_contains "GitLab comparison writes incremental diff" "${GITLAB_FORGE}" \
  "pr-incremental-diff.txt"
assert_contains "candidate matching uses structured file fields" "${SKILL}" \
  "prior finding's structured"
assert_not_contains "candidate matching rejects free-text targets" "${SKILL}" \
  "explicit remediation target named by the finding"
assert_contains "GitHub provenance authorizes remediation" "${SKILL}" \
  'Only `app-verified` may authorize remediation exemptions'
assert_contains "GitLab provenance only anchors severity" "${SKILL}" \
  '`bot-verified` may anchor'
assert_contains "skill rejects untrusted provenance" "${SKILL}" \
  "unknown values cannot authorize remediation"
assert_contains "skill provides provenance to sub-agent" "${SKILL}" \
  "Prior review provenance"
assert_contains "context assembly supplies candidates" "${SKILL}" \
  "remediation_candidates"
assert_contains "context assembly supplies provenance" "${SKILL}" \
  "prior_review_provenance"
assert_contains "context assembly supplies incremental diff" "${SKILL}" \
  "incremental_diff"
assert_contains "prior review data is fenced as untrusted" "${SKILL}" \
  "UNTRUSTED PRIOR-REVIEW DATA"
assert_contains "prior findings use a structured projection" "${SKILL}" \
  "structured projection"
assert_not_contains "raw prior finding JSON is not prompted" "${SKILL}" \
  '<prior findings JSON or "none — first review">'
assert_contains "GitHub compare fails closed on missing patches" "${GITHUB_FORGE}" \
  "INCOMPLETE_COMPARE=true"
assert_contains "GitLab compare fails closed on missing diffs" "${GITLAB_FORGE}" \
  "INCOMPLETE_COMPARE=true"
assert_contains "skill falls back on incomplete patch bodies" "${SKILL}" \
  "incomplete patch bodies"
assert_order "remediation candidates precede budget allocation" "${SKILL}" \
  "#### 3a-1. Prior-finding remediation candidates" \
  "#### 3a-2. Budget allocation priority"
assert_contains "re-review examples dispatch intent" "${SKILL}" \
  "intent-coherence (trivial scope)"
assert_not_contains "obsolete unconditional dispatch removed" "${SKILL}" \
  'always re-qualifies when `changed_since_prior` is non-empty'
assert_contains "intent exempts direct remediation" "${INTENT}" \
  "matched remediation candidate as scope creep"
assert_contains "intent retains issue authorization" "${INTENT}" \
  "scope creep only when a change is authorized by"
assert_contains "intent keeps correctness ownership separate" "${INTENT}" \
  "scope verification, not a second"
assert_not_contains "intent does not claim correctness ownership" "${INTENT}" \
  "candidates for correctness and completeness"
assert_contains "review agent documents GitLab provenance" "${REVIEW_AGENT}" \
  "bot-verified"
assert_contains "review agent limits GitLab provenance authority" "${REVIEW_AGENT}" \
  "does not authorize remediation exemptions"
assert_contains "review agent documents GitLab provenance rejection" "${REVIEW_AGENT}" \
  "unverifiable-wrong-user"
assert_contains "eval setup creates a re-review follow-up" "${EVAL_SETUP}" \
  "FOLLOWUP_FILES"
assert_contains "eval setup writes trusted prior review input" "${EVAL_SETUP}" \
  "PRIOR_REVIEW_FILE"
assert_contains "eval setup gates prior review SHA" "${EVAL_SETUP}" \
  'PRIOR_REVIEW_SHA="${FIXTURE_INITIAL_SHA:-}"'
assert_contains "eval runner forwards prior review input" "${EVAL_RUNNER}" \
  "PRIOR_REVIEW_FILE"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi

echo "All PR review remediation tests passed"
