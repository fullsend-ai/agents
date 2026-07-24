#!/usr/bin/env bash
# pre-explore.sh — Fetch issue data and prepare context for the explore agent.
#
# Runs on the host before the sandbox is created. Fetches issue data from
# Jira or GitHub using credentials that never enter the sandbox.
#
# Required env vars:
#   ISSUE_KEY        — Jira key (e.g., PROJ-123) or GitHub issue number
#   ISSUE_SOURCE     — "jira" or "github"
#   GH_TOKEN         — GitHub token
#
# Jira-only env vars:
#   JIRA_HOST        — Jira hostname (e.g., your-org.atlassian.net)
#   JIRA_EMAIL       — Jira user email
#   JIRA_API_TOKEN   — Jira API token
#
# GitHub-only env vars:
#   REPO_FULL_NAME   — owner/repo (e.g., fullsend-ai/features)

set -euo pipefail

WORKSPACE="/tmp/workspace"
mkdir -p "$WORKSPACE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Companion resolution for harness base: composition (ADR-0045).
# URL-fetched scripts are isolated blobs without siblings. Prefer install copies
# under GITHUB_WORKSPACE/.fullsend/scripts or FULLSEND_DIR/scripts (overlay pattern).
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
  echo "ERROR: companion ${name} not found next to ${BASH_SOURCE[0]} or under install .fullsend/scripts." >&2
  echo "Installs using harness base: should override pre_script/post_script locally, or vendor companions into .fullsend/scripts/." >&2
  return 1
}

# shellcheck disable=SC1090
source "$(_resolve_companion comment-helpers.sh)"

echo "::notice::Pre-explore: fetching issue data (source=${ISSUE_SOURCE}, key=${ISSUE_KEY})"

# Validate inputs to prevent injection
if [[ "${ISSUE_SOURCE}" != "jira" && "${ISSUE_SOURCE}" != "github" ]]; then
  echo "ERROR: ISSUE_SOURCE must be 'jira' or 'github', got: ${ISSUE_SOURCE}"
  exit 1
fi

