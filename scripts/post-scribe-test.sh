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
FULLSEND_LOG="${TMPDIR}/fullsend-calls.log"
MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"

# Mock fullsend CLI — handles `fullsend issues create --tracker jira`
FULLSEND_ENV_LOG="${TMPDIR}/fullsend-env.log"
cat > "${MOCK_BIN}/fullsend" <<MOCKEOF
#!/usr/bin/env bash
echo "fullsend \$*" >> "${FULLSEND_LOG}"
# Record the Jira credentials the CLI reads from its environment.
echo "token=\${FULLSEND_JIRA_TOKEN-unset} email=\${FULLSEND_JIRA_EMAIL-unset}" >> "${FULLSEND_ENV_LOG}"
if [[ "\$1" == "issues" ]] && [[ "\$2" == "create" ]]; then
  if [[ "\$3" == "--help" ]]; then
    echo "Usage: fullsend issues create [flags]"
    exit 0
  fi
  if [[ -n "\${FULLSEND_MOCK_FAIL_TITLE:-}" ]] && [[ "\$*" == *"--title \${FULLSEND_MOCK_FAIL_TITLE}"* ]]; then
    echo "ERROR: mocked creation failure for \${FULLSEND_MOCK_FAIL_TITLE}" >&2
    exit 1
  fi
  # Read --body from stdin if present (consume it so pipe doesn't break)
  cat > /dev/null
  echo '{"number":100,"key":"PROJ-100","title":"mock title","url":"https://mock.atlassian.net/browse/PROJ-100"}'
  exit 0
fi
exit 1
MOCKEOF
chmod +x "${MOCK_BIN}/fullsend"

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
      elif [[ "\${JIRA_MOCK_REQUIRED_LABELS:-}" == "1" ]]; then
        echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false},{"fieldId":"description","required":false,"hasDefaultValue":false},{"fieldId":"labels","required":true,"hasDefaultValue":false}]}'
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
      elif [[ "\${JIRA_MOCK_BAD_SEARCH:-}" == "islast-false-no-token" ]]; then
        echo '{"issues":[],"isLast":false}'
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
    */issue/PROJ-*)
      # Label PUT on a created issue — log the payload for assertion.
      # DATA may be multi-line (jq pretty-prints), so compact it for grep.
      printf 'LABEL_PUT_DATA=%s\n' "\$(printf '%s' "\${DATA}" | tr -d '[:space:]')" >> "${CURL_LOG}"
      if [[ "\${JIRA_MOCK_LABEL_FAIL:-}" == "1" ]]; then
        # _scribe_jira_add_labels calls _scribe_jira_api_with_status, which
        # calls curl without --fail. Simulate a failure by exiting non-zero
        # so _scribe_jira_api_with_status enters its "curl failed" branch.
        echo "Field labels does not exist" >&2
        exit 1
      fi
      # _scribe_jira_api_with_status uses --write-out '\n%{http_code}' and
      # parses the last line as the HTTP status code. The mock must emit a
      # response body followed by the status code on the last line.
      printf '\n204'
      ;;
    *)
      exit 22
      ;;
  esac
  exit 0
fi

# Slack incoming webhook — success unless fail/timeout markers are set.
# Exit 28 matches curl's timeout status (connection or --max-time).
if [[ "\${URL}" == *"hooks.slack.com"* ]]; then
  if [[ -f "${TMPDIR}/slack-timeout" ]]; then
    exit 28
  fi
  if [[ -f "${TMPDIR}/slack-fail" ]]; then
    exit 1
  fi
  # Capture the piped payload (sent via --data-binary @-) so tests can assert
  # on the notification text (issues #1618, #706).
  SLACK_BODY="\$(cat 2>/dev/null || true)"
  printf 'SLACK_PAYLOAD=%s\n' "\$(printf '%s' "\${SLACK_BODY}" | tr '\n' ' ')" >> "${CURL_LOG}"
  echo "ok"
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

# Fail if the post-script still shells out to bc (not in the runner image).
cat > "${MOCK_BIN}/bc" <<'MOCKEOF'
#!/usr/bin/env bash
echo "bc was invoked" >&2
exit 127
MOCKEOF
chmod +x "${MOCK_BIN}/bc"

export PATH="${MOCK_BIN}:${PATH}"
# Isolate the runner-side scribe workspace so the meta file (no-notes #1618 and
# meeting-title #706) lives under the test tempdir, not the real ${RUNNER_TEMP:-/tmp}.
export RUNNER_TEMP="${TMPDIR}"
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
  : > "${FULLSEND_LOG}"
  : > "${FULLSEND_ENV_LOG}"

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
      if ! grep -qF "${expected_pattern}" "${FULLSEND_LOG}" 2>/dev/null; then
        if ! grep -qF "${expected_pattern}" "${TMPDIR}/stdout.log"; then
          echo "FAIL: ${test_name} — expected pattern '${expected_pattern}' not found"
          echo "stdout:"
          cat "${TMPDIR}/stdout.log"
          echo "gh calls:"
          cat "${GH_LOG}" 2>/dev/null || true
          echo "curl calls:"
          cat "${CURL_LOG}" 2>/dev/null || true
          echo "fullsend calls:"
          cat "${FULLSEND_LOG}" 2>/dev/null || true
          FAILURES=$((FAILURES + 1))
          return
        fi
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
  : > "${FULLSEND_LOG}"
  : > "${FULLSEND_ENV_LOG}"

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

