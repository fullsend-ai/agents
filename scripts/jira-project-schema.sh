#!/usr/bin/env bash
# jira-project-schema.sh — Shared helpers for per-project Jira scheme awareness.
#
# Live-fetch issue types from Jira; apply optional team preferences from
# project-field-config.json; filter plan custom_fields against allowlists.
#
# Safe to source from pre-scripts and create-children.sh.
# Network functions no-op / return [] when JIRA_* creds are missing (tests).

# shellcheck disable=SC2034

jira_schema_find_field_config() {
  local repo_root="${1:-.}"
  local candidate
  for candidate in \
    "${repo_root}/.fullsend/customized/skills/jira-routing/project-field-config.json" \
    "${repo_root}/.fullsend/skills/jira-routing/project-field-config.json"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  echo ""
}

jira_schema_load_config() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    echo '{}'
    return 1
  fi
  if [[ ! -f "$path" ]]; then
    echo "::warning::Project field config not found at ${path} — proceeding with empty config" >&2
    echo '{}'
    return 1
  fi
  if ! jq empty "$path" 2>/dev/null; then
    echo "::warning::Invalid project-field-config JSON at ${path} — proceeding with empty config" >&2
    echo '{}'
    return 1
  fi
  cat "$path"
  return 0
}

# LIVE_TYPES: JSON array of {name, ...} or array of strings
# ALLOWED: JSON array of strings, or empty/null/[] meaning "no filter"
jira_schema_intersect_issue_types() {
  local live_json="${1:-[]}"
  local allowed_json="${2:-}"

  if [[ -z "$allowed_json" || "$allowed_json" == "null" || "$allowed_json" == "[]" ]]; then
    echo "$live_json" | jq -c '
      if type == "array" then
        if length == 0 then []
        elif (.[0] | type) == "string" then map({name: .})
        else .
        end
      else []
      end'
    return 0
  fi

  echo "$live_json" | jq -c --argjson allowed "$allowed_json" '
    def names:
      if type != "array" then []
      elif length == 0 then []
      elif (.[0] | type) == "string" then map({name: .})
      else .
      end;
    (names) as $live
    | ($allowed | map(ascii_downcase)) as $allow
    | [$live[] | select((.name | ascii_downcase) as $n | $allow | index($n))]
  '
}

# PLAN_FIELDS: object; ALLOWLIST_KEYS: array of field id strings
# Prints filtered object on stdout. Unknown keys warned on stderr.
# Always strips reserved Jira system fields so allowlists cannot override
# project/issuetype/summary/description/parent/etc. on create.
JIRA_SCHEMA_RESERVED_FIELDS='["project","issuetype","summary","description","parent","labels","priority","reporter","assignee","creator","comment","attachment","worklog","issuelinks","subtasks","timetracking","security","votes","status","resolution","watches","thumbnail","created","updated","resolutiondate","lastViewed","environment","duedate","progress","aggregateprogress","workratio","timeestimate","timeoriginalestimate","timespent","aggregatetimespent","aggregatetimeestimate","aggregatetimeoriginalestimate"]'

jira_schema_valid_project_key() {
  local key="${1:-}"
  [[ "$key" =~ ^[A-Z][A-Z0-9]{1,14}$ ]]
}

