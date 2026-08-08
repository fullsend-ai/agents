#!/usr/bin/env bash
# post-critique-test.sh — Test the verdict and label logic from post-critique.sh.
#
# Extracts and tests key decision logic in isolation using shell functions.
# This avoids needing comment-helpers.sh or a live GitHub/Jira API.
#
# Run from the repo root:
#   bash scripts/post-critique-test.sh

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
# Reply target determination — mirrors logic from post-critique.sh
# ---------------------------------------------------------------------------

determine_reply_target() {
  local github_issue_number="${1:-}"
  local issue_source="${2:-}"
  # Third arg (issue_key) is unused — kept for call-site parity with post-critique.sh
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

# ---------------------------------------------------------------------------
# Verdict routing — mirrors logic from post-critique.sh
# ---------------------------------------------------------------------------

determine_verdict_action() {
  local verdict="$1"
  local review_round="${2:-1}"
  local max_review_rounds="${3:-3}"
  local auto_create="${4:-false}"

  case "${verdict}" in
    approved)
      if [[ "${auto_create}" == "true" ]]; then
        echo "create-children"
      else
        echo "post-approval"
      fi
      ;;
    revise)
      local next_round=$((review_round + 1))
      if [[ $next_round -gt $max_review_rounds ]]; then
        echo "escalate-to-human"
      else
        echo "signal-refine-round-${next_round}"
      fi
      ;;
    needs_input)
      echo "post-question"
      ;;
    *)
      echo "error:unknown-verdict"
      ;;
  esac
}

# --- Approved verdict tests ---

run_test "approved-auto-create" \
  "create-children" \
  "$(determine_verdict_action "approved" 1 3 "true")"

run_test "approved-no-auto-create" \
  "post-approval" \
  "$(determine_verdict_action "approved" 1 3 "false")"

run_test "approved-round-2-auto-create" \
  "create-children" \
  "$(determine_verdict_action "approved" 2 3 "true")"

# --- Revise verdict tests ---

run_test "revise-round-1-of-3" \
  "signal-refine-round-2" \
  "$(determine_verdict_action "revise" 1 3 "false")"

run_test "revise-round-2-of-3" \
  "signal-refine-round-3" \
  "$(determine_verdict_action "revise" 2 3 "false")"

run_test "revise-round-3-of-3-escalates" \
  "escalate-to-human" \
  "$(determine_verdict_action "revise" 3 3 "false")"

run_test "revise-round-2-of-2-escalates" \
  "escalate-to-human" \
  "$(determine_verdict_action "revise" 2 2 "false")"

run_test "revise-round-1-of-1-escalates" \
  "escalate-to-human" \
  "$(determine_verdict_action "revise" 1 1 "false")"

run_test "revise-round-4-of-5" \
  "signal-refine-round-5" \
  "$(determine_verdict_action "revise" 4 5 "false")"

# --- Needs input verdict tests ---

run_test "needs-input-round-1" \
  "post-question" \
  "$(determine_verdict_action "needs_input" 1 3 "false")"

run_test "needs-input-round-3" \
  "post-question" \
  "$(determine_verdict_action "needs_input" 3 3 "false")"

# --- Unknown verdict ---

run_test "unknown-verdict" \
  "error:unknown-verdict" \
  "$(determine_verdict_action "banana" 1 3 "false")"

# ---------------------------------------------------------------------------
# Label determination per verdict — mirrors post-critique.sh label logic
# ---------------------------------------------------------------------------

determine_labels() {
  local verdict="$1"
  local review_round="${2:-1}"
  local max_review_rounds="${3:-3}"

  case "${verdict}" in
    approved)
      echo "refine-approved"
      ;;
    revise)
      local next_round=$((review_round + 1))
      if [[ $next_round -gt $max_review_rounds ]]; then
        echo "refine-needs-human,refine-escalated"
      else
        echo "ready-to-refine,refine-revision-round-${next_round}"
      fi
      ;;
    needs_input)
      echo "refine-needs-input"
      ;;
  esac
}

run_test "labels-approved-round-1" \
  "refine-approved" \
  "$(determine_labels "approved" 1 3)"

run_test "labels-approved-at-limit" \
  "refine-approved" \
  "$(determine_labels "approved" 3 3)"

run_test "labels-revise-round-1" \
  "ready-to-refine,refine-revision-round-2" \
  "$(determine_labels "revise" 1 3)"

run_test "labels-revise-at-limit" \
  "refine-needs-human,refine-escalated" \
  "$(determine_labels "revise" 3 3)"

run_test "labels-needs-input" \
  "refine-needs-input" \
  "$(determine_labels "needs_input" 1 3)"

# ---------------------------------------------------------------------------
# Critique history update — mirrors logic from post-critique.sh
# ---------------------------------------------------------------------------

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

test_critique_history_update() {
  local test_name="$1"
  local initial_history="$2"
  local review_round="$3"
  local verdict="$4"
  local overall_score="$5"
  local expected_round_count="$6"

  local history_file="${TMPDIR}/history-${test_name}.json"
  echo "$initial_history" > "$history_file"

  local revisions='[]'
  local updated
  updated=$(jq --argjson round "$review_round" \
    --arg verdict "$verdict" \
    --argjson score "$overall_score" \
    --argjson revisions "$revisions" \
    '.rounds += [{"round": $round, "verdict": $verdict, "overall_score": $score, "revisions": $revisions}]' \
    "$history_file")

  local actual_count
  actual_count=$(echo "$updated" | jq '.rounds | length')

  run_test "${test_name}" "${expected_round_count}" "${actual_count}"
}

