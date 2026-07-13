#!/usr/bin/env bash
# gitlint-forbidden-type-scope-test.sh — Test the UL1 forbidden-type-scope
# gitlint rule that enforces COMMITS.md's forbidden type+scope table.
#
# Run from the repo root:
#   bash scripts/gitlint-forbidden-type-scope-test.sh

set -euo pipefail

FAILURES=0
TMPFILE="$(mktemp)"
trap 'rm -f "${TMPFILE}"' EXIT

# ---------------------------------------------------------------------------
# Helper — run gitlint on a single-line commit message and check the result.
# ---------------------------------------------------------------------------
run_test() {
  local test_name="$1"
  local commit_msg="$2"
  local expect_pass="$3"  # "yes" = should pass, "no" = should be rejected

  echo "${commit_msg}" > "${TMPFILE}"

  local rc=0
  local output
  output="$(gitlint --config .gitlint --ignore B6 --msg-filename "${TMPFILE}" 2>&1)" || rc=$?

  if [ "${expect_pass}" = "yes" ]; then
    if [ "${rc}" -ne 0 ]; then
      echo "FAIL: ${test_name}"
      echo "  input:    '${commit_msg}'"
      echo "  expected: pass (exit 0)"
      echo "  actual:   exit ${rc}"
      echo "  output:   ${output}"
      FAILURES=$((FAILURES + 1))
      return
    fi
  else
    if [ "${rc}" -eq 0 ]; then
      echo "FAIL: ${test_name}"
      echo "  input:    '${commit_msg}'"
      echo "  expected: reject (exit non-zero)"
      echo "  actual:   exit 0"
      FAILURES=$((FAILURES + 1))
      return
    fi
    # Verify the violation is from UL1 specifically
    if ! echo "${output}" | grep -q "UL1"; then
      echo "FAIL: ${test_name}"
      echo "  input:    '${commit_msg}'"
      echo "  expected: UL1 violation"
      echo "  actual:   rejected by different rule: ${output}"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

# --- Forbidden combinations (should be rejected) ---

run_test "forbidden-fix-ci" \
  "fix(ci): update pipeline" \
  "no"

run_test "forbidden-feat-ci" \
  "feat(ci): add new workflow" \
  "no"

run_test "forbidden-fix-e2e" \
  "fix(e2e): correct test assertion" \
  "no"

run_test "forbidden-feat-e2e" \
  "feat(e2e): add smoke test" \
  "no"

# Breaking change marker should not bypass the rule
run_test "forbidden-fix-ci-breaking" \
  "fix(ci)!: breaking pipeline change" \
  "no"

run_test "forbidden-feat-e2e-breaking" \
  "feat(e2e)!: restructure test suite" \
  "no"

# --- Valid combinations (should pass) ---

run_test "valid-ci-pipeline" \
  "ci(pipeline): update pipeline config" \
  "yes"

run_test "valid-ci-e2e" \
  "ci(e2e): fix flaky test" \
  "yes"

run_test "valid-fix-dispatch" \
  "fix(dispatch): correct event payload" \
  "yes"

run_test "valid-chore-ci" \
  "chore(ci): bump action version" \
  "yes"

run_test "valid-fix-issue-ref" \
  "fix(#123): resolve widget bug" \
  "yes"

run_test "valid-feat-harness" \
  "feat(harness): add role field" \
  "yes"

run_test "valid-no-scope" \
  "fix: correct typo in error message" \
  "yes"

run_test "valid-docs" \
  "docs: update contributing guide" \
  "yes"

run_test "valid-refactor" \
  "refactor(review): simplify verdict logic" \
  "yes"

# --- Summary ---

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
