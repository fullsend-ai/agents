#!/usr/bin/env bash
# post-triage.sh — Parse triage agent JSON output and perform mutations.
#
# Runs on the host after sandbox cleanup. Working directory is the fullsend
# run output directory (e.g., /tmp/fullsend/agent-triage-<id>/iteration-1/).
#
# Required env vars:
#   ISSUE_URL        — HTML URL of the issue
#   FULLSEND_TRACKER — "github", "gitlab", or "jira" (falls back to FULLSEND_FORGE)
#
# The agent writes its decision to output/agent-result.json (relative to
# the iteration directory). This script finds the most recent iteration's output.
#
# IMPORTANT: Label mutations use the labels API directly instead of issue edit
# commands. On GitHub, gh issue edit uses PATCH /issues/{number} which fires
# issues.edited, re-triggering the triage dispatch in the shim workflow.
# The labels API (POST/DELETE /issues/{number}/labels) only fires
# issues.labeled/issues.unlabeled, avoiding the re-triage loop.

set -euo pipefail

: "${ISSUE_URL:?ISSUE_URL must be set}"
FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE:-}}"
: "${FULLSEND_TRACKER:?FULLSEND_TRACKER must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/triage-ops.lib.sh
source "${SCRIPT_DIR}/lib/triage-ops.lib.sh"
# shellcheck source=lib/labels.lib.sh
source "${SCRIPT_DIR}/lib/labels.lib.sh"

