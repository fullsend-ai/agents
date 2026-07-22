#!/usr/bin/env bash
# Post-script: post the review agent's result to GitHub.
#
# Runs on the GitHub Actions runner AFTER the sandbox is destroyed.
# CWD is runDir.
#
# This script is the sole enforcement point for protected-path checks:
# if the PR touches sensitive paths, an "approve" action is downgraded
# to "comment" so only a human can grant approval.
#
# Required environment variables:
#   REVIEW_TOKEN    — token with pull-requests:write on the target repo
#   PR_NUMBER       — GitHub PR number
#   REPO_FULL_NAME  — owner/repo (e.g. my-org/my-repo)
#
# Exit codes:
#   0 — review posted
#   1 — error (review not posted or fallback comment posted)
set -euo pipefail

: "${REVIEW_TOKEN:?REVIEW_TOKEN is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
if ! [[ "${PR_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "::error::PR_NUMBER must be a positive integer" >&2
  exit 1
fi
: "${REPO_FULL_NAME:?REPO_FULL_NAME is required}"

echo "::add-mask::${REVIEW_TOKEN}"
export GH_TOKEN="${REVIEW_TOKEN}"

# Temp file cleanup: accumulate files to remove on exit so later traps
# don't overwrite earlier ones.
CLEANUP_FILES=()
trap 'rm -f "${CLEANUP_FILES[@]}"' EXIT

# Refuse to post reviews on merged or closed PRs.
# Also fetch draft status — draft PRs must not receive ready-for-merge.
PR_INFO=$(gh pr view "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" --json state,isDraft)
PR_STATE=$(echo "${PR_INFO}" | jq -r '.state')
PR_IS_DRAFT=$(echo "${PR_INFO}" | jq -r '.isDraft')
if [ "${PR_STATE}" != "OPEN" ]; then
  echo "PR is ${PR_STATE}, skipping review"

  STATE_LOWER="$(echo "${PR_STATE}" | tr '[:upper:]' '[:lower:]')"
  COMMENT_BODY="Review skipped — this PR is already **${STATE_LOWER}**.

The \`/fs-review\` command only reviews open pull requests.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> post-review check</sub>"

  printf '%s' "${COMMENT_BODY}" | gh issue comment "${PR_NUMBER}" \
    --repo "${REPO_FULL_NAME}" --body-file - 2>/dev/null || true

  exit 0
fi

# Find the agent result from the last iteration
RESULT_FILE=$(find .  -maxdepth 4 -path '*/iteration-*/output/agent-result.json' | sort -V | tail -1)

if [ -z "${RESULT_FILE}" ] || [ ! -f "${RESULT_FILE}" ]; then
  echo "::error::No agent-result.json found — posting failure notice"
  echo '{"action":"failure","reason":"agent-no-output"}' | \
    fullsend post-review \
      --repo "${REPO_FULL_NAME}" \
      --pr "${PR_NUMBER}" \
      --token "${REVIEW_TOKEN}" \
      --result -
  exit 1
fi

echo "Using result: ${RESULT_FILE}"

# ---------------------------------------------------------------------------
# Severity filtering: drop findings below the configured threshold.
# Defense-in-depth — the agent should already have filtered, but the
# post-script enforces it. The filter runs before ACTION is read so
# that verdict recalculation (if all findings are removed) is possible.
# ---------------------------------------------------------------------------
REVIEW_FINDING_SEVERITY_THRESHOLD="${REVIEW_FINDING_SEVERITY_THRESHOLD:-low}"

case "$REVIEW_FINDING_SEVERITY_THRESHOLD" in
  info|low|medium|high|critical) ;;
  *) echo "::warning::Invalid REVIEW_FINDING_SEVERITY_THRESHOLD='${REVIEW_FINDING_SEVERITY_THRESHOLD}', defaulting to 'low'"
     REVIEW_FINDING_SEVERITY_THRESHOLD="low" ;;
esac

severity_rank() {
  case "$1" in
    info)     echo 0 ;;
    low)      echo 1 ;;
    medium)   echo 2 ;;
    high)     echo 3 ;;
    critical) echo 4 ;;
    *)        echo 1 ;;
  esac
}

threshold_rank=$(severity_rank "$REVIEW_FINDING_SEVERITY_THRESHOLD")

if jq -e '.findings' "${RESULT_FILE}" >/dev/null 2>&1; then
  original_count=$(jq '.findings | length' "${RESULT_FILE}")
  FILTERED_RESULT=$(mktemp)
  CLEANUP_FILES+=("${FILTERED_RESULT}")
  jq --argjson rank "$threshold_rank" '
    .findings |= [.[] | select(
      (if .severity == "info" then 0
       elif .severity == "low" then 1
       elif .severity == "medium" then 2
       elif .severity == "high" then 3
       elif .severity == "critical" then 4
       else 1 end) >= $rank
    )]
  ' "${RESULT_FILE}" > "${FILTERED_RESULT}"
  filtered_count=$(jq '.findings | length' "${FILTERED_RESULT}")

  if [ "${filtered_count}" -lt "${original_count}" ]; then
    echo "Severity filter (threshold=${REVIEW_FINDING_SEVERITY_THRESHOLD}): kept ${filtered_count}/${original_count} findings"
    RESULT_FILE="${FILTERED_RESULT}"

    # If filtering removed all findings, delete the empty findings array
    # (minItems: 1 in the schema). For request-changes/reject, also
    # downgrade to comment — zero findings with a blocking verdict is
    # semantically wrong. Use "comment" (not "approve") so the PR gets
    # requires-manual-review, not ready-for-merge.
    if [ "${filtered_count}" -eq 0 ]; then
      original_action=$(jq -r '.action' "${FILTERED_RESULT}")
      DOWNGRADE_RESULT=$(mktemp)
      CLEANUP_FILES+=("${DOWNGRADE_RESULT}")
      if [ "${original_action}" = "request-changes" ] || [ "${original_action}" = "reject" ]; then
        echo "All findings removed by severity filter — downgrading '${original_action}' to 'comment'"
        jq 'del(.findings) | .action = "comment"' "${FILTERED_RESULT}" > "${DOWNGRADE_RESULT}"
      else
        jq 'del(.findings)' "${FILTERED_RESULT}" > "${DOWNGRADE_RESULT}"
      fi
      RESULT_FILE="${DOWNGRADE_RESULT}"
    fi
  else
    rm -f "${FILTERED_RESULT}"
  fi
fi

ACTION=$(jq -r '.action' "${RESULT_FILE}")
# ACTION retains the original value for the entire script — not re-read after protected-path downgrade.

# ---------------------------------------------------------------------------
# Protected-path check: the review agent must not approve PRs that touch
# sensitive paths. If the PR modifies any of these, downgrade "approve" to
# "comment" so only a human can grant approval. This is the sole enforcement
# point — the code agent is free to propose changes to any path.
# ---------------------------------------------------------------------------
REVIEW_PROTECTED_PATHS=(
  ".claude/"
  ".cursor/"
  ".gitattributes"
  ".github/"
  ".pre-commit-config.yaml"
  "AGENTS.md"
  "agents/"
  "api-servers/"
  "CLAUDE.md"
  "CODEOWNERS"
  "Containerfile"
  "Dockerfile"
  "harness/"
  "images/"
  "plugins/"
  "policies/"
  "scripts/"
  "skills/"
)

DOWNGRADED=false
if [ "${ACTION}" = "approve" ]; then
  PR_FILES=$(gh pr view "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" --json files --jq '.files[].path')
  if [ -z "${PR_FILES}" ]; then
    echo "::error::Failed to fetch PR files or PR has no changed files — refusing to approve (gh pr view --json files)" >&2
    exit 1
  fi

  PROTECTED_MATCHES=""
  while IFS= read -r file; do
    [ -z "${file}" ] && continue
    for pattern in "${REVIEW_PROTECTED_PATHS[@]}"; do
      if [[ "${file}" == "${pattern}"* ]]; then
        PROTECTED_MATCHES="${PROTECTED_MATCHES}${file}"$'\n'
        break
      fi
    done
  done <<< "${PR_FILES}"

  if [ -n "${PROTECTED_MATCHES}" ]; then
    echo "PR touches protected paths — downgrading approve to comment"
    echo "${PROTECTED_MATCHES}" | sed '/^$/d' | sed 's/^/  /'

    PROTECTED_NOTICE=$'\n\n---\n\n'
    PROTECTED_NOTICE+=$'> **Protected paths detected** — this PR modifies files under one or more\n'
    PROTECTED_NOTICE+=$'> protected paths. The review agent cannot approve PRs that touch these paths.\n'
    PROTECTED_NOTICE+=$'> A human reviewer must approve this PR.\n'
    PROTECTED_NOTICE+=$'>\n'
    PROTECTED_NOTICE+=$'> Protected files in this PR:\n'
    while IFS= read -r f; do
      [ -z "${f}" ] && continue
      PROTECTED_NOTICE+="> - \`${f}\`"$'\n'
    done <<< "${PROTECTED_MATCHES}"

    # Rewrite the result file with downgraded action and appended notice.
    MODIFIED_RESULT=$(mktemp)
    CLEANUP_FILES+=("${MODIFIED_RESULT}")
    jq --arg notice "${PROTECTED_NOTICE}" \
      '.action = "comment" | .body = (.body + $notice)' \
      "${RESULT_FILE}" > "${MODIFIED_RESULT}"
    RESULT_FILE="${MODIFIED_RESULT}"
    DOWNGRADED=true
  fi
fi

# ---------------------------------------------------------------------------
# Label-actions validation: the review agent may recommend contextual labels
# (e.g. area/api, priority/high). Validate them here so the label reason
# appears in the review body. Actual label API calls happen after posting.
# ---------------------------------------------------------------------------
REVIEW_CONTROL_LABELS=(
  "ready-for-merge" "requires-manual-review" "rejected"
  "ready-for-review" "fullsend-no-fix" "fullsend-fix"
)

is_control_label() {
  local label="$1"
  for cl in "${REVIEW_CONTROL_LABELS[@]}"; do
    if [[ "${cl}" == "${label}" ]]; then
      return 0
    fi
  done
  return 1
}

VALIDATED_LABEL_ADDS=()
VALIDATED_LABEL_REMOVES=()
LABEL_REASON=""

HAS_LABEL_ACTIONS=$(jq 'has("label_actions")' "${RESULT_FILE}")
if [[ "${HAS_LABEL_ACTIONS}" == "true" ]]; then
  LABEL_REASON=$(jq -r '.label_actions.reason' "${RESULT_FILE}")
  LABEL_COUNT=$(jq '.label_actions.actions | length' "${RESULT_FILE}")

  echo "Validating ${LABEL_COUNT} label action(s)..."

  # Fetch existing repo labels once.
  EXISTING_LABELS=$(gh api "repos/${REPO_FULL_NAME}/labels" --paginate --jq '.[].name' 2>/dev/null || true)

  label_exists() {
    local label="$1"
    echo "${EXISTING_LABELS}" | grep -qFx "${label}"
  }

  for i in $(seq 0 $((LABEL_COUNT - 1))); do
    LA_ACTION=$(jq -r ".label_actions.actions[${i}].action" "${RESULT_FILE}")
    LA_LABEL=$(jq -r ".label_actions.actions[${i}].label" "${RESULT_FILE}")

    # Sanitize jq -r output: strip newlines, carriage returns, and GHA
    # workflow command delimiters to prevent command injection via crafted
    # label names or action values.
    LA_ACTION="${LA_ACTION//$'\n'/}"
    LA_ACTION="${LA_ACTION//$'\r'/}"
    LA_ACTION="${LA_ACTION//::/:}"
    LA_LABEL="${LA_LABEL//$'\n'/}"
    LA_LABEL="${LA_LABEL//$'\r'/}"
    LA_LABEL="${LA_LABEL//::/:}"

    if [[ ! "${LA_LABEL}" =~ ^[a-zA-Z0-9._/:\ +\-]+$ ]]; then
      echo "::warning::Refused label '${LA_LABEL}' -- contains invalid characters"
      continue
    fi

    if is_control_label "${LA_LABEL}"; then
      echo "::warning::Refused to ${LA_ACTION} control label '${LA_LABEL}' -- control labels are managed by the review pipeline"
      continue
    fi

    case "${LA_ACTION}" in
      add)
        if ! label_exists "${LA_LABEL}"; then
          echo "::warning::Skipping label '${LA_LABEL}' -- does not exist in repo (will not auto-create)"
          continue
        fi
        VALIDATED_LABEL_ADDS+=("${LA_LABEL}")
        ;;
      remove)
        VALIDATED_LABEL_REMOVES+=("${LA_LABEL}")
        ;;
      *)
        echo "::warning::Unknown label action '${LA_ACTION}' for label '${LA_LABEL}'"
        ;;
    esac
  done

  # Append label reason to body if any labels validated.
  VALIDATED_COUNT=$(( ${#VALIDATED_LABEL_ADDS[@]} + ${#VALIDATED_LABEL_REMOVES[@]} ))
  if [[ "${VALIDATED_COUNT}" -gt 0 ]]; then
    LABEL_NOTICE=$'\n\n---\n'"**Labels:** ${LABEL_REASON}"
    LABEL_MODIFIED_RESULT=$(mktemp)
    CLEANUP_FILES+=("${LABEL_MODIFIED_RESULT}")
    jq --arg notice "${LABEL_NOTICE}" \
      '.body = (.body + $notice)' \
      "${RESULT_FILE}" > "${LABEL_MODIFIED_RESULT}"
    RESULT_FILE="${LABEL_MODIFIED_RESULT}"
  fi
fi

# ---------------------------------------------------------------------------
# Post the review with retry logic. Transient GitHub API errors (e.g. 422
# during PR transitional states) can cause fullsend post-review to fail even
# though the review comment was posted successfully. Retry with backoff to
# handle these transient failures.
#
# Exit code 10 = stale-head: bypasses retry, handled separately below.
# Other non-zero exit codes are retried up to POST_REVIEW_MAX_ATTEMPTS times.
# NOTE: fullsend does not expose distinct exit codes for transient vs.
# permanent failures (e.g. invalid token, malformed result file). As a
# deliberate trade-off, all non-zero/non-10 codes are retried — a permanent
# failure wastes at most two retry attempts (~20s) before falling through to
# the degraded-mode fallback.
# If all retries are exhausted, attempt degraded-mode label fallback so the
# PR is not left without an outcome label.
#
# Idempotency: a "failed" attempt may have actually succeeded server-side
# (e.g. a 422/timeout after the server processed the request). Before each
# retry, a lightweight check queries the reviews API to detect if a new
# review appeared. If so, the retry is skipped to avoid double-posting.
#
# Environment:
#   POST_REVIEW_RETRY_DELAY — override backoff seconds for all retries
#                             (default: 5s first retry, 15s second retry;
#                              set to 0 in tests to skip sleep). Must be a
#                             non-negative integer; invalid values are ignored
#                             and the progressive default is used.
# ---------------------------------------------------------------------------
POST_REVIEW_MAX_ATTEMPTS=3

# Snapshot the latest review ID before the retry loop for idempotency.
# If a "failed" attempt actually posted a review, the retry detects it.
_last_review_id=$(gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/reviews" \
  --jq 'map(.id) | max // 0' 2>/dev/null) || true
_last_review_id="${_last_review_id:-0}"

# Temp file for capturing stderr from fullsend post-review.
_pr_stderr=$(mktemp)
CLEANUP_FILES+=("${_pr_stderr}")

POST_REVIEW_EXIT=0
for _pr_attempt in $(seq 1 "${POST_REVIEW_MAX_ATTEMPTS}"); do
  POST_REVIEW_EXIT=0
  fullsend post-review \
    --repo "${REPO_FULL_NAME}" \
    --pr "${PR_NUMBER}" \
    --token "${REVIEW_TOKEN}" \
    --result "${RESULT_FILE}" 2>"${_pr_stderr}" || POST_REVIEW_EXIT=$?

  # Exit code 10 = stale-head: bypass retry, handle below
  if [ "${POST_REVIEW_EXIT}" -eq 10 ]; then
    break
  fi

  # Success: no retry needed
  if [ "${POST_REVIEW_EXIT}" -eq 0 ]; then
    break
  fi

  # Non-zero, non-stale-head: log and retry if attempts remain
  # Include first line of stderr for diagnostics (fullsend prints
  # "Error: github api: <status> <message>" on API failures).
  _pr_err_detail=""
  if [ -s "${_pr_stderr}" ]; then
    _pr_err_detail=" — $(head -1 "${_pr_stderr}")"
  fi

  if [ "${_pr_attempt}" -lt "${POST_REVIEW_MAX_ATTEMPTS}" ]; then
    # Idempotency check: if a new review appeared since the loop started,
    # the "failed" attempt actually succeeded server-side — skip retry.
    _current_review_id=$(gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/reviews" \
      --jq 'map(.id) | max // 0' 2>/dev/null) || true
    _current_review_id="${_current_review_id:-0}"
    if [ "${_current_review_id}" -gt "${_last_review_id}" ]; then
      echo "::notice::Review was posted despite exit code ${POST_REVIEW_EXIT} — skipping retry (idempotency guard)"
      POST_REVIEW_EXIT=0
      break
    fi

    if [[ "${POST_REVIEW_RETRY_DELAY:-}" =~ ^[0-9]+$ ]]; then
      _backoff="${POST_REVIEW_RETRY_DELAY}"
    elif [ "${_pr_attempt}" -eq 1 ]; then
      _backoff=5
    else
      _backoff=15
    fi
    echo "::warning::fullsend post-review attempt ${_pr_attempt}/${POST_REVIEW_MAX_ATTEMPTS} failed (exit ${POST_REVIEW_EXIT}${_pr_err_detail}) — retrying in ${_backoff}s"
    sleep "${_backoff}"
  else
    echo "::warning::fullsend post-review attempt ${_pr_attempt}/${POST_REVIEW_MAX_ATTEMPTS} failed (exit ${POST_REVIEW_EXIT}${_pr_err_detail}) — all retries exhausted"
  fi
done

if [ "${POST_REVIEW_EXIT}" -eq 10 ]; then
  echo "Stale-head detected — checking whether to re-dispatch review"

  # Loop guard: if a stale-head re-dispatch comment was posted recently
  # (within the last 5 minutes), skip to avoid cascading dispatches from
  # rapid force-pushes. The next synchronize event will pick it up.
  REDISPATCH_MARKER="<!-- fullsend:stale-head-redispatch -->"
  RECENT_REDISPATCH=$(gh api \
    "repos/${REPO_FULL_NAME}/issues/${PR_NUMBER}/comments" \
    --paginate 2>/dev/null \
    | jq -s "add // [] | [.[] | select(.body | contains(\"${REDISPATCH_MARKER}\"))
          | select(.created_at > (now - 300 | strftime(\"%Y-%m-%dT%H:%M:%SZ\")))]
     | length") || RECENT_REDISPATCH=0

  if [ "${RECENT_REDISPATCH}" -gt 0 ]; then
    echo "Recent stale-head re-dispatch already exists — skipping"
  else
    echo "Re-dispatching review for current HEAD"
    gh pr comment "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" \
      --body "/fs-review
${REDISPATCH_MARKER}" || echo "::warning::Failed to post re-dispatch comment"
  fi

  # Stale-head is handled gracefully — exit 0 so the workflow does not
  # appear as a failure.
  exit 0
elif [ "${POST_REVIEW_EXIT}" -ne 0 ]; then
  echo "::error::fullsend post-review failed after ${POST_REVIEW_MAX_ATTEMPTS} attempts (exit ${POST_REVIEW_EXIT}, PR #${PR_NUMBER} in ${REPO_FULL_NAME})" >&2

  # Degraded-mode fallback: apply the outcome label directly so the PR is
  # not left in limbo without a label.
  #
  # Assumption: fullsend post-review is a two-step operation (post comment,
  # then submit formal review). A transient API failure may occur between
  # the steps, leaving the comment posted but the formal review missing.
  # We cannot distinguish "comment posted, review failed" from "nothing
  # posted" because fullsend post-review does not emit distinct exit codes
  # for each case. (The CLI does print diagnostic details to stderr — these
  # are captured and included in the retry warning messages above — but exit
  # codes do not differentiate failure modes.) Applying the label here is a
  # best-effort measure — exit 1 still signals CI failure so a human can
  # verify.
  echo "Attempting degraded-mode label fallback..."
  _fallback_applied=false

  # Determine the target fallback label so we can skip removing it
  # (avoids a pointless unlabel/relabel cycle — mirrors normal path).
  # Label logic mirrors the outcome-label block below — keep in sync.
  _fallback_label=""
  if [ "${ACTION}" = "approve" ] && [ "${DOWNGRADED}" = "false" ] && [ "${PR_IS_DRAFT}" != "true" ]; then
    _fallback_label="ready-for-merge"
  elif { [ "${ACTION}" = "approve" ] && { [ "${DOWNGRADED}" = "true" ] || [ "${PR_IS_DRAFT}" = "true" ]; }; } || \
       [ "${ACTION}" = "comment" ]; then
    _fallback_label="requires-manual-review"
  elif [ "${ACTION}" = "reject" ]; then
    _fallback_label="rejected"
  fi

  # Remove stale outcome labels, skipping the one about to be applied.
  for _stale in "ready-for-merge" "requires-manual-review" "rejected"; do
    [ "${_stale}" = "${_fallback_label}" ] && continue
    gh pr edit "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" \
      --remove-label "${_stale}" 2>/dev/null || true
  done
  if [ "${ACTION}" = "approve" ] && [ "${DOWNGRADED}" = "false" ] && [ "${PR_IS_DRAFT}" != "true" ]; then
    gh label create "ready-for-merge" --repo "${REPO_FULL_NAME}" \
      --description "All reviewers approved — ready to merge" --color "0E8A16" \
      2>/dev/null || true
    if gh pr edit "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" \
      --add-label "ready-for-merge"; then
      _fallback_applied=true
      echo "Degraded-mode fallback: applied ready-for-merge label"
    fi
  elif { [ "${ACTION}" = "approve" ] && { [ "${DOWNGRADED}" = "true" ] || [ "${PR_IS_DRAFT}" = "true" ]; }; } || \
       [ "${ACTION}" = "comment" ]; then
    gh label create "requires-manual-review" --repo "${REPO_FULL_NAME}" \
      --description "Review requires human judgment" --color "FBCA04" \
      2>/dev/null || true
    if gh pr edit "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" \
      --add-label "requires-manual-review"; then
      _fallback_applied=true
      echo "Degraded-mode fallback: applied requires-manual-review label"
    fi
  elif [ "${ACTION}" = "reject" ]; then
    # NOTE: The normal path closes the PR before applying the rejected
    # label (gh pr close with a comment). In degraded mode, closing is
    # intentionally omitted as a conservative measure — without
    # confirmation that the formal review was posted, closing the PR
    # would be a destructive action based on uncertain state. The exit 1
    # ensures CI failure so a human can intervene.
    gh label create "rejected" --repo "${REPO_FULL_NAME}" \
      --description "Approach rejected by review agent" --color "B60205" \
      2>/dev/null || true
    if gh pr edit "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" \
      --add-label "rejected"; then
      _fallback_applied=true
      echo "Degraded-mode fallback: applied rejected label"
    fi
  fi

  # Sanitize ACTION for GHA workflow command output (defense-in-depth,
  # matches the pattern used for label-action values above).
  _safe_action="${ACTION//$'\n'/}"
  _safe_action="${_safe_action//$'\r'/}"
  _safe_action="${_safe_action//::/:}"

  if [ "${_fallback_applied}" = "true" ]; then
    echo "::warning::Formal review failed but outcome label applied via degraded-mode fallback"
  else
    echo "::warning::Degraded-mode label fallback not applicable (action=${_safe_action})"
  fi

  exit 1
fi

# ---------------------------------------------------------------------------
# Outcome labels: apply labels based on the review action.
# Labels are created if missing, matching the needs-human pattern in
# post-fix.sh.
# Label logic is mirrored in post-review-test.sh — update both.
# ---------------------------------------------------------------------------

# Determine the target outcome label before mutating anything so we can
# skip no-op remove/re-add cycles that generate timeline noise.
OUTCOME_LABEL=""
if [ "${ACTION}" = "approve" ] && [ "${DOWNGRADED}" = "false" ] && [ "${PR_IS_DRAFT}" != "true" ]; then
  OUTCOME_LABEL="ready-for-merge"
elif { [ "${ACTION}" = "approve" ] && { [ "${DOWNGRADED}" = "true" ] || [ "${PR_IS_DRAFT}" = "true" ]; }; } || \
     [ "${ACTION}" = "comment" ]; then
  OUTCOME_LABEL="requires-manual-review"
elif [ "${ACTION}" = "reject" ]; then
  OUTCOME_LABEL="rejected"
fi

# Remove stale outcome labels from prior runs, skipping the label we are
# about to apply so we don't create a pointless unlabel/relabel cycle.
# 2>/dev/null is intentional: removal of a non-existent label is the
# common case and not worth logging.
for stale_label in "ready-for-merge" "requires-manual-review" "rejected"; do
  [ "${stale_label}" = "${OUTCOME_LABEL}" ] && continue
  gh pr edit "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" \
    --remove-label "${stale_label}" 2>/dev/null || true
done

if [ "${OUTCOME_LABEL}" = "ready-for-merge" ]; then
  echo "Approve disposition — applying ready-for-merge label"
  gh label create "ready-for-merge" --repo "${REPO_FULL_NAME}" \
    --description "All reviewers approved — ready to merge" --color "0E8A16" \
    2>/dev/null || true
  gh pr edit "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" \
    --add-label "ready-for-merge" || true
elif [ "${OUTCOME_LABEL}" = "requires-manual-review" ]; then
  if [ "${PR_IS_DRAFT}" = "true" ] && [ "${ACTION}" = "approve" ]; then
    echo "PR is a draft — skipping ready-for-merge, applying requires-manual-review"
  else
    echo "Review requires human judgment — applying requires-manual-review label"
  fi
  gh label create "requires-manual-review" --repo "${REPO_FULL_NAME}" \
    --description "Review requires human judgment" --color "FBCA04" \
    2>/dev/null || true
  gh pr edit "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" \
    --add-label "requires-manual-review" || true
elif [ "${OUTCOME_LABEL}" = "rejected" ]; then
  echo "Reject disposition — closing PR and applying label"
  gh label create "rejected" --repo "${REPO_FULL_NAME}" \
    --description "Approach rejected by review agent" --color "B60205" \
    2>/dev/null || true
  gh pr close "${PR_NUMBER}" \
    --repo "${REPO_FULL_NAME}" \
    --comment "Closed by review agent: approach rejected." || true
  gh pr edit "${PR_NUMBER}" \
    --repo "${REPO_FULL_NAME}" \
    --add-label "rejected" || true
elif [ "${ACTION}" = "request-changes" ]; then
  echo "Request-changes disposition — no outcome label (fix agent triggers on event)"
fi

# ---------------------------------------------------------------------------
# Contextual labels: apply validated label mutations from label_actions.
# ---------------------------------------------------------------------------
for label in "${VALIDATED_LABEL_ADDS[@]}"; do
  echo "Adding contextual label '${label}'..."
  gh api "repos/${REPO_FULL_NAME}/issues/${PR_NUMBER}/labels" \
    -f "labels[]=${label}" --silent || \
    echo "::warning::Failed to add label '${label}'"
done

for label in "${VALIDATED_LABEL_REMOVES[@]}"; do
  echo "Removing contextual label '${label}'..."
  encoded=$(printf '%s' "${label}" | jq -sRr @uri)
  gh api "repos/${REPO_FULL_NAME}/issues/${PR_NUMBER}/labels/${encoded}" \
    -X DELETE --silent 2>/dev/null || true
done

echo "Review posted on ${REPO_FULL_NAME}#${PR_NUMBER}"
