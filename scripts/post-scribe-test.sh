#!/usr/bin/env bash
# post-scribe-test.sh — Test post-scribe.sh with fixture JSON inputs.
#
# Run from the repo root: bash scripts/post-scribe-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"

POST_SCRIPT="$(resolve_agent_script post-scribe)"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

GH_LOG="${TMPDIR}/gh-calls.log"
CURL_LOG="${TMPDIR}/curl-calls.log"
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

cat > "${MOCK_BIN}/curl" <<MOCKEOF
#!/usr/bin/env bash
echo "curl \$*" >> "${CURL_LOG}"

# Detect endpoint from URL argument
URL=""
for arg in "\$@"; do
  if [[ "\${arg}" == https://* ]]; then
    URL="\${arg}"
  fi
done
DATA=""
PREV=""
for arg in "\$@"; do
  [[ "\${PREV}" == "--data" ]] && DATA="\${arg}"
  PREV="\${arg}"
done

# Jira Cloud REST API
if [[ "\${URL}" == *"atlassian.net/rest/api/3"* ]]; then
  case "\${URL}" in
    */issue/createmeta/PROJ/issuetypes\?*)
      if [[ "\${JIRA_MOCK_PAGED_META:-}" == "1" ]]; then
        if [[ "\${URL}" == *"startAt=0"* ]]; then
          echo '{"issueTypes":[{"id":"10002","name":"Bug"}],"startAt":0,"total":2,"isLast":false}'
        else
          echo '{"issueTypes":[{"id":"10001","name":"Task"}],"startAt":1,"total":2,"isLast":true}'
        fi
      else
        echo '{"issueTypes":[{"id":"10001","name":"Task"}]}'
      fi
      ;;
    */issue/createmeta/PROJ/issuetypes/10001\?*)
      if [[ "\${JIRA_MOCK_PAGED_META:-}" == "1" ]]; then
        if [[ "\${URL}" == *"startAt=0"* ]]; then
          echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false}],"startAt":0,"total":2,"isLast":false}'
        else
          echo '{"fields":[{"fieldId":"customfield_10060","required":true,"hasDefaultValue":false}],"startAt":1,"total":2,"isLast":true}'
        fi
      elif [[ "\${JIRA_MOCK_REQUIRED_FIELD:-}" == "1" ]]; then
        echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false},{"fieldId":"customfield_10050","required":true,"hasDefaultValue":false}]}'
      elif [[ "\${JIRA_MOCK_NO_LABELS:-}" == "1" ]]; then
        echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false},{"fieldId":"description","required":false,"hasDefaultValue":false}]}'
      elif [[ "\${JIRA_MOCK_NO_DESCRIPTION:-}" == "1" ]]; then
        echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false},{"fieldId":"labels","required":false,"hasDefaultValue":false}]}'
      else
        echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false},{"fieldId":"description","required":false,"hasDefaultValue":false},{"fieldId":"labels","required":false,"hasDefaultValue":false},{"fieldId":"reporter","required":true,"hasDefaultValue":true}]}'
      fi
      ;;
    */search/jql)
      if [[ "\${JIRA_MOCK_BAD_SEARCH:-}" == "html" ]]; then
        echo '<html>maintenance</html>'
      elif [[ "\${JIRA_MOCK_BAD_SEARCH:-}" == "no-issues" ]]; then
        echo '{"isLast":true}'
      elif [[ "\${JIRA_MOCK_ENDLESS:-}" == "1" ]]; then
        echo '{"issues":[{"key":"PROJ-3","fields":{"summary":"Unrelated"}}],"nextPageToken":"more","isLast":false}'
      elif [[ "\${DATA}" == *'添加深色模式'* ]]; then
        if [[ "\${JIRA_MOCK_DUP_CJK:-}" == "1" ]]; then
          echo '{"issues":[{"key":"PROJ-8","fields":{"summary":"添加深色模式"}}],"isLast":true}'
        else
          echo '{"issues":[],"isLast":true}'
        fi
      elif [[ "\${DATA}" == *'"nextPageToken":"p2"'* ]]; then
        if [[ "\${JIRA_MOCK_DUP:-}" == "1" ]]; then
          echo '{"issues":[{"key":"PROJ-7","fields":{"summary":"Add dark mode"}}],"isLast":true}'
        else
          echo '{"issues":[],"isLast":true}'
        fi
      else
        echo '{"issues":[{"key":"PROJ-3","fields":{"summary":"Add dark mode toggle"}}],"nextPageToken":"p2","isLast":false}'
      fi
      ;;
    */issue)
      echo '{"id":"10100","key":"PROJ-100"}'
      ;;
    *)
      exit 22
      ;;
  esac
  exit 0
