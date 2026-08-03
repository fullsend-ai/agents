#!/usr/bin/env bash
# post-classify.sh — Apply classification decisions from the classify agent.
#
# Runs on the host after sandbox cleanup. Reads the agent's JSON output and:
# 1. Adds issues to the GitHub Project if not already present
# 2. Sets the Workstream Category field value on classified issues
#
# In dry-run mode, no writes are performed. A structured report is written
# to output/classify-report.json and a markdown summary is written to the
# GitHub Step Summary (if in Actions) and to stdout.
#
# Required env vars:
#   GH_TOKEN              — GitHub token with issues:write, project scope
#   CLASSIFY_SOURCE_REPO  — owner/repo
#   CLASSIFY_MIN_CONFIDENCE — minimum confidence to apply classification (default: 0.7)
#
# SECURITY:
# - Never logs tokens, credentials, or issue body content.
# - The classify-report.json artifact contains only issue numbers, categories,
#   and sanitized reasoning — no issue bodies, tokens, or credentials.

set -euo pipefail

# Normalize sentinel values (see pre-script for explanation).
[[ "${CLASSIFY_FILTER_CATEGORY:-}" == "__all__" ]] && CLASSIFY_FILTER_CATEGORY=""
[[ "${CLASSIFY_PROJECT_TOKEN:-}" == "__none__" ]] && CLASSIFY_PROJECT_TOKEN=""
[[ "${CLASSIFY_ISSUE_NUMBER:-}" == "0" ]] && CLASSIFY_ISSUE_NUMBER=""

MIN_CONFIDENCE="${CLASSIFY_MIN_CONFIDENCE:-0.7}"
CONTEXT_DIR="/tmp/workspace/context"
DRY_RUN="${CLASSIFY_DRY_RUN:-false}"
FILTER_CATEGORY="${CLASSIFY_FILTER_CATEGORY:-}"

# Mask tokens immediately (only in GitHub Actions to avoid printing them locally).
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  [[ -n "${GH_TOKEN:-}" ]] && echo "::add-mask::${GH_TOKEN}"
  [[ -n "${CLASSIFY_PROJECT_TOKEN:-}" ]] && echo "::add-mask::${CLASSIFY_PROJECT_TOKEN}"
fi

# Use the project-specific PAT for cross-org project writes when available.
PROJECT_GH_TOKEN="${CLASSIFY_PROJECT_TOKEN:-${GH_TOKEN}}"