# run_test_content_suppressed — run the post-script and assert that stdout
# contains the expected pattern and never contains the forbidden value.
run_test_content_suppressed() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"
  local forbidden_stdout="$4"
  local expected_rejections="${5:-1}"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${CURL_LOG}"
  : > "${FULLSEND_LOG}"
  : > "${FULLSEND_ENV_LOG}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF "${forbidden_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — forbidden value '${forbidden_stdout}' found in stdout"
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

  if ! grep -qF "Gate rejections: ${expected_rejections}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected Gate rejections: ${expected_rejections}"
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

run_test_stdout "github/confidence-at-threshold-passes" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.6,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "[DRY RUN] Would post comment"

run_test_stdout "github/confidence-decimal-just-below-rejected" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.59,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "GATE REJECTED"

run_test_stdout "github/confidence-equal-decimal-passes" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.60,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "[DRY RUN] Would post comment"

export SCRIBE_MIN_CONFIDENCE="1.5"
run_test_stdout "github/min-confidence-above-one-fails" \
  '{"topics":[],"new_issues":[],"stats":{"notes_processed":0,"topics_extracted":0,"existing_matched":0,"new_proposed":0,"omitted":0}}' \
  "" \
  "true"
unset SCRIBE_MIN_CONFIDENCE

run_test_stdout "github/public-safe-false-rejected" \
  '{"topics":[{"topic":"Comp review","summary":"**Meeting update — 2026-04-28**\n\nSalary discussion.","existing_issue":42,"confidence":0.9,"public_safe":false,"public_safe_category":"hr","omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "content gate: hr"

run_test_stdout "github/sensitive-email-rejected" \
  '{"topics":[{"topic":"Contact follow-up","summary":"**Meeting update — 2026-04-28**\n\nReach out at alice@example.com.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "content gate: sensitive content"
if grep -qF "alice@example.com" "${TMPDIR}/stdout.log"; then
  echo "FAIL: github/sensitive-email-not-in-stdout — sensitive text leaked to stdout"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: github/sensitive-email-not-in-stdout"
fi

run_test_stdout "github/sensitive-title-rejected" \
  '{"topics":[],"new_issues":[{"title":"Contact alice@example.com","summary":"Follow up.","body":"## Problem\nContact.\n\n## Acceptance criteria\n- [ ] Done","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "content gate: sensitive content"
if grep -qF "alice@example.com" "${TMPDIR}/stdout.log"; then
  echo "FAIL: github/sensitive-title-not-in-stdout — sensitive title leaked to stdout"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: github/sensitive-title-not-in-stdout"
fi

# Content gates must run before every gate that prints the title/topic,
# so a low-confidence proposal with sensitive content is never printed.
run_test_content_suppressed "github/low-confidence-sensitive-topic-suppressed" \
  '{"topics":[{"topic":"Ping alice@example.com","summary":"**Meeting update — 2026-04-28**\n\nFollow up.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.2,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "content gate: sensitive content" \
  "alice@example.com"

run_test_content_suppressed "github/low-confidence-sensitive-summary-suppressed" \
  '{"topics":[{"topic":"Payroll followup","summary":"**Meeting update — 2026-04-28**\n\nSSN 123-45-6789.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.2,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "content gate: sensitive content" \
  "Payroll followup"

run_test_content_suppressed "github/invalid-issue-unicode-topic-suppressed" \
  '{"topics":[{"topic":"Hidden\u200bdirective","summary":"**Meeting update — 2026-04-28**\n\nFollow up.","existing_issue":"abc","confidence":0.2,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "content gate: suspicious Unicode" \
  "Hidden"

run_test_content_suppressed "github/omitted-sensitive-topic-suppressed" \
  '{"topics":[{"topic":"Ping alice@example.com","summary":null,"existing_issue":null,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":"not actionable"}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":0,"new_proposed":0,"omitted":1}}' \
  "OMITTED: item 1 of 1 (details suppressed)" \
  "alice@example.com" \
  0

run_test_content_suppressed "github/omitted-clean-topic-unsuppressed" \
  '{"topics":[{"topic":"Rollout followup","summary":null,"existing_issue":null,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":"not actionable"}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":0,"new_proposed":0,"omitted":1}}' \
  "OMITTED: [Rollout followup] — not actionable" \
  "(details suppressed)" \
  0

run_test_content_suppressed "github/no-issue-sensitive-topic-skipped" \
  '{"topics":[{"topic":"Ping alice@example.com","summary":"Follow up.","existing_issue":null,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":0,"new_proposed":0,"omitted":0}}' \
  "Topics processed: 1" \
  "alice@example.com" \
  0

run_test_content_suppressed "github/low-confidence-sensitive-new-issue-title-suppressed" \
  '{"topics":[],"new_issues":[{"title":"Email bob@example.com about rollout","summary":"Rollout.","body":"## Problem\nRollout.\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":0.2,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "content gate: sensitive content" \
  "bob@example.com"

run_test_content_suppressed "github/low-confidence-sensitive-new-issue-body-suppressed" \
  '{"topics":[],"new_issues":[{"title":"Rollout followup","summary":"Rollout.","body":"## Problem\nContact bob@example.com.\n\n## Related\nSource: [Meeting notes](https://docs.google.com/document/d/abc123)","confidence":0.2,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "content gate: sensitive content" \
  "Rollout followup"

run_test_content_suppressed "github/invalid-confidence-unicode-new-issue-suppressed" \
  '{"topics":[],"new_issues":[{"title":"Hidden\u202edirective","summary":"Rollout.","body":"## Problem\nRollout.","confidence":"invalid","public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "content gate: suspicious Unicode" \
  "Hidden"

run_test_content_suppressed "github/sensitive-new-issue-label-suppressed" \
  '{"topics":[],"new_issues":[{"title":"Rollout followup","summary":"Rollout.","body":"## Problem\nRollout.","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes","bob@example.com"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "content gate: sensitive content" \
  "bob@example.com"

# Unbounded fields (labels, omit_reason) larger than the pipe buffer must still
# be scanned in full: a detector whose reader exits early must not report
# "clean" because the writer was killed by SIGPIPE. The match sits on the first
# line and the padding is many short lines (JSON \n escapes, ~600KB decoded —
# well past both the pipe buffer and grep's read buffer), so an early-exiting
# reader stops before the writer has finished.
PADDING="$(printf 'a\\n%.0s' $(seq 1 300000))"
# JSON escape for U+200B (zero-width space), decoded by jq in the post-script.
ZWSP_ESCAPE="\\u200b"

run_test_content_suppressed "github/oversized-omit-reason-sensitive-suppressed" \
  '{"topics":[{"topic":"Rollout followup","summary":null,"existing_issue":null,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":"bob@example.com\n'"${PADDING}"'"}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":0,"new_proposed":0,"omitted":1}}' \
  "OMITTED: item 1 of 1 (details suppressed)" \
  "bob@example.com" \
  0

run_test_content_suppressed "github/oversized-omit-reason-unicode-suppressed" \
  '{"topics":[{"topic":"Rollout followup","summary":null,"existing_issue":null,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":"Hidden'"${ZWSP_ESCAPE}"'directive\n'"${PADDING}"'"}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":0,"new_proposed":0,"omitted":1}}' \
  "OMITTED: item 1 of 1 (details suppressed)" \
  "Hidden" \
  0

run_test_content_suppressed "github/oversized-label-sensitive-suppressed" \
  '{"topics":[],"new_issues":[{"title":"Rollout followup","summary":"Rollout.","body":"## Problem\nRollout.","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes","bob@example.com\n'"${PADDING}"'"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}' \
  "content gate: sensitive content" \
  "bob@example.com"

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

# Omitted and unsafe topics carry summary: null (issue #1838). They must
# never cause writes, and must not suppress a valid actionable topic.
run_test "github/omitted-and-unsafe-null-summary-no-writes" \
  '{"topics":[{"topic":"Low-confidence aside","summary":null,"existing_issue":42,"new_issue_title":null,"confidence":0.3,"public_safe":true,"public_safe_category":null,"omit_reason":"Below confidence threshold"},{"topic":"Unsafe topic","summary":null,"existing_issue":43,"new_issue_title":null,"confidence":0.9,"public_safe":false,"public_safe_category":"hr","omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":2,"existing_matched":0,"new_proposed":0,"omitted":2}}' \
  "OMITTED: [Low-confidence aside]"
if grep -qF "issue comment" "${GH_LOG}"; then
  echo "FAIL: github/omitted-and-unsafe-null-summary-no-writes — omitted/unsafe topic posted a comment"
  FAILURES=$((FAILURES + 1))
fi
if ! grep -qF "content gate: hr" "${TMPDIR}/stdout.log"; then
  echo "FAIL: github/omitted-and-unsafe-null-summary-no-writes — unsafe topic not rejected by content gate"
  FAILURES=$((FAILURES + 1))
fi

run_test "github/mixed-omitted-unsafe-actionable-one-write" \
  '{"topics":[{"topic":"Low-confidence aside","summary":null,"existing_issue":42,"new_issue_title":null,"confidence":0.3,"public_safe":true,"public_safe_category":null,"omit_reason":"Below confidence threshold"},{"topic":"Unsafe topic","summary":null,"existing_issue":43,"new_issue_title":null,"confidence":0.9,"public_safe":false,"public_safe_category":"hr","omit_reason":null},{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\nPoint A.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"new_issue_title":null,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null},{"topic":"Omitted with placeholder","summary":"OMITTED_CONTENT_MARKER","existing_issue":42,"new_issue_title":null,"confidence":0.3,"public_safe":true,"public_safe_category":null,"omit_reason":"Below confidence threshold"}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":4,"existing_matched":1,"new_proposed":0,"omitted":3}}' \
  "gh issue comment 42 --repo mock-org/mock-repo --body-file -"
MIXED_COMMENTS=$(grep -cF "issue comment" "${GH_LOG}" || true)
if [[ "${MIXED_COMMENTS}" -ne 1 ]]; then
  echo "FAIL: github/mixed-omitted-unsafe-actionable-one-write — expected 1 comment, got ${MIXED_COMMENTS}"
  FAILURES=$((FAILURES + 1))
fi
if grep -qF "Dedup: merged" "${TMPDIR}/stdout.log"; then
  echo "FAIL: github/mixed-omitted-unsafe-actionable-one-write — omitted topic was merged into actionable topic"
  FAILURES=$((FAILURES + 1))
fi
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
  : > "${FULLSEND_LOG}"
  : > "${FULLSEND_ENV_LOG}"

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
  "content gate: sensitive content"

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

# Live GitLab writes must succeed even when Slack cannot be notified.
touch "${TMPDIR}/slack-fail"
export SCRIBE_SLACK_WEBHOOK_URL="https://hooks.slack.com/test-webhook"
run_test_stdout "gitlab/live-write-succeeds-when-slack-fails" \
  '{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}' \
  "WARNING: Slack notification failed (non-fatal)"
if ! grep -qF "mock-group%2Fmock-project/issues/42/notes" "${CURL_LOG}"; then
  echo "FAIL: gitlab/live-write-succeeds-when-slack-fails — GitLab write missing from curl log"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
fi
unset SCRIBE_SLACK_WEBHOOK_URL
rm -f "${TMPDIR}/slack-fail"
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

# ---------------------------------------------------------------------------
# Slack notification: best-effort, bounded timeouts, never fails the job
# ---------------------------------------------------------------------------
SLACK_OK_JSON='{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\n**Relevant to this issue:** flaky matrix tests.\n\n[Meeting notes](https://docs.google.com/document/d/abc123)","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}'
SLACK_WEBHOOK_FAKE="https://hooks.slack.com/test-webhook"

run_slack_test() {
  local test_name="$1"
  local slack_result="$2"
  local expected_stdout="$3"
  local expected_curl="${4:-}"

  rm -f "${TMPDIR}/slack-fail" "${TMPDIR}/slack-timeout"
  case "${slack_result}" in
    fail) touch "${TMPDIR}/slack-fail" ;;
    timeout) touch "${TMPDIR}/slack-timeout" ;;
  esac

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${SLACK_OK_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${CURL_LOG}"

  local exit_code=0
  (
    cd "${run_dir}"
    export SCRIBE_SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_FAKE}"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  rm -f "${TMPDIR}/slack-fail" "${TMPDIR}/slack-timeout"

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code} (Slack must be non-fatal)"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF "bc was invoked" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — post-script invoked bc"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_curl}" ]] && ! grep -qF -- "${expected_curl}" "${CURL_LOG}"; then
    echo "FAIL: ${test_name} — expected curl pattern '${expected_curl}' not found"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_slack_test "github/slack-reachable-webhook" "ok" \
  "Slack notification sent" \
  "--connect-timeout 10 --max-time 30"

