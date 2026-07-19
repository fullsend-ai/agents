#!/usr/bin/env bash
# pr-assignee-test.sh — Tests for scripts/lib/pr-assignee.lib.sh
#
# Run from the repo root:
#   bash scripts/pr-assignee-test.sh

set -euo pipefail

if [[ "${SCRIPT_TEST_TARGET:-source}" == "bundled" ]]; then
  echo "SKIP: pr-assignee-test (lib tests skipped in bundled mode)"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pr-assignee.lib.sh
source "${SCRIPT_DIR}/lib/pr-assignee.lib.sh"

FAILURES=0

decide_assign_action() {
  local comments_json="$1"
  local issue_json="$2"
  local existing_assignee_count="$3"

  if [[ "${existing_assignee_count}" != "0" ]]; then
    echo "skip:has-assignees"
    return 0
  fi

  local assignee
  assignee="$(resolve_pr_assignee_from_context "${comments_json}" "${issue_json}" || true)"
  if [[ -z "${assignee}" ]]; then
    echo "skip:no-candidate"
    return 0
  fi

  echo "assign:${assignee}"
}

run_assignee_test() {
  local test_name="$1"
  local comments_json="$2"
  local issue_json="$3"
  local existing_count="$4"
  local expected="$5"

  local actual
  actual="$(decide_assign_action "${comments_json}" "${issue_json}" "${existing_count}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  existing_count: '${existing_count}'"
    echo "  expected:       '${expected}'"
    echo "  actual:         '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_comment_match_test() {
  local test_name="$1"
  local body="$2"
  local expect_match="$3"  # "yes" or "no"

  if comment_is_fs_code "${body}"; then
    if [ "${expect_match}" != "yes" ]; then
      echo "FAIL: ${test_name} (expected no match)"
      FAILURES=$((FAILURES + 1))
      return
    fi
  else
    if [ "${expect_match}" = "yes" ]; then
      echo "FAIL: ${test_name} (expected match)"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi
  echo "PASS: ${test_name}"
}

HUMAN_ISSUE_JSON='{
  "assignees": [{"login": "alice"}],
  "author": {"login": "bob"}
}'

BOT_ISSUE_JSON='{
  "assignees": [{"login": "fullsend-ai-triage[bot]"}],
  "author": {"login": "app/fullsend-ai-retro"}
}'

FS_CODE_COMMENTS='[
  {"user": {"login": "carol"}, "body": "please look"},
  {"user": {"login": "ifireball"}, "body": "/fs-code\n"},
  {"user": {"login": "dave"}, "body": "thanks"}
]'

FS_CODE_FORCE_COMMENTS='[
  {"user": {"login": "alice"}, "body": "/fs-code --force"}
]'

MULTI_FS_CODE_COMMENTS='[
  {"user": {"login": "alice"}, "body": "/fs-code"},
  {"user": {"login": "bob"}, "body": "/fs-code --force"}
]'

BOT_FS_CODE_THEN_HUMAN_ASSIGNEE='[
  {"user": {"login": "fullsend-ai-coder[bot]"}, "body": "/fs-code"}
]'

NO_FS_CODE_COMMENTS='[
  {"user": {"login": "carol"}, "body": "ready when you are"}
]'

# Comment matching (dispatch-compatible)
run_comment_match_test "fs-code-plain" "/fs-code" "yes"
run_comment_match_test "fs-code-force" "/fs-code --force" "yes"
run_comment_match_test "fs-code-crlf" $'/fs-code\r\nmore' "yes"
run_comment_match_test "not-fs-code-midline" "please /fs-code now" "no"
run_comment_match_test "fs-review-not-code" "/fs-review" "no"
run_comment_match_test "empty-body" "" "no"

# Most recent human /fs-code invoker wins over issue assignee and author
run_assignee_test "fs-code-invoker-wins" \
  "${FS_CODE_COMMENTS}" "${HUMAN_ISSUE_JSON}" "0" "assign:ifireball"

# /fs-code --force counts as an invoker
run_assignee_test "fs-code-force-invoker" \
  "${FS_CODE_FORCE_COMMENTS}" "${HUMAN_ISSUE_JSON}" "0" "assign:alice"

# Later /fs-code wins when multiple exist
run_assignee_test "latest-fs-code-wins" \
  "${MULTI_FS_CODE_COMMENTS}" "${HUMAN_ISSUE_JSON}" "0" "assign:bob"

# Bot /fs-code ignored — fall through to human assignee
run_assignee_test "bot-fs-code-uses-human-assignee" \
  "${BOT_FS_CODE_THEN_HUMAN_ASSIGNEE}" "${HUMAN_ISSUE_JSON}" "0" "assign:alice"

# No /fs-code comment — use human assignee
run_assignee_test "no-fs-code-uses-assignee" \
  "${NO_FS_CODE_COMMENTS}" "${HUMAN_ISSUE_JSON}" "0" "assign:alice"

# No /fs-code, no human assignee — use human author
run_assignee_test "no-fs-code-uses-author" \
  "[]" '{"assignees": [], "author": {"login": "bob"}}' "0" "assign:bob"

# All candidates are bots — no assignment
run_assignee_test "all-bot-candidates-no-assign" \
  "${BOT_FS_CODE_THEN_HUMAN_ASSIGNEE}" "${BOT_ISSUE_JSON}" "0" "skip:no-candidate"

# PR already has assignees — no reassignment
run_assignee_test "existing-assignees-skip" \
  "${FS_CODE_COMMENTS}" "${HUMAN_ISSUE_JSON}" "1" "skip:has-assignees"

# dependabot filtered from assignee chain
run_assignee_test "dependabot-filtered" \
  "[]" '{"assignees": [{"login": "dependabot[bot]"}], "author": {"login": "dependabot"}}' "0" "skip:no-candidate"

# dependabotb is human (not matched by dependabot exact name)
run_assignee_test "dependabotb-is-human" \
  "[]" '{"assignees": [], "author": {"login": "dependabotb"}}' "0" "assign:dependabotb"

# Empty comments + empty issue JSON — no candidate
run_assignee_test "empty-context-no-assign" \
  "" "" "0" "skip:no-candidate"

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