fi

# Note listing (comments) — return empty array
if [[ "\${URL}" == *"/notes"* ]] && [[ " \$* " == *" GET "* ]]; then
  echo "[]"
  exit 0
fi

# Note creation (comments) — succeed
if [[ "\${URL}" == *"/notes" ]] && [[ " \$* " == *" POST "* ]]; then
  echo '{"id": 1}'
  exit 0
fi

# Issue creation — return fake URL
if [[ "\${URL}" == *"/issues" ]] && [[ " \$* " == *" POST "* ]]; then
  echo '{"web_url": "https://gitlab.com/mock-group/mock-project/-/issues/999", "iid": 999}'
  exit 0
fi

exit 0
MOCKEOF
chmod +x "${MOCK_BIN}/curl"

export PATH="${MOCK_BIN}:${PATH}"
export SCRIBE_REPO="mock-org/mock-repo"
export GH_TOKEN="fake-token"
export SCRIBE_DRY_RUN="true"
# shellcheck disable=SC2031 # FULLSEND_FORGE exported for subshell test runs
export FULLSEND_FORGE="github"

run_test() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"
  local expect_failure="${4:-false}"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${CURL_LOG}"

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

  if [[ -n "${expected_pattern}" ]] && ! grep -qF "${expected_pattern}" "${GH_LOG}" 2>/dev/null; then
    if ! grep -qF "${expected_pattern}" "${CURL_LOG}" 2>/dev/null; then
      if ! grep -qF "${expected_pattern}" "${TMPDIR}/stdout.log"; then
        echo "FAIL: ${test_name} — expected pattern '${expected_pattern}' not found"
        echo "stdout:"
        cat "${TMPDIR}/stdout.log"
        echo "gh calls:"
        cat "${GH_LOG}" 2>/dev/null || true
        echo "curl calls:"
        cat "${CURL_LOG}" 2>/dev/null || true
        FAILURES=$((FAILURES + 1))
        return
      fi
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
  : > "${CURL_LOG}"

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

# --- GitHub test cases (FULLSEND_FORGE=github) ---

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

run_test_stdout "github/dry-run-comment" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "[DRY RUN] Would post comment"

run_test_stdout "github/low-confidence-rejected" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.2,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "GATE REJECTED"

run_test_stdout "github/public-safe-false-rejected" \
  '{"topics":[{"topic":"Comp review","summary":"**Meeting update — 2026-04-28**\n\nSalary discussion.","existing_issue":42,"confidence":0.9,"public_safe":false,"public_safe_category":"hr","omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "content gate: hr"

run_test_stdout "github/sensitive-email-rejected" \
  '{"topics":[{"topic":"Contact follow-up","summary":"**Meeting update — 2026-04-28**\n\nReach out at alice@example.com.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "contains sensitive content"

run_test_stdout "github/code-block-rejected" \
  '{"topics":[{"topic":"Config change","summary":"**Meeting update — 2026-04-28**\n\nUse ```yaml\nkey: value\n``` in the workflow.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "contains code block"

run_test_stdout "github/new-issue-code-block-rejected" \
  '{"topics":[],"new_issues":[{"title":"Add config","summary":"Need config docs.","body":"## Problem\nUse ```yaml\nkey: value\n``` here.\n\n## Options considered\nInline only.\n\n## Acceptance criteria\n- [ ] Works\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "issue body contains code block"