run_slack_test "github/slack-unreachable-webhook" "fail" \
  "WARNING: Slack notification failed (non-fatal)" \
  "--connect-timeout 10 --max-time 30"

run_slack_test "github/slack-stalled-webhook" "timeout" \
  "WARNING: Slack notification failed (non-fatal)" \
  "--max-time 30"

# --- Jira tracker test cases (FULLSEND_FORGE=github, FULLSEND_TRACKER=jira) ---

JIRA_NEW_ISSUE='{"topics":[],"new_issues":[{"title":"Add dark mode","summary":"Users want dark mode.","body":"## Problem\nNo dark mode.\n\n## Acceptance criteria\n- [ ] Toggle works","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}'
JIRA_REJECTED_ISSUE='{"topics":[],"new_issues":[{"title":"Add dark mode","summary":"Users want dark mode.","body":"Contact jane@example.com","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":1,"omitted":0}}'
JIRA_COMMENT_TOPIC='{"topics":[{"topic":"CI reliability","summary":"**Meeting update — 2026-04-28**\n\nflaky tests.","existing_issue":42,"confidence":0.9,"public_safe":true,"public_safe_category":null,"omit_reason":null}],"new_issues":[],"stats":{"notes_processed":1,"topics_extracted":1,"existing_matched":1,"new_proposed":0,"omitted":0}}'

