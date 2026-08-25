#!/usr/bin/env bash
# risk-tier1-test.sh — Unit tests for risk-tier1.sh signal computation.
#
# Sources the actual risk-tier1.sh script and exercises its functions
# directly. Includes an end-to-end test that stubs `gh` with a fixture
# payload and verifies the complete KEY=VALUE output.
#
# Run from the repo root:
#   bash scripts/risk-tier1-test.sh

set -euo pipefail

FAILURES=0

# Source the actual script — the main() guard prevents execution,
# so only functions and pattern arrays are loaded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../skills/pr-risk-assessment/scripts/risk-tier1.sh
source "${SCRIPT_DIR}/../skills/pr-risk-assessment/scripts/risk-tier1.sh"

run_test() {
  local test_name="$1"
  local actual="$2"
  local expected="$3"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# ---------------------------------------------------------------------------
# Blast radius classification
# ---------------------------------------------------------------------------

run_test "blast-radius-small" \
  "$(classify_blast_radius 2 30)" "small"
run_test "blast-radius-medium" \
  "$(classify_blast_radius 10 300)" "medium"
run_test "blast-radius-large-files" \
  "$(classify_blast_radius 25 100)" "large"
run_test "blast-radius-large-lines" \
  "$(classify_blast_radius 3 600)" "large"
run_test "blast-radius-boundary-small" \
  "$(classify_blast_radius 4 99)" "small"
run_test "blast-radius-boundary-medium" \
  "$(classify_blast_radius 19 499)" "medium"

# ---------------------------------------------------------------------------
# Protected path matching
# ---------------------------------------------------------------------------

run_test "protected-none" \
  "$(count_protected_paths "src/main.go" "pkg/util.go")" "0"
run_test "protected-one" \
  "$(count_protected_paths "src/main.go" ".github/workflows/ci.yaml")" "1"
run_test "protected-multiple" \
  "$(count_protected_paths "scripts/deploy.sh" "CLAUDE.md" "src/main.go")" "2"
run_test "protected-exact-match" \
  "$(count_protected_paths "CODEOWNERS")" "1"
run_test "protected-prefix-match" \
  "$(count_protected_paths "CODEOWNERS.old")" "1"
run_test "protected-nested" \
  "$(count_protected_paths "skills/pr-review/SKILL.md")" "1"

# ---------------------------------------------------------------------------
# Security-sensitive path matching
# ---------------------------------------------------------------------------

run_test "security-none" \
  "$(count_security_sensitive "src/main.go" "pkg/util.go")" "0"
run_test "security-auth" \
  "$(count_security_sensitive "internal/auth/handler.go")" "1"
run_test "security-nested-token" \
  "$(count_security_sensitive "pkg/token/mint.go" "src/main.go")" "1"
run_test "security-multiple" \
  "$(count_security_sensitive "internal/auth/login.go" "internal/rbac/policy.go")" "2"
run_test "security-no-false-substring" \
  "$(count_security_sensitive "internal/unauth/handler.go")" "0"
run_test "security-root-path" \
  "$(count_security_sensitive "auth/login.go")" "1"

# ---------------------------------------------------------------------------
# CI/workflow detection
# ---------------------------------------------------------------------------

run_test "ci-false" \
  "$(has_ci_files "src/main.go" "pkg/util.go")" "false"
run_test "ci-github-workflow" \
  "$(has_ci_files "src/main.go" ".github/workflows/ci.yaml")" "true"
run_test "ci-dockerfile" \
  "$(has_ci_files "Dockerfile")" "true"
run_test "ci-makefile" \
  "$(has_ci_files "Makefile")" "true"
run_test "ci-github-codeowners-not-ci" \
  "$(has_ci_files ".github/CODEOWNERS")" "false"
run_test "ci-github-issue-template-not-ci" \
  "$(has_ci_files ".github/ISSUE_TEMPLATE/bug.md")" "false"
run_test "ci-github-actions" \
  "$(has_ci_files ".github/actions/setup/action.yml")" "true"
run_test "ci-gitlab-ci" \
  "$(has_ci_files ".gitlab-ci.yml")" "true"
run_test "ci-jenkinsfile" \
  "$(has_ci_files "Jenkinsfile")" "true"

# ---------------------------------------------------------------------------
# Dependency file detection
# ---------------------------------------------------------------------------

run_test "deps-none" \
  "$(find_dependency_files "src/main.go")" "none"
run_test "deps-go-mod" \
  "$(find_dependency_files "go.mod" "src/main.go")" "go.mod"
run_test "deps-multiple" \
  "$(find_dependency_files "go.mod" "go.sum" "src/main.go")" "go.mod,go.sum"
run_test "deps-nested" \
  "$(find_dependency_files "frontend/package.json" "src/main.go")" "frontend/package.json"

# ---------------------------------------------------------------------------
# Test file ratio
# ---------------------------------------------------------------------------

run_test "ratio-no-tests" \
  "$(compute_test_ratio "src/main.go" "src/util.go")" "0.00"
run_test "ratio-half" \
  "$(compute_test_ratio "src/main.go" "src/main_test.go")" "0.50"
run_test "ratio-all-tests" \
  "$(compute_test_ratio "main_test.go" "util_test.go")" "1.00"
run_test "ratio-one-third" \
  "$(compute_test_ratio "a.go" "b.go" "a_test.go")" "0.33"
run_test "ratio-nested-test-prefix" \
  "$(compute_test_ratio "tests/test_foo.py" "src/foo.py")" "0.50"
run_test "ratio-dot-spec" \
  "$(compute_test_ratio "src/component.spec.ts" "src/component.ts")" "0.50"

# ---------------------------------------------------------------------------
# Author bot detection
# ---------------------------------------------------------------------------

run_test "bot-dependabot" \
  "$(is_bot_author "dependabot[bot]")" "true"
run_test "bot-renovate" \
  "$(is_bot_author "renovate[bot]")" "true"
run_test "bot-human" \
  "$(is_bot_author "octocat")" "false"
run_test "bot-empty" \
  "$(is_bot_author "")" "false"

# ---------------------------------------------------------------------------
# End-to-end: stub gh, run main(), verify complete output
# ---------------------------------------------------------------------------

e2e_test() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' RETURN

  # gh stub — returns fixture data for PR #42, 5 files (64 total lines).
  cat > "${tmpdir}/gh" <<'STUB'
#!/usr/bin/env bash
JQ_FILTER="" prev=""
for arg in "$@"; do
  [[ "${prev}" == "--jq" ]] && JQ_FILTER="${arg}"
  prev="${arg}"
done
case "$*" in
  *pulls/42/files*)
    JSON='[{"filename":"src/main.go","additions":10,"deletions":5},{"filename":".github/workflows/ci.yaml","additions":3,"deletions":1},{"filename":"go.mod","additions":1,"deletions":1},{"filename":"internal/auth/handler.go","additions":20,"deletions":8},{"filename":"internal/auth/handler_test.go","additions":15,"deletions":0}]'
    ;;
  *pulls/42*)
    JSON='{"user":{"login":"octocat"},"author_association":"CONTRIBUTOR"}'
    ;;
  *)
    echo "gh stub: unhandled: $*" >&2; exit 1
    ;;