run_test_stdout "github/dedup-merges-duplicate-issues" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\nPoint A.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.8,"public_safe":true,"public_safe_category":null,"omit_reason":null},{"topic":"CI reliability (cont.)","summary":"**Meeting update — 2026-04-28**\n\nPoint B.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":2,"existing_matched":2,"new_proposed":0,"omitted":0}}' \
  "Dedup: merged 2"

export SCRIBE_MODE="comments_only"
run_test_stdout "github/comments-only-mode-skips-new-issues" \
  '{"topics":[],"new_issues":[{"title":"Add dark mode","summary":"Users want dark mode.","body":"## Problem\nNo dark mode.\n\n## Options considered\nTheme toggle.\n\n## Acceptance criteria\n- [ ] Toggle works\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "Skipping 1 new issue proposals (mode: comments_only)"
export SCRIBE_MODE="all"

export SCRIBE_MODE="new_issues_only"
run_test_stdout "github/new-issues-only-invalid-confidence-rejected" \
  '{"topics":[],"new_issues":[{"title":"Add dark mode","summary":"Users want dark mode.","body":"## Problem\nNo dark mode.\n\n## Options considered\nTheme toggle.\n\n## Acceptance criteria\n- [ ] Toggle works\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":"invalid","public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "GATE REJECTED"
export SCRIBE_MODE="all"

export SCRIBE_DRY_RUN="false"
run_test "github/live-mode-uses-paginate-for-idempotency" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "api --paginate repos/mock-org/mock-repo/issues/42/comments"
export SCRIBE_DRY_RUN="true"

# ---------------------------------------------------------------------------
# FULLSEND_VALIDATED_ITERATION_DIR tests
# ---------------------------------------------------------------------------

VALIDATED_DIR_FIXTURE='{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}'
WRONG_ITERATION_FIXTURE='{"topics":[{"topic":"WRONG_ITERATION_MARKER","summary":"should not be used","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}'

run_validated_dir_test() {
  local test_name="$1"
  local validated_dir_file="$2"   # "agent-result.json", "result.json", or "none"
  local expect_failure="${3:-false}"

  local run_dir="${TMPDIR}/run-${test_name}"
  local validated_dir="${run_dir}/validated-output"
  mkdir -p "${validated_dir}"

  if [[ "${validated_dir_file}" != "none" ]]; then
    echo "${VALIDATED_DIR_FIXTURE}" > "${validated_dir}/${validated_dir_file}"
  fi

  # A later iteration with different, distinguishable content — must never
  # be used when FULLSEND_VALIDATED_ITERATION_DIR is set.
  mkdir -p "${run_dir}/iteration-2/output"
  echo "${WRONG_ITERATION_FIXTURE}" > "${run_dir}/iteration-2/output/agent-result.json"

  : > "${GH_LOG}"
  : > "${CURL_LOG}"

  local exit_code=0
  (
    cd "${run_dir}"
    export FULLSEND_VALIDATED_ITERATION_DIR="${validated_dir}"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

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

  if grep -qF "WRONG_ITERATION_MARKER" "${TMPDIR}/stdout.log" "${GH_LOG}" "${CURL_LOG}" 2>/dev/null; then
    echo "FAIL: ${test_name} — used iteration-2's output instead of the validated iteration"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_validated_dir_test "validated-dir-expected-filename" "agent-result.json"
run_validated_dir_test "validated-dir-fallback-filename" "result.json"
run_validated_dir_test "validated-dir-neither-filename" "none" "true"

# --- GitLab test cases (FULLSEND_FORGE=gitlab) ---

# shellcheck disable=SC2031 # FULLSEND_FORGE exported for subshell test runs
export FULLSEND_FORGE="gitlab"
export GITLAB_TOKEN="fake-gitlab-token"
export SCRIBE_REPO="mock-group/mock-project"
export CI_SERVER_HOST="gitlab.com"

run_test_stdout "gitlab/dry-run-comment" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "[DRY RUN] Would post comment"

run_test_stdout "gitlab/low-confidence-rejected" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.2,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "GATE REJECTED"

run_test_stdout "gitlab/public-safe-false-rejected" \
  '{"topics":[{"topic":"Comp review","summary":"**Meeting update — 2026-04-28**\n\nSalary discussion.","existing_issue":42,"confidence":0.9,"public_safe":false,"public_safe_category":"hr","omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "content gate: hr"

run_test_stdout "gitlab/dedup-merges-duplicate-issues" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\nPoint A.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.8,"public_safe":true,"public_safe_category":null,"omit_reason":null},{"topic":"CI reliability (cont.)","summary":"**Meeting update — 2026-04-28**\n\nPoint B.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":2,"existing_matched":2,"new_proposed":0,"omitted":0}}' \
  "Dedup: merged 2"

