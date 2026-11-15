#!/usr/bin/env bash
# pr-review-provisional-result-test.sh — Verify the review orchestrator
# leaves a schema-valid agent-result.json even when the session ends before
# the final write (#1169).
#
# Run from the repo root:
#   bash scripts/pr-review-provisional-result-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/pr-review/SKILL.md"
AGENT="${REPO_ROOT}/agents/review.md"
SCHEMA="${REPO_ROOT}/schemas/review-result.schema.json"
VALIDATE="${REPO_ROOT}/scripts/validate-output-schema.sh"
FAILURES=0

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

normalize() { tr '\n' ' ' | tr -s ' '; }

assert_contains() {
  local name="$1" expected="$2"
  if grep -qF -- "${expected}" <<<"${TARGET}"; then
    pass "${name}"
  else
    fail "${name} — missing '${expected}'"
  fi
}

# ---------------------------------------------------------------------------
# Provisional result: the agent's jq template produces a schema-valid file.
# ---------------------------------------------------------------------------
PROVISIONAL_CMD="$(awk '
  /^\*\*Provisional result\.\*\*/ { found = 1 }
  found && /^```bash$/ { inblock = 1; next }
  inblock && /^```$/ { exit }
  inblock { print }
' "${AGENT}")"

if [[ -z "${PROVISIONAL_CMD}" ]]; then
  fail "could not extract the provisional result command from ${AGENT}"
else
  PROVISIONAL_CMD="${PROVISIONAL_CMD//<number>/42}"
  PROVISIONAL_CMD="${PROVISIONAL_CMD//<owner\/repo>/example-org/example-repo}"

  # Simulate an orchestrator that writes the provisional result in step 1
  # and then stops before step 7.
  ITER_DIR="${TMPDIR_ROOT}/iteration-1"
  mkdir -p "${ITER_DIR}/output"
  if (cd "${ITER_DIR}" && FULLSEND_OUTPUT_DIR="${ITER_DIR}/output" bash -c "${PROVISIONAL_CMD}"); then
    pass "provisional result command runs"
  else
    fail "provisional result command failed"
  fi

  if (cd "${ITER_DIR}" && FULLSEND_OUTPUT_SCHEMA="${SCHEMA}" bash "${VALIDATE}" >/dev/null); then
    pass "provisional result passes schema validation"
  else
    fail "provisional result fails schema validation"
  fi

  if [[ "$(jq -r '.action' "${ITER_DIR}/output/agent-result.json" 2>/dev/null)" == "failure" ]]; then
    pass "provisional result is a failure result"
  else
    fail "provisional result is not action=failure"
  fi

  # A normal run overwrites the provisional file with the final result.
  jq -n '{action: "approve", pr_number: 42, repo: "example-org/example-repo",
    head_sha: "0123456789abcdef0123456789abcdef01234567",
    body: "Looks good to me"}' > "${ITER_DIR}/output/agent-result.json"
  if (cd "${ITER_DIR}" && FULLSEND_OUTPUT_SCHEMA="${SCHEMA}" bash "${VALIDATE}" >/dev/null) \
    && [[ "$(jq -r '.action' "${ITER_DIR}/output/agent-result.json")" == "approve" ]]; then
    pass "final result overwrites the provisional result"
  else
    fail "final result did not replace the provisional result"
  fi
fi

# ---------------------------------------------------------------------------
# Guidance contract: provisional write, final overwrite, labels before write.
# ---------------------------------------------------------------------------
TARGET="$(normalize < "${SKILL}")"
assert_contains "step 1 writes the provisional result before step 2" \
  'write the provisional result (`agents/review.md`) before step 2; step 7 must still replace it.'
assert_contains "step 7 writes the result after labels, even with none" \
  'After the label step, even with no labels, write the result to'

TARGET="$(normalize < "${AGENT}")"
assert_contains "provisional result is written once the PR is known" \
  'As soon as the PR number and repo are known (`pr-review` step 1), write a provisional `failure` result'
assert_contains "provisional result is not the end of the run" \
  'overwrite it with the final result and run `fullsend-check-output` as the last actions of the run.'
assert_contains "labels are decided before writing the result file" \
  'After deciding the review verdict and before writing the result file'
assert_contains "label step never ends the run" \
  'The label step never ends the run.'

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi

echo "All PR review provisional result tests passed"