export FULLSEND_TRACKER="jira"
export JIRA_BASE_URL="https://mock.atlassian.net"
export JIRA_USER_EMAIL="bot@mock.example"
export JIRA_TOKEN="fake-jira-token"
export FULLSEND_DIR="${TMPDIR}/dot-fullsend"
export SCRIBE_JIRA_PROJECT="PROJ"
export SCRIBE_MODE="all"

# Fails if any Jira create (fullsend issues create) or forge write happened.
# The preflight `fullsend issues create --help` is not a write and is excluded.
assert_no_writes() {
  local test_name="$1"
  if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -qvF -- '--help' \
    || grep -qE '^gh issue (create|comment)' "${GH_LOG}" 2>/dev/null; then
    echo "FAIL: ${test_name} — unexpected write call"
    cat "${FULLSEND_LOG}" "${CURL_LOG}" "${GH_LOG}" 2>/dev/null || true
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
if grep -qF 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null \
  && grep -qF -- '--project PROJ' "${FULLSEND_LOG}" 2>/dev/null; then
  echo "PASS: jira/live-create-scoped-to-project"
else
  echo "FAIL: jira/live-create-scoped-to-project — fullsend issues create not called with --project PROJ"
  cat "${FULLSEND_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -qF -- '--token'; then
  echo "FAIL: jira/live-create-no-token-arg — token exposed in command line arguments"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/live-create-no-token-arg"
fi
if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -v -- '--help' \
  | grep -qF -- "--fullsend-dir ${FULLSEND_DIR}" \
  && ! grep -qF -- '--jira-email' "${FULLSEND_LOG}"; then
  echo "PASS: jira/live-create-uses-config-backed-cli"
else
  echo "FAIL: jira/live-create-uses-config-backed-cli — expected --fullsend-dir and no --jira-email"
  cat "${FULLSEND_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
if grep -qF "token=fake-jira-token email=bot@mock.example" "${FULLSEND_ENV_LOG}" 2>/dev/null \
  && grep -qF -- '--user bot@mock.example:fake-jira-token' "${CURL_LOG}" \
  && ! grep -qF -- '--oauth2-bearer' "${CURL_LOG}"; then
  echo "PASS: jira/live-basic-auth-with-email"
else
  echo "FAIL: jira/live-basic-auth-with-email — expected Basic auth and FULLSEND_JIRA_EMAIL for the CLI"
  cat "${FULLSEND_ENV_LOG}" "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# Service account (#1900): an unset, empty, or blank email selects Bearer
# auth for the REST calls and gives the CLI no FULLSEND_JIRA_EMAIL, even
# when one is inherited.
for email_case in unset empty blank; do
  case "${email_case}" in
    unset) unset JIRA_USER_EMAIL ;;
    empty) export JIRA_USER_EMAIL="" ;;
    blank) export JIRA_USER_EMAIL="  " ;;
  esac
  FULLSEND_JIRA_EMAIL="inherited@mock.example" \
    run_test_stdout "jira/live-bearer-auth-email-${email_case}" "${JIRA_NEW_ISSUE}" \
    "Created: https://mock.atlassian.net/browse/PROJ-100"
  if grep -qF -- '--oauth2-bearer fake-jira-token' "${CURL_LOG}" \
    && ! grep -qF -- '--user' "${CURL_LOG}" \
    && grep -qF "token=fake-jira-token email=unset" "${FULLSEND_ENV_LOG}" \
    && ! grep -qF "token=fake-jira-token email=inherited" "${FULLSEND_ENV_LOG}"; then
    echo "PASS: jira/live-bearer-auth-email-${email_case}-no-basic"
  else
    echo "FAIL: jira/live-bearer-auth-email-${email_case}-no-basic — expected Bearer auth and no CLI email"
    cat "${FULLSEND_ENV_LOG}" "${CURL_LOG}" 2>/dev/null || true
    FAILURES=$((FAILURES + 1))
  fi
done
export JIRA_USER_EMAIL="bot@mock.example"

# The config-backed CLI needs FULLSEND_DIR for tracker.jira.
unset FULLSEND_DIR
run_test_stdout "jira/live-missing-fullsend-dir-fails" "${JIRA_NEW_ISSUE}" "" true
export FULLSEND_DIR="${TMPDIR}/dot-fullsend"
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

export JIRA_MOCK_REQUIRED_LABELS="1"
run_test_stdout "jira/required-labels-fails-before-create" "${JIRA_NEW_ISSUE}" "" true
if grep -qF "requires fields scribe does not set: labels" "${TMPDIR}/stdout.log"; then
  echo "PASS: jira/required-labels-error-message"
else
  echo "FAIL: jira/required-labels-error-message"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
fi
assert_no_writes "jira/required-labels-no-writes"
unset JIRA_MOCK_REQUIRED_LABELS

# A search response that is not JSON, or has no issues array, must not be
# read as "no duplicate": refuse to create.
for bad_search in html no-issues islast-false-no-token; do
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
  if [[ "${bad_search}" == "islast-false-no-token" ]]; then
    if grep -qF "ERROR: Jira JQL search returned isLast=false with no nextPageToken" "${TMPDIR}/stdout.log"; then
      echo "PASS: jira/malformed-search-islast-false-specific-error-message"
    else
      echo "FAIL: jira/malformed-search-islast-false-specific-error-message"
      cat "${TMPDIR}/stdout.log"
      FAILURES=$((FAILURES + 1))
    fi
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

# Create screen without Labels: the label PUT must not be sent.
export JIRA_MOCK_NO_LABELS="1"
run_test_stdout "jira/live-no-labels-field-creates-without-labels" "${JIRA_NEW_ISSUE}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF 'issue/PROJ-' "${CURL_LOG}" 2>/dev/null; then
  echo "FAIL: jira/no-labels-field-payload-omits-labels — label PUT sent"
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
if grep -qF "jane@example.com" "${TMPDIR}/stdout.log"; then
  echo "FAIL: jira/sensitive-label-not-in-stdout — sensitive label leaked to stdout"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/sensitive-label-not-in-stdout"
fi
JIRA_UNICODE_LABEL_ISSUE="${JIRA_NEW_ISSUE//\"meeting-notes\"/\"notes\\u200bx\"}"
run_test_stdout "jira/live-suspicious-unicode-label-rejected" "${JIRA_UNICODE_LABEL_ISSUE}" "GATE REJECTED"
assert_no_writes "jira/suspicious-unicode-label-no-writes"

