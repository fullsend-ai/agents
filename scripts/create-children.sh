#!/usr/bin/env bash
# create-children.sh — Create child issues from an approved refinement plan.
#
# Reusable script that reads a refinement result JSON and creates child issues
# in topological order using parent_title references for hierarchy.
#
# Can be called from:
#   - post-critique.sh (auto-approval path)
#   - create-children.yml workflow (human-approval path)
#
# Required env vars:
#   RESULT_FILE        — Path to the approved agent-result.json
#   ISSUE_KEY          — Parent issue identifier (Jira key or GH issue number)
#   ISSUE_SOURCE       — "jira" or "github"
#   GH_TOKEN           — GitHub token
#
# GitHub flow env vars:
#   GITHUB_ISSUE_NUMBER — GitHub issue number
#   REPO_FULL_NAME      — owner/repo
#   PUSH_TOKEN          — Token with write access
#
# Jira flow env vars:
#   JIRA_HOST, JIRA_EMAIL, JIRA_API_TOKEN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${RESULT_FILE:-}" ]]; then
  echo "ERROR: RESULT_FILE env var not set"
  exit 1
fi

if [[ ! -f "${RESULT_FILE}" ]]; then
  echo "ERROR: Result file not found: ${RESULT_FILE}"
  exit 1
fi

if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

USE_GITHUB=false
if [[ -n "${GITHUB_ISSUE_NUMBER:-}" && "${GITHUB_ISSUE_NUMBER}" != "" && "${GITHUB_ISSUE_NUMBER}" != "N/A" ]]; then
  USE_GITHUB=true
elif [[ "${ISSUE_SOURCE:-}" == "github" ]]; then
  USE_GITHUB=true
  GITHUB_ISSUE_NUMBER="${ISSUE_KEY}"
fi

ADF_SCRIPT="${SCRIPT_DIR}/markdown-to-adf.py"
if [[ ! -f "$ADF_SCRIPT" ]]; then
  echo "ERROR: markdown-to-adf.py not found (requires PR #11 explore agent)"
  exit 1
fi

# --- Helper functions ---

