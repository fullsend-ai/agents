#!/usr/bin/env bash
# post-refine-test.sh — Test the plan-summary and label logic from post-refine.sh.
#
# Extracts and tests key decision logic in isolation using shell functions.
# This avoids needing comment-helpers.sh or a live GitHub/Jira API.
#
# Run from the repo root:
#   bash scripts/post-refine-test.sh

set -euo pipefail

FAILURES=0

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

run_test() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"

  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL: ${test_name}"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# ---------------------------------------------------------------------------
# Reply target determination — mirrors logic from post-refine.sh
# ---------------------------------------------------------------------------

determine_reply_target() {
  local github_issue_number="${1:-}"
  local issue_source="${2:-}"
  # Third arg (issue_key) is unused — kept for call-site parity with post-refine.sh
  # shellcheck disable=SC2034
  local issue_key="${3:-}"

  local use_github=false
  if [[ -n "${github_issue_number}" && "${github_issue_number}" != "" && "${github_issue_number}" != "N/A" ]]; then
    use_github=true
  elif [[ "${issue_source}" == "github" ]]; then
    use_github=true
  fi

  if $use_github; then
    echo "github"
  else
    echo "jira"
  fi
}

run_test "reply-target-github-explicit" \
  "github" "$(determine_reply_target "42" "github" "42")"

run_test "reply-target-github-from-source" \
  "github" "$(determine_reply_target "" "github" "42")"

run_test "reply-target-jira" \
  "jira" "$(determine_reply_target "" "jira" "PROJ-123")"

run_test "reply-target-na-falls-to-jira" \
  "jira" "$(determine_reply_target "N/A" "jira" "PROJ-123")"

run_test "reply-target-empty-falls-to-jira" \
  "jira" "$(determine_reply_target "" "jira" "PROJ-123")"

# ---------------------------------------------------------------------------
# Plan summary construction — mirrors logic from post-refine.sh
# ---------------------------------------------------------------------------