jira_schema_filter_custom_fields() {
  local plan_fields='{}'
  local allowlist_keys='[]'
  [[ $# -ge 1 && -n "$1" ]] && plan_fields="$1"
  [[ $# -ge 2 && -n "$2" ]] && allowlist_keys="$2"

  if [[ "$plan_fields" == "null" ]]; then
    echo '{}'
    return 0
  fi
  if [[ "$allowlist_keys" == "null" ]]; then
    allowlist_keys='[]'
  fi

  local filtered dropped
  filtered=$(echo "$plan_fields" | jq -c \
    --argjson allow "$allowlist_keys" \
    --argjson reserved "$JIRA_SCHEMA_RESERVED_FIELDS" '
    def is_reserved($k): ($reserved | map(ascii_downcase) | index($k | ascii_downcase)) != null;
    (if ($allow | length) == 0 then
      {filtered: {}, dropped: keys_unsorted}
    else
      {
        filtered: with_entries(select(.key as $k | ($allow | index($k)))),
        dropped: [keys_unsorted[] | select(. as $k | ($allow | index($k) | not))]
      }
    end) as $base
    | ($base.filtered | with_entries(select(.key as $k | is_reserved($k) | not))) as $safe
    | ($base.filtered | keys_unsorted | map(select(is_reserved(.)))) as $blocked
    | {
        filtered: $safe,
        dropped: (($base.dropped + $blocked) | unique)
      }
  ')
  dropped=$(echo "$filtered" | jq -r '.dropped[]?' 2>/dev/null || true)
  if [[ -n "$dropped" ]]; then
    while IFS= read -r key; do
      [[ -n "$key" ]] && echo "::warning::Dropping non-allowlisted or reserved field: ${key}" >&2
    done <<< "$dropped"
  fi
  echo "$filtered" | jq -c '.filtered'
}

jira_schema_allowlist_keys_for_project() {
  local config_json='{}'
  local project_key="${2:-}"
  [[ $# -ge 1 && -n "$1" ]] && config_json="$1"

  echo "$config_json" | jq -c --arg p "$project_key" --argjson reserved "$JIRA_SCHEMA_RESERVED_FIELDS" '
    (
      ((.projects[$p].fields // {}) | keys)
      + ((.default_fields // {}) | keys)
      | unique
    ) as $keys
    | [$keys[] | select(. as $k | ($reserved | map(ascii_downcase) | index($k | ascii_downcase)) | not)]
  '
}

jira_schema_allowed_types_for_project() {
  local config_json='{}'
  local project_key="${2:-}"
  [[ $# -ge 1 && -n "$1" ]] && config_json="$1"

  echo "$config_json" | jq -c --arg p "$project_key" '
    .projects[$p].allowed_issue_types // []
  '
}

# Resolve candidate project keys: parent ∪ config.projects keys ∪ uppercase tokens in skill that look like keys
# Caps at 20 valid keys to bound live API fan-out.
jira_schema_candidate_project_keys() {
  local parent_key="${1:-}"
  local config_json='{}'
  local skill_path="${3:-}"
  [[ $# -ge 2 && -n "$2" ]] && config_json="$2"

  local from_config
  from_config=$(echo "$config_json" | jq -r '.projects // {} | keys[]?' 2>/dev/null || true)

  local from_skill=""
  if [[ -n "$skill_path" && -f "$skill_path" ]]; then
    # Match bare Jira-like project keys (2–15 uppercase letters) in skill prose/tables
    from_skill=$(grep -oE '\b[A-Z][A-Z0-9]{1,14}\b' "$skill_path" 2>/dev/null \
      | grep -Ev '^(THE|AND|FOR|USE|NOT|ONLY|WHEN|WITH|FROM|THIS|THAT|JSON|API|URL|HTTP|EPIC|TASK|STORY|BUG|SPIKE|FEATURE|RELATES|TEAM)$' \
      || true)
  fi

  local -a out=()
  local k
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if jira_schema_valid_project_key "$k"; then
      local seen=0
      local e
      for e in "${out[@]+"${out[@]}"}"; do
        [[ "$e" == "$k" ]] && seen=1 && break
      done
      if [[ $seen -eq 0 ]]; then
        out+=("$k")
      fi
    fi
    if [[ ${#out[@]} -ge 20 ]]; then
      break
    fi
  done < <(printf '%s\n%s\n%s\n' "$parent_key" "$from_config" "$from_skill")

  printf '%s\n' "${out[@]+"${out[@]}"}"
}

jira_schema_fetch_project_issue_types() {
  local project_key="${1:-}"
  if [[ -z "$project_key" || -z "${JIRA_HOST:-}" || -z "${JIRA_EMAIL:-}" || -z "${JIRA_API_TOKEN:-}" ]]; then
    echo '[]'
    return 0
  fi
  if ! jira_schema_valid_project_key "$project_key"; then
    echo "::warning::Ignoring invalid Jira project key: ${project_key}" >&2
    echo '[]'
    return 0
  fi

  local auth
  auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  local types
  types=$(curl -sf \
    -H "Authorization: Basic $auth" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/project/${project_key}" 2>/dev/null \
    | jq -c '[.issueTypes[]? | {name: .name, subtask: .subtask, hierarchyLevel: .hierarchyLevel, description: (.description // "")}]' \
    || echo '[]')

  if [[ "$types" == "[]" || "$types" == "null" ]]; then
    types=$(curl -sf \
      -H "Authorization: Basic $auth" \
      -H "Accept: application/json" \
      "https://${JIRA_HOST}/rest/api/3/issue/createmeta/${project_key}/issuetypes" 2>/dev/null \
      | jq -c '[.issueTypes // [] | .[] | {name, subtask, hierarchyLevel, description: (.description // "")}]' \
      || echo '[]')
  fi

  echo "${types:-[]}"
}

# Build routable_projects object for issue-context enrichment.
# Optional 4th arg: path to a mock types JSON file map — used only in tests via JIRA_SCHEMA_TYPES_MOCK_DIR
jira_schema_build_routable_projects() {
  local parent_key="${1:-}"
  local config_json='{}'
  local skill_path="${3:-}"
  [[ $# -ge 2 && -n "$2" ]] && config_json="$2"

  local keys
  keys=$(jira_schema_candidate_project_keys "$parent_key" "$config_json" "$skill_path")

  local result='{}'
  local key live allowed usable allow_keys
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    if ! jira_schema_valid_project_key "$key"; then
      echo "::warning::Skipping invalid project key in routable_projects: ${key}" >&2
      continue
    fi

    if [[ -n "${JIRA_SCHEMA_TYPES_MOCK_DIR:-}" && -f "${JIRA_SCHEMA_TYPES_MOCK_DIR}/${key}.json" ]]; then
      live=$(cat "${JIRA_SCHEMA_TYPES_MOCK_DIR}/${key}.json")
    else
      live=$(jira_schema_fetch_project_issue_types "$key")
    fi

    allowed=$(jira_schema_allowed_types_for_project "$config_json" "$key")
    if [[ -z "$allowed" || "$allowed" == "null" ]]; then
      usable=$(jira_schema_intersect_issue_types "$live" "")
    else
      usable=$(jira_schema_intersect_issue_types "$live" "$allowed")
    fi
    allow_keys=$(jira_schema_allowlist_keys_for_project "$config_json" "$key")
    team_values=$(echo "$config_json" | jq -c --arg p "$key" '.projects[$p].team_values // {}')
    field_guidance=$(echo "$config_json" | jq -c --arg p "$key" '
      ((.projects[$p].fields // {}) + (.default_fields // {}))
      | with_entries(select(.key | startswith("_") | not))
    ')

    result=$(jq -c --arg k "$key" --argjson live "$live" --argjson usable "$usable" \
      --argjson fields "$allow_keys" --argjson teams "$team_values" --argjson guidance "$field_guidance" '
      . + {($k): {
        available_issue_types: $live,
        usable_issue_types: $usable,
        allowed_custom_fields: $fields,
        team_values: $teams,
        custom_field_guidance: $guidance
      }}
    ' <<< "$result")
  done <<< "$keys"

  echo "$result"
}

# Map an optional plan priority token to a Jira priority name.
# Empty input → empty output (do not invent a default for the API).
# Stage/company-managed schemes often use Critical/Major/Normal/Minor/Trivial
# rather than Highest/High/Medium/Low/Lowest — map the plan tokens accordingly.
jira_schema_map_priority() {
  local raw="${1:-}"
  if [[ -z "$raw" || "$raw" == "null" ]]; then
    echo ""
    return 0
  fi
  case "${raw,,}" in
    highest|blocker) echo "Blocker" ;;
    high|critical) echo "Critical" ;;
    medium|major|normal) echo "Major" ;;
    low|minor) echo "Minor" ;;
    lowest|trivial) echo "Trivial" ;;
    *) echo "$raw" ;;
  esac
}

jira_schema_merge_routable_into_issue_context() {
  local issue_context_file="${1:-}"
  local routable_json='{}'
  [[ $# -ge 2 && -n "$2" ]] && routable_json="$2"

  if [[ -z "$issue_context_file" || ! -f "$issue_context_file" ]]; then
    echo "::warning::Cannot merge routable_projects — issue context missing" >&2
    return 1
  fi

  local tmp
  tmp=$(mktemp)
  jq --argjson rp "$routable_json" '. + {routable_projects: $rp}' "$issue_context_file" > "$tmp"
  mv "$tmp" "$issue_context_file"
}