test_critique_history_update "history-first-round" \
  '{"rounds": []}' 1 "revise" 62 "1"

test_critique_history_update "history-second-round" \
  '{"rounds": [{"round": 1, "verdict": "revise", "overall_score": 62}]}' 2 "approved" 83 "2"

test_critique_history_update "history-third-round" \
  '{"rounds": [{"round": 1, "verdict": "revise", "overall_score": 62}, {"round": 2, "verdict": "revise", "overall_score": 71}]}' 3 "approved" 85 "3"

# ---------------------------------------------------------------------------
# Result file discovery — mirrors the iteration-*/output search
# ---------------------------------------------------------------------------

test_result_file_discovery() {
  local test_name="$1"
  local expected_iteration="$2"

  local run_dir="${TMPDIR}/run-${test_name}"
  rm -rf "${run_dir}"

  for iter in 1 2; do
    mkdir -p "${run_dir}/iteration-${iter}/output"
    echo "{\"iteration\": ${iter}, \"verdict\": \"approved\"}" > "${run_dir}/iteration-${iter}/output/agent-result.json"
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

test_result_file_discovery "result-file-picks-last-iteration" "2"

# ---------------------------------------------------------------------------
# JSON field extraction — test jq commands used in post-critique.sh
# ---------------------------------------------------------------------------

APPROVED_FIXTURE='{"verdict":"approved","review_round":1,"assessment":{"coverage":{"score":85},"granularity":{"score":80},"overall":83},"revisions":[],"comment":"Plan looks good.","summary":"Approved with minor notes."}'
APPROVED_FILE="${TMPDIR}/approved.json"
echo "$APPROVED_FIXTURE" > "$APPROVED_FILE"

run_test "extract-verdict-approved" \
  "approved" \
  "$(jq -r '.verdict' "$APPROVED_FILE")"

run_test "extract-overall-score" \
  "83" \
  "$(jq -r '.assessment.overall' "$APPROVED_FILE")"

run_test "extract-revision-count-zero" \
  "0" \
  "$(jq '.revisions | length' "$APPROVED_FILE")"

REVISE_FIXTURE='{"verdict":"revise","review_round":1,"assessment":{"overall":62},"revisions":[{"type":"remove","target":"Epic 4","reasoning":"Scope creep"},{"type":"revise","target":"Story 2","reasoning":"Vague AC","suggestion":"Add metrics"}],"comment":"Needs work.","summary":"Two revisions needed."}'
REVISE_FILE="${TMPDIR}/revise.json"
echo "$REVISE_FIXTURE" > "$REVISE_FILE"

run_test "extract-verdict-revise" \
  "revise" \
  "$(jq -r '.verdict' "$REVISE_FILE")"

run_test "extract-revision-count" \
  "2" \
  "$(jq '.revisions | length' "$REVISE_FILE")"

NEEDS_INPUT_FIXTURE='{"verdict":"needs_input","review_round":1,"assessment":{"overall":58},"question":{"dimension":"scope_clarity","text":"Is this validation or new implementation?","impact":"Changes the entire decomposition."},"comment":"Cannot proceed without clarity.","summary":"Human input needed."}'
NEEDS_INPUT_FILE="${TMPDIR}/needs-input.json"
echo "$NEEDS_INPUT_FIXTURE" > "$NEEDS_INPUT_FILE"

run_test "extract-verdict-needs-input" \
  "needs_input" \
  "$(jq -r '.verdict' "$NEEDS_INPUT_FILE")"

run_test "extract-question-dimension" \
  "scope_clarity" \
  "$(jq -r '.question.dimension' "$NEEDS_INPUT_FILE")"

run_test "extract-question-text" \
  "Is this validation or new implementation?" \
  "$(jq -r '.question.text' "$NEEDS_INPUT_FILE")"

# ---------------------------------------------------------------------------
# Escalation history update — when max rounds reached, history is mutated
# ---------------------------------------------------------------------------

test_escalation_history() {
  local history_file="${TMPDIR}/escalation-history.json"
  echo '{"rounds": [{"round": 1, "verdict": "revise", "overall_score": 62}, {"round": 2, "verdict": "revise", "overall_score": 68}, {"round": 3, "verdict": "revise", "overall_score": 71}]}' > "$history_file"

  local updated
  updated=$(jq '.rounds[-1].escalated = true | .rounds[-1].escalation_reason = "max_rounds"' "$history_file")

  local last_verdict
  last_verdict=$(echo "$updated" | jq -r '.rounds[-1].verdict')
  local last_escalated
  last_escalated=$(echo "$updated" | jq -r '.rounds[-1].escalated')
  local escalation_reason
  escalation_reason=$(echo "$updated" | jq -r '.rounds[-1].escalation_reason')

  run_test "escalation-preserves-verdict" "revise" "$last_verdict"
  run_test "escalation-sets-flag" "true" "$last_escalated"
  run_test "escalation-records-reason" "max_rounds" "$escalation_reason"
}

test_escalation_history

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