run_test_stdout "gitlab/sensitive-email-rejected" \
  '{"topics":[{"topic":"Contact follow-up","summary":"**Meeting update — 2026-04-28**\n\nReach out at alice@example.com.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "contains sensitive content"

run_test_stdout "gitlab/code-block-rejected" \
  '{"topics":[{"topic":"Config change","summary":"**Meeting update — 2026-04-28**\n\nUse ```yaml\nkey: value\n``` in the workflow.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "contains code block"

run_test_stdout "gitlab/new-issue-code-block-rejected" \
  '{"topics":[],"new_issues":[{"title":"Add config","summary":"Need config docs.","body":"## Problem\nUse ```yaml\nkey: value\n``` here.\n\n## Options considered\nInline only.\n\n## Acceptance criteria\n- [ ] Works\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "issue body contains code block"

export SCRIBE_MODE="comments_only"
run_test_stdout "gitlab/comments-only-mode-skips-new-issues" \
  '{"topics":[],"new_issues":[{"title":"Add dark mode","summary":"Users want dark mode.","body":"## Problem\nNo dark mode.\n\n## Options considered\nTheme toggle.\n\n## Acceptance criteria\n- [ ] Toggle works\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "Skipping 1 new issue proposals (mode: comments_only)"
export SCRIBE_MODE="all"

export SCRIBE_MODE="new_issues_only"
run_test_stdout "gitlab/new-issues-only-invalid-confidence-rejected" \
  '{"topics":[],"new_issues":[{"title":"Add dark mode","summary":"Users want dark mode.","body":"## Problem\nNo dark mode.\n\n## Options considered\nTheme toggle.\n\n## Acceptance criteria\n- [ ] Toggle works\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":"invalid","public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "GATE REJECTED"
export SCRIBE_MODE="all"

export SCRIBE_DRY_RUN="false"
run_test "gitlab/live-mode-posts-comment" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "mock-group%2Fmock-project/issues/42/notes"
run_test "gitlab/live-mode-creates-issue" \
  '{"topics":[],"new_issues":[{"title":"Add dark mode","summary":"Users want dark mode.","body":"## Problem\nNo dark mode.\n\n## Options considered\nTheme toggle.\n\n## Acceptance criteria\n- [ ] Toggle works\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "mock-group%2Fmock-project/issues"
export SCRIBE_DRY_RUN="true"

# --- GitLab self-managed origin with a non-default HTTPS port (#1732) ---
# API requests and generated links must keep the port from CI_SERVER_URL.

export CI_SERVER_URL="https://ce.example.test:34881"
export CI_SERVER_HOST="ce.example.test"
export SCRIBE_DRY_RUN="false"
export GITHUB_STEP_SUMMARY="${TMPDIR}/step-summary.md"
: > "${GITHUB_STEP_SUMMARY}"
run_test "gitlab/custom-port-api-url-keeps-port" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "https://ce.example.test:34881/api/v4/projects/mock-group%2Fmock-project/issues/42/notes"
if grep -qF "](https://ce.example.test:34881/mock-group/mock-project/-/issues/42)" "${GITHUB_STEP_SUMMARY}"; then
  echo "PASS: gitlab/custom-port-step-summary-link-keeps-port"