# Large multiline label list: verify that pipefail does not cause early-exit SIGPIPE to drop detection
LARGE_LABELS_JSON=$(jq -cn '["confidential@example.com"] + [range(500) | "label\(.)"]')
JIRA_LARGE_SENSITIVE_LABELS_ISSUE=$(echo "${JIRA_NEW_ISSUE}" | jq -c --argjson l "${LARGE_LABELS_JSON}" '.new_issues[0].labels = $l')
run_test_stdout "jira/live-large-sensitive-label-rejected" "${JIRA_LARGE_SENSITIVE_LABELS_ISSUE}" "GATE REJECTED"
assert_no_writes "jira/large-sensitive-label-no-writes"
if grep -qF "confidential@example.com" "${TMPDIR}/stdout.log"; then
  echo "FAIL: jira/large-sensitive-label-not-in-stdout — sensitive label leaked to stdout"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/large-sensitive-label-not-in-stdout"
fi
export SCRIBE_DRY_RUN="true"

# Label PUT payload shape: verify that the PUT sends the correct
# {update:{labels:[{add:"meeting-notes"}]}} structure.
export SCRIBE_DRY_RUN="false"
: > "${CURL_LOG}"
run_test_stdout "jira/live-label-put-payload-shape" "${JIRA_NEW_ISSUE}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF 'LABEL_PUT_DATA=' "${CURL_LOG}" 2>/dev/null; then
  # The DATA variable captured by the mock may contain multiline jq output.
  # Extract everything after LABEL_PUT_DATA= on that line.
  LABEL_DATA=$(sed -n 's/^LABEL_PUT_DATA=//p' "${CURL_LOG}" | head -1)
  if echo "${LABEL_DATA}" | jq -e '.update.labels | length > 0' >/dev/null 2>&1 \
    && echo "${LABEL_DATA}" | jq -e '.update.labels[0].add == "meeting-notes"' >/dev/null 2>&1; then
    echo "PASS: jira/label-put-payload-has-update-labels-add"
  else
    echo "FAIL: jira/label-put-payload-has-update-labels-add — unexpected payload: ${LABEL_DATA}"
    FAILURES=$((FAILURES + 1))
  fi
else
  echo "FAIL: jira/label-put-payload-shape — no label PUT recorded"
  cat "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# Allowlist filtering: agent-proposed labels not in allowlist are excluded
JIRA_UNALLOWLISTED_LABELS_ISSUE=$(echo "${JIRA_NEW_ISSUE}" | jq -c '.new_issues[0].labels = ["meeting-notes", "release-blocker", "do-not-triage"]')
run_test_stdout "jira/live-unallowlisted-labels-filtered" "${JIRA_UNALLOWLISTED_LABELS_ISSUE}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
LABEL_DATA=$(sed -n 's/^LABEL_PUT_DATA=//p' "${CURL_LOG}" | head -1)
if echo "${LABEL_DATA}" | jq -e '.update.labels == [{"add":"meeting-notes"}]' >/dev/null 2>&1; then
  echo "PASS: jira/unallowlisted-labels-excluded-from-put"
else
  echo "FAIL: jira/unallowlisted-labels-excluded-from-put — unexpected payload: ${LABEL_DATA}"
  FAILURES=$((FAILURES + 1))
fi

# Custom allowlist: operator-specified allowlist permits multiple configured labels
export SCRIBE_JIRA_LABELS="meeting-notes,team-a"
JIRA_CUSTOM_ALLOWLIST_ISSUE=$(echo "${JIRA_NEW_ISSUE}" | jq -c '.new_issues[0].labels = ["meeting-notes", "team-a", "unapproved"]')
run_test_stdout "jira/live-custom-allowlist-applied" "${JIRA_CUSTOM_ALLOWLIST_ISSUE}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
LABEL_DATA=$(sed -n 's/^LABEL_PUT_DATA=//p' "${CURL_LOG}" | head -1)
if echo "${LABEL_DATA}" | jq -e '.update.labels == [{"add":"meeting-notes"},{"add":"team-a"}]' >/dev/null 2>&1; then
  echo "PASS: jira/custom-allowlist-permitted-labels"
else
  echo "FAIL: jira/custom-allowlist-permitted-labels — unexpected payload: ${LABEL_DATA}"
  FAILURES=$((FAILURES + 1))
fi
unset SCRIBE_JIRA_LABELS

# Label with comma is rejected by format regex and not split into multiple labels
JIRA_COMMA_LABEL_ISSUE=$(echo "${JIRA_NEW_ISSUE}" | jq -c '.new_issues[0].labels = ["label,with,comma", "meeting-notes"]')
run_test_stdout "jira/live-label-with-comma-rejected-not-split" "${JIRA_COMMA_LABEL_ISSUE}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
LABEL_DATA=$(sed -n 's/^LABEL_PUT_DATA=//p' "${CURL_LOG}" | head -1)
if echo "${LABEL_DATA}" | jq -e '.update.labels == [{"add":"meeting-notes"}]' >/dev/null 2>&1; then
  echo "PASS: jira/label-with-comma-rejected-and-not-split"
else
  echo "FAIL: jira/label-with-comma-rejected-and-not-split — unexpected payload: ${LABEL_DATA}"
  FAILURES=$((FAILURES + 1))
fi

# Label exceeding 64 chars is filtered out by format regex even when allowlisted;
# 64-char boundary label is preserved.
LONG_LABEL="this-label-is-sixty-five-characters-long-which-exceeds-the-max-65"
BOUNDARY_64_LABEL="label-with-exact-length-of-sixty-four-characters-boundary-case64"
export SCRIBE_JIRA_LABELS="meeting-notes,${LONG_LABEL},${BOUNDARY_64_LABEL}"
JIRA_LONG_LABEL_ISSUE=$(echo "${JIRA_NEW_ISSUE}" | jq -c --arg long "${LONG_LABEL}" --arg b64 "${BOUNDARY_64_LABEL}" \
  '.new_issues[0].labels = [$long, $b64, "meeting-notes"]')
run_test_stdout "jira/live-label-over-64-chars-filtered" "${JIRA_LONG_LABEL_ISSUE}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
LABEL_DATA=$(sed -n 's/^LABEL_PUT_DATA=//p' "${CURL_LOG}" | head -1)
if echo "${LABEL_DATA}" | jq -e --arg b64 "${BOUNDARY_64_LABEL}" \
  '.update.labels == [{"add":$b64},{"add":"meeting-notes"}]' >/dev/null 2>&1; then
  echo "PASS: jira/label-over-64-chars-filtered"
else
  echo "FAIL: jira/label-over-64-chars-filtered — unexpected payload: ${LABEL_DATA}"
  FAILURES=$((FAILURES + 1))
fi
unset SCRIBE_JIRA_LABELS