if [[ "${ISSUE_SOURCE}" == "jira" && ! "${ISSUE_KEY}" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]; then
  echo "ERROR: ISSUE_KEY does not match Jira key pattern (e.g., PROJECT-123): ${ISSUE_KEY}"
  exit 1
fi

if [[ "${ISSUE_SOURCE}" == "github" && ! "${ISSUE_KEY}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: ISSUE_KEY must be a numeric GitHub issue number, got: ${ISSUE_KEY}"
  exit 1
fi

if [[ "${ISSUE_SOURCE}" == "jira" ]]; then
  if [[ -z "${JIRA_HOST:-}" || -z "${JIRA_EMAIL:-}" || -z "${JIRA_API_TOKEN:-}" ]]; then
    echo "ERROR: Jira credentials not set (JIRA_HOST, JIRA_EMAIL, JIRA_API_TOKEN)"
    exit 1
  fi
  validate_jira_host

  JIRA_BASE="https://${JIRA_HOST}/rest/api/3"
  AUTH=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  jira_get() {
    curl -sSf -H "Authorization: Basic $AUTH" \
      -H "Accept: application/json" "$1"
  }

  ISSUE_JSON=$(jira_get "${JIRA_BASE}/issue/${ISSUE_KEY}?expand=names")

  SUMMARY=$(echo "$ISSUE_JSON" | jq -r '.fields.summary // ""')
  DESCRIPTION=$(echo "$ISSUE_JSON" | jq -r '.fields.description // ""')
  if echo "$ISSUE_JSON" | jq -e '.fields.description | type == "object"' > /dev/null 2>&1; then
    DESCRIPTION=$(echo "$ISSUE_JSON" | jq '.fields.description' | python3 "$(_resolve_companion adf-to-markdown.py)")
  fi
  STATUS=$(echo "$ISSUE_JSON" | jq -r '.fields.status.name // ""')
  PRIORITY=$(echo "$ISSUE_JSON" | jq -r '.fields.priority.name // ""')
  ISSUE_TYPE=$(echo "$ISSUE_JSON" | jq -r '.fields.issuetype.name // ""')
  REPORTER=$(echo "$ISSUE_JSON" | jq -r '.fields.reporter.emailAddress // ""')
  LABELS=$(echo "$ISSUE_JSON" | jq -c '.fields.labels // []')
  CREATED=$(echo "$ISSUE_JSON" | jq -r '.fields.created // ""')
  UPDATED=$(echo "$ISSUE_JSON" | jq -r '.fields.updated // ""')

  # Determine level from issue type
  LEVEL="issue"
  case "${ISSUE_TYPE,,}" in
    outcome) LEVEL="outcome" ;;
    feature) LEVEL="feature" ;;
    epic)    LEVEL="epic" ;;
    story)   LEVEL="story" ;;
    task|sub-task) LEVEL="task" ;;
  esac

  PARENT_KEY=$(echo "$ISSUE_JSON" | jq -r '.fields.parent.key // ""')
  PARENT_JSON="null"
  if [[ -n "$PARENT_KEY" ]]; then
    PARENT_ISSUE=$(jira_get "${JIRA_BASE}/issue/${PARENT_KEY}" 2>/dev/null || echo "{}")
    PARENT_SUMMARY=$(echo "$PARENT_ISSUE" | jq -r '.fields.summary // ""')
    PARENT_DESC=$(echo "$PARENT_ISSUE" | jq -r '.fields.description // ""')
    if echo "$PARENT_ISSUE" | jq -e '.fields.description | type == "object"' > /dev/null 2>&1; then
      PARENT_DESC=$(echo "$PARENT_ISSUE" | jq '.fields.description' | python3 "$(_resolve_companion adf-to-markdown.py)")
    fi
    PARENT_JSON=$(jq -n --arg k "$PARENT_KEY" --arg s "$PARENT_SUMMARY" --arg d "$PARENT_DESC" \
      '{"key": $k, "summary": $s, "description": $d}')
  fi

  CHILDREN_JSON=$(jira_get "${JIRA_BASE}/search?jql=parent=${ISSUE_KEY}&fields=summary,status,issuetype&maxResults=50" 2>/dev/null \
    | jq '[.issues[] | {key: .key, summary: .fields.summary, status: .fields.status.name, type: .fields.issuetype.name}]' \
    || echo "[]")

  COMMENTS_TMPFILE=$(mktemp)
  jira_get "${JIRA_BASE}/issue/${ISSUE_KEY}/comment?maxResults=50" > "$COMMENTS_TMPFILE" 2>/dev/null \
    || echo '{"comments":[]}' > "$COMMENTS_TMPFILE"
  COMMENT_COUNT=$(jq '.comments | length' "$COMMENTS_TMPFILE")
  COMMENTS_JSON="[]"
  if [[ "$COMMENT_COUNT" -gt 0 ]]; then
    COMMENTS_TMPDIR=$(mktemp -d)
    for i in $(seq 0 $((COMMENT_COUNT - 1))); do
      BODY_TYPE=$(jq -r ".comments[$i].body | type" "$COMMENTS_TMPFILE")
      if [[ "$BODY_TYPE" == "object" ]]; then
        jq ".comments[$i].body" "$COMMENTS_TMPFILE" \
          | python3 "$(_resolve_companion adf-to-markdown.py)" > "$COMMENTS_TMPDIR/body_$i.txt"
      else
        jq -r ".comments[$i].body // \"\"" "$COMMENTS_TMPFILE" > "$COMMENTS_TMPDIR/body_$i.txt"
      fi
    done
    COMMENTS_JSON=$(JIRA_EMAIL="$JIRA_EMAIL" COMMENTS_TMPFILE="$COMMENTS_TMPFILE" COMMENTS_TMPDIR="$COMMENTS_TMPDIR" python3 -c "
import json, os, re
with open(os.environ['COMMENTS_TMPFILE']) as f:
    data = json.load(f)
result = []
# Service account emails used by automation are filtered from comments.
AGENT_EMAIL = os.environ.get('JIRA_EMAIL', '')
SKIP_PATTERNS = [
    r'fullsend dispatched',  # dispatch confirmations
]
COMMAND_RE = re.compile(r'^/fs-\S*\s*', re.MULTILINE)
for i, comment in enumerate(data['comments']):
    author = comment.get('author', {}).get('emailAddress', '')
    if author == AGENT_EMAIL:
        continue
    body_path = os.path.join(os.environ['COMMENTS_TMPDIR'], f'body_{i}.txt')
    with open(body_path) as bf:
        body = bf.read().rstrip('\n')
    if any(re.match(p, body.strip()) for p in SKIP_PATTERNS):
        continue
    # Strip /fs-* command prefix but keep the guidance text after it
    body = COMMAND_RE.sub('', body).strip()
    if not body:
        continue
    result.append({
        'author': author,
        'created': comment.get('created', ''),
        'body': body,
    })
print(json.dumps(result, ensure_ascii=False))
")
    rm -rf "$COMMENTS_TMPDIR"
  fi
  rm -f "$COMMENTS_TMPFILE"

  LINKS_JSON=$(echo "$ISSUE_JSON" | jq '[.fields.issuelinks // [] | .[] | {
    type: (.type.outward // .type.name),
    key: (.outwardIssue.key // .inwardIssue.key),
    summary: (.outwardIssue.fields.summary // .inwardIssue.fields.summary),
    status: (.outwardIssue.fields.status.name // .inwardIssue.fields.status.name)
  }]')

  # Fetch project metadata
  PROJECT_KEY=$(echo "$ISSUE_JSON" | jq -r '.fields.project.key')
  PROJECT_NAME=$(echo "$ISSUE_JSON" | jq -r '.fields.project.name')

  # Fetch available issue types for the project
  PROJECT_ISSUE_TYPES=$(jira_get "${JIRA_BASE}/project/${PROJECT_KEY}" 2>/dev/null \
    | jq '[.issueTypes[]? | {name: .name, subtask: .subtask, hierarchyLevel: .hierarchyLevel, description: .description}]' \
    || echo "[]")

  # If project endpoint didn't return issue types, try createmeta
  if [[ "$PROJECT_ISSUE_TYPES" == "[]" || "$PROJECT_ISSUE_TYPES" == "null" ]]; then
    PROJECT_ISSUE_TYPES=$(jira_get "${JIRA_BASE}/issue/createmeta?projectKeys=${PROJECT_KEY}&expand=projects.issuetypes" 2>/dev/null \
      | jq '[.projects[0].issuetypes[]? | {name: .name, subtask: .subtask, hierarchyLevel: .hierarchyLevel, description: .description}]' \
      || echo "[]")
  fi

  echo "Available issue types for ${PROJECT_KEY}: $(echo "$PROJECT_ISSUE_TYPES" | jq -r '[.[].name] | join(", ")')"

  # Sample existing children to learn team conventions (type distribution)
  TEAM_USAGE=$(jira_get "${JIRA_BASE}/search?jql=project=${PROJECT_KEY}+AND+issuetype+in+(Story,Task,Epic,Feature,Bug,Spike)+ORDER+BY+created+DESC&fields=issuetype,labels&maxResults=50" 2>/dev/null \
    | jq '{
        type_counts: [.issues[]? | .fields.issuetype.name] | group_by(.) | map({type: .[0], count: length}) | sort_by(-.count),
        common_labels: [.issues[]? | .fields.labels[]?] | group_by(.) | map({label: .[0], count: length}) | sort_by(-.count) | .[0:10]
      }' \
    || echo '{"type_counts": [], "common_labels": []}')

  jq -n \
    --arg source "jira" \
    --arg host "$JIRA_HOST" \
    --arg key "$ISSUE_KEY" \
    --arg level "$LEVEL" \
    --arg summary "$SUMMARY" \
    --arg description "$DESCRIPTION" \
    --arg status "$STATUS" \
    --arg priority "$PRIORITY" \
    --argjson labels "$LABELS" \
    --arg reporter "$REPORTER" \
    --arg created "$CREATED" \
    --arg updated "$UPDATED" \
    --argjson parent "$PARENT_JSON" \
    --argjson children "$CHILDREN_JSON" \
    --argjson comments "$COMMENTS_JSON" \
    --argjson linked_issues "$LINKS_JSON" \
    --arg project_key "$PROJECT_KEY" \
    --arg project_name "$PROJECT_NAME" \
    --argjson available_issue_types "$PROJECT_ISSUE_TYPES" \
    --argjson team_usage "$TEAM_USAGE" \
    '{
      source: $source,
      host: $host,
      key: $key,
      level: $level,
      summary: $summary,
      description: $description,
      status: $status,
      priority: $priority,
      labels: $labels,
      reporter: $reporter,
      created: $created,
      updated: $updated,
      parent: $parent,
      children: $children,
      comments: $comments,
      linked_issues: $linked_issues,
      project: {key: $project_key, name: $project_name, available_issue_types: $available_issue_types, team_usage: $team_usage}
    }' > "$WORKSPACE/issue-context.json"

elif [[ "${ISSUE_SOURCE}" == "github" ]]; then
  if [[ -z "${REPO_FULL_NAME:-}" ]]; then
    echo "ERROR: REPO_FULL_NAME not set for GitHub source"
    exit 1
  fi
  if [[ ! "${REPO_FULL_NAME}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: REPO_FULL_NAME must be owner/repo format, got: ${REPO_FULL_NAME}"
    exit 1
  fi

  ISSUE_JSON=$(gh issue view "$ISSUE_KEY" --repo "$REPO_FULL_NAME" \
    --json number,title,body,labels,comments,state,milestone,assignees,createdAt,updatedAt,author)

  TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
  BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')
  STATE=$(echo "$ISSUE_JSON" | jq -r '.state')
  LABELS=$(echo "$ISSUE_JSON" | jq -c '[.labels[].name]')
  AUTHOR=$(echo "$ISSUE_JSON" | jq -r '.author.login')
  CREATED=$(echo "$ISSUE_JSON" | jq -r '.createdAt')
  UPDATED=$(echo "$ISSUE_JSON" | jq -r '.updatedAt')

  # Determine level from labels
  LEVEL="issue"
  while IFS= read -r label; do
    case "${label,,}" in
      feature) LEVEL="feature" ;;
      epic)    LEVEL="epic" ;;
      story)   LEVEL="story" ;;
      task)    LEVEL="task" ;;
    esac
  done < <(echo "$LABELS" | jq -r '.[]')

  COMMENT_COUNT=$(echo "$ISSUE_JSON" | jq '.comments | length')

  COMMENTS=$(echo "$ISSUE_JSON" | jq '[.comments[] | {author: .author.login, created: .createdAt, body: .body}]')

  SUB_ISSUES=$(gh issue list --repo "$REPO_FULL_NAME" --state all \
    --search "parent:#${ISSUE_KEY}" --json number,title,state,labels --limit 30 2>/dev/null \
    | jq '[.[] | {key: ("#" + (.number | tostring)), summary: .title, status: .state, type: "issue"}]' \
    || echo "[]")
  jq -n \
    --arg source "github" \
    --arg key "#${ISSUE_KEY}" \
    --arg level "$LEVEL" \
    --arg summary "$TITLE" \
    --arg description "$BODY" \
    --arg status "$STATE" \
    --argjson labels "$LABELS" \
    --arg reporter "$AUTHOR" \
    --arg created "$CREATED" \
    --arg updated "$UPDATED" \
    --argjson children "$SUB_ISSUES" \
    --argjson comments "$COMMENTS" \
    --arg repo "$REPO_FULL_NAME" \
    '{
      source: $source,
      key: $key,
      level: $level,
      summary: $summary,
      description: $description,
      status: $status,
      labels: $labels,
      reporter: $reporter,
      created: $created,
      updated: $updated,
      parent: null,
      children: $children,
      comments: $comments,
      linked_issues: [],
      project: {key: $repo, name: $repo}
    }' > "$WORKSPACE/issue-context.json"

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "GITHUB_ISSUE_NUMBER=${ISSUE_KEY}" >> "${GITHUB_ENV}"
  fi
  export GITHUB_ISSUE_NUMBER="${ISSUE_KEY}"