build_plan_summary() {
  local child_count="$1"
  local epic_count="$2"
  local story_count="$3"
  local task_count="$4"
  local open_question_count="$5"

  local summary="Proposed: ${child_count} work items"
  local parts=()
  [[ "$epic_count" -gt 0 ]] && parts+=("${epic_count} epics")
  [[ "$story_count" -gt 0 ]] && parts+=("${story_count} stories")
  [[ "$task_count" -gt 0 ]] && parts+=("${task_count} tasks")
  if [[ ${#parts[@]} -gt 0 ]]; then
    local joined=""
    for i in "${!parts[@]}"; do
      [[ $i -gt 0 ]] && joined+=", "
      joined+="${parts[$i]}"
    done
    summary="${summary} (${joined})"
  fi

  if [[ "$open_question_count" -gt 0 ]]; then
    summary="${summary} · ${open_question_count} open question(s)"
  fi

  echo "$summary"
}

run_test "plan-summary-full" \
  "Proposed: 15 work items (3 epics, 8 stories, 4 tasks) · 2 open question(s)" \
  "$(build_plan_summary 15 3 8 4 2)"

run_test "plan-summary-no-questions" \
  "Proposed: 6 work items (1 epics, 3 stories, 2 tasks)" \
  "$(build_plan_summary 6 1 3 2 0)"

run_test "plan-summary-stories-only" \
  "Proposed: 3 work items (3 stories)" \
  "$(build_plan_summary 3 0 3 0 0)"

run_test "plan-summary-tasks-only" \
  "Proposed: 2 work items (2 tasks)" \
  "$(build_plan_summary 2 0 0 2 0)"

run_test "plan-summary-no-typed-children" \
  "Proposed: 1 work items" \
  "$(build_plan_summary 1 0 0 0 0)"

# ---------------------------------------------------------------------------
# Revision detection — mirrors logic from post-refine.sh
# ---------------------------------------------------------------------------

is_revision() {
  local review_round="${1:-1}"
  if [[ "$review_round" -gt 1 ]]; then
    echo "true"
  else
    echo "false"
  fi
}

run_test "is-revision-round-1" "false" "$(is_revision 1)"
run_test "is-revision-round-2" "true" "$(is_revision 2)"
run_test "is-revision-round-3" "true" "$(is_revision 3)"

# ---------------------------------------------------------------------------
# Label payload construction — mirrors logic from post-refine.sh
# ---------------------------------------------------------------------------

build_label_payload() {
  local review_round="${1:-1}"

  if [[ "$review_round" -gt 1 ]]; then
    echo "[\"ready-to-critique\",\"refine-revision-round-${review_round}\"]"
  else
    echo '["ready-to-critique"]'
  fi
}

run_test "label-payload-round-1" \
  '["ready-to-critique"]' \
  "$(build_label_payload 1)"

run_test "label-payload-round-2" \
  '["ready-to-critique","refine-revision-round-2"]' \
  "$(build_label_payload 2)"

run_test "label-payload-round-3" \
  '["ready-to-critique","refine-revision-round-3"]' \
  "$(build_label_payload 3)"

# ---------------------------------------------------------------------------
# Result file discovery — mirrors the iteration-*/output search in post-refine.sh
# ---------------------------------------------------------------------------

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

test_result_file_discovery() {
  local test_name="$1"
  local expected_iteration="$2"

  local run_dir="${TMPDIR}/run-${test_name}"
  rm -rf "${run_dir}"

  # Create multiple iterations — script should pick the last one
  for iter in 1 2 3; do
    mkdir -p "${run_dir}/iteration-${iter}/output"
    echo "{\"iteration\": ${iter}}" > "${run_dir}/iteration-${iter}/output/agent-result.json"
  done

  local result_file=""
  for dir in "${run_dir}"/iteration-*/output; do
    if [[ -f "${dir}/agent-result.json" ]]; then
      result_file="${dir}/agent-result.json"
    fi
  done

  local actual_iteration
  actual_iteration=$(jq -r '.iteration' "$result_file" 2>/dev/null || echo "none")

  run_test "${test_name}" "${expected_iteration}" "${actual_iteration}"
}

test_result_file_discovery "result-file-picks-last-iteration" "3"

test_result_file_missing() {
  local run_dir="${TMPDIR}/run-missing"
  rm -rf "${run_dir}"
  mkdir -p "${run_dir}/iteration-1/output"

  local result_file=""
  for dir in "${run_dir}"/iteration-*/output; do
    if [[ -f "${dir}/agent-result.json" ]]; then
      result_file="${dir}/agent-result.json"
    fi
  done

  run_test "result-file-missing-returns-empty" "" "${result_file}"
}

test_result_file_missing

# ---------------------------------------------------------------------------
# JSON field extraction — test jq commands used in post-refine.sh
# ---------------------------------------------------------------------------

FIXTURE='{"status":"complete","confidence":{"overall":82},"comment":"Plan summary here","children":[{"type":"epic","title":"E1"},{"type":"story","title":"S1"},{"type":"story","title":"S2"},{"type":"task","title":"T1"}],"open_questions":[{"dimension":"scope","question":"Q1","impact":"High"}],"uncited_assumptions":["Assumed X","Assumed Y"]}'
FIXTURE_FILE="${TMPDIR}/fixture.json"
echo "$FIXTURE" > "$FIXTURE_FILE"

run_test "extract-status" \
  "complete" \
  "$(jq -r '.status' "$FIXTURE_FILE")"

run_test "extract-confidence" \
  "82" \
  "$(jq -r '.confidence.overall' "$FIXTURE_FILE")"

run_test "extract-child-count" \
  "4" \
  "$(jq '.children | length' "$FIXTURE_FILE")"

run_test "extract-epic-count" \
  "1" \
  "$(jq '[.children[] | select(.type == "epic")] | length' "$FIXTURE_FILE")"

run_test "extract-story-count" \
  "2" \
  "$(jq '[.children[] | select(.type == "story")] | length' "$FIXTURE_FILE")"

run_test "extract-task-count" \
  "1" \
  "$(jq '[.children[] | select(.type == "task")] | length' "$FIXTURE_FILE")"

run_test "extract-open-question-count" \
  "1" \
  "$(jq '.open_questions | length' "$FIXTURE_FILE")"

run_test "extract-assumption-count" \
  "2" \
  "$(jq '.uncited_assumptions | length' "$FIXTURE_FILE")"

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

MINIMAL='{"status":"complete","confidence":{"overall":50},"comment":"Minimal plan","children":[{"type":"task","title":"T1"}]}'
MINIMAL_FILE="${TMPDIR}/minimal.json"
echo "$MINIMAL" > "$MINIMAL_FILE"

run_test "minimal-no-open-questions" \
  "0" \
  "$(jq '.open_questions // [] | length' "$MINIMAL_FILE")"

run_test "minimal-no-assumptions" \
  "0" \
  "$(jq '.uncited_assumptions // [] | length' "$MINIMAL_FILE")"

run_test "minimal-child-count" \
  "1" \
  "$(jq '.children | length' "$MINIMAL_FILE")"

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