# Label count capped at 10
export SCRIBE_JIRA_LABELS="l1,l2,l3,l4,l5,l6,l7,l8,l9,l10,l11,l12"
TWELVE_LABELS_JSON=$(jq -cn '[range(1; 13) | "l\(.)"]')
JIRA_MANY_LABELS_ISSUE=$(echo "${JIRA_NEW_ISSUE}" | jq -c --argjson l "${TWELVE_LABELS_JSON}" '.new_issues[0].labels = $l')
run_test_stdout "jira/live-label-count-capped-at-10" "${JIRA_MANY_LABELS_ISSUE}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
LABEL_DATA=$(sed -n 's/^LABEL_PUT_DATA=//p' "${CURL_LOG}" | head -1)
LABEL_COUNT=$(echo "${LABEL_DATA}" | jq -r '.update.labels | length' 2>/dev/null || echo 0)
if [[ "${LABEL_COUNT}" -eq 10 ]]; then
  echo "PASS: jira/label-count-capped-at-10"
else
  echo "FAIL: jira/label-count-capped-at-10 — expected 10 labels, got ${LABEL_COUNT} (payload: ${LABEL_DATA})"
  FAILURES=$((FAILURES + 1))
fi
unset SCRIBE_JIRA_LABELS

# When all proposed labels are unallowlisted, issue is created without label PUT
JIRA_NO_ALLOWED_LABELS_ISSUE=$(echo "${JIRA_NEW_ISSUE}" | jq -c '.new_issues[0].labels = ["unapproved-label"]')
run_test_stdout "jira/live-all-unallowlisted-omits-put" "${JIRA_NO_ALLOWED_LABELS_ISSUE}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF 'LABEL_PUT_DATA=' "${CURL_LOG}" 2>/dev/null; then
  echo "FAIL: jira/all-unallowlisted-omits-put — unexpected label PUT sent"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/all-unallowlisted-omits-put"
fi

# Dry run reflects filtered labels in output
export SCRIBE_DRY_RUN="true"
JIRA_DRY_RUN_FILTER_ISSUE=$(echo "${JIRA_NEW_ISSUE}" | jq -c '.new_issues[0].labels = ["meeting-notes", "unapproved-label"]')
run_test_stdout "jira/dry-run-filters-labels-in-output" "${JIRA_DRY_RUN_FILTER_ISSUE}" \
  "[DRY RUN] Labels: meeting-notes"
if grep -qF "unapproved-label" "${TMPDIR}/stdout.log"; then
  echo "FAIL: jira/dry-run-filters-labels-in-output — unapproved label leaked into stdout"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/dry-run-excludes-unapproved-label-from-stdout"
fi
export SCRIBE_DRY_RUN="false"

# Label PUT failure: verify the issue is still created but the failure
# is surfaced in the console summary.
export JIRA_MOCK_LABEL_FAIL="1"
run_test_stdout "jira/live-label-put-failure-surfaced" "${JIRA_NEW_ISSUE}" \
  "Label failures: 1 issue(s) created without labels"
if grep -qF "Created: https://mock.atlassian.net/browse/PROJ-100" "${TMPDIR}/stdout.log"; then
  echo "PASS: jira/label-put-failure-issue-still-created"
else
  echo "FAIL: jira/label-put-failure-issue-still-created — issue not created"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
fi
unset JIRA_MOCK_LABEL_FAIL

# Missing fullsend CLI: verify preflight check catches it.
# Replace the mock fullsend with one that rejects `issues create --help`.
cat > "${MOCK_BIN}/fullsend" <<'NOCLIMOCK'
#!/usr/bin/env bash
# Simulate an old fullsend that does not have `issues create`
echo "fullsend: unknown command \"issues\"" >&2
exit 1
NOCLIMOCK
chmod +x "${MOCK_BIN}/fullsend"
run_test_stdout "jira/missing-cli-subcommand-fails-preflight" "${JIRA_NEW_ISSUE}" "" true
if grep -qF "fullsend issues create" "${TMPDIR}/stdout.log"; then
  echo "PASS: jira/missing-cli-error-message"
else
  echo "FAIL: jira/missing-cli-error-message — expected error about missing CLI"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
fi
assert_no_writes "jira/missing-cli-no-jira-writes"
# Restore the working mock.
cat > "${MOCK_BIN}/fullsend" <<MOCKEOF
#!/usr/bin/env bash
echo "fullsend \$*" >> "${FULLSEND_LOG}"
if [[ "\$1" == "issues" ]] && [[ "\$2" == "create" ]]; then
  if [[ "\$3" == "--help" ]]; then
    echo "Usage: fullsend issues create [flags]"
    exit 0
  fi
  if [[ -n "\${FULLSEND_MOCK_FAIL_TITLE:-}" ]] && [[ "\$*" == *"--title \${FULLSEND_MOCK_FAIL_TITLE}"* ]]; then
    echo "ERROR: mocked creation failure for \${FULLSEND_MOCK_FAIL_TITLE}" >&2
    exit 1
  fi
  cat > /dev/null
  echo '{"number":100,"key":"PROJ-100","title":"mock title","url":"https://mock.atlassian.net/browse/PROJ-100"}'
  exit 0
fi
exit 1
MOCKEOF
chmod +x "${MOCK_BIN}/fullsend"

# Single failed create: verify that a run with only one failing proposal exits nonzero
export SCRIBE_DRY_RUN="false"
export FULLSEND_MOCK_FAIL_TITLE="Add dark mode"
run_test_stdout "jira/single-failed-create-exits-nonzero" "${JIRA_NEW_ISSUE}" "" true
if grep -qF "New issues created: 0" "${TMPDIR}/stdout.log"; then
  echo "PASS: jira/single-failed-create-zero-created"
else
  echo "FAIL: jira/single-failed-create-zero-created"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
fi
unset FULLSEND_MOCK_FAIL_TITLE

# Failed create followed by a successful create: verify that the failed proposal's
# title is removed from NEW_ISSUE_TITLES, subsequent successful proposals remain
# properly aligned in the summary and step summary, and the run exits non-zero.
JIRA_TWO_ISSUES='{"topics":[],"new_issues":[{"title":"First will fail","summary":"Summary 1","body":"Body 1","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]},{"title":"Second will succeed","summary":"Summary 2","body":"Body 2","confidence":0.9,"public_safe":true,"public_safe_category":null,"labels":["meeting-notes"]}],"stats":{"notes_processed":1,"topics_extracted":0,"existing_matched":0,"new_proposed":2,"omitted":0}}'
export FULLSEND_MOCK_FAIL_TITLE="First will fail"
export GITHUB_STEP_SUMMARY="${TMPDIR}/step-summary-create-fail.md"
: > "${GITHUB_STEP_SUMMARY}"
run_test_stdout "jira/failed-create-removes-title-and-exits-nonzero" "${JIRA_TWO_ISSUES}" "" true

