#!/usr/bin/env bash
# after_each hook (eval/dev/code-rhai): run the fullsend review agent on the PR the
# code agent opened, without posting anything, and keep its findings for the
# quality judge. Runs after capture-pr-artifacts.sh and before teardown.
#
# The review step is held constant across arms: Claude Code runtime, Sonnet,
# regardless of what the code agent ran on (EVAL_RUNTIME/EVAL_MODEL). Override
# with EVAL_REVIEW_RUNTIME / EVAL_REVIEW_MODEL / EVAL_REVIEW_EFFORT.
#
# Writes:
#   output/review-result.json   the review agent's agent-result.json
#                               (findings, risk_assessment, body, action) or
#                               {review_ran: false, reason}
#   output/review-metrics.json  the review run's metrics.json (kept apart from
#                               the code run's metrics.json so cost judges are
#                               not polluted); includes the agents-repo commit
#                               so the review agent version is on record
#   output/review-run/          the review run's own output tree
set -euo pipefail

CASE_WORKSPACE="${CASE_WORKSPACE:?CASE_WORKSPACE is required}"
EPHEMERAL_REPO="${EPHEMERAL_REPO:?EPHEMERAL_REPO is required}"
FULLSEND_DIR="${FULLSEND_DIR:?FULLSEND_DIR is required}"
OUTPUT_DIR="${CASE_WORKSPACE}/output"
JUDGE_DIR="${CASE_WORKSPACE}/judge"
PR_JSON="${OUTPUT_DIR}/pr.json"
mkdir -p "$OUTPUT_DIR" "$JUDGE_DIR"

# Plain-text rendering of the findings for the agent judge (judge/review.md).
render_review() {
  local f="$OUTPUT_DIR/review-result.json"
  {
    echo "# Independent automated code review of the PR"; echo
    echo "Produced by the fullsend review agent, which read the repository, the diff and"
    echo "the linked issue. Evidence to verify, not a verdict."; echo
    if [[ "$(jq -r '.review_ran // false' "$f")" != "true" ]]; then
      echo "The review did not run: $(jq -r '.reason // "unknown"' "$f")"
    else
      echo "Recommended action: $(jq -r '.action // "n/a"' "$f")"
      echo "Risk assessment: $(jq -c '.risk_assessment // "n/a"' "$f")"; echo
      echo "## Findings ($(jq '.findings // [] | length' "$f"))"; echo
      jq -r '(.findings // []) | to_entries[] | .value as $x | "\(.key+1). [\($x.severity // "?")/\($x.category // "-")] \($x.file // $x.path // "")\(if ($x.line // null) then ":" + ($x.line|tostring) else "" end)\n   \($x.description // $x.body // $x.message // "")\n   Suggested fix: \($x.remediation // "n/a")\n"' "$f"
      echo "## Review summary"; echo
      jq -r '.body // "(none)"' "$f"
    fi
  } > "$JUDGE_DIR/review.md"
}

skip() { jq -n --arg r "$1" '{review_ran: false, reason: $r}' > "$OUTPUT_DIR/review-result.json"; render_review; echo "review agent skipped: $1"; exit 0; }
[[ "${EVAL_SKIP_REVIEW:-}" == "1" ]] && skip "EVAL_SKIP_REVIEW=1"
[[ -f "$PR_JSON" ]] || skip "pr.json missing; capture-pr-artifacts.sh did not run"
[[ "$(jq -r '.pr_found // false' "$PR_JSON")" == "true" ]] || skip "no PR to review"
num=$(jq -r .number "$PR_JSON"); url=$(jq -r .url "$PR_JSON")

REVIEW_OUT="${OUTPUT_DIR}/review-run"
mkdir -p "$REVIEW_OUT"
rc=0
FIXTURE_TYPE=pull_request FIXTURE_URL="$url" FIXTURE_NUMBER="$num" \
EPHEMERAL_REPO="$EPHEMERAL_REPO" EVAL_NO_POST_SCRIPT=1 \
EVAL_RUNTIME="${EVAL_REVIEW_RUNTIME:-}" \
EVAL_MODEL="${EVAL_REVIEW_MODEL:-claude-sonnet-4-6}" EVAL_EFFORT="${EVAL_REVIEW_EFFORT:-}" \
EVAL_TIMEOUT="${EVAL_REVIEW_TIMEOUT:-2700}" \
  run-fullsend.sh review "$CASE_WORKSPACE" "$REVIEW_OUT" || rc=$?
echo "review agent run exit: $rc"

result=$(find "$REVIEW_OUT" -maxdepth 4 -path '*/iteration-*/output/agent-result.json' | sort -V | tail -1)
if [[ -n "$result" ]]; then
  # A result file is not a review: the schema's action enum includes "failure".
  jq --argjson rc "$rc" '. + {exit_code: $rc,
        review_ran: ((.action // "") as $a | ($a != "" and $a != "failure")),
        reason: (if (.action // "") == "failure" then "review agent reported failure"
                 elif (.action // "") == "" then "agent-result.json has no action" else null end)}' \
    "$result" > "$OUTPUT_DIR/review-result.json"
else
  jq -n --argjson rc "$rc" '{review_ran: false, reason: "no agent-result.json from the review run", exit_code: $rc}' > "$OUTPUT_DIR/review-result.json"
fi
agents_commit=$(git -C "$FULLSEND_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
if [[ -f "$REVIEW_OUT/metrics.json" ]]; then
  jq --arg c "$agents_commit" '. + {agents_repo_commit: $c}' "$REVIEW_OUT/metrics.json" > "$OUTPUT_DIR/review-metrics.json"
else
  jq -n --arg c "$agents_commit" --argjson rc "$rc" '{agents_repo_commit: $c, exit_code: $rc, metrics_missing: true}' > "$OUTPUT_DIR/review-metrics.json"
fi
render_review
echo "Saved review findings -> ${OUTPUT_DIR}/review-result.json and ${JUDGE_DIR}/review.md"
