#!/usr/bin/env bash
# post-scribe-test.sh — Test post-scribe.sh with fixture JSON inputs.
#
# Run from the repo root: bash scripts/post-scribe-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST_SCRIPT="${SCRIPT_DIR}/post-scribe.sh"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

GH_LOG="${TMPDIR}/gh-calls.log"
MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/gh" <<MOCKEOF
#!/usr/bin/env bash
if [[ "\$1" == "api" ]] && [[ "\$2" == *"/comments" ]] && [[ "\$*" == *"--paginate"* ]]; then
  echo "gh \$*" >> "${GH_LOG}"
  echo "[]"
  exit 0
fi
if [[ "\$1" == "issue" ]] && [[ "\$2" == "comment" ]]; then
  echo "gh \$*" >> "${GH_LOG}"
  exit 0
fi
if [[ "\$1" == "issue" ]] && [[ "\$2" == "create" ]]; then
  echo "gh \$*" >> "${GH_LOG}"
  echo "https://github.com/mock-org/mock-repo/issues/999"
  exit 0
fi
echo "gh \$*" >> "${GH_LOG}"
MOCKEOF
chmod +x "${MOCK_BIN}/gh"

export PATH="${MOCK_BIN}:${PATH}"
export SCRIBE_REPO="mock-org/mock-repo"
export GH_TOKEN="fake-token"
export SCRIBE_DRY_RUN="true"

run_test() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"
  local expect_failure="${4:-false}"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure, got exit code ${exit_code})"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_pattern}" ]] && ! grep -qF "${expected_pattern}" "${GH_LOG}"; then
    if ! grep -qF "${expected_pattern}" "${TMPDIR}/stdout.log"; then
      echo "FAIL: ${test_name} — expected pattern '${expected_pattern}' not found"
      echo "stdout:"
      cat "${TMPDIR}/stdout.log"
      echo "gh calls:"
      cat "${GH_LOG}"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

run_test_stdout() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"
  local expect_failure="${4:-false}"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure, got exit code ${exit_code})"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Test cases ---

run_test_missing_dry_run() {
  local run_dir="${TMPDIR}/run-missing-dry-run"
  mkdir -p "${run_dir}/iteration-1/output"
  echo '{"topics":[],"new_issues":[],"stats":{"notes_processed":0,"topics_extracted":0,"existing_matched":0,"new_proposed":0,"omitted":0}}' \
    > "${run_dir}/iteration-1/output/agent-result.json"
  local exit_code=0
  (cd "${run_dir}" && env -u SCRIBE_DRY_RUN bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?
  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: missing-dry-run-fails — expected failure but got success"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: missing-dry-run-fails (expected failure, got exit code ${exit_code})"
}

run_test_missing_dry_run

run_test_stdout "dry-run-comment" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "[DRY RUN] Would post comment"

run_test_stdout "low-confidence-rejected" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.2,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "GATE REJECTED"

run_test_stdout "public-safe-false-rejected" \
  '{"topics":[{"topic":"Comp review","summary":"**Meeting update — 2026-04-28**\n\nSalary discussion.","existing_issue":42,"confidence":0.9,"public_safe":false,"public_safe_category":"hr","omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "content gate: hr"

run_test_stdout "sensitive-email-rejected" \
  '{"topics":[{"topic":"Contact follow-up","summary":"**Meeting update — 2026-04-28**\n\nReach out at alice@example.com.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "contains sensitive content"

run_test_stdout "code-block-rejected" \
  '{"topics":[{"topic":"Config change","summary":"**Meeting update — 2026-04-28**\n\nUse ```yaml\nkey: value\n``` in the workflow.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "contains code block"

run_test_stdout "new-issue-code-block-rejected" \
  '{"topics":[],"new_issues":[{"title":"Add config","summary":"Need config docs.","body":"## Problem\nUse ```yaml\nkey: value\n``` here.\n\n## Options considered\nInline only.\n\n## Acceptance criteria\n- [ ] Works\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "issue body contains code block"

run_test_stdout "dedup-merges-duplicate-issues" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\nPoint A.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.8,"public_safe":true,"public_safe_category":null,"omit_reason":null},{"topic":"CI reliability (cont.)","summary":"**Meeting update — 2026-04-28**\n\nPoint B.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":2,"existing_matched":2,"new_proposed":0,"omitted":0}}' \
  "Dedup: merged 2"

export SCRIBE_MODE="comments_only"
run_test_stdout "comments-only-mode-skips-new-issues" \
  '{"topics":[],"new_issues":[{"title":"Add dark mode","summary":"Users want dark mode.","body":"## Problem\nNo dark mode.\n\n## Options considered\nTheme toggle.\n\n## Acceptance criteria\n- [ ] Toggle works\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "Skipping 1 new issue proposals (mode: comments_only)"
export SCRIBE_MODE="all"

export SCRIBE_MODE="new_issues_only"
run_test_stdout "new-issues-only-invalid-confidence-rejected" \
  '{"topics":[],"new_issues":[{"title":"Add dark mode","summary":"Users want dark mode.","body":"## Problem\nNo dark mode.\n\n## Options considered\nTheme toggle.\n\n## Acceptance criteria\n- [ ] Toggle works\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":"invalid","public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "GATE REJECTED"
export SCRIBE_MODE="all"

export SCRIBE_DRY_RUN="false"
run_test "live-mode-uses-paginate-for-idempotency" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "api --paginate repos/mock-org/mock-repo/issues/42/comments"
export SCRIBE_DRY_RUN="true"

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