resolve_github_parent_number() {
  local parent_key="$1"

  if [[ "$parent_key" =~ ^[0-9]+$ ]]; then
    echo "$parent_key"
    return
  fi

  if [[ "$parent_key" =~ ^#[0-9]+$ ]]; then
    echo "${parent_key#\#}"
    return
  fi

  if [[ "$parent_key" == "$ISSUE_KEY" && -n "${GITHUB_ISSUE_NUMBER:-}" && "${GITHUB_ISSUE_NUMBER}" != "N/A" ]]; then
    echo "$GITHUB_ISSUE_NUMBER"
    return
  fi

  echo ""
}

github_create_issue() {
  local repo="$1" title="$2" body="$3" labels="$4" parent_number="${5:-}"
  local args=(--repo "$repo" --title "$title")
  if [[ -n "$labels" && "$labels" != "null" ]]; then
    while IFS= read -r label; do
      if [[ -n "$label" ]]; then
        gh label create "$label" --repo "$repo" --force 2>/dev/null || true
        args+=(--label "$label")
      fi
    done < <(echo "$labels" | jq -r '.[]')
  fi
  local result
  result=$(printf '%s' "$body" | gh issue create "${args[@]}" --body-file - 2>&1) || {
    echo "::warning::Failed to create issue '${title}': ${result}" >&2
    echo "FAILED"
    return 0
  }

  local issue_number
  issue_number=$(echo "$result" | grep -oP '/issues/\K[0-9]+' || true)

  if [[ -n "$parent_number" && -n "$issue_number" ]]; then
    local child_id
    child_id=$(gh api "repos/${repo}/issues/${issue_number}" --jq '.id' 2>/dev/null)
    if [[ -n "$child_id" ]]; then
      gh api "repos/${repo}/issues/${parent_number}/sub_issues" \
        -F sub_issue_id="$child_id" \
        --silent 2>/dev/null || \
        echo "::warning::Could not link #${issue_number} as sub-issue of #${parent_number}" >&2
    fi
  fi

  echo "$issue_number"
}

jira_link_issues() {
  local from_key="$1" to_key="$2" link_type="${3:-Relates}"
  local auth
  auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  local payload
  payload=$(jq -n \
    --arg type "$link_type" \
    --arg inward "$from_key" \
    --arg outward "$to_key" \
    '{
      type: {name: $type},
      inwardIssue: {key: $inward},
      outwardIssue: {key: $outward}
    }')

  local http_code
  http_code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Basic $auth" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://${JIRA_HOST}/rest/api/3/issueLink")

  if [[ "$http_code" -ge 400 ]]; then
    echo "::warning::Failed to link ${from_key} → ${to_key} (type: ${link_type}, HTTP ${http_code})" >&2
    return 1
  fi
  echo "  Linked ${from_key} → ${to_key} (${link_type})"
  return 0
}

jira_create_issue() {
  local project="$1" type="$2" summary="$3" description="$4" parent_key="${5:-}"
  local auth
  auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  local adf_desc
  adf_desc=$(printf '%s' "$description" | python3 "${ADF_SCRIPT}" | jq '.body')

  local payload
  payload=$(jq -n \
    --arg proj "$project" \
    --arg type "$type" \
    --arg summary "$summary" \
    --argjson desc "$adf_desc" \
    --arg parent "$parent_key" \
    '{
      fields: ({
        project: {key: $proj},
        issuetype: {name: $type},
        summary: $summary,
        description: $desc
      } + (if $parent != "" then {parent: {key: $parent}} else {} end))
    }')

  local response http_code
  response=$(curl -sS -w "\n%{http_code}" -X POST \
    -H "Authorization: Basic $auth" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://${JIRA_HOST}/rest/api/3/issue")

  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 400 ]]; then
    echo "::warning::Jira API returned ${http_code} creating '${summary}' (type: ${type}, parent: ${parent_key}): ${body}" >&2
    if [[ -n "$parent_key" && "$http_code" == "400" ]]; then
      echo "  Retrying without parent (will link instead)..." >&2
      payload=$(jq -n \
        --arg proj "$project" \
        --arg type "$type" \
        --arg summary "$summary" \
        --argjson desc "$adf_desc" \
        '{
          fields: {
            project: {key: $proj},
            issuetype: {name: $type},
            summary: $summary,
            description: $desc
          }
        }')
      response=$(curl -sS -w "\n%{http_code}" -X POST \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "https://${JIRA_HOST}/rest/api/3/issue")
      http_code=$(echo "$response" | tail -1)
      body=$(echo "$response" | sed '$d')
      if [[ "$http_code" -ge 400 ]]; then
        echo "::warning::Retry without parent also failed (${http_code}): ${body}" >&2
        echo ""
        return 0
      fi
      local created_key
      created_key=$(echo "$body" | jq -r '.key')
      if [[ -n "$created_key" && "$created_key" != "null" ]]; then
        jira_link_issues "$created_key" "$parent_key" "Relates" || true
      fi
      echo "$created_key"
      return 0
    else
      echo ""
      return 0
    fi
  fi

  echo "$body" | jq -r '.key'
}

resolve_jira_type() {
  local requested_type="$1"
  local available_types="${2:-}"

  if [[ -z "$available_types" || "$available_types" == "[]" ]]; then
    case "${requested_type,,}" in
      feature) echo "Feature" ;;
      epic)    echo "Epic" ;;
      story)   echo "Story" ;;
      task)    echo "Task" ;;
      spike)   echo "Spike" ;;
      bug)     echo "Bug" ;;
      *)       echo "Story" ;;
    esac
    return
  fi

  local match
  match=$(echo "$available_types" | jq -r --arg t "$requested_type" \
    '[.[].name] | map(select(ascii_downcase == ($t | ascii_downcase))) | .[0] // empty')

  if [[ -n "$match" ]]; then
    echo "$match"
    return
  fi

  local fallback
  fallback=$(echo "$available_types" | jq -r '
    [.[] | select(.subtask != true) | .name] |
    if any(. == "Story") then "Story"
    elif any(. == "Task") then "Task"
    elif any(. == "Bug") then "Bug"
    else .[0] // "Story"
    end')

  echo "$fallback"
}