else
  echo "ERROR: Unknown ISSUE_SOURCE: ${ISSUE_SOURCE}"
  exit 1
fi

echo "Issue context written to $WORKSPACE/issue-context.json"
echo "::notice::Issue: ${ISSUE_KEY} (${ISSUE_SOURCE}, level=$(jq -r .level "$WORKSPACE/issue-context.json"))"

# --- Phase 2: Clone referenced GitHub repos for deep exploration ---
#
# Discovers repo references from three sources:
#   1. Issue text — explicit URLs and bare owner/repo patterns
#   2. Jira ADF inlineCard/link nodes — smart links
#   3. Previous explore output — repos the agent discovered on prior runs
# Then validates candidates against GitHub API and shallow-clones public ones.
#
# This is fully generic — discovers repos from whatever is in the issue.
# Callers (pre-refine.sh, pre-critique.sh) can set SKIP_REPO_CLONING=1 to
# skip this phase — only the explore agent needs pre-cloned repos.

if [[ "${SKIP_REPO_CLONING:-}" == "1" ]]; then
  echo "::notice::Repo cloning skipped (SKIP_REPO_CLONING=1)"
  echo "ISSUE_CONTEXT=$WORKSPACE/issue-context.json" >> "${GITHUB_ENV:-/dev/null}"
  exit 0