else
  echo "FAIL: gitlab/custom-port-step-summary-link-keeps-port — issue link missing port"
  cat "${GITHUB_STEP_SUMMARY}"
  FAILURES=$((FAILURES + 1))
fi
unset GITHUB_STEP_SUMMARY

# Non-HTTPS CI_SERVER_URL fails closed before any API call.
export CI_SERVER_URL="http://ce.example.test:34881"
run_test "gitlab/non-https-ci-server-url-rejected" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "" "true"
if ! grep -qF "CI_SERVER_URL is not an HTTPS origin" "${TMPDIR}/stdout.log"; then
  echo "FAIL: gitlab/non-https-ci-server-url-error — expected error not found"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
elif grep -qF "/api/v4/" "${CURL_LOG}"; then
  echo "FAIL: gitlab/non-https-ci-server-url-no-api-call — API was called"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: gitlab/non-https-ci-server-url-no-api-call"
fi
export SCRIBE_DRY_RUN="true"

# Link builders, exercised directly from the GitLab scribe lib.
run_scribe_link_test() {
  local test_name="$1" expected="$2"
  shift 2
  local actual
  actual=$(bash -c 'source "$1"; shift; "$@"' _ "${SCRIPT_DIR}/lib/gitlab-scribe-ops.lib.sh" "$@" 2>&1) || true
  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL: ${test_name} — expected '${expected}', got '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

export CI_SERVER_URL="https://ce.example.test:34881"
run_scribe_link_test "gitlab/issue-url-base-keeps-port" \
  "https://ce.example.test:34881/mock-group/mock-project/-/issues" \
  forge_issue_url_base "mock-group/mock-project"
run_scribe_link_test "gitlab/run-url-fallback-keeps-port" \
  "https://ce.example.test:34881/mock-group/mock-project" \
  forge_run_url "mock-group/mock-project"

# CI_SERVER_URL host that does not match CI_SERVER_HOST is rejected.
export CI_SERVER_URL="https://evil.example.test:34881"
run_scribe_link_test "gitlab/issue-url-base-host-mismatch-rejected" \
  "ERROR: GitLab host 'evil.example.test' does not match CI_SERVER_HOST" \
  forge_issue_url_base "mock-group/mock-project"

# Standard-port regression: no CI_SERVER_URL falls back to CI_SERVER_HOST.
unset CI_SERVER_URL
export CI_SERVER_HOST="gitlab.com"
run_scribe_link_test "gitlab/issue-url-base-default-port" \
  "https://gitlab.com/mock-group/mock-project/-/issues" \
  forge_issue_url_base "mock-group/mock-project"

# Restore GitHub defaults for any subsequent test additions
export FULLSEND_FORGE="github"
export SCRIBE_REPO="mock-org/mock-repo"
unset GITLAB_TOKEN
unset CI_SERVER_HOST

# --- Jira tracker test cases (FULLSEND_FORGE=github, FULLSEND_TRACKER=jira) ---

JIRA_NEW_ISSUE='{"topics":[],"new_issues":[{"title":"Add dark mode","summary":"Users want dark mode.","body":"## Problem\nNo dark mode.\n\n## Acceptance criteria\n- [ ] Toggle works","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}'
JIRA_REJECTED_ISSUE='{"topics":[],"new_issues":[{"title":"Add dark mode","summary":"Users want dark mode.","body":"Contact jane@example.com","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}'
JIRA_COMMENT_TOPIC='{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\nflaky tests.","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}'

export FULLSEND_TRACKER="jira"
export JIRA_BASE_URL="https://mock.atlassian.net"
export JIRA_USER_EMAIL="bot@mock.example"
export JIRA_TOKEN="fake-jira-token"
export SCRIBE_JIRA_PROJECT="PROJ"
export SCRIBE_MODE="all"

# Fails if any Jira create (POST /rest/api/3/issue) or forge write happened.
assert_no_writes() {
  local test_name="$1"
  if grep -qE 'rest/api/3/issue( |$)' "${CURL_LOG}" 2>/dev/null \
    || grep -qE '^gh issue (create|comment)' "${GH_LOG}" 2>/dev/null; then
    echo "FAIL: ${test_name} — unexpected write call"
    cat "${CURL_LOG}" "${GH_LOG}" 2>/dev/null || true
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${test_name} (no write calls)"
  fi
}

run_test_stdout "jira/dry-run-validates-project" "${JIRA_NEW_ISSUE}" \
  "[DRY RUN] Would create issue: Add dark mode"
assert_no_writes "jira/dry-run-no-writes"

run_test_stdout "jira/all-mode-skips-comments" "${JIRA_COMMENT_TOPIC}" \
  "comments are not supported; using new_issues_only"
assert_no_writes "jira/comment-topic-no-writes"

export SCRIBE_MODE="comments_only"
run_test_stdout "jira/comments-only-rejected" "${JIRA_COMMENT_TOPIC}" "" true
export SCRIBE_MODE="all"

export SCRIBE_DRY_RUN="false"
run_test_stdout "jira/live-creates-issue" "${JIRA_NEW_ISSUE}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -E 'rest/api/3/issue( |$)' "${CURL_LOG}" | grep -qF '"project":{"key":"PROJ"}'; then
  echo "PASS: jira/live-create-scoped-to-project"
else
  echo "FAIL: jira/live-create-scoped-to-project — create payload missing project PROJ"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
fi
if grep -q '^gh issue create' "${GH_LOG}" 2>/dev/null; then
  echo "FAIL: jira/live-no-github-issue — GitHub issue created on Jira path"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/live-no-github-issue"
fi

run_test_stdout "jira/live-content-gate-rejected" "${JIRA_REJECTED_ISSUE}" "GATE REJECTED"
assert_no_writes "jira/content-gate-no-writes"

export JIRA_MOCK_DUP="1"
run_test_stdout "jira/live-rerun-duplicate-on-page-2-skipped" "${JIRA_NEW_ISSUE}" \
  "SKIP: duplicate issue (already exists: https://mock.atlassian.net/browse/PROJ-7)"
assert_no_writes "jira/duplicate-no-writes"
unset JIRA_MOCK_DUP

# Non-Latin title: the duplicate lookup must still run and find the match.
JIRA_CJK_ISSUE="${JIRA_NEW_ISSUE//Add dark mode/添加深色模式}"
export JIRA_MOCK_DUP_CJK="1"
run_test_stdout "jira/live-rerun-non-latin-title-skipped" "${JIRA_CJK_ISSUE}" \
  "SKIP: duplicate issue (already exists: https://mock.atlassian.net/browse/PROJ-8)"
assert_no_writes "jira/non-latin-duplicate-no-writes"
unset JIRA_MOCK_DUP_CJK

# Title with no letters or digits: lookup cannot run, so refuse to create.
JIRA_PUNCT_ISSUE="${JIRA_NEW_ISSUE//Add dark mode/!!!}"
run_test_stdout "jira/live-no-searchable-terms-refused" "${JIRA_PUNCT_ISSUE}" "" true
assert_no_writes "jira/no-searchable-terms-no-writes"

# Page cap hit with no exact match: refuse to create.
export JIRA_MOCK_ENDLESS="1"
export SCRIBE_JIRA_MAX_PAGES=2
run_test_stdout "jira/live-page-cap-refused" "${JIRA_NEW_ISSUE}" "" true
assert_no_writes "jira/page-cap-no-writes"
unset JIRA_MOCK_ENDLESS SCRIBE_JIRA_MAX_PAGES

# Create metadata spread over two pages: page two must be read.
export JIRA_MOCK_PAGED_META="1"
run_test_stdout "jira/createmeta-page-two-required-field" "${JIRA_NEW_ISSUE}" "" true
if grep -qF "requires fields scribe does not set: customfield_10060" "${TMPDIR}/stdout.log"; then
  echo "PASS: jira/createmeta-page-two-field-detected"
else
  echo "FAIL: jira/createmeta-page-two-field-detected"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
fi
assert_no_writes "jira/createmeta-page-two-no-writes"
unset JIRA_MOCK_PAGED_META

export JIRA_MOCK_REQUIRED_FIELD="1"
run_test_stdout "jira/required-field-fails-before-create" "${JIRA_NEW_ISSUE}" "" true
if grep -qF "requires fields scribe does not set: customfield_10050" "${TMPDIR}/stdout.log"; then
  echo "PASS: jira/required-field-error-message"
else
  echo "FAIL: jira/required-field-error-message"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
fi
assert_no_writes "jira/required-field-no-writes"
unset JIRA_MOCK_REQUIRED_FIELD

# A search response that is not JSON, or has no issues array, must not be
# read as "no duplicate": refuse to create.
for bad_search in html no-issues; do
  export JIRA_MOCK_BAD_SEARCH="${bad_search}"
  run_test_stdout "jira/live-malformed-search-${bad_search}-refused" "${JIRA_NEW_ISSUE}" \
    "Jira duplicate check failed" true
  if grep -qF "Jira duplicate check failed — refusing to create issue" "${TMPDIR}/stdout.log"; then
    echo "PASS: jira/malformed-search-${bad_search}-error-message"
  else
    echo "FAIL: jira/malformed-search-${bad_search}-error-message"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
  fi
  assert_no_writes "jira/malformed-search-${bad_search}-no-writes"
done
unset JIRA_MOCK_BAD_SEARCH

# Create screen without Description: fail validation before any create.
export JIRA_MOCK_NO_DESCRIPTION="1"
run_test_stdout "jira/no-description-field-fails-before-create" "${JIRA_NEW_ISSUE}" "" true
if grep -qF "has no Description field" "${TMPDIR}/stdout.log"; then
  echo "PASS: jira/no-description-field-error-message"
else
  echo "FAIL: jira/no-description-field-error-message"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
fi
assert_no_writes "jira/no-description-field-no-writes"
unset JIRA_MOCK_NO_DESCRIPTION

# Create screen without Labels: the create must omit labels.
export JIRA_MOCK_NO_LABELS="1"
run_test_stdout "jira/live-no-labels-field-creates-without-labels" "${JIRA_NEW_ISSUE}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -E 'rest/api/3/issue( |$)' "${CURL_LOG}" | grep -qF '"labels"'; then
  echo "FAIL: jira/no-labels-field-payload-omits-labels — labels sent"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/no-labels-field-payload-omits-labels"
fi
unset JIRA_MOCK_NO_LABELS

# Labels pass the same content gates as title and body.
JIRA_SENSITIVE_LABEL_ISSUE="${JIRA_NEW_ISSUE//\"meeting-notes\"/\"jane@example.com\"}"
run_test_stdout "jira/live-sensitive-label-rejected" "${JIRA_SENSITIVE_LABEL_ISSUE}" "GATE REJECTED"
assert_no_writes "jira/sensitive-label-no-writes"
JIRA_UNICODE_LABEL_ISSUE="${JIRA_NEW_ISSUE//\"meeting-notes\"/\"notes\\u200bx\"}"
run_test_stdout "jira/live-suspicious-unicode-label-rejected" "${JIRA_UNICODE_LABEL_ISSUE}" "GATE REJECTED"
assert_no_writes "jira/suspicious-unicode-label-no-writes"
export SCRIBE_DRY_RUN="true"

export SCRIBE_JIRA_PROJECT="bad key"
run_test_stdout "jira/invalid-project-key-rejected" "${JIRA_NEW_ISSUE}" "" true
export SCRIBE_JIRA_PROJECT="PROJ"

export JIRA_BASE_URL="https://jira.example.com"
run_test_stdout "jira/non-cloud-base-url-rejected" "${JIRA_NEW_ISSUE}" "" true

unset FULLSEND_TRACKER JIRA_BASE_URL JIRA_USER_EMAIL JIRA_TOKEN SCRIBE_JIRA_PROJECT

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
