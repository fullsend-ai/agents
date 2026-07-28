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

# Companion resolution for harness base: composition (ADR-0045).
# URL-fetched scripts are isolated content-addressed blobs (no siblings).
# Resolution order: next to this script → install .fullsend/scripts →
# same-commit fetch via fullsend cache metadata.json origin URL.
_resolve_companion() {
  local name="$1"
  if [[ -f "${SCRIPT_DIR}/${name}" ]]; then
    printf '%s\n' "${SCRIPT_DIR}/${name}"
    return 0
  fi
  local d
  for d in \
    "${GITHUB_WORKSPACE:+${GITHUB_WORKSPACE}/.fullsend/scripts}" \
    "${FULLSEND_DIR:+${FULLSEND_DIR}/scripts}"; do
    if [[ -n "${d}" && -f "${d}/${name}" ]]; then
      printf '%s\n' "${d}/${name}"
      return 0
    fi
  done
  local meta="${SCRIPT_DIR}/metadata.json"
  if [[ -f "$meta" ]] && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    local origin base_url tmp
    origin=$(jq -r '.url // empty' "$meta" 2>/dev/null || true)
    if [[ -n "$origin" && "$origin" == http*://* ]]; then
      base_url="${origin%/*}"
      tmp="${TMPDIR:-/tmp}/fullsend-script-companions/$(printf '%s' "$base_url" | sha256sum | awk '{print $1}')"
      mkdir -p "$tmp"
      if [[ ! -f "${tmp}/metadata.json" ]]; then
        jq -nc --arg url "${base_url}/entrypoint" '{url:$url}' > "${tmp}/metadata.json"
      fi
      if [[ ! -f "${tmp}/${name}" ]]; then
        if curl -fsSL --retry 3 --retry-delay 1 "${base_url}/${name}" -o "${tmp}/${name}.tmp"; then
          mv "${tmp}/${name}.tmp" "${tmp}/${name}"
          case "$name" in *.sh) chmod +x "${tmp}/${name}" ;; esac
        else
          rm -f "${tmp}/${name}.tmp"
          echo "ERROR: failed to fetch companion ${name} from ${base_url}/${name}" >&2
          return 1
        fi
      fi
      printf '%s\n' "${tmp}/${name}"
      return 0
    fi
  fi
  echo "ERROR: companion ${name} not found next to ${BASH_SOURCE[0]}, under install .fullsend/scripts, or via script origin URL." >&2
  return 1
}

# shellcheck source=jira-project-schema.sh
source "$(_resolve_companion jira-project-schema.sh)"

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

# Optional project-field-config (allowlist + type preferences)
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
FIELD_CONFIG_PATH="${PROJECT_FIELD_CONFIG:-}"
if [[ -z "$FIELD_CONFIG_PATH" ]]; then
  FIELD_CONFIG_PATH=$(jira_schema_find_field_config "$REPO_ROOT")
fi
FIELD_CONFIG_JSON='{}'
if [[ -n "$FIELD_CONFIG_PATH" ]]; then
  if FIELD_CONFIG_JSON=$(jira_schema_load_config "$FIELD_CONFIG_PATH"); then
    echo "::notice::Loaded project field config from ${FIELD_CONFIG_PATH}"
  else
    FIELD_CONFIG_JSON='{}'
    # load_config already emitted a warning for missing/invalid paths
  fi
fi

# Map an optional plan priority token to a Jira priority name.
# Empty input → empty output (do not invent a default for the API).
map_jira_priority() {
  jira_schema_map_priority "$@"
}

# Cache of live(+filtered) issue types per project key
declare -A PROJECT_TYPES_CACHE=()

get_usable_types_for_project() {
  local project_key="$1"
  if ! jira_schema_valid_project_key "$project_key"; then
    echo "::warning::Invalid target_project key: ${project_key}" >&2
    echo '[]'
    return 0
  fi
  if [[ -n "${PROJECT_TYPES_CACHE[$project_key]:-}" ]]; then
    echo "${PROJECT_TYPES_CACHE[$project_key]}"
    return 0
  fi

  local live allowed usable=""
  # Prefer routable_projects from issue-context when present
  local issue_context_file="/tmp/workspace/issue-context.json"
  live='[]'
  if [[ -f "$issue_context_file" ]]; then
    live=$(jq -c --arg p "$project_key" '
      .routable_projects[$p].available_issue_types
      // (if .project.key == $p then .project.available_issue_types else null end)
      // []
    ' "$issue_context_file")
  fi
  if [[ "$live" == "[]" || "$live" == "null" ]]; then
    live=$(jira_schema_fetch_project_issue_types "$project_key")
  fi

  allowed=$(jira_schema_allowed_types_for_project "$FIELD_CONFIG_JSON" "$project_key")
  if [[ -z "$allowed" || "$allowed" == "null" ]]; then
    # Also prefer precomputed usable list from context
    if [[ -f "$issue_context_file" ]]; then
      usable=$(jq -c --arg p "$project_key" '
        .routable_projects[$p].usable_issue_types // empty
      ' "$issue_context_file")
    fi
    if [[ -z "${usable:-}" || "$usable" == "null" ]]; then
      usable=$(jira_schema_intersect_issue_types "$live" "")
    fi
  else
    usable=$(jira_schema_intersect_issue_types "$live" "$allowed")
  fi

  if [[ "$usable" == "[]" ]]; then
    echo "::warning::No usable issue types for project ${project_key} after applying team preferences" >&2
  fi

  PROJECT_TYPES_CACHE[$project_key]="$usable"
  echo "$usable"
}

# --- Helper functions ---

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

# Resolve a Jira issue-link type name that exists on this site.
# Caches the resolved name in JIRA_RESOLVED_LINK_TYPE.
jira_resolve_link_type() {
  local preferred="${1:-Relates}"
  if [[ -n "${JIRA_RESOLVED_LINK_TYPE:-}" ]]; then
    echo "$JIRA_RESOLVED_LINK_TYPE"
    return 0
  fi

  local auth types_json resolved=""
  auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
  types_json=$(curl -sf \
    -H "Authorization: Basic $auth" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issueLinkType" 2>/dev/null || echo '{"issueLinkTypes":[]}')

  # Prefer exact name, then case-insensitive Relates/Related, then first type whose
  # name/inward/outward contains "relat".
  resolved=$(echo "$types_json" | jq -r --arg pref "$preferred" '
    .issueLinkTypes // []
    | (map(select(.name == $pref))[0].name)
      // (map(select((.name // "") | ascii_downcase == ($pref | ascii_downcase)))[0].name)
      // (map(select(
            ((.name // "") | test("relat"; "i"))
            or ((.inward // "") | test("relat"; "i"))
            or ((.outward // "") | test("relat"; "i"))
          ))[0].name)
      // empty
  ' 2>/dev/null || true)

  if [[ -z "$resolved" ]]; then
    # Last resort: first available link type
    resolved=$(echo "$types_json" | jq -r '.issueLinkTypes[0].name // empty' 2>/dev/null || true)
  fi

  if [[ -z "$resolved" ]]; then
    echo "::warning::Could not discover any Jira issue link types; using '${preferred}'" >&2
    resolved="$preferred"
  else
    echo "::notice::Resolved Jira link type '${preferred}' → '${resolved}'" >&2
  fi

  JIRA_RESOLVED_LINK_TYPE="$resolved"
  export JIRA_RESOLVED_LINK_TYPE
  echo "$resolved"
}

jira_link_issues() {
  local from_key="$1" to_key="$2" link_type="${3:-Relates}"
  local auth
  auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  local resolved_type
  resolved_type=$(jira_resolve_link_type "$link_type")

  local payload response http_code body
  payload=$(jq -n \
    --arg type "$resolved_type" \
    --arg inward "$from_key" \
    --arg outward "$to_key" \
    '{
      type: {name: $type},
      inwardIssue: {key: $inward},
      outwardIssue: {key: $outward}
    }')

  response=$(curl -sS -w "\n%{http_code}" -X POST \
    -H "Authorization: Basic $auth" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://${JIRA_HOST}/rest/api/3/issueLink")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  # Some sites reject one direction — swap inward/outward once
  if [[ "$http_code" -ge 400 ]]; then
    echo "::warning::Link ${from_key} → ${to_key} as '${resolved_type}' failed (HTTP ${http_code}): ${body}" >&2
    payload=$(jq -n \
      --arg type "$resolved_type" \
      --arg inward "$to_key" \
      --arg outward "$from_key" \
      '{
        type: {name: $type},
        inwardIssue: {key: $inward},
        outwardIssue: {key: $outward}
      }')
    response=$(curl -sS -w "\n%{http_code}" -X POST \
      -H "Authorization: Basic $auth" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "https://${JIRA_HOST}/rest/api/3/issueLink")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
  fi

  if [[ "$http_code" -ge 400 ]]; then
    echo "::warning::Failed to link ${from_key} ↔ ${to_key} (type: ${resolved_type}, HTTP ${http_code}): ${body}" >&2
    return 1
  fi
  # stdout is reserved for callers that capture issue keys via $(jira_create_issue …)
  echo "  Linked ${from_key} ↔ ${to_key} (${resolved_type})" >&2
  return 0
}

jira_create_issue() {
  local project="$1" type="$2" summary="$3" description="$4" parent_key="${5:-}"
  local labels_json="${6:-[]}"
  local priority="${7:-}"
  local custom_fields_json="${8:-{}}"
  local auth
  auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  local adf_desc
  adf_desc=$(printf '%s' "$description" | python3 "$(_resolve_companion markdown-to-adf.py)" | jq '.body')

  # Filter custom fields against allowlist for this project
  local allow_keys filtered_customs
  allow_keys=$(jira_schema_allowlist_keys_for_project "$FIELD_CONFIG_JSON" "$project")
  filtered_customs=$(jira_schema_filter_custom_fields "$custom_fields_json" "$allow_keys")

  local payload
  payload=$(jq -n \
    --arg proj "$project" \
    --arg type "$type" \
    --arg summary "$summary" \
    --argjson desc "$adf_desc" \
    --arg parent "$parent_key" \
    --argjson labels "$labels_json" \
    --arg priority "$priority" \
    --argjson customs "$filtered_customs" \
    '{
      fields: (
        {
          project: {key: $proj},
          issuetype: {name: $type},
          summary: $summary,
          description: $desc
        }
        + (if $parent != "" then {parent: {key: $parent}} else {} end)
        + (if ($labels | length) > 0 then {labels: $labels} else {} end)
        + (if $priority != "" and $priority != "null" then {priority: {name: $priority}} else {} end)
        + $customs
      )
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

    # Priority schemes vary by project — drop priority and retry once
    if [[ "$http_code" == "400" && -n "$priority" && "$body" == *'"priority"'* ]]; then
      echo "  Retrying without priority..." >&2
      priority=""
      payload=$(jq -n \
        --arg proj "$project" \
        --arg type "$type" \
        --arg summary "$summary" \
        --argjson desc "$adf_desc" \
        --arg parent "$parent_key" \
        --argjson labels "$labels_json" \
        --argjson customs "$filtered_customs" \
        '{
          fields: (
            {
              project: {key: $proj},
              issuetype: {name: $type},
              summary: $summary,
              description: $desc
            }
            + (if $parent != "" then {parent: {key: $parent}} else {} end)
            + (if ($labels | length) > 0 then {labels: $labels} else {} end)
            + $customs
          )
        }')
      response=$(curl -sS -w "\n%{http_code}" -X POST \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "https://${JIRA_HOST}/rest/api/3/issue")
      http_code=$(echo "$response" | tail -1)
      body=$(echo "$response" | sed '$d')
      if [[ "$http_code" -lt 400 ]]; then
        echo "$body" | jq -r '.key'
        return 0
      fi
      echo "::warning::Retry without priority also failed (${http_code}): ${body}" >&2
    fi

    if [[ -n "$parent_key" && "$http_code" == "400" ]]; then
      echo "  Retrying without parent (will link instead)..." >&2
      payload=$(jq -n \
        --arg proj "$project" \
        --arg type "$type" \
        --arg summary "$summary" \
        --argjson desc "$adf_desc" \
        --argjson labels "$labels_json" \
        --arg priority "$priority" \
        --argjson customs "$filtered_customs" \
        '{
          fields: (
            {
              project: {key: $proj},
              issuetype: {name: $type},
              summary: $summary,
              description: $desc
            }
            + (if ($labels | length) > 0 then {labels: $labels} else {} end)
            + (if $priority != "" and $priority != "null" then {priority: {name: $priority}} else {} end)
            + $customs
          )
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

# Legacy single-project type list removed — use get_usable_types_for_project per child.

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

  # Empty assoc arrays trip `set -u` on ${#arr[@]} in some bash builds
  set +u
  _dedup_n=${#EXISTING_TITLES[@]}
  set -u
  echo "Found ${_dedup_n} existing child/linked issue(s) for dedup"
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
    CHILD_AC=$(jq -r ".children[${i}].acceptance_criteria | map(\"- [ ] \" + .) | join(\"\n\")" "${RESULT_FILE}")
    CHILD_LABELS=$(jq -c ".children[${i}].labels // []" "${RESULT_FILE}")
    # Description footer may default; Jira API only gets an explicit plan priority
    CHILD_PRIORITY_RAW=$(jq -r ".children[${i}].priority // empty" "${RESULT_FILE}")
    CHILD_PRIORITY_TEXT="${CHILD_PRIORITY_RAW:-medium}"
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
*Priority: ${CHILD_PRIORITY_TEXT} | Scope: ${CHILD_SCOPE} | Generated by fullsend refine agent*"

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
      NEW_ISSUE=$(github_create_issue "${REPO_FULL_NAME}" "$CHILD_TITLE" "$FULL_BODY" "$COMBINED_LABELS" "$PARENT_KEY_FOR_CHILD")
      if [[ -z "$NEW_ISSUE" || "$NEW_ISSUE" == "FAILED" ]]; then
        echo "  [pass ${PASS}] FAILED to create ${CHILD_TYPE}: ${CHILD_TITLE}"
        continue
      fi
      echo "  [pass ${PASS}] Created ${CHILD_TYPE} #${NEW_ISSUE} under #${PARENT_KEY_FOR_CHILD}"
      TITLE_TO_KEY["$CHILD_TITLE"]="$NEW_ISSUE"
      CREATED_KEYS+=("#$NEW_ISSUE")
    else
      CHILD_TARGET_PROJECT=$(jq -r ".children[${i}].target_project // \"\"" "${RESULT_FILE}")
      PROJECT_KEY="${CHILD_TARGET_PROJECT:-$(echo "$ISSUE_KEY" | sed 's/-.*//')}"
      if ! jira_schema_valid_project_key "$PROJECT_KEY"; then
        echo "  [pass ${PASS}] SKIP '${CHILD_TITLE}' — invalid target_project '${PROJECT_KEY}'"
        continue
      fi
      PROJECT_TYPES=$(get_usable_types_for_project "$PROJECT_KEY")
      if [[ "$PROJECT_TYPES" == "[]" ]]; then
        echo "  [pass ${PASS}] SKIP '${CHILD_TITLE}' — no usable issue types for ${PROJECT_KEY}"
        continue
      fi
      JIRA_TYPE=$(resolve_jira_type "$CHILD_TYPE" "$PROJECT_TYPES")
      CHILD_CUSTOM_FIELDS=$(jq -c ".children[${i}].custom_fields // {}" "${RESULT_FILE}")
      JIRA_PRIORITY=$(map_jira_priority "$CHILD_PRIORITY_RAW")
      # Always try with parent first -- jira_create_issue retries without
      # parent and adds a "Relates" link if Jira rejects the hierarchy
      # (e.g., Task directly under Feature). Cross-project parent-child
      # works for Feature→Epic in Jira Cloud.
      NEW_KEY=$(jira_create_issue "$PROJECT_KEY" "$JIRA_TYPE" "$CHILD_TITLE" "$FULL_BODY" "$PARENT_KEY_FOR_CHILD" "$CHILD_LABELS" "$JIRA_PRIORITY" "$CHILD_CUSTOM_FIELDS")
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
    CHILD_AC=$(jq -r ".children[${i}].acceptance_criteria | map(\"- [ ] \" + .) | join(\"\n\")" "${RESULT_FILE}")
    CHILD_LABELS=$(jq -c ".children[${i}].labels // []" "${RESULT_FILE}")
    CHILD_PRIORITY_RAW=$(jq -r ".children[${i}].priority // empty" "${RESULT_FILE}")
    CHILD_PRIORITY_TEXT="${CHILD_PRIORITY_RAW:-medium}"
    CHILD_SCOPE=$(jq -r ".children[${i}].estimated_scope // \"M\"" "${RESULT_FILE}")

    FULL_BODY="${CHILD_DESC}

## Acceptance Criteria

${CHILD_AC}

---
*Priority: ${CHILD_PRIORITY_TEXT} | Scope: ${CHILD_SCOPE} | Generated by fullsend refine agent*"

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
      NEW_ISSUE=$(github_create_issue "${REPO_FULL_NAME}" "$CHILD_TITLE" "$FULL_BODY" "$COMBINED_LABELS" "$ISSUE_KEY")
      if [[ -z "$NEW_ISSUE" || "$NEW_ISSUE" == "FAILED" ]]; then
        echo "  [orphan] FAILED to create: ${CHILD_TITLE}"
        continue
      fi
      echo "  [orphan] Created #${NEW_ISSUE} under #${ISSUE_KEY}"
      CREATED_KEYS+=("#$NEW_ISSUE")
    else
      CHILD_TARGET_PROJECT=$(jq -r ".children[${i}].target_project // \"\"" "${RESULT_FILE}")
      PROJECT_KEY="${CHILD_TARGET_PROJECT:-$(echo "$ISSUE_KEY" | sed 's/-.*//')}"
      if ! jira_schema_valid_project_key "$PROJECT_KEY"; then
        echo "  [orphan] SKIP '${CHILD_TITLE}' — invalid target_project '${PROJECT_KEY}'"
        continue
      fi
      PROJECT_TYPES=$(get_usable_types_for_project "$PROJECT_KEY")
      if [[ "$PROJECT_TYPES" == "[]" ]]; then
        echo "  [orphan] SKIP '${CHILD_TITLE}' — no usable issue types for ${PROJECT_KEY}"
        continue
      fi
      JIRA_TYPE=$(resolve_jira_type "$CHILD_TYPE" "$PROJECT_TYPES")
      CHILD_CUSTOM_FIELDS=$(jq -c ".children[${i}].custom_fields // {}" "${RESULT_FILE}")
      JIRA_PRIORITY=$(map_jira_priority "$CHILD_PRIORITY_RAW")
      NEW_KEY=$(jira_create_issue "$PROJECT_KEY" "$JIRA_TYPE" "$CHILD_TITLE" "$FULL_BODY" "" "$CHILD_LABELS" "$JIRA_PRIORITY" "$CHILD_CUSTOM_FIELDS")
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