if grep -qF "New issues created: 1" "${TMPDIR}/stdout.log"; then
  echo "PASS: jira/failed-create-title-removed-from-summary"
else
  echo "FAIL: jira/failed-create-title-removed-from-summary — unexpected summary count"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
fi

if grep -qF -- "[Second will succeed](https://mock.atlassian.net/browse/PROJ-100)" "${GITHUB_STEP_SUMMARY}" 2>/dev/null; then
  echo "PASS: jira/failed-create-subsequent-url-aligned-with-correct-title"
else
  echo "FAIL: jira/failed-create-subsequent-url-aligned-with-correct-title — wrong title-URL pair in step summary"
  cat "${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

if grep -qF "issue creation(s) failed" "${TMPDIR}/stdout.log"; then
  echo "PASS: jira/failed-create-error-message-on-exit"
else
  echo "FAIL: jira/failed-create-error-message-on-exit — expected exit error not found"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
fi
unset FULLSEND_MOCK_FAIL_TITLE GITHUB_STEP_SUMMARY
export SCRIBE_DRY_RUN="true"

export SCRIBE_JIRA_PROJECT="bad key"
run_test_stdout "jira/invalid-project-key-rejected" "${JIRA_NEW_ISSUE}" "" true
export SCRIBE_JIRA_PROJECT="PROJ"

export JIRA_BASE_URL="https://jira.example.com"
run_test_stdout "jira/non-cloud-base-url-rejected" "${JIRA_NEW_ISSUE}" "" true

unset FULLSEND_TRACKER JIRA_BASE_URL JIRA_USER_EMAIL JIRA_TOKEN SCRIBE_JIRA_PROJECT

# ============================================================
# No-notes notification (#1618) and meeting title (#706)
# ============================================================
# pre-scribe writes ${RUNNER_TEMP}/scribe-workspace/scribe-meta.json; post-scribe
# reads docs_downloaded (no-notes gate) and doc_names (meeting title) from it. A
# confirmed numeric 0 with an empty result yields the concise no-notes message;
# doc_names are untrusted Drive titles rendered on a sanitized "Meeting:" line.
SCRIBE_META_DIR="${RUNNER_TEMP}/scribe-workspace"
mkdir -p "${SCRIBE_META_DIR}"
EMPTY_RESULT='{"topics":[],"new_issues":[]}'