# Find the triage result JSON — prefer the validated iteration when set.
# Trust boundary: FULLSEND_VALIDATED_ITERATION_DIR is set by the fullsend CLI
# on the runner — not by the sandbox or the agent. No containment check
# (realpath / prefix guard) is applied here; the value is trusted from the
# external harness. If the trust model changes, add a realpath prefix check.
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  if [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
  elif [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/result.json"
  else
    echo "ERROR: FULLSEND_VALIDATED_ITERATION_DIR is set but contains neither agent-result.json nor result.json" >&2
    exit 1
  fi
else
  # Backward compatibility: scan iteration-N/ subdirectories for the last one's output.
  RESULT_FILE=""
  for dir in iteration-*/output; do
    if [[ -f "${dir}/agent-result.json" ]]; then
      RESULT_FILE="${dir}/agent-result.json"
    fi
  done
fi

if [[ -z "${RESULT_FILE}" ]]; then
  echo "ERROR: agent-result.json not found in any iteration output directory" >&2
  exit 1
fi

echo "Reading triage result from: ${RESULT_FILE}"

# Validate JSON is parseable.
if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON" >&2
  exit 1
fi

ACTION=$(jq -r '.action' "${RESULT_FILE}")
COMMENT=$(jq -r '.comment // empty' "${RESULT_FILE}")

tracker_validate_issue_url
tracker_parse_issue_url

echo "Action: ${ACTION}"
echo "Repo: ${REPO}"
echo "Issue: #${ISSUE_NUMBER}"

# Control labels managed by the triage pipeline. The post script refuses to
# add or remove these via label_actions. pre-triage.sh resets needs-info,
# ready-to-code, duplicate, feature, question, not-planned, and pr-open
# before each run; the action handlers below apply the rest. pr-open is
# also created and applied independently by the code agent's pre-check
# (scripts/pre-code.sh) when it finds a human PR before dispatching.
CONTROL_LABELS=("needs-info" "ready-to-code" "duplicate" "feature" "blocked" "triaged" "question" "bug" "documentation" "not-planned" "pr-open")

is_control_label() {
  local label="$1"
  for cl in "${CONTROL_LABELS[@]}"; do
    if [[ "${cl}" == "${label}" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Action-specific validation and control labels ---

# Deferred label: when set, applied after label_actions so it fires last.
# This prevents the ready-to-code webhook event from being superseded by
# subsequent label events in the dispatch concurrency group (see #1752).
DEFERRED_LABEL=""

# Clear a stale "triaged" label from a prior re-triage before dispatching on
# the new action. Every terminal action below resets its own set of control
# labels, but "triaged" is only ever re-applied (never removed) by the
# handlers themselves, so it must be cleared up front rather than per-branch.
tracker_remove_label "triaged"

# --- Cross-repo issue creation allowlist ---
# Used by prerequisites and split actions. Read once before the case
# statement so both handlers share the same config and helper.

WORKSPACE="${GITHUB_WORKSPACE:-${CI_PROJECT_DIR:-/tmp}}"
CONFIG_FILE="${WORKSPACE}/config.yaml"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  CONFIG_FILE="${WORKSPACE}/.fullsend/config.yaml"
fi

ALLOWED_ORGS=""
ALLOWED_REPOS=""
ALLOWED_JIRA_PROJECTS=""
if [[ -f "${CONFIG_FILE}" ]] && ! command -v yq &>/dev/null; then
  echo "::warning::yq not found — cannot read create_issues.allow_targets from config; cross-repo issue creation disabled"
fi
if [[ -f "${CONFIG_FILE}" ]] && command -v yq &>/dev/null; then
  ALLOWED_ORGS=$(yq -r '.create_issues.allow_targets.orgs // [] | .[]' "${CONFIG_FILE}" 2>/dev/null || true)
  ALLOWED_REPOS=$(yq -r '.create_issues.allow_targets.repos // [] | .[]' "${CONFIG_FILE}" 2>/dev/null || true)
  ALLOWED_JIRA_PROJECTS=$(yq -r '.create_issues.allow_targets.jira_projects // [] | .[]' "${CONFIG_FILE}" 2>/dev/null || true)
fi

is_target_allowed() {
  local target_repo="$1"
  local target_org="${target_repo%%/*}"

  if [[ "${target_repo}" == "${REPO}" ]]; then
    return 0
  fi

  if [[ -n "${ALLOWED_ORGS}" ]] && echo "${ALLOWED_ORGS}" | grep -qFx "${target_org}"; then
    return 0
  fi

  if [[ -n "${ALLOWED_REPOS}" ]] && echo "${ALLOWED_REPOS}" | grep -qFx "${target_repo}"; then
    return 0
  fi

  if [[ -n "${ALLOWED_JIRA_PROJECTS}" ]] && echo "${ALLOWED_JIRA_PROJECTS}" | grep -qFx "${target_repo}"; then
    return 0
  fi

  return 1
}

case "${ACTION}" in
  insufficient)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'insufficient' but no comment provided" >&2
      exit 1
    fi
    tracker_remove_label "blocked"
    tracker_remove_label "pr-open"
    tracker_add_label "needs-info"
    ;;

  duplicate)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'duplicate' but no comment provided" >&2
      exit 1
    fi
    DUPLICATE_OF=$(jq -r '.duplicate_of' "${RESULT_FILE}")
    if [[ "${DUPLICATE_OF}" == "${ISSUE_NUMBER}" ]]; then
      echo "ERROR: issue cannot be a duplicate of itself (#${ISSUE_NUMBER})" >&2
      exit 1
    fi
    tracker_remove_label "blocked"
    tracker_remove_label "pr-open"
    tracker_add_label "duplicate"
    ;;

  prerequisites)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'prerequisites' but no comment provided" >&2
      exit 1
    fi

    # Process create entries: create issues, collect URLs.
    CREATE_COUNT=$(jq '.prerequisites.create // [] | length' "${RESULT_FILE}")
    CREATED_URLS=""
    FAILED_CREATES=""

    for i in $(seq 0 $((CREATE_COUNT - 1))); do
      TARGET_REPO=$(jq -r ".prerequisites.create[${i}].repo" "${RESULT_FILE}")
      ISSUE_TITLE=$(jq -r ".prerequisites.create[${i}].title" "${RESULT_FILE}")
      ISSUE_BODY=$(jq -r ".prerequisites.create[${i}].body" "${RESULT_FILE}")

      if ! is_target_allowed "${TARGET_REPO}"; then
        echo "::warning::Skipping issue creation in '$(_gha_sanitize "${TARGET_REPO}")' — not in create_issues.allow_targets"
        FAILED_CREATES="${FAILED_CREATES}
<details>
<summary>Prerequisite: ${TARGET_REPO} — ${ISSUE_TITLE}</summary>

${ISSUE_BODY}

</details>"
        continue
      fi

      echo "Creating prerequisite issue in $(_gha_sanitize "${TARGET_REPO}")..."
      CREATED_URL=$(tracker_create_issue "${TARGET_REPO}" "${ISSUE_TITLE}" "${ISSUE_BODY}") || {
        echo "::warning::Failed to create issue in '$(_gha_sanitize "${TARGET_REPO}")' (see stderr for details)"
        FAILED_CREATES="${FAILED_CREATES}
<details>
<summary>Prerequisite: ${TARGET_REPO} — ${ISSUE_TITLE}</summary>

${ISSUE_BODY}

</details>"
        continue
      }
      echo "Created: ${CREATED_URL}"
      CREATED_URLS="${CREATED_URLS} ${CREATED_URL}"
    done

    # Collect existing URLs.
    EXISTING_COUNT=$(jq '.prerequisites.existing // [] | length' "${RESULT_FILE}")
    EXISTING_URLS=""
    for i in $(seq 0 $((EXISTING_COUNT - 1))); do
      URL=$(jq -r ".prerequisites.existing[${i}].url" "${RESULT_FILE}")
      EXISTING_URLS="${EXISTING_URLS} ${URL}"
    done

    # Merge all blocker URLs for the comment.
    ALL_URLS="${EXISTING_URLS} ${CREATED_URLS}"
    ALL_URLS=$(echo "${ALL_URLS}" | xargs)  # trim whitespace

    if [[ -n "${ALL_URLS}" ]]; then
      BLOCKER_LIST=""
      for url in ${ALL_URLS}; do
        BLOCKER_LIST="${BLOCKER_LIST}
- ${url}"
      done
      COMMENT="${COMMENT}

**Blocked by:**${BLOCKER_LIST}"
    fi

    if [[ -n "${FAILED_CREATES}" ]]; then
      COMMENT="${COMMENT}

**Could not create automatically** (file manually or update \`create_issues.allow_targets\` in config.yaml):
${FAILED_CREATES}"
    fi

    tracker_remove_label "ready-to-code"
    tracker_remove_label "needs-info"
    tracker_remove_label "pr-open"
    tracker_add_label "blocked"
    ;;

  in-progress)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'in-progress' but no comment provided" >&2
      exit 1
    fi

    # Guard: an in-progress result with no PR to point at is useless — it would
    # apply pr-open and claim a PR addresses the issue without linking one. The
    # schema requires pull_requests here, but re-check rather than trust that
    # validation gated us (the agent is told to emit its best JSON after 3
    # failed validation attempts).
    PR_COUNT=$(jq '.pull_requests // [] | length' "${RESULT_FILE}")
    if [[ "${PR_COUNT}" -eq 0 ]]; then
      echo "ERROR: action is 'in-progress' but no pull_requests provided" >&2
      exit 1
    fi

    # The prompt tells the agent to note separate blockers in comment rather
    # than populating prerequisites alongside pull_requests. Nothing enforces
    # that, so warn when we drop it instead of discarding it silently.
    DROPPED_PREREQS=$(jq '((.prerequisites.existing // []) + (.prerequisites.create // [])) | length' "${RESULT_FILE}")
    if [[ "${DROPPED_PREREQS}" -gt 0 ]]; then
      echo "::warning::Ignoring 'prerequisites' on an 'in-progress' result -- mention separate blockers in 'comment' instead"
    fi

    # Collect PR URLs from pull_requests array. Capture via command
    # substitution rather than process substitution so a jq failure — a
    # pull_requests that passed the count check but is not an array of
    # objects, e.g. a bare string — still trips set -e instead of silently
    # rendering an empty list. -e also rejects a null url.
    PR_URLS=$(jq -er '.pull_requests[].url' "${RESULT_FILE}")
    PR_LIST=""
    while IFS= read -r url; do
      PR_LIST="${PR_LIST}
- ${url}"
    done <<< "${PR_URLS}"

    COMMENT="${COMMENT}

**Addressed by:**${PR_LIST}"

    tracker_remove_label "blocked"
    tracker_remove_label "ready-to-code"
    tracker_remove_label "needs-info"
    tracker_create_label "pr-open" "An open PR already addresses this issue" "D4C5F9"
    tracker_add_label "pr-open"
    ;;

  sufficient)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'sufficient' but no comment provided" >&2
      exit 1
    fi

    # Guard: reject sufficient results that contain information_gaps.
    # If the agent identified open questions, it should have used "insufficient".
    GAP_COUNT=$(jq '.triage_summary.information_gaps // [] | length' "${RESULT_FILE}")
    if [[ "${GAP_COUNT}" -gt 0 ]]; then
      echo "ERROR: action is 'sufficient' but triage_summary contains ${GAP_COUNT} information_gaps — open questions must block triage" >&2
      exit 1
    fi

    # Guard: warn and strip label_actions that contradict triage_summary.category.
    # Maps each category to label names that would be inconsistent (e.g., category
    # "documentation" should not apply an "enhancement" label). See #39.
    # Control labels are excluded — they are already handled by is_control_label().
    if [[ "$(jq 'has("label_actions")' "${RESULT_FILE}")" == "true" ]]; then
      CATEGORY_CHECK=$(jq -r '.triage_summary.category // "unknown"' "${RESULT_FILE}")
      CONTRADICTING_LABELS=""
      case "${CATEGORY_CHECK}" in
        bug)           CONTRADICTING_LABELS="enhancement" ;;
        documentation) CONTRADICTING_LABELS="enhancement" ;;
        performance)   CONTRADICTING_LABELS="enhancement" ;;
        security)      CONTRADICTING_LABELS="enhancement" ;;
      esac
      if [[ -n "${CONTRADICTING_LABELS}" ]]; then
        # Build a jq array of labels to strip.
        JQ_ARRAY="["
        first=true
        for cl in ${CONTRADICTING_LABELS}; do
          ${first} || JQ_ARRAY="${JQ_ARRAY},"
          JQ_ARRAY="${JQ_ARRAY}\"${cl}\""
          first=false
        done
        JQ_ARRAY="${JQ_ARRAY}]"

        # Log which labels are being stripped.
        STRIPPED=$(jq -r --argjson bad "${JQ_ARRAY}" \
          '.label_actions.actions[] | select(.label as $l | $bad | index($l)) | .label' \
          "${RESULT_FILE}")
        for lbl in ${STRIPPED}; do
          echo "::warning::Stripping label '$(_gha_sanitize "${lbl}")' from label_actions — contradicts triage_summary.category '$(_gha_sanitize "${CATEGORY_CHECK}")'"
        done

        # Remove contradicting labels from the actions array.
        if [[ -n "${STRIPPED}" ]]; then
          RESULT_FILE_TMP="${RESULT_FILE}.tmp"
          jq --argjson bad "${JQ_ARRAY}" \
            '.label_actions.actions |= [.[] | select(.label as $l | $bad | index($l) | not)]' \
            "${RESULT_FILE}" > "${RESULT_FILE_TMP}" && mv "${RESULT_FILE_TMP}" "${RESULT_FILE}"

          # If all actions were removed, drop label_actions entirely.
          REMAINING=$(jq '.label_actions.actions | length' "${RESULT_FILE}")
          if [[ "${REMAINING}" -eq 0 ]]; then
            RESULT_FILE_TMP="${RESULT_FILE}.tmp"
            jq 'del(.label_actions)' "${RESULT_FILE}" > "${RESULT_FILE_TMP}" && mv "${RESULT_FILE_TMP}" "${RESULT_FILE}"
          fi
        fi
      fi
    fi

    tracker_remove_label "blocked"
    tracker_remove_label "needs-info"
    tracker_remove_label "pr-open"

    # Low-risk categories (bug, documentation, performance) auto-promote to
    # ready-to-code, which triggers the code agent. Feature work and anything
    # else receives the triaged label and waits for human prioritization
    # (per #561, only feature issues should require human review before coding).
    #
    # TRIAGE_AUTO_CODE (#1754) controls whether auto-promotion happens:
    #   on (default) — auto-promote categories listed in TRIAGE_AUTO_CODE_CATEGORIES
    #   off          — never auto-promote; always apply triaged
    #
    # TRIAGE_AUTO_CODE_CATEGORIES is a comma-separated category list with no
    # default baked into this script -- harness/triage.yaml and docs/triage.md
    # own the "bug,documentation,performance" default. An absent or unset
    # TRIAGE_AUTO_CODE_CATEGORIES means no categories auto-promote.
    #
    # Workflow-change guard (#325): if triage detected that the fix requires
    # modifying workflow files (.github/workflows/, .fullsend/.github/workflows/,
    # or shim workflows), skip ready-to-code regardless of category. The code
    # agent cannot modify workflow files under current permissions.
    REQUIRES_WORKFLOW=$(jq -r '.triage_summary.requires_workflow_changes // false' "${RESULT_FILE}")
    CATEGORY=$(jq -r '.triage_summary.category // "unknown"' "${RESULT_FILE}")
    echo "Category: ${CATEGORY}"

    AUTO_CODE="${TRIAGE_AUTO_CODE:-on}"
    AUTO_CODE="$(printf '%s' "${AUTO_CODE}" | tr '[:upper:]' '[:lower:]')"

    # Check whether CATEGORY appears in the comma-separated TRIAGE_AUTO_CODE_CATEGORIES list.
    category_in_auto_code_list() {
      local categories="${TRIAGE_AUTO_CODE_CATEGORIES:-}"
      categories="${categories//[[:space:]]/}"
      categories="$(printf '%s' "${categories}" | tr '[:upper:]' '[:lower:]')"
      echo ",${categories}," | grep -qF ",${CATEGORY},"
    }

    # Determine whether this category should auto-promote to ready-to-code.
    auto_code_allowed() {
      case "${AUTO_CODE}" in
        off) return 1 ;;
        on) category_in_auto_code_list ;;
        *)
          echo "::warning::Unrecognized TRIAGE_AUTO_CODE value '$(_gha_sanitize "${AUTO_CODE}")' — falling back to 'on'"
          category_in_auto_code_list
          ;;
      esac
    }

    # Evaluate once — auto_code_allowed() can emit a ::warning:: for
    # unrecognized TRIAGE_AUTO_CODE values, and calling it repeatedly below
    # would duplicate that annotation in the Actions UI.
    if auto_code_allowed; then
      AUTO_CODE_ALLOWED=true
    else
      AUTO_CODE_ALLOWED=false
    fi

    # Workflow-change guard: if triage detected workflow file changes, always
    # log the (#325) warning for operational visibility. Only block auto-
    # promotion (apply triaged early) when the category would otherwise
    # auto-promote to ready-to-code.
    WORKFLOW_BLOCKED=false
    if [[ "${REQUIRES_WORKFLOW}" == "true" ]]; then
      echo "::warning::Triage detected workflow file changes required (#325)"
      if [[ "${AUTO_CODE_ALLOWED}" == "true" ]]; then
        echo "Applying triaged label (workflow changes required)..."
        tracker_add_label "triaged"
        WORKFLOW_BLOCKED=true
      fi
    fi
    case "${CATEGORY}" in
      bug)
        echo "Applying bug label..."
        tracker_add_label "bug"
        if [[ "${WORKFLOW_BLOCKED}" != "true" ]] && [[ "${AUTO_CODE_ALLOWED}" == "true" ]]; then
          echo "Deferring ready-to-code label (${CATEGORY}) until after label_actions..."
          DEFERRED_LABEL="ready-to-code"
        elif [[ "${WORKFLOW_BLOCKED}" != "true" ]]; then
          echo "Applying triaged label (auto-code disabled for ${CATEGORY})..."
          tracker_add_label "triaged"
        fi
        ;;
      documentation)
        echo "Applying documentation label..."
        tracker_add_label "documentation"
        if [[ "${WORKFLOW_BLOCKED}" != "true" ]] && [[ "${AUTO_CODE_ALLOWED}" == "true" ]]; then
          echo "Deferring ready-to-code label (${CATEGORY}) until after label_actions..."
          DEFERRED_LABEL="ready-to-code"
        elif [[ "${WORKFLOW_BLOCKED}" != "true" ]]; then
          echo "Applying triaged label (auto-code disabled for ${CATEGORY})..."
          tracker_add_label "triaged"
        fi
        ;;
      performance)
        if [[ "${WORKFLOW_BLOCKED}" != "true" ]] && [[ "${AUTO_CODE_ALLOWED}" == "true" ]]; then
          echo "Deferring ready-to-code label (${CATEGORY}) until after label_actions..."
          DEFERRED_LABEL="ready-to-code"
        elif [[ "${WORKFLOW_BLOCKED}" != "true" ]]; then
          echo "Applying triaged label (auto-code disabled for ${CATEGORY})..."
          tracker_add_label "triaged"
        fi
        ;;
      feature)
        echo "Applying feature + triaged labels..."
        tracker_add_label "feature"
        tracker_add_label "triaged"
        ;;
      *)
        echo "Applying triaged label (${CATEGORY})..."
        tracker_add_label "triaged"
        ;;
    esac
    ;;

  split)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'split' but no comment provided" >&2
      exit 1
    fi

    SUB_ISSUE_COUNT=$(jq '.sub_issues // [] | length' "${RESULT_FILE}")
    if [[ "${SUB_ISSUE_COUNT}" -lt 2 ]]; then
      echo "ERROR: action is 'split' but fewer than 2 sub-issues provided" >&2
      exit 1
    fi

    # Ensure the ready-for-triage label exists so dispatch works for
    # each sub-issue. forge_ensure_label is a no-op for non-mandatory
    # labels and for Jira (which has no label registry).
    if [[ "${FULLSEND_TRACKER}" != "jira" ]]; then
      forge_ensure_label "ready-for-triage"
    fi

    CREATED_URLS=""
    FAILED_CREATES=""
    FAILED_DISPATCHES=""
    for i in $(seq 0 $((SUB_ISSUE_COUNT - 1))); do
      SUB_TITLE=$(jq -r ".sub_issues[${i}].title" "${RESULT_FILE}")
      SUB_BODY=$(jq -r ".sub_issues[${i}].body" "${RESULT_FILE}")
      TARGET_REPO=$(jq -r ".sub_issues[${i}].repo // empty" "${RESULT_FILE}")
      TARGET_REPO="${TARGET_REPO:-${REPO}}"

      SAFE_TITLE="${SUB_TITLE//$'\n'/ }"
      SAFE_TITLE="${SAFE_TITLE//::/-}"

      if ! is_target_allowed "${TARGET_REPO}"; then
        echo "::warning::Skipping sub-issue creation in '$(_gha_sanitize "${TARGET_REPO}")' — not in create_issues.allow_targets"
        FAILED_CREATES="${FAILED_CREATES}
<details>
<summary>Sub-issue: ${TARGET_REPO} — ${SUB_TITLE}</summary>

${SUB_BODY}

</details>"
        continue
      fi

      echo "Creating sub-issue ${i}: $(_gha_sanitize "${SAFE_TITLE}") (repo: $(_gha_sanitize "${TARGET_REPO}"))..."
      CREATED_URL=$(tracker_create_issue "${TARGET_REPO}" "${SUB_TITLE}" "${SUB_BODY}") || {
        echo "::warning::Failed to create sub-issue '$(_gha_sanitize "${SAFE_TITLE}")' (see stderr for details)"
        FAILED_CREATES="${FAILED_CREATES}
<details>
<summary>Sub-issue: ${TARGET_REPO} — ${SUB_TITLE}</summary>

${SUB_BODY}

</details>"
        continue
      }
      echo "Created: ${CREATED_URL}"
      CREATED_URLS="${CREATED_URLS}
- ${CREATED_URL}"

      # Dispatch triage for the newly created sub-issue by applying
      # the ready-for-triage label. A dispatch failure must not prevent
      # other sub-issues from being created or dispatched (#1123).
      echo "Dispatching triage for sub-issue: ${CREATED_URL}"
      if ! tracker_dispatch_triage "${CREATED_URL}"; then
        FAILED_DISPATCHES="${FAILED_DISPATCHES}
- ${CREATED_URL}"
      fi
    done

    if [[ -z "${CREATED_URLS}" ]] && [[ -n "${FAILED_CREATES}" ]]; then
      echo "ERROR: all sub-issue creations failed — not closing the original issue" >&2
      exit 1
    fi

    if [[ -n "${CREATED_URLS}" ]]; then
      COMMENT="${COMMENT}

**Split into:**${CREATED_URLS}"
    fi

    if [[ -n "${FAILED_CREATES}" ]]; then
      COMMENT="${COMMENT}

**Could not create automatically** (file manually or update \`create_issues.allow_targets\` in config.yaml):
${FAILED_CREATES}"
    fi

    if [[ -n "${FAILED_DISPATCHES}" ]]; then
      COMMENT="${COMMENT}

**Triage dispatch failed** (run \`/fs-triage\` manually on these issues):
${FAILED_DISPATCHES}"
    fi

    tracker_remove_label "blocked"
    tracker_remove_label "needs-info"
    tracker_remove_label "ready-to-code"
    tracker_remove_label "pr-open"
    ;;

  question)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'question' but no comment provided" >&2
      exit 1
    fi
    tracker_remove_label "blocked"
    tracker_remove_label "needs-info"
    tracker_remove_label "pr-open"
    tracker_add_label "question"
    ;;

  not-planned)
    if [[ -z "${COMMENT}" ]]; then
      echo "ERROR: action is 'not-planned' but no comment provided" >&2
      exit 1
    fi
    tracker_remove_label "blocked"
    tracker_remove_label "needs-info"
    tracker_remove_label "pr-open"
    tracker_add_label "not-planned"
    ;;

  *)
    echo "ERROR: unknown action '${ACTION}' — this may be a newer action that post-triage.sh does not handle yet" >&2
    exit 1
    ;;
esac

# --- Process label_actions (applies to all actions) ---

HAS_LABEL_ACTIONS=$(jq 'has("label_actions")' "${RESULT_FILE}")
if [[ "${HAS_LABEL_ACTIONS}" == "true" ]]; then
  LABEL_REASON=$(jq -r '.label_actions.reason' "${RESULT_FILE}")
  LABEL_COUNT=$(jq '.label_actions.actions | length' "${RESULT_FILE}")

  echo "Processing ${LABEL_COUNT} label action(s)..."

  EXISTING_LABELS=$(tracker_list_repo_labels)

  label_exists() {
    local label="$1"
    echo "${EXISTING_LABELS}" | grep -qFx "${label}"
  }

  LABELS_APPLIED=0
  for i in $(seq 0 $((LABEL_COUNT - 1))); do
    LA_ACTION=$(jq -r ".label_actions.actions[${i}].action" "${RESULT_FILE}")
    LA_LABEL=$(jq -r ".label_actions.actions[${i}].label" "${RESULT_FILE}")

    # Validate label name to prevent path injection from untrusted agent output.
    if [[ ! "${LA_LABEL}" =~ ^[a-zA-Z0-9._/:\ +\-]+$ ]]; then
      echo "::warning::Refused label '$(_gha_sanitize "${LA_LABEL}")' -- contains invalid characters"
      continue
    fi

    if is_control_label "${LA_LABEL}"; then
      echo "::warning::Refused to $(_gha_sanitize "${LA_ACTION}") control label '$(_gha_sanitize "${LA_LABEL}")' -- control labels are managed by the triage pipeline"
      continue
    fi

    case "${LA_ACTION}" in
      add)
        if ! label_exists "${LA_LABEL}"; then
          echo "::warning::Skipping label '$(_gha_sanitize "${LA_LABEL}")' -- does not exist in repo (will not auto-create)"
          continue
        fi
        echo "Adding label '$(_gha_sanitize "${LA_LABEL}")'..."
        tracker_add_label "${LA_LABEL}"
        LABELS_APPLIED=$((LABELS_APPLIED + 1))
        ;;
      remove)
        echo "Removing label '$(_gha_sanitize "${LA_LABEL}")'..."
        tracker_remove_label "${LA_LABEL}"
        LABELS_APPLIED=$((LABELS_APPLIED + 1))
        ;;
      *)
        echo "::warning::Unknown label action '$(_gha_sanitize "${LA_ACTION}")' for label '$(_gha_sanitize "${LA_LABEL}")'"
        ;;
    esac
  done

  # Append the label reason to the comment only if at least one label was applied.
  if [[ "${LABELS_APPLIED}" -gt 0 ]]; then
    COMMENT="${COMMENT}

---
**Labels:** ${LABEL_REASON}"
  fi
fi

# --- Process component_actions (Jira only) ---

HAS_COMPONENT_ACTIONS=$(jq 'has("component_actions")' "${RESULT_FILE}")
if [[ "${HAS_COMPONENT_ACTIONS}" == "true" ]]; then
  if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
    COMPONENT_REASON=$(jq -r '.component_actions.reason' "${RESULT_FILE}")
    COMPONENT_COUNT=$(jq '.component_actions.actions | length' "${RESULT_FILE}")

    echo "Processing ${COMPONENT_COUNT} component action(s)..."

    # Get current components on the issue. Abort component processing on
    # failure — falling back to "[]" would cause tracker_set_components (a
    # full replacement via PUT) to silently delete pre-existing components.
    if ! CURRENT_COMPONENTS=$(tracker_get_components); then
      echo "::warning::Failed to fetch current components — skipping component mutations to avoid data loss"
    else
      # Build the new component list by applying add/remove actions.
      NEW_COMPONENTS="${CURRENT_COMPONENTS}"
      COMPONENTS_APPLIED=0
      for i in $(seq 0 $((COMPONENT_COUNT - 1))); do
        CA_ACTION=$(jq -r ".component_actions.actions[${i}].action" "${RESULT_FILE}")
        CA_COMPONENT=$(jq -r ".component_actions.actions[${i}].component" "${RESULT_FILE}")

        # Validate component name to prevent injection from untrusted agent output.
        # More permissive than label regex — Jira component names may contain
        # parentheses, ampersands, commas, and apostrophes.
        if [[ ! "${CA_COMPONENT}" =~ ^[a-zA-Z0-9\ _./:+\(\)\&,\'\-]+$ ]]; then
          echo "::warning::Refused component '$(_gha_sanitize "${CA_COMPONENT}")' -- contains invalid characters"
          continue
        fi

        case "${CA_ACTION}" in
          add)
            echo "Adding component '$(_gha_sanitize "${CA_COMPONENT}")'..."
            NEW_COMPONENTS=$(echo "${NEW_COMPONENTS}" | jq --arg c "${CA_COMPONENT}" \
              'if any(. == $c) then . else . + [$c] end')
            COMPONENTS_APPLIED=$((COMPONENTS_APPLIED + 1))
            ;;
          remove)
            echo "Removing component '$(_gha_sanitize "${CA_COMPONENT}")'..."
            NEW_COMPONENTS=$(echo "${NEW_COMPONENTS}" | jq --arg c "${CA_COMPONENT}" \
              '[.[] | select(. != $c)]')
            COMPONENTS_APPLIED=$((COMPONENTS_APPLIED + 1))
            ;;
          *)
            echo "::warning::Unknown component action '$(_gha_sanitize "${CA_ACTION}")' for component '$(_gha_sanitize "${CA_COMPONENT}")'"
            ;;
        esac
      done

      # Apply the updated component list to the issue.
      if [[ "${COMPONENTS_APPLIED}" -gt 0 ]]; then
        COMPONENTS_PAYLOAD=$(echo "${NEW_COMPONENTS}" | jq '[.[] | {name: .}]')
        tracker_set_components "${COMPONENTS_PAYLOAD}"

        COMMENT="${COMMENT}

---
**Components:** ${COMPONENT_REASON}"
      fi
    fi
  else
    echo "Ignoring component_actions — not supported on ${FULLSEND_TRACKER} tracker"
  fi
fi

# --- Apply deferred label (must be last label mutation) ---

if [[ -n "${DEFERRED_LABEL}" ]]; then
  echo "Applying deferred label '${DEFERRED_LABEL}'..."
  # forge_ensure_label creates the label via `gh` against REPO. On Jira, REPO
  # is a project key, not an OWNER/REPO, and Jira has no label registry to
  # create into — any string is already a valid label.
  if [[ "${FULLSEND_TRACKER}" != "jira" ]]; then
    forge_ensure_label "${DEFERRED_LABEL}"
  fi
  tracker_add_label "${DEFERRED_LABEL}"
fi

# --- Append action-hints footer (sufficient only) ---

if [[ "${ACTION}" == "sufficient" ]]; then
  COMMENT="${COMMENT}

---
**Next steps:**
- \`/fs-code\` — agent creates a PR to implement this issue
- \`/fs-code <your instruction>\` — agent implements with your specific guidance"
fi

# --- Post comment ---

echo "Posting comment..."
if [[ "${ACTION}" == "sufficient" ]]; then
  tracker_post_sticky_comment "${COMMENT}" "<!-- fullsend:triage-agent -->"
elif [[ "${ACTION}" == "in-progress" ]]; then
  tracker_post_sticky_comment "${COMMENT}" "<!-- fullsend:triage-in-progress -->"
else
  tracker_post_comment "${COMMENT}"
fi

# --- Post-action: close issues ---

if [[ "${ACTION}" == "duplicate" ]]; then
  tracker_close_issue "duplicate"
fi

if [[ "${ACTION}" == "not-planned" ]]; then
  tracker_close_issue "not planned"
fi

if [[ "${ACTION}" == "split" ]]; then
  tracker_close_issue "completed"
fi

echo "Post-triage complete."