esac
if [[ -n "${JQ_FILTER}" ]]; then
  echo "${JSON}" | jq -r "${JQ_FILTER}"
else
  echo "${JSON}"
fi
STUB
  chmod +x "${tmpdir}/gh"

  local actual expected
  actual=$(
    PATH="${tmpdir}:${PATH}" \
    PR_NUMBER=42 \
    REPO_FULL_NAME="test-org/test-repo" \
    main 2>/dev/null
  )

  expected="FILES_CHANGED=5
LINES_CHANGED=64
BLAST_RADIUS=medium
PROTECTED_PATH_COUNT=1
SECURITY_SENSITIVE_COUNT=2
CI_WORKFLOW_CHANGED=true
DEPENDENCY_FILES_CHANGED=go.mod
TEST_FILE_RATIO=0.20
AUTHOR_IS_BOT=false
AUTHOR_IS_FIRST_TIME=false"

  run_test "e2e-full-output" "${actual}" "${expected}"
}

e2e_test

# ---------------------------------------------------------------------------
# End-to-end: multi-page pagination (jq -s 'add' merge)
# ---------------------------------------------------------------------------

e2e_pagination_test() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' RETURN

  # gh stub — simulates two-page paginated response for PR #99.
  # gh api --paginate outputs one JSON array per page on separate lines.
  cat > "${tmpdir}/gh" <<'STUB'