# Load available issue types — prefer issue-context.json, fall back to API
AVAILABLE_TYPES="[]"
ISSUE_CONTEXT_FILE="/tmp/workspace/issue-context.json"
if [[ -f "$ISSUE_CONTEXT_FILE" ]]; then
  AVAILABLE_TYPES=$(jq -c '.project.available_issue_types // []' "$ISSUE_CONTEXT_FILE")
fi
if [[ "$AVAILABLE_TYPES" == "[]" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" ]]; then
  PROJECT_KEY_FOR_TYPES=$(echo "$ISSUE_KEY" | sed 's/-.*//')
  _auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
  AVAILABLE_TYPES=$(curl -sf \
    -H "Authorization: Basic $_auth" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issue/createmeta/${PROJECT_KEY_FOR_TYPES}/issuetypes" \
    | jq -c '[.issueTypes // [] | .[] | {name, subtask, hierarchyLevel}]' 2>/dev/null || echo "[]")
  echo "Fetched ${#AVAILABLE_TYPES} bytes of issue type metadata from API"
fi

# --- Fetch existing children for deduplication ---

declare -A EXISTING_TITLES

if [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" ]]; then
  _dedup_auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  # Child work items (parent hierarchy)
  _children_json=$(curl -sf \
    -H "Authorization: Basic $_dedup_auth" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/search?jql=parent%3D${ISSUE_KEY}&fields=summary,status&maxResults=100" 2>/dev/null || echo '{"issues":[]}')

  while IFS='|' read -r _ck _cs; do
    [[ -n "$_ck" ]] && EXISTING_TITLES["$_cs"]="$_ck"
  done < <(echo "$_children_json" | jq -r '.issues[]? | "\(.key)|\(.fields.summary)"')

  # Linked issues (Relates)
  _links_json=$(curl -sf \
    -H "Authorization: Basic $_dedup_auth" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}?fields=issuelinks" 2>/dev/null || echo '{"fields":{"issuelinks":[]}}')

  while IFS='|' read -r _lk _ls; do
    [[ -n "$_lk" && -z "${EXISTING_TITLES[$_ls]:-}" ]] && EXISTING_TITLES["$_ls"]="$_lk"
  done < <(echo "$_links_json" | jq -r '.fields.issuelinks[]? | (.outwardIssue // .inwardIssue) | "\(.key)|\(.fields.summary)"')

  echo "Found ${#EXISTING_TITLES[@]} existing child/linked issue(s) for dedup"
fi

if $USE_GITHUB && [[ -n "${REPO_FULL_NAME:-}" ]]; then
  _gh_parent="${GITHUB_ISSUE_NUMBER:-}"
  if [[ -z "$_gh_parent" && "${ISSUE_SOURCE:-}" == "github" ]]; then
    _gh_parent="$ISSUE_KEY"
  fi

  if [[ -n "$_gh_parent" && "$_gh_parent" =~ ^[0-9]+$ ]]; then
    while IFS='|' read -r _num _title; do
      [[ -n "$_title" && -n "$_num" && -z "${EXISTING_TITLES[$_title]:-}" ]] && EXISTING_TITLES["$_title"]="#${_num}"
    done < <(gh api "repos/${REPO_FULL_NAME}/issues/${_gh_parent}/sub_issues" --paginate --jq '.[] | "\(.number)|\(.title)"' 2>/dev/null || true)
    echo "GitHub dedup index contains ${#EXISTING_TITLES[@]} title(s)"
  fi
fi

# --- Create children in topological order ---

CHILD_COUNT=$(jq '.children | length' "${RESULT_FILE}")
echo "Creating ${CHILD_COUNT} child issue(s) with hierarchy..."

declare -A TITLE_TO_KEY
CREATED_KEYS=()
SKIPPED_KEYS=()
CREATED_COUNT=0
MAX_PASSES=5
PASS=0

declare -A CREATED_IDX

while [[ $CREATED_COUNT -lt $CHILD_COUNT && $PASS -lt $MAX_PASSES ]]; do
  PASS=$((PASS + 1))
  PROGRESS=false

  for i in $(seq 0 $((CHILD_COUNT - 1))); do
    if [[ -n "${CREATED_IDX[$i]:-}" ]]; then continue; fi

    CHILD_TITLE=$(jq -r ".children[${i}].title" "${RESULT_FILE}")

    # Dedup: skip if an issue with this title already exists
    if [[ -n "${EXISTING_TITLES[$CHILD_TITLE]:-}" ]]; then
      _existing_key="${EXISTING_TITLES[$CHILD_TITLE]}"
      echo "  [skip] '${CHILD_TITLE}' already exists as ${_existing_key}"
      TITLE_TO_KEY["$CHILD_TITLE"]="$_existing_key"
      SKIPPED_KEYS+=("$_existing_key")
      CREATED_IDX[$i]=1
      CREATED_COUNT=$((CREATED_COUNT + 1))
      PROGRESS=true
      continue
    fi

    CHILD_PARENT_TITLE=$(jq -r ".children[${i}].parent_title // \"\"" "${RESULT_FILE}")
    CHILD_TYPE=$(jq -r ".children[${i}].type" "${RESULT_FILE}")
    CHILD_DESC=$(jq -r ".children[${i}].description" "${RESULT_FILE}")
    CHILD_AC=$(jq -r ".children[${i}].acceptance_criteria // [] | map(\"- [ ] \" + .) | join(\"\n\")" "${RESULT_FILE}")
    CHILD_LABELS=$(jq -c ".children[${i}].labels // []" "${RESULT_FILE}")
    CHILD_PRIORITY=$(jq -r ".children[${i}].priority // \"medium\"" "${RESULT_FILE}")
    CHILD_SCOPE=$(jq -r ".children[${i}].estimated_scope // \"M\"" "${RESULT_FILE}")

    PARENT_KEY_FOR_CHILD=""
    if [[ -z "$CHILD_PARENT_TITLE" || "$CHILD_PARENT_TITLE" == "null" ]]; then
      PARENT_KEY_FOR_CHILD="$ISSUE_KEY"
    elif [[ -n "${TITLE_TO_KEY[$CHILD_PARENT_TITLE]:-}" ]]; then
      PARENT_KEY_FOR_CHILD="${TITLE_TO_KEY[$CHILD_PARENT_TITLE]}"
    else
      continue
    fi

    FULL_BODY="${CHILD_DESC}

## Acceptance Criteria

${CHILD_AC}

---
*Priority: ${CHILD_PRIORITY} | Scope: ${CHILD_SCOPE} | Generated by fullsend refine agent*"

    # Determine which platform to create this child on (per-child override)
    CHILD_TARGET_PLATFORM=$(jq -r ".children[${i}].target_platform // \"\"" "${RESULT_FILE}")
    USE_GITHUB_FOR_CHILD=$USE_GITHUB
    if [[ "$CHILD_TARGET_PLATFORM" == "github" ]]; then
      USE_GITHUB_FOR_CHILD=true
    elif [[ "$CHILD_TARGET_PLATFORM" == "jira" ]]; then
      USE_GITHUB_FOR_CHILD=false
    elif [[ "$CHILD_TARGET_PLATFORM" == "gitlab" ]]; then
      echo "  [pass ${PASS}] SKIP '${CHILD_TITLE}' — GitLab creation not yet supported"
      continue
    fi

    if $USE_GITHUB_FOR_CHILD; then
      TYPE_LABEL="$CHILD_TYPE"
      COMBINED_LABELS=$(echo "$CHILD_LABELS" | jq --arg t "$TYPE_LABEL" '. + [$t]')
      GITHUB_PARENT=$(resolve_github_parent_number "$PARENT_KEY_FOR_CHILD")
      if [[ -z "$GITHUB_PARENT" && -n "$PARENT_KEY_FOR_CHILD" ]]; then
        echo "::warning::Skipping sub-issue link for '${CHILD_TITLE}' — parent '${PARENT_KEY_FOR_CHILD}' is not a GitHub issue number"
      fi
      NEW_ISSUE=$(github_create_issue "${REPO_FULL_NAME}" "$CHILD_TITLE" "$FULL_BODY" "$COMBINED_LABELS" "$GITHUB_PARENT")
      if [[ -z "$NEW_ISSUE" || "$NEW_ISSUE" == "FAILED" ]]; then
        echo "  [pass ${PASS}] FAILED to create ${CHILD_TYPE}: ${CHILD_TITLE}"
        continue
      fi
      if [[ -n "$GITHUB_PARENT" ]]; then
        echo "  [pass ${PASS}] Created ${CHILD_TYPE} #${NEW_ISSUE} under #${GITHUB_PARENT}"
      else
        echo "  [pass ${PASS}] Created ${CHILD_TYPE} #${NEW_ISSUE} (no parent link)"
      fi
      TITLE_TO_KEY["$CHILD_TITLE"]="$NEW_ISSUE"
      CREATED_KEYS+=("#$NEW_ISSUE")
    else
      CHILD_TARGET_PROJECT=$(jq -r ".children[${i}].target_project // \"\"" "${RESULT_FILE}")
      PROJECT_KEY="${CHILD_TARGET_PROJECT:-$(echo "$ISSUE_KEY" | sed 's/-.*//')}"
      JIRA_TYPE=$(resolve_jira_type "$CHILD_TYPE" "$AVAILABLE_TYPES")
      # Always try with parent first -- jira_create_issue retries without
      # parent and adds a "Relates" link if Jira rejects the hierarchy
      # (e.g., Task directly under Feature). Cross-project parent-child
      # works for Feature→Epic in Jira Cloud.
      NEW_KEY=$(jira_create_issue "$PROJECT_KEY" "$JIRA_TYPE" "$CHILD_TITLE" "$FULL_BODY" "$PARENT_KEY_FOR_CHILD")
      if [[ -z "$NEW_KEY" ]]; then
        echo "  [pass ${PASS}] FAILED to create ${JIRA_TYPE}: ${CHILD_TITLE}"
        continue
      fi
      echo "  [pass ${PASS}] Created ${JIRA_TYPE} ${NEW_KEY} in ${PROJECT_KEY} under ${PARENT_KEY_FOR_CHILD} (requested: ${CHILD_TYPE})"
      TITLE_TO_KEY["$CHILD_TITLE"]="$NEW_KEY"
      CREATED_KEYS+=("$NEW_KEY")
    fi

    CREATED_IDX[$i]=1
    CREATED_COUNT=$((CREATED_COUNT + 1))
    PROGRESS=true
  done

  if ! $PROGRESS; then
    echo "::warning::Pass ${PASS} made no progress — $((CHILD_COUNT - CREATED_COUNT)) items have unresolvable parent_title references"
    break
  fi
done

# Orphans fall back to root parent
if [[ $CREATED_COUNT -lt $CHILD_COUNT ]]; then
  echo "::warning::Creating remaining orphaned items under root issue"
  for i in $(seq 0 $((CHILD_COUNT - 1))); do
    if [[ -n "${CREATED_IDX[$i]:-}" ]]; then continue; fi

    CHILD_TITLE=$(jq -r ".children[${i}].title" "${RESULT_FILE}")

    # Dedup check for orphans too
    if [[ -n "${EXISTING_TITLES[$CHILD_TITLE]:-}" ]]; then
      _existing_key="${EXISTING_TITLES[$CHILD_TITLE]}"
      echo "  [skip] '${CHILD_TITLE}' already exists as ${_existing_key}"
      SKIPPED_KEYS+=("$_existing_key")
      continue
    fi

    CHILD_TYPE=$(jq -r ".children[${i}].type" "${RESULT_FILE}")
    CHILD_DESC=$(jq -r ".children[${i}].description" "${RESULT_FILE}")
    CHILD_AC=$(jq -r ".children[${i}].acceptance_criteria // [] | map(\"- [ ] \" + .) | join(\"\n\")" "${RESULT_FILE}")
    CHILD_LABELS=$(jq -c ".children[${i}].labels // []" "${RESULT_FILE}")
    CHILD_PRIORITY=$(jq -r ".children[${i}].priority // \"medium\"" "${RESULT_FILE}")
    CHILD_SCOPE=$(jq -r ".children[${i}].estimated_scope // \"M\"" "${RESULT_FILE}")

    FULL_BODY="${CHILD_DESC}

## Acceptance Criteria

${CHILD_AC}

---
*Priority: ${CHILD_PRIORITY} | Scope: ${CHILD_SCOPE} | Generated by fullsend refine agent*"

    # Determine platform for orphan (same logic as main loop)
    CHILD_TARGET_PLATFORM=$(jq -r ".children[${i}].target_platform // \"\"" "${RESULT_FILE}")
    USE_GITHUB_FOR_CHILD=$USE_GITHUB
    if [[ "$CHILD_TARGET_PLATFORM" == "github" ]]; then
      USE_GITHUB_FOR_CHILD=true
    elif [[ "$CHILD_TARGET_PLATFORM" == "jira" ]]; then
      USE_GITHUB_FOR_CHILD=false
    fi

    if $USE_GITHUB_FOR_CHILD; then
      TYPE_LABEL="$CHILD_TYPE"
      COMBINED_LABELS=$(echo "$CHILD_LABELS" | jq --arg t "$TYPE_LABEL" '. + [$t]')
      GITHUB_PARENT=$(resolve_github_parent_number "$ISSUE_KEY")
      if [[ -z "$GITHUB_PARENT" ]]; then
        echo "::warning::Skipping sub-issue link for orphan '${CHILD_TITLE}' — no GitHub parent issue number available"
      fi
      NEW_ISSUE=$(github_create_issue "${REPO_FULL_NAME}" "$CHILD_TITLE" "$FULL_BODY" "$COMBINED_LABELS" "$GITHUB_PARENT")
      if [[ -z "$NEW_ISSUE" || "$NEW_ISSUE" == "FAILED" ]]; then
        echo "  [orphan] FAILED to create: ${CHILD_TITLE}"
        continue
      fi
      echo "  [orphan] Created #${NEW_ISSUE} under #${ISSUE_KEY}"
      CREATED_KEYS+=("#$NEW_ISSUE")
    else
      CHILD_TARGET_PROJECT=$(jq -r ".children[${i}].target_project // \"\"" "${RESULT_FILE}")
      PROJECT_KEY="${CHILD_TARGET_PROJECT:-$(echo "$ISSUE_KEY" | sed 's/-.*//')}"
      JIRA_TYPE=$(resolve_jira_type "$CHILD_TYPE" "$AVAILABLE_TYPES")
      NEW_KEY=$(jira_create_issue "$PROJECT_KEY" "$JIRA_TYPE" "$CHILD_TITLE" "$FULL_BODY" "")
      if [[ -z "$NEW_KEY" ]]; then
        echo "  [orphan] FAILED to create ${JIRA_TYPE}: ${CHILD_TITLE}"
        continue
      fi
      jira_link_issues "$NEW_KEY" "$ISSUE_KEY" "Relates" || true
      echo "  [orphan] Created ${JIRA_TYPE}: ${NEW_KEY} in ${PROJECT_KEY} (linked to ${ISSUE_KEY})"
      CREATED_KEYS+=("$NEW_KEY")
    fi
  done
fi

SKIPPED_MSG=""
if [[ ${#SKIPPED_KEYS[@]} -gt 0 ]]; then
  SKIPPED_MSG=" (skipped ${#SKIPPED_KEYS[@]} existing: ${SKIPPED_KEYS[*]})"
fi
echo "::notice::Created ${#CREATED_KEYS[@]} child issue(s): ${CREATED_KEYS[*]}${SKIPPED_MSG}"

# Export for callers that need the result
export CREATED_CHILD_COUNT="${#CREATED_KEYS[@]}"
export CREATED_CHILD_KEYS="${CREATED_KEYS[*]}"