fi

REFERENCED_REPOS_DIR="$WORKSPACE/referenced-repos"
REFERENCED_MANIFEST="$WORKSPACE/referenced-repos-manifest.json"
MAX_REPOS=5
CLONE_TIMEOUT=30  # seconds per repo
TOTAL_BUDGET=120  # seconds total for all cloning

mkdir -p "$REFERENCED_REPOS_DIR"

# Extract GitHub repo references from issue text and ADF structures.
extract_repo_refs_from_text() {
  TEXT_CONTENT=$(jq -r '
    [.description // "", (.comments // [] | .[].body // "")] | join("\n")
  ' "$WORKSPACE/issue-context.json")

  ADF_INLINE=$(echo "$ISSUE_JSON" 2>/dev/null \
    | jq -r '[.. | select(type == "object") | select(.type == "inlineCard" or .type == "link") | .attrs.url // empty] | .[]' 2>/dev/null \
    || true)

  ALL_TEXT=$(printf '%s\n%s' "$TEXT_CONTENT" "$ADF_INLINE")

  # Explicit github.com URLs
  EXPLICIT=$(echo "$ALL_TEXT" \
    | grep -oP '(?:https?://)?github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)' \
    | sed 's|.*github\.com/||' \
    | sed 's|\.git$||' \
    | sed 's|/tree/.*||; s|/blob/.*||; s|/issues.*||; s|/pull.*||; s|/actions.*||; s|/settings.*||' \
    || true)

  # Bare owner/repo patterns (require at least one hyphen to reduce false positives)
  BARE=$(echo "$ALL_TEXT" \
    | grep -oP '\b([A-Za-z][A-Za-z0-9_-]{1,38}/[A-Za-z][A-Za-z0-9._-]{1,99})\b' \
    | grep -P '[-]' \
    | grep -vP '\.(go|py|js|ts|yaml|yml|json|md|txt|sh|rs|toml|lock|mod|sum|html|css|xml|proto|sql)$' \
    | grep -vP '^(src/|cmd/|pkg/|internal/|docs/|test/|bin/|lib/|etc/|var/|tmp/|usr/|dev/|app/)' \
    || true)

  # Filter bare patterns that are substrings of explicit URLs (e.g., "com/ambient-code"
  # appears inside "github.com/ambient-code/agentready" and is not a real repo ref).
  if [[ -n "$EXPLICIT" && -n "$BARE" ]]; then
    FILTERED_BARE=$(echo "$BARE" | while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      IS_SUBSTRING=false
      while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        if [[ "github.com/$url" == *"$candidate"* ]]; then
          IS_SUBSTRING=true
          break
        fi
      done <<< "$EXPLICIT"
      $IS_SUBSTRING || echo "$candidate"
    done || true)
    { echo "$EXPLICIT"; echo "$FILTERED_BARE"; } | sort -u | grep -v '^$' || true
  else
    { echo "$EXPLICIT"; echo "$BARE"; } | sort -u | grep -v '^$' || true
  fi
}

# Extract repo references from a previous explore result attachment.
# On re-runs, the agent's own discoveries from prior runs become seed repos.
extract_repo_refs_from_previous_explore() {
  if [[ "${ISSUE_SOURCE}" != "jira" || -z "${JIRA_HOST:-}" ]]; then
    return
  fi

  # Check for exploration_context.json attachment on the Jira issue
  ATTACHMENTS=$(jira_get "${JIRA_BASE}/issue/${ISSUE_KEY}?fields=attachment" 2>/dev/null \
    | jq -r '.fields.attachment[]? | select(.filename == "exploration_context.json") | .content' 2>/dev/null \
    || true)

  if [[ -z "$ATTACHMENTS" ]]; then
    echo "  (no previous exploration_context.json attachment found)" >&2
    return
  fi

  # Download the most recent explore result (last URL in the list)
  EXPLORE_URL=$(echo "$ATTACHMENTS" | tail -1)
  if [[ "$EXPLORE_URL" != "https://${JIRA_HOST}/"* ]]; then
    echo "  (previous explore attachment URL rejected — host mismatch)" >&2
    return
  fi
  PREV_EXPLORE=$(curl -sSf -H "Authorization: Basic $AUTH" "$EXPLORE_URL" 2>/dev/null || true)

  if [[ -z "$PREV_EXPLORE" ]]; then
    echo "  (previous explore attachment download failed)" >&2
    return
  fi

  echo "  Found previous explore result — extracting discovered repos" >&2

  # Extract owner/repo patterns from key_dependencies, related_work, etc.
  echo "$PREV_EXPLORE" | jq -r '
    [
      (.technical_landscape.key_dependencies[]?.name // empty),
      (.related_work[]? | select(.source == "github") | .key // empty)
    ] | .[] | select(test("^[A-Za-z][A-Za-z0-9._-]*/[A-Za-z][A-Za-z0-9._-]*$"))
  ' 2>/dev/null || true
}

# Validate a candidate owner/repo against the GitHub API.
validate_repo() {
  local ref="$1"
  local http_code
  http_code=$(GIT_TERMINAL_PROMPT=0 curl -sf -o /dev/null -w "%{http_code}" \
    "https://api.github.com/repos/${ref}" 2>/dev/null || echo "000")
  [[ "$http_code" == "200" ]]
}

SELF_REPO="${GITHUB_REPOSITORY:-}"
TARGET="${REPO_FULL_NAME:-}"

echo "::group::Clone referenced repos"

# Gather candidates from all sources
TEXT_REFS=$(extract_repo_refs_from_text)
PREV_REFS=$(extract_repo_refs_from_previous_explore)

REPO_REFS=$(printf '%s\n%s' "$TEXT_REFS" "$PREV_REFS" | sort -u | grep -v '^$' || true)

CLONED=()
SKIPPED=()
FAILED=()
START_TIME=$(date +%s)

if [[ -z "$REPO_REFS" ]]; then
  echo "No GitHub repo references found in issue context or previous runs"
else
  echo "Candidates found:"
  echo "$REPO_REFS" | sed 's/^/  /'
  echo "---"

  REPO_COUNT=0
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue

    # Budget check
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if (( ELAPSED >= TOTAL_BUDGET )); then
      echo "WARN: Total time budget (${TOTAL_BUDGET}s) exceeded, stopping"
      SKIPPED+=("$ref (budget)")
      continue
    fi

    # Max repos check
    if (( REPO_COUNT >= MAX_REPOS )); then
      echo "WARN: Max repos ($MAX_REPOS) reached, skipping: $ref"
      SKIPPED+=("$ref (limit)")
      continue
    fi

    # Skip self and target repo
    if [[ "$ref" == "$SELF_REPO" || "$ref" == "$TARGET" ]]; then
      echo "  skip (self/target): $ref"
      SKIPPED+=("$ref (self)")
      continue
    fi

    OWNER="${ref%%/*}"
    REPO="${ref##*/}"

    # SECURITY: Reject path traversal and invalid GitHub name patterns.
    # GitHub usernames/repos must start with alphanumeric.
    if [[ ! "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      echo "  skip (invalid format): $ref"
      SKIPPED+=("$ref (invalid)")
      continue
    fi

    # Validate candidate is a real public repo via GitHub API
    echo -n "  validating: $ref ... "
    if ! validate_repo "$ref"; then
      echo "not a public repo"
      SKIPPED+=("$ref (not found)")
      continue
    fi
    echo "confirmed"

    DEST="$REFERENCED_REPOS_DIR/$OWNER/$REPO"

    if [[ -d "$DEST" ]]; then
      echo "  skip (already cloned): $ref"
      continue
    fi

    echo "  cloning: $ref → $DEST"
    mkdir -p "$DEST"

    # SECURITY: Explicitly disable credential helpers to ensure only public repos
    # are cloneable. This prevents accidentally leaking private repo content if
    # a credential helper is configured on the runner (e.g., by actions/checkout).
    if GIT_TERMINAL_PROMPT=0 timeout "${CLONE_TIMEOUT}" \
        git -c credential.helper= clone --depth 1 --single-branch --quiet \
        "https://github.com/${ref}.git" "$DEST" 2>/dev/null; then
      rm -rf "$DEST/.git"  # agent only needs source files, not git metadata
      CLONED+=("$ref")
      REPO_COUNT=$((REPO_COUNT + 1))
      echo "    ✓ cloned ($REPO_COUNT/$MAX_REPOS)"
    else
      rm -rf "$DEST"
      FAILED+=("$ref")
      echo "    ✗ failed (private or timeout)"
    fi
  done <<< "$REPO_REFS"
fi

# Write manifest so the agent knows what's available
CLONED_JSON="[]"
SKIPPED_JSON="[]"
FAILED_JSON="[]"
[[ ${#CLONED[@]} -gt 0 ]] && CLONED_JSON=$(printf '%s\n' "${CLONED[@]}" | jq -R . | jq -s .)
[[ ${#SKIPPED[@]} -gt 0 ]] && SKIPPED_JSON=$(printf '%s\n' "${SKIPPED[@]}" | jq -R . | jq -s .)
[[ ${#FAILED[@]} -gt 0 ]] && FAILED_JSON=$(printf '%s\n' "${FAILED[@]}" | jq -R . | jq -s .)

jq -n \
  --argjson cloned "$CLONED_JSON" \
  --argjson skipped "$SKIPPED_JSON" \
  --argjson failed "$FAILED_JSON" \
  '{cloned: $cloned, skipped: $skipped, failed: $failed}' \
  > "$REFERENCED_MANIFEST"

echo "::endgroup::"
echo "::notice::Referenced repos: ${#CLONED[@]} cloned, ${#SKIPPED[@]} skipped, ${#FAILED[@]} failed"

# --- Phase 2b: Generate navigation manifests for each cloned repo ---
# Creates a REPO-INDEX.md in each repo root with:
#   1. Context files (AGENTS.md, CLAUDE.md, README.md, BOOKMARKS.md)
#   2. Directory-level code map (packages, file counts, line counts)
#   3. Exported symbol index (public functions/types with file:line refs)

generate_repo_index() {
  local repo_dir="$1"
  local index_file="$repo_dir/REPO-INDEX.md"

  {
    echo "# Repository Navigation Index"
    echo ""
    echo "Generated by pre-explore.sh — use this to orient before reading source."
    echo ""
  } > "$index_file"

  # Section 1: Context files
  for ctx_file in AGENTS.md CLAUDE.md README.md BOOKMARKS.md; do
    if [[ -f "$repo_dir/$ctx_file" ]]; then
      {
        echo "## $ctx_file"
        echo ""
        echo '```'
        head -80 "$repo_dir/$ctx_file"
        local total_lines
        total_lines=$(wc -l < "$repo_dir/$ctx_file")
        if [[ $total_lines -gt 80 ]]; then
          echo ""
          echo "... ($total_lines total lines, showing first 80)"
        fi
        echo '```'
        echo ""
      } >> "$index_file"
    fi
  done

  # Section 2: Directory-level code map
  {
    echo "## Code Map (directories with source files)"
    echo ""
    echo '```'
  } >> "$index_file"

  find "$repo_dir" -type f \( -name "*.go" -o -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.rs" \) \
    -not -path "*node_modules*" -not -path "*vendor*" -not -path "*_test.*" -not -path "*.test.*" \
    -not -path "*__pycache__*" -printf "%h\n" 2>/dev/null | sort -u | while read -r dir; do
    local rel_dir="${dir#"$repo_dir"/}"
    local file_count line_count
    file_count=$(find "$dir" -maxdepth 1 -type f \( -name "*.go" -o -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.rs" \) \
      -not -name "*_test.*" -not -name "*.test.*" 2>/dev/null | wc -l)
    if [[ $file_count -gt 0 ]]; then
      line_count=$(find "$dir" -maxdepth 1 -type f \( -name "*.go" -o -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.rs" \) \
        -not -name "*_test.*" -not -name "*.test.*" -exec cat {} + 2>/dev/null | wc -l)
      printf "  %-60s %3d files  %5d lines\n" "$rel_dir/" "$file_count" "$line_count" >> "$index_file"
    fi
  done || true

  {
    echo '```'
    echo ""
    # Section 3: Exported symbol index (public API surface)
    echo "## Exported Symbols (public functions and types)"
    echo ""
    echo '```'
  } >> "$index_file"

  if [[ -f "$repo_dir/go.mod" ]]; then
    # Go: exported = starts with uppercase
    grep -rn "^func [A-Z]\|^type [A-Z]" "$repo_dir" --include="*.go" \
      | grep -v "_test.go" \
      | sed "s|^$repo_dir/||" \
      | sort \
      | head -500 >> "$index_file" 2>/dev/null || true
  elif [[ -f "$repo_dir/package.json" ]]; then
    # JS/TS: export statements
    grep -rn "^export " "$repo_dir" --include="*.ts" --include="*.js" \
      | grep -v "node_modules\|\.test\.\|\.spec\." \
      | sed "s|^$repo_dir/||" \
      | sort \
      | head -500 >> "$index_file" 2>/dev/null || true
  elif [[ -f "$repo_dir/requirements.txt" ]] || [[ -f "$repo_dir/pyproject.toml" ]]; then
    # Python: class and def at module level
    grep -rn "^class \|^def " "$repo_dir" --include="*.py" \
      | grep -v "__pycache__\|test_\|_test\.py" \
      | sed "s|^$repo_dir/||" \
      | sort \
      | head -500 >> "$index_file" 2>/dev/null || true
  fi

  {
    echo '```'
    echo ""
  } >> "$index_file"

  local index_size
  index_size=$(wc -c < "$index_file")
  echo "    ✓ generated REPO-INDEX.md ($(( index_size / 1024 ))KB)" >&2
}

if [[ ${#CLONED[@]} -gt 0 ]]; then
  echo "::group::Generating navigation manifests"
  for ref in "${CLONED[@]}"; do
    local_dir="$REFERENCED_REPOS_DIR/$ref"
    if [[ -d "$local_dir" ]]; then
      echo "  indexing: $ref"
      generate_repo_index "$local_dir"
    fi
  done
  echo "::endgroup::"
fi

# Create tarball for sandbox mounting (host_files only supports files, not dirs)
if [[ ${#CLONED[@]} -gt 0 ]]; then
  tar czf "$WORKSPACE/referenced-repos.tar.gz" -C "$WORKSPACE" referenced-repos/
  echo "Tarball created: $(du -h "$WORKSPACE/referenced-repos.tar.gz" | cut -f1)"
fi

# Export paths for the agent
echo "ISSUE_CONTEXT=$WORKSPACE/issue-context.json" >> "${GITHUB_ENV:-/dev/null}"