#!/usr/bin/env bash
JQ_FILTER="" prev=""
for arg in "$@"; do
  [[ "${prev}" == "--jq" ]] && JQ_FILTER="${arg}"
  prev="${arg}"
done
case "$*" in
  *pulls/99/files*)
    PAGE1='[{"filename":"src/main.go","additions":5,"deletions":2}]'
    PAGE2='[{"filename":"src/util.go","additions":3,"deletions":1}]'
    echo "${PAGE1}"
    echo "${PAGE2}"
    exit 0
    ;;
  *pulls/99*)
    JSON='{"user":{"login":"testbot[bot]"},"author_association":"FIRST_TIME_CONTRIBUTOR"}'
    ;;
  *)
    echo "gh stub: unhandled: $*" >&2; exit 1
    ;;
esac
if [[ -n "${JQ_FILTER}" ]]; then
  echo "${JSON}" | jq -r "${JQ_FILTER}"
else
  echo "${JSON}"
fi
STUB
  chmod +x "${tmpdir}/gh"

  local actual expected
  actual=$(
    PATH="${tmpdir}:${PATH}" \
    PR_NUMBER=99 \
    REPO_FULL_NAME="test-org/test-repo" \
    main 2>/dev/null
  )

  expected="FILES_CHANGED=2
LINES_CHANGED=11
BLAST_RADIUS=small
PROTECTED_PATH_COUNT=0
SECURITY_SENSITIVE_COUNT=0
CI_WORKFLOW_CHANGED=false
DEPENDENCY_FILES_CHANGED=none
TEST_FILE_RATIO=0.00
AUTHOR_IS_BOT=true
AUTHOR_IS_FIRST_TIME=true"

  run_test "e2e-multi-page-pagination" "${actual}" "${expected}"
}

e2e_pagination_test

# ---------------------------------------------------------------------------
# PROTECTED_PATHS drift: hardcoded fallback must match harness/review.yaml
# ---------------------------------------------------------------------------

drift_test() {
  local harness_file="${SCRIPT_DIR}/../harness/review.yaml"
  if [[ ! -f "${harness_file}" ]]; then
    echo "SKIP: drift-protected-paths (harness/review.yaml not found)"
    return
  fi

  local harness_paths
  harness_paths=$(grep 'REVIEW_PROTECTED_PATHS:' "${harness_file}" | head -1 \
    | sed 's/.*REVIEW_PROTECTED_PATHS:[[:space:]]*//' | tr -d '"' | tr -d "'")

  # Extract hardcoded fallback from risk-tier1.sh by sourcing with unset
  # REVIEW_PROTECTED_PATHS and reading the resulting PROTECTED_PATHS array.
  local script_paths
  script_paths=$(
    unset REVIEW_PROTECTED_PATHS
    source "${SCRIPT_DIR}/../skills/pr-risk-assessment/scripts/risk-tier1.sh"
    IFS=','; echo "${PROTECTED_PATHS[*]}"
  )

  run_test "drift-protected-paths: hardcoded fallback matches harness/review.yaml" \
    "${script_paths}" "${harness_paths}"
}

drift_test

# --- Summary ---

echo ""
if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