# Find the agent result JSON — prefer the validated iteration when set.
# Trust boundary: FULLSEND_VALIDATED_ITERATION_DIR is set by the fullsend CLI
# on the runner — not by the sandbox or the agent.
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  if [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
  elif [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/result.json"
  else
    echo "ERROR: FULLSEND_VALIDATED_ITERATION_DIR is set but contains neither agent-result.json nor result.json"
    exit 1
  fi
else
  # Backward compatibility: scan iteration-N/ subdirectories for the last
  # iteration's output (glob order = naturally ascending iteration numbers).
  RESULT_FILE=""
  for dir in iteration-*/output; do
    if [[ -f "${dir}/agent-result.json" ]]; then
      RESULT_FILE="${dir}/agent-result.json"
    fi
  done
fi

if [[ -z "${RESULT_FILE}" ]] || [[ ! -f "${RESULT_FILE}" ]]; then
  echo "ERROR: agent-result.json not found in any iteration output directory"
  exit 1
fi

echo "Reading classify result from: ${RESULT_FILE}"

if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

# Load project metadata from pre-script.
if [[ ! -f "${CONTEXT_DIR}/project-meta.json" ]]; then
  echo "ERROR: project-meta.json not found — pre-script may have failed"
  exit 1
fi

PROJECT_ID=$(jq -r '.project_id // empty' "${CONTEXT_DIR}/project-meta.json")
FIELD_ID=$(jq -r '.field_id // empty' "${CONTEXT_DIR}/project-meta.json")

if [[ -z "${PROJECT_ID}" || -z "${FIELD_ID}" ]]; then
  echo "WARNING: Project metadata incomplete — will skip project field updates."
fi

REPO="${CLASSIFY_SOURCE_REPO}"

# Load issue titles from the pre-script's open-issues.json for display.
# Pre-compute a TSV lookup file (number<TAB>title) to avoid running jq per issue.
ISSUES_FILE="${CONTEXT_DIR}/open-issues.json"
TITLES_FILE="/tmp/workspace/issue-titles.tsv"
if [[ -f "${ISSUES_FILE}" ]]; then
  jq -r '.[] | "\(.number)\t\(.title[:80])"' "${ISSUES_FILE}" > "${TITLES_FILE}" 2>/dev/null || true
else
  touch "${TITLES_FILE}"
fi

lookup_title() {
  local num="$1"
  awk -F'\t' -v n="${num}" '$1 == n { print $2; exit }' "${TITLES_FILE}"
}

AGENT_EVALUATED=$(jq '.classifications | length' "${RESULT_FILE}")
CLASSIFIED=0
SKIPPED=0
ERRORS=0
NOT_EVALUATED=0

# Build a set of issue numbers the agent evaluated for fast lookup.
AGENT_ISSUE_NUMS=$(jq -r '.classifications[].issue_number' "${RESULT_FILE}" | sort -n)

# Count total open issues from the pre-script's list.
if [[ -f "${ISSUES_FILE}" ]]; then
  ALL_OPEN_COUNT=$(jq length "${ISSUES_FILE}")
else
  ALL_OPEN_COUNT="${AGENT_EVALUATED}"
fi

# Prepare the report array (built incrementally).
REPORT_FILE="/tmp/workspace/classify-report.json"
echo '[]' > "${REPORT_FILE}"

echo ""
echo "============================================================"
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "  CLASSIFY AGENT -- DRY RUN"
else
  echo "  CLASSIFY AGENT -- LIVE RUN"
fi
echo "============================================================"
printf '  Repository:   %s\n' "${REPO}"
THRESHOLD_PCT=$(printf '%.0f' "$(echo "${MIN_CONFIDENCE} * 100" | bc -l)")
printf '  Threshold:    %s%%\n' "${THRESHOLD_PCT}"
if [[ -n "${FILTER_CATEGORY}" ]]; then
  printf '  Filter:       %s\n' "${FILTER_CATEGORY}"
fi
echo "------------------------------------------------------------"
echo ""

set_project_field() {
  local issue_number="$1"
  local category="$2"

  if [[ -z "${PROJECT_ID}" || -z "${FIELD_ID}" ]]; then
    return 1
  fi

  local option_id
  option_id=$(jq -r --arg name "${category}" \
    '.options[] | select(.name == $name) | .id' \
    "${CONTEXT_DIR}/project-meta.json")

  if [[ -z "${option_id}" ]]; then
    echo "  ⚠ No project option found for category '${category}'"
    return 1
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    return 0
  fi

  # Resolve the issue's node_id once (used by both add and query).
  local content_id err_output
  content_id=$(gh api "repos/${REPO}/issues/${issue_number}" --jq '.node_id' 2>/dev/null || true)
  if [[ -z "${content_id}" ]]; then
    echo "  ⚠ Failed to resolve node_id for #${issue_number}"
    return 1
  fi

  # addProjectV2ItemById is idempotent — if the issue is already on the
  # project it returns the existing item. If the mutation fails for any
  # reason, fall back to querying for the existing item.
  local item_id
  item_id=$(GH_TOKEN="${PROJECT_GH_TOKEN}" gh api graphql -f query='
    mutation($projectId: ID!, $contentId: ID!) {
      addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
        item { id }
      }
    }' -f projectId="${PROJECT_ID}" \
    -f contentId="${content_id}" \
    --jq '.data.addProjectV2ItemById.item.id' 2>/dev/null || true)

  if [[ -z "${item_id}" ]]; then
    # Fallback: item may already exist. Page through project items to find it.
    local cursor=""
    while true; do
      local GH_ARGS=(gh api graphql -f query='
        query($projectId: ID!, $afterCursor: String) {
          node(id: $projectId) {
            ... on ProjectV2 {
              items(first: 100, after: $afterCursor) {
                nodes {
                  id
                  content { ... on Issue { id } }
                }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
        }' -f projectId="${PROJECT_ID}")

      if [[ -n "${cursor}" ]]; then
        GH_ARGS+=(-f "afterCursor=${cursor}")
      fi

      local page_result
      page_result=$(GH_TOKEN="${PROJECT_GH_TOKEN}" "${GH_ARGS[@]}" 2>/dev/null || echo '{}')

      item_id=$(printf '%s' "${page_result}" | jq -r --arg cid "${content_id}" \
        '.data.node.items.nodes[]? | select(.content.id == $cid) | .id' 2>/dev/null || true)
      if [[ -n "${item_id}" ]]; then
        break
      fi

      local has_next
      has_next=$(printf '%s' "${page_result}" | jq -r '.data.node.items.pageInfo.hasNextPage // false')
      if [[ "${has_next}" != "true" ]]; then
        break
      fi
      cursor=$(printf '%s' "${page_result}" | jq -r '.data.node.items.pageInfo.endCursor // empty')
    done
  fi

  if [[ -z "${item_id}" ]]; then
    echo "  ⚠ Failed to add or find #${issue_number} on project"
    return 1
  fi

  err_output=$(GH_TOKEN="${PROJECT_GH_TOKEN}" gh api graphql -f query='
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: { singleSelectOptionId: $optionId }
      }) {
        projectV2Item { id }
      }
    }' -f projectId="${PROJECT_ID}" \
    -f itemId="${item_id}" \
    -f fieldId="${FIELD_ID}" \
    -f optionId="${option_id}" --silent 2>&1)
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    local safe_err
    safe_err=$(printf '%s' "${err_output}" | head -c 200 | sed "s/${PROJECT_GH_TOKEN:-__NONE__}/***TOKEN***/g")
    echo "  ⚠ Failed to set field on #${issue_number}: ${safe_err}"
    return 1
  fi

  return 0
}

# --- Process all agent-evaluated issues (build arrays for display later) ---
CLASSIFIED_LINES=()
SKIPPED_LINES=()
FILTER_MISMATCH_LINES=()
BELOW_THRESHOLD_LINES=()

for i in $(seq 0 $((AGENT_EVALUATED - 1))); do
  ISSUE_NUM=$(jq -r ".classifications[${i}].issue_number" "${RESULT_FILE}")
  CATEGORY=$(jq -r ".classifications[${i}].workstream_category // empty" "${RESULT_FILE}")
  CONFIDENCE=$(jq -r ".classifications[${i}].confidence" "${RESULT_FILE}")
  REASONING=$(jq -r ".classifications[${i}].reasoning" "${RESULT_FILE}")

  ACTIONS_TAKEN=""
  ISSUE_STATUS="skipped"

  # All API calls below are scoped to REPO (repos/${REPO}/issues/...).
  # Cross-repo writes are impossible — GitHub returns 404 for issue numbers
  # that don't exist in the target repo.

  # Safety net: if filter is active and agent returned a non-matching category, treat as null.
  FILTER_SKIPPED="false"
  if [[ -n "${FILTER_CATEGORY}" && -n "${CATEGORY}" && "${CATEGORY}" != "null" && "${CATEGORY}" != "${FILTER_CATEGORY}" ]]; then
    FILTER_SKIPPED="true"
    CATEGORY=""
  fi

  CATEGORY_ACTION="none"
  if [[ -n "${CATEGORY}" && "${CATEGORY}" != "null" ]]; then
    PASSES_THRESHOLD=$(printf '%s >= %s\n' "${CONFIDENCE}" "${MIN_CONFIDENCE}" | bc -l 2>/dev/null || echo "0")
    if [[ "${PASSES_THRESHOLD}" == "1" ]]; then
      if [[ "${DRY_RUN}" == "true" ]]; then
        ((CLASSIFIED++)) || true
        ISSUE_STATUS="classified"
        CATEGORY_ACTION="would-set"
        ACTIONS_TAKEN="${ACTIONS_TAKEN:+${ACTIONS_TAKEN}, }category:${CATEGORY}"
      elif set_project_field "${ISSUE_NUM}" "${CATEGORY}"; then
        ((CLASSIFIED++)) || true
        ISSUE_STATUS="classified"
        CATEGORY_ACTION="set"
        ACTIONS_TAKEN="${ACTIONS_TAKEN:+${ACTIONS_TAKEN}, }category:${CATEGORY}"
      else
        ((ERRORS++)) || true
        ISSUE_STATUS="error"
        CATEGORY_ACTION="error"
      fi
    else
      ((SKIPPED++)) || true
      CATEGORY_ACTION="below-threshold"
    fi
  else
    ((SKIPPED++)) || true
    if [[ "${FILTER_SKIPPED}" == "true" ]]; then
      CATEGORY_ACTION="filter-mismatch"
    else
      CATEGORY_ACTION="unclassifiable"
    fi
  fi

  ISSUE_TITLE=$(lookup_title "${ISSUE_NUM}")
  CONF_PCT=$(printf '%.0f' "$(echo "${CONFIDENCE} * 100" | bc -l)")

  if [[ "${ISSUE_STATUS}" == "classified" ]]; then
    CLASSIFIED_LINES+=("$(printf '  #%-4s  %3s%%  %s' "${ISSUE_NUM}" "${CONF_PCT}" "${ISSUE_TITLE}")")
  elif [[ "${ISSUE_STATUS}" == "error" ]]; then
    CLASSIFIED_LINES+=("$(printf '  #%-4s  ERR   %s' "${ISSUE_NUM}" "${ISSUE_TITLE}")")
  elif [[ "${CATEGORY_ACTION}" == "filter-mismatch" ]]; then
    FILTER_MISMATCH_LINES+=("$(printf '  #%-4s  %3s%%  %s' "${ISSUE_NUM}" "${CONF_PCT}" "${ISSUE_TITLE}")")
  elif [[ "${CATEGORY_ACTION}" == "below-threshold" ]]; then
    BELOW_THRESHOLD_LINES+=("$(printf '  #%-4s  %3s%%  %s' "${ISSUE_NUM}" "${CONF_PCT}" "${ISSUE_TITLE}")")
  else
    SKIPPED_LINES+=("$(printf '  #%-4s  %3s%%  %s' "${ISSUE_NUM}" "${CONF_PCT}" "${ISSUE_TITLE}")")
  fi

  SAFE_REASONING=$(printf '%s' "${REASONING}" | head -c 500)

  jq --argjson num "${ISSUE_NUM}" \
    --arg cat "${CATEGORY}" \
    --arg cat_action "${CATEGORY_ACTION}" \
    --arg status "${ISSUE_STATUS}" \
    --arg conf "${CONFIDENCE}" \
    --arg reason "${SAFE_REASONING}" \
    '. += [{
      issue_number: $num,
      status: $status,
      workstream_category: (if $cat == "" or $cat == "null" then null else $cat end),
      category_action: $cat_action,
      confidence: ($conf | tonumber),
      reasoning: $reason
    }]' "${REPORT_FILE}" > "${REPORT_FILE}.tmp" && mv "${REPORT_FILE}.tmp" "${REPORT_FILE}"
done

# --- Display: Classified issues ---
if [[ ${#CLASSIFIED_LINES[@]} -gt 0 ]]; then
  echo "CLASSIFIED (${#CLASSIFIED_LINES[@]} issues)"
  echo "------------------------------------------------------------"
  for line in "${CLASSIFIED_LINES[@]}"; do
    echo "${line}"
  done
  echo ""
fi

# --- Display: Below threshold ---
if [[ ${#BELOW_THRESHOLD_LINES[@]} -gt 0 ]]; then
  echo "BELOW ${THRESHOLD_PCT}% CONFIDENCE (${#BELOW_THRESHOLD_LINES[@]} issues)"
  echo "------------------------------------------------------------"
  for line in "${BELOW_THRESHOLD_LINES[@]}"; do
    echo "${line}"
  done
  echo ""
fi

# --- Display: Filter mismatch (agent classified into a different category) ---
if [[ ${#FILTER_MISMATCH_LINES[@]} -gt 0 ]]; then
  echo "NOT \"${FILTER_CATEGORY}\" (${#FILTER_MISMATCH_LINES[@]} issues)"
  echo "------------------------------------------------------------"
  printf '  Agent classified these into other categories — skipped because\n'
  printf '  filter is restricted to "%s"\n' "${FILTER_CATEGORY}"
  for line in "${FILTER_MISMATCH_LINES[@]}"; do
    echo "${line}"
  done
  echo ""
fi

# --- Display: Unclassifiable / belongs elsewhere (agent returned null) ---
if [[ ${#SKIPPED_LINES[@]} -gt 0 ]]; then
  if [[ -n "${FILTER_CATEGORY}" ]]; then
    echo "LIKELY BELONGS ELSEWHERE (${#SKIPPED_LINES[@]} issues)"
    echo "------------------------------------------------------------"
    printf '  Agent believes these belong in a different category,\n'
    printf '  not "%s" — confidence reflects certainty of mismatch\n' "${FILTER_CATEGORY}"
  else
    echo "UNCLASSIFIABLE (${#SKIPPED_LINES[@]} issues)"
    echo "------------------------------------------------------------"
    printf '  Agent could not confidently assign any category\n'
  fi
  for line in "${SKIPPED_LINES[@]}"; do
    echo "${line}"
  done
  echo ""
fi

# --- Section 2: Distinguish already-classified from screened-out ---
ALREADY_CLASSIFIED=0
SCREENED_OUT=0

CANDIDATE_NUMBERS_FILE="${CONTEXT_DIR}/issue-numbers.txt"
CURRENT_MODE="${CLASSIFY_MODE:-unclassified}"

if [[ -f "${ISSUES_FILE}" ]]; then
  if [[ "${CURRENT_MODE}" == "single" ]]; then
    : # Single mode: one specific issue was targeted, "already classified" is N/A
  elif [[ -f "${CANDIDATE_NUMBERS_FILE}" ]]; then
    CANDIDATE_COUNT=$(wc -l < "${CANDIDATE_NUMBERS_FILE}" | tr -d ' ')
    ALREADY_CLASSIFIED=$((ALL_OPEN_COUNT - CANDIDATE_COUNT))

    SCREENED_NUMS=()
    while IFS= read -r num; do
      if [[ -n "${num}" ]] && ! printf '%s\n' ${AGENT_ISSUE_NUMS} | grep -qx "${num}"; then
        SCREENED_NUMS+=("${num}")
      fi
    done < "${CANDIDATE_NUMBERS_FILE}"
    SCREENED_OUT=${#SCREENED_NUMS[@]}
  else
    while IFS= read -r num; do
      if ! printf '%s\n' ${AGENT_ISSUE_NUMS} | grep -qx "${num}"; then
        ((SCREENED_OUT++)) || true
      fi
    done < <(jq -r '.[].number' "${ISSUES_FILE}")
  fi

  if [[ ${ALREADY_CLASSIFIED} -gt 0 ]]; then
    printf 'ALREADY CLASSIFIED (%s issues)\n' "${ALREADY_CLASSIFIED}"
    echo "------------------------------------------------------------"
    printf '  %s issues already have a category on the project board\n' "${ALREADY_CLASSIFIED}"
    echo ""
  fi

  if [[ ${SCREENED_OUT} -gt 0 ]]; then
    printf 'SCREENED OUT (%s issues)\n' "${SCREENED_OUT}"
    echo "------------------------------------------------------------"
    if [[ -n "${FILTER_CATEGORY}" ]]; then
      printf '  %s issues did not match the "%s" filter\n' "${SCREENED_OUT}" "${FILTER_CATEGORY}"
    else
      printf '  %s issues screened out by title/labels before evaluation\n' "${SCREENED_OUT}"
    fi
    echo "  (full list available in classify-report.json artifact)"
    echo ""
  fi
fi

NOT_EVALUATED=$((ALREADY_CLASSIFIED + SCREENED_OUT))

echo "============================================================"
echo "  SUMMARY"
echo "============================================================"
if [[ "${CURRENT_MODE}" == "single" ]]; then
  printf '  Mode:               single (issue #%s)\n' "${CLASSIFY_ISSUE_NUMBER:-?}"
else
  printf '  Open issues:        %s\n' "${ALL_OPEN_COUNT}"
  if [[ ${ALREADY_CLASSIFIED} -gt 0 ]]; then
    printf '  Already classified: %s\n' "${ALREADY_CLASSIFIED}"
  fi
  printf '  Candidates:         %s\n' "$((ALL_OPEN_COUNT - ALREADY_CLASSIFIED))"
fi
printf '  Agent evaluated:    %s\n' "${AGENT_EVALUATED}"
printf '    Classified:       %s\n' "${CLASSIFIED}"
printf '    Skipped:          %s\n' "${SKIPPED}"
if [[ ${ERRORS} -gt 0 ]]; then
  printf '    Errors:           %s\n' "${ERRORS}"
fi
printf '  Screened out:       %s\n' "${SCREENED_OUT}"
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "------------------------------------------------------------"
  echo "  DRY RUN -- no changes were written to GitHub"
fi
echo "============================================================"

# Copy the report to the output directory so it's included in artifacts.
LATEST_OUTPUT=""
for dir in iteration-*/output; do
  if [[ -d "${dir}" ]]; then
    LATEST_OUTPUT="${dir}"
  fi
done
if [[ -n "${LATEST_OUTPUT}" ]]; then
  cp "${REPORT_FILE}" "${LATEST_OUTPUT}/classify-report.json"
  echo ""
  echo "Report written to ${LATEST_OUTPUT}/classify-report.json"
fi

# Write GitHub Step Summary.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Classify Agent Results"
    echo ""
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "> **DRY RUN** — no changes were applied to GitHub. Review the table below to see what *would* happen."
      echo ""
    fi
    echo "| Metric | Count |"
    echo "|--------|------:|"
    if [[ "${CURRENT_MODE}" == "single" ]]; then
      echo "| Mode | single (issue #${CLASSIFY_ISSUE_NUMBER:-?}) |"
    else
      echo "| Total open issues | ${ALL_OPEN_COUNT} |"
      if [[ ${ALREADY_CLASSIFIED} -gt 0 ]]; then
        echo "| Already classified | ${ALREADY_CLASSIFIED} |"
      fi
      echo "| Candidates | $((ALL_OPEN_COUNT - ALREADY_CLASSIFIED)) |"
    fi
    echo "| Agent evaluated | ${AGENT_EVALUATED} |"
    echo "| Screened out | ${SCREENED_OUT} |"
    echo "| Classified | ${CLASSIFIED} |"
    echo "| Skipped (low conf) | ${SKIPPED} |"
    echo "| Errors | ${ERRORS} |"
    echo ""
    echo "**Confidence threshold:** ${THRESHOLD_PCT}%"
    if [[ -n "${FILTER_CATEGORY}" ]]; then
      echo ""
      echo "**Filter:** ${FILTER_CATEGORY}"
    fi
    echo ""
    echo "### Classified issues"
    echo ""
    echo "| Issue | Category | Confidence | Action |"
    echo "|------:|----------|:----------:|--------|"
    jq -r '
      .[] | select(.status == "classified") |
      "| #\(.issue_number) | \(.workstream_category // "—") | \((.confidence * 100) | floor)% | \(.category_action) |"
    ' "${REPORT_FILE}" 2>/dev/null || echo "| — | — | — | — |"
    echo ""
    echo "### Skipped issues (below threshold)"
    echo ""
    echo "| Issue | Confidence | Reasoning |"
    echo "|------:|:----------:|-----------|"
    jq -r '
      .[] | select(.status == "skipped") |
      "| #\(.issue_number) | \((.confidence * 100) | floor)% | \(.reasoning | gsub("\n"; " ") | gsub("\\|"; "∣") | if length > 100 then .[:100] + "…" else . end) |"
    ' "${REPORT_FILE}" 2>/dev/null || echo "| — | — | — |"
  } >> "${GITHUB_STEP_SUMMARY}"
fi

if [[ ${ERRORS} -gt 0 ]]; then
  echo "::warning::${ERRORS} error(s) during classification"
fi