run_no_notes_test() {
  local test_name="$1" meta_json="$2" result_json="$3" must_contain="$4" must_not="$5"
  local run_dir="${TMPDIR}/run-${test_name//\//-}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${result_json}" > "${run_dir}/iteration-1/output/agent-result.json"
  rm -f "${TMPDIR}/slack-fail" "${TMPDIR}/slack-timeout"
  rm -f "${SCRIBE_META_DIR}/scribe-meta.json"
  [[ -n "${meta_json}" ]] && printf '%s' "${meta_json}" > "${SCRIBE_META_DIR}/scribe-meta.json"
  : > "${CURL_LOG}"
  : > "${GH_LOG}"

  # Scope the webhook to the command (not a top-level export) so it does not
  # collide with run_slack_test's subshell-local use (shellcheck SC2030/SC2031).
  local exit_code=0
  (cd "${run_dir}" && SCRIBE_SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_FAKE}" bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [[ -n "${must_contain}" ]] && ! grep -qF "${must_contain}" "${CURL_LOG}"; then
    echo "FAIL: ${test_name} — expected '${must_contain}' in Slack payload"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [[ -n "${must_not}" ]] && grep -qF "${must_not}" "${CURL_LOG}"; then
    echo "FAIL: ${test_name} — unexpected '${must_not}' in Slack payload"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# run_meeting_test NAME META_JSON MUST_CONTAIN MUST_NOT — a no-notes test with an
# empty agent result, used for the meeting-title (#706) Slack assertions.
run_meeting_test() {
  run_no_notes_test "$1" "$2" "${EMPTY_RESULT}" "$3" "$4"
}

export SCRIBE_MODE="all"

export SCRIBE_DRY_RUN="true"
run_no_notes_test "no-notes/empty-search-message" \
  '{"docs_downloaded":0}' "${EMPTY_RESULT}" \
  "No meeting notes found for today." "Topics processed"

# DRY RUN: label is kept on the no-notes path (must_not proves the branch fired,
# since "Topics processed" only appears in the normal activity report).
run_no_notes_test "no-notes/dry-run-keeps-label" \
  '{"docs_downloaded":0}' "${EMPTY_RESULT}" \
  "Scribe agent* (DRY RUN)" "Topics processed"

# LIVE: label and View run link are kept on the no-notes path. must_not is
# "Topics processed" so these fail if the no-notes branch stops firing.
export SCRIBE_DRY_RUN="false"
run_no_notes_test "no-notes/live-keeps-label" \
  '{"docs_downloaded":0}' "${EMPTY_RESULT}" \
  "Scribe agent* (LIVE)" "Topics processed"
run_no_notes_test "no-notes/live-keeps-view-run-link" \
  '{"docs_downloaded":0}' "${EMPTY_RESULT}" \
  "View run" "Topics processed"
export SCRIBE_DRY_RUN="true"

run_no_notes_test "no-notes/notes-with-zero-topics-keeps-report" \
  '{"docs_downloaded":3}' "${EMPTY_RESULT}" \
  "Topics processed" "No meeting notes found for today."

run_no_notes_test "no-notes/missing-meta-no-false-positive" \
  "" "${EMPTY_RESULT}" \
  "Topics processed" "No meeting notes found for today."

run_no_notes_test "no-notes/non-numeric-meta-no-false-positive" \
  '{"docs_downloaded":"nan"}' "${EMPTY_RESULT}" \
  "Topics processed" "No meeting notes found for today."

# Invalid JSON must hit the `jq -e .` guard and not trigger the no-notes message.
run_no_notes_test "no-notes/malformed-meta-no-false-positive" \
  '{"docs_downloaded":' "${EMPTY_RESULT}" \
  "Topics processed" "No meeting notes found for today."

# Valid JSON with a NON-object root must not abort the run (reading
# .docs_downloaded on it errors with jq exit 5): treat as invalid, keep the
# normal report. run_no_notes_test fails on any non-zero exit, so these also
# guard against the script aborting before summary/Slack delivery.
run_no_notes_test "no-notes/array-root-meta-no-abort" \
  '[]' "${EMPTY_RESULT}" \
  "Topics processed" "No meeting notes found for today."
run_no_notes_test "no-notes/string-root-meta-no-abort" \
  '"bad"' "${EMPTY_RESULT}" \
  "Topics processed" "No meeting notes found for today."
run_no_notes_test "no-notes/number-root-meta-no-abort" \
  '123' "${EMPTY_RESULT}" \
  "Topics processed" "No meeting notes found for today."
run_no_notes_test "no-notes/bool-root-meta-no-abort" \
  'true' "${EMPTY_RESULT}" \
  "Topics processed" "No meeting notes found for today."

# Zero-document search but the agent still produced an actionable result: the
# post-script acts on it, so the activity report must win over the no-notes line.
run_no_notes_test "no-notes/empty-search-with-actionable-result-keeps-report" \
  '{"docs_downloaded":0}' \
  '{"topics":[{"topic":"leftover","summary":"s","confidence":0.99,"public_safe":true,"public_safe_category":null,"existing_issue":1}],"new_issues":[]}' \
  "Topics processed" "No meeting notes found for today."

# comments_only + zero-document search + leftover new_issues: the proposals are
# skipped by mode (so never created), but the agent still produced them, so the
# activity report must win over the no-notes message. The gate reads the raw
# .topics/.new_issues counts from RESULT_FILE, so mode zeroing of
# NEW_COUNT/TOPIC_COUNT cannot hide these proposals.
export SCRIBE_MODE="comments_only"
run_no_notes_test "no-notes/empty-search-skipped-new-issues-keeps-report" \
  '{"docs_downloaded":0}' \
  '{"topics":[],"new_issues":[{"title":"Leftover proposal","summary":"s","body":"b","confidence":0.99,"public_safe":true,"public_safe_category":null,"labels":[]}]}' \
  "Topics processed" "No meeting notes found for today."
export SCRIBE_MODE="all"

# --- Meeting title cases (issue #706) ---
export SCRIBE_DRY_RUN="true"

# Single doc: title appears on a Meeting: line.
run_meeting_test "meeting/single-doc-title" \
  '{"docs_downloaded":1,"doc_names":["Team Sync - 2026/08/06"]}' \
  "Meeting: Team Sync - 2026/08/06" ""

# Multiple docs: count header plus each title listed.
run_meeting_test "meeting/multi-doc-titles" \
  '{"docs_downloaded":2,"doc_names":["Team Sync","User Forum"]}' \
  "Meetings (2):" ""
run_meeting_test "meeting/multi-doc-second-title" \
  '{"docs_downloaded":2,"doc_names":["Team Sync","User Forum"]}' \
  "User Forum" ""

# Missing meta / absent field: no Meeting line, no crash.
run_meeting_test "meeting/missing-meta-no-line" \
  "" "View run" "Meeting"
run_meeting_test "meeting/absent-field-no-line" \
  '{"docs_downloaded":1}' "View run" "Meeting"

# Untrusted title: newline must not inject an extra line, and mrkdwn/link
# metacharacters must be escaped (issue #706 — doc names are untrusted input).
run_meeting_test "meeting/untrusted-title-newline-stripped" \
  '{"docs_downloaded":1,"doc_names":["Evil\n• Topics processed: *999*"]}' \
  "Meeting: Evil• Topics processed:" "Meeting: Evil\n"
run_meeting_test "meeting/untrusted-title-mrkdwn-escaped" \
  '{"docs_downloaded":1,"doc_names":["<https://evil|x> & <y>"]}' \
  "&lt;https://evil¦x&gt; &amp; &lt;y&gt;" ""

# Untrusted title with a literal backslash escape: SLACK_TEXT is expanded with
# printf '%b', so an un-doubled "\c" would truncate the message (dropping the
# counters and View run link) and "\n" would inject a line. The backslash is now
# doubled before display, so the full message is still delivered.
run_meeting_test "meeting/untrusted-title-backslash-no-truncate" \
  '{"docs_downloaded":1,"doc_names":["Evil\\cTITLE"]}' \
  "View run" ""

# Hex escape must not be decoded by printf '%b' into a Slack mention/link that
# bypasses the mrkdwn escaping — "\x3c!channel\x3e" must stay literal, not "<!channel>".
run_meeting_test "meeting/untrusted-title-hex-escape-not-decoded" \
  '{"docs_downloaded":1,"doc_names":["\\x3c!channel\\x3e ping"]}' \
  "View run" "<!channel>"

# Empty title must be skipped without aborting the run (notification still sent).
run_meeting_test "meeting/empty-title-skipped" \
  '{"docs_downloaded":1,"doc_names":[""]}' \
  "View run" "Meeting"

rm -f "${SCRIBE_META_DIR}/scribe-meta.json"

# Step-summary (GitHub Markdown/HTML): an untrusted title with a Markdown link or
# raw HTML must be escaped so it does not render as an active link (issue #706).
run_md_summary_test() {
  local test_name="$1" meta_json="$2" must_contain="$3" must_not="$4"
  local run_dir="${TMPDIR}/run-${test_name//\//-}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${EMPTY_RESULT}" > "${run_dir}/iteration-1/output/agent-result.json"
  rm -f "${SCRIBE_META_DIR}/scribe-meta.json"
  printf '%s' "${meta_json}" > "${SCRIBE_META_DIR}/scribe-meta.json"
  local summary="${TMPDIR}/step-summary-${test_name//\//-}.md"
  : > "${summary}"
  local exit_code=0
  (cd "${run_dir}" && GITHUB_STEP_SUMMARY="${summary}" bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"; cat "${TMPDIR}/stdout.log"; FAILURES=$((FAILURES + 1)); return
  fi
  if ! grep -qF -- "${must_contain}" "${summary}"; then
    echo "FAIL: ${test_name} — expected '${must_contain}' in step summary"; cat "${summary}"; FAILURES=$((FAILURES + 1)); return
  fi
  if grep -qF -- "${must_not}" "${summary}"; then
    echo "FAIL: ${test_name} — unexpected '${must_not}' in step summary"; cat "${summary}"; FAILURES=$((FAILURES + 1)); return
  fi
  echo "PASS: ${test_name}"
}

run_md_summary_test "meeting/step-summary-markdown-link-escaped" \
  '{"docs_downloaded":1,"doc_names":["[click](http://evil.example)"]}' \
  '\[click\](http://evil.example)' '[click](http://evil.example)'
run_md_summary_test "meeting/step-summary-html-escaped" \
  '{"docs_downloaded":1,"doc_names":["<a href=\"http://evil\">x</a>"]}' \
  '&lt;a href=' '<a href='

rm -f "${SCRIBE_META_DIR}/scribe-meta.json"

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
