#!/usr/bin/env bash
# comment-helpers.sh — Shared helpers for posting sticky comments to GitHub/Jira.
#
# Sticky comments: each agent (explore, refine, critique) maintains a single
# comment on the issue. On re-run, the existing comment is edited rather than
# creating a new one.
#
# GitHub: delegates to `fullsend post-comment` CLI which handles sticky
# lifecycle (find by marker → collapse old content into <details> → update).
# This matches the behavior of triage/review agents upstream.
#
# Jira: custom implementation using ADF with collapsed expand-node history
# (upstream fullsend doesn't support Jira yet).
#
# Usage:
#   source "${SCRIPT_DIR}/comment-helpers.sh"
#   init_comment_helpers "explore" "$USE_GITHUB"
#   sticky_comment "$body"
#
# Required env vars (set before sourcing):
#   ISSUE_KEY, ISSUE_SOURCE, JIRA_HOST, JIRA_EMAIL, JIRA_API_TOKEN
#   GITHUB_ISSUE_NUMBER, REPO_FULL_NAME, GH_TOKEN (for GitHub flow)

_CH_AGENT=""
_CH_USE_GITHUB=false
_CH_MARKER=""
_CH_GH_MARKER=""
# Total "Previous · …" expand nodes to retain (including the new snapshot).
_CH_MAX_HISTORY=3
# Resolve companions relative to this file — not the caller's SCRIPT_DIR.
# URL-fetched post scripts live as isolated cache blobs; companions are
# sourced from install .fullsend/scripts via _resolve_companion.
_CH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

validate_jira_host() {
  if [[ -z "${JIRA_HOST:-}" ]]; then
    echo "ERROR: JIRA_HOST not set"
    exit 1
  fi
  if [[ ! "${JIRA_HOST}" =~ ^[a-zA-Z0-9.-]+\.atlassian\.net$ ]]; then
    echo "ERROR: JIRA_HOST must be a *.atlassian.net hostname, got: ${JIRA_HOST}"
    exit 1
  fi
}

init_comment_helpers() {
  _CH_AGENT="$1"
  _CH_USE_GITHUB="${2:-false}"
  _CH_MARKER="fullsend:${_CH_AGENT}-agent"
  _CH_GH_MARKER="<!-- ${_CH_MARKER} -->"
}

_find_sticky_comment_jira() {
  local key="$1"
  validate_jira_host
  local auth
  auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)

  curl -sSf \
    -H "Authorization: Basic $auth" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issue/${key}/comment?orderBy=-created&maxResults=50" \
    2>/dev/null \
    | jq -r --arg marker "$_CH_MARKER" \
      '[.comments[] | select(
        [.body.content[]? | .. | .text? // empty] | join(" ") | contains($marker)
      ) | .id] | first // empty'
}

_build_jira_adf_with_history() {
  local new_adf="$1" existing_id="$2" auth="$3"
  local new_content old_body old_current old_history timestamp history_entry final_adf

  new_content=$(echo "$new_adf" | jq '.body.content')

  old_body=$(curl -sSf \
    -H "Authorization: Basic $auth" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/comment/${existing_id}" \
    2>/dev/null | jq '.body // empty')

  if [[ -z "$old_body" || "$old_body" == "null" ]]; then
    echo "$new_adf"
    return
  fi

  # Preserve full prior sticky body in history — including content that lived
  # inside non-Previous expands (e.g. accidental "Detailed Specification" wraps).
  # Drop only nested Previous expands (they are tracked separately).
  old_current=$(echo "$old_body" | jq '
    [
      .content[]?
      | select((.type != "expand") or ((.attrs.title // "") | startswith("Previous") | not))
      | if .type == "expand" then .content[] else . end
    ]
  ')
  old_history=$(echo "$old_body" | jq --argjson max "$((_CH_MAX_HISTORY - 1))" \
    '[.content[]? | select(.type == "expand" and (.attrs.title // "" | startswith("Previous")))] | .[:$max]')

  timestamp=$(date -u +"%b %d, %H:%M UTC")

  history_entry=$(jq -n --argjson content "$old_current" --arg title "Previous · ${timestamp}" \
    '{"type": "expand", "attrs": {"title": $title}, "content": $content}')

  final_adf=$(jq -n \
    --argjson new_content "$new_content" \
    --argjson history_entry "$history_entry" \
    --argjson old_history "$old_history" \
    --arg marker "$_CH_MARKER" \
    '{body: {type: "doc", version: 1, content:
      ($new_content
       + [{"type": "rule"}]
       + [$history_entry]
       + $old_history
       + [{"type": "expand", "attrs": {"title": ""}, "content":
           [{"type": "paragraph", "content": [{"type": "text", "text": $marker}]}]}]
      )
    }}')

  echo "$final_adf"
}

_redact_secrets() {
  if command -v fullsend >/dev/null 2>&1; then
    fullsend scan output
  else
    echo "::warning::fullsend not on PATH — posting comment without secret scanning" >&2
    cat
  fi
}

sticky_comment() {
  local body
  body=$(printf '%s' "$1" | _redact_secrets)

  if $_CH_USE_GITHUB; then
    printf '%s' "$body" | fullsend post-comment \
      --repo "${REPO_FULL_NAME}" \
      --number "${GITHUB_ISSUE_NUMBER}" \
      --marker "${_CH_GH_MARKER}" \
      --token "${GH_TOKEN}" \
      --result -

  elif [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
    local auth
    auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
    local adf_body adf_flags
    # Collapse post-meta detail (after first ---) under Detailed Specification.
    # History unwrap flattens that expand when snapshotting Previous runs.
    adf_flags="--wrap-detail"
    if [[ "$JIRA_HOST" != *"atlassian.net"* ]]; then
      adf_flags="--wrap-detail --no-expand"
    fi
    adf_body=$(printf '%s' "$body" | python3 "${_CH_DIR}/markdown-to-adf.py" $adf_flags)

    local existing_id
    existing_id=$(_find_sticky_comment_jira "$ISSUE_KEY")

    if [[ -n "$existing_id" ]]; then
      local full_adf
      full_adf=$(_build_jira_adf_with_history "$adf_body" "$existing_id" "$auth")
      if curl -sSf -X PUT \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json" \
        -d "$full_adf" \
        "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/comment/${existing_id}" > /dev/null 2>&1; then
        echo "Updated sticky Jira comment ${existing_id} (history preserved)"
      else
        curl -sSf -X POST \
          -H "Authorization: Basic $auth" \
          -H "Content-Type: application/json" \
          -d "$full_adf" \
          "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/comment" > /dev/null 2>&1 || true
      fi
    else
      adf_body=$(echo "$adf_body" | jq --arg marker "$_CH_MARKER" '
        .body.content += [{
          "type": "expand",
          "attrs": {"title": ""},
          "content": [{"type": "paragraph", "content": [{"type": "text", "text": $marker}]}]
        }]
      ')
      curl -sSf -X POST \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: application/json" \
        -d "$adf_body" \
        "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/comment" > /dev/null 2>&1 || true
    fi
  fi
}

new_comment() {
  local body
  body=$(printf '%s' "$1" | _redact_secrets)
  if $_CH_USE_GITHUB; then
    printf '%s' "$body" | gh issue comment "$GITHUB_ISSUE_NUMBER" \
      --repo "$REPO_FULL_NAME" --body-file - 2>/dev/null || true
  elif [[ "${ISSUE_SOURCE:-}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
    validate_jira_host
    local auth adf_flags
    auth=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
    adf_flags="--wrap-detail"
    if [[ "$JIRA_HOST" != *"atlassian.net"* ]]; then
      adf_flags="--wrap-detail --no-expand"
    fi
    local adf_body
    adf_body=$(printf '%s' "$body" | python3 "${_CH_DIR}/markdown-to-adf.py" $adf_flags)
    curl -sSf -X POST \
      -H "Authorization: Basic $auth" \
      -H "Content-Type: application/json" \
      -d "$adf_body" \
      "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}/comment" > /dev/null 2>&1 || true
  fi
}

add_label() {
  local repo="$1" number="$2" label="$3"
  gh api "repos/${repo}/issues/${number}/labels" -f "labels[]=${label}" --silent 2>/dev/null || true
}

remove_label() {
  local repo="$1" number="$2" label="$3"
  local encoded
  encoded=$(printf '%s' "$label" | jq -sRr @uri)
  gh api "repos/${repo}/issues/${number}/labels/${encoded}" -X DELETE --silent 2>/dev/null || true
}

# --- Human-facing markdown formatters (sticky comments / description headers) ---
# Full JSON stays in attachments for agents; these helpers keep Jira scannable.

# Bullet list from a JSON string array (or empty).
_format_string_array_bullets() {
  local json_array="$1"
  jq -r '
    (. // [])[]
    | select(type == "string" and length > 0)
    | "- \(.)"
  ' <<<"${json_array}" 2>/dev/null || true
}

# Data sources section — link Jira keys, GitHub repos, curated knowledge files.
format_data_sources_md() {
  local file="$1"
  local browse="${2:-}"
  [[ -f "$file" ]] || return 0
  if [[ -z "$browse" && -n "${JIRA_HOST:-}" ]]; then
    browse="https://${JIRA_HOST}/browse/"
  fi
  local knowledge_repo="${FULLSEND_KNOWLEDGE_REPO:-${GITHUB_REPOSITORY:-konflux-ci/refinement}}"
  local knowledge_ref="${FULLSEND_KNOWLEDGE_REF:-main}"
  local knowledge_base="https://github.com/${knowledge_repo}/blob/${knowledge_ref}/.fullsend/knowledge/curated"

  python3 - "$file" "$browse" "$knowledge_base" <<'PY'
import json, re, sys

path, browse, knowledge_base = sys.argv[1:4]
browse = (browse or "").rstrip("/") + "/" if browse else ""
knowledge_base = (knowledge_base or "").rstrip("/")
data = json.load(open(path))
ds = data.get("data_sources") or {}
accessed = [x for x in (ds.get("accessed") or []) if isinstance(x, str) and x.strip()]
missing = [x for x in (ds.get("not_accessed") or []) if isinstance(x, str) and x.strip()]
if not accessed and not missing:
    raise SystemExit(0)

def jira_url(key: str) -> str:
    return f"{browse}{key}" if browse else ""

def linkify(line: str) -> str:
    m = re.match(
        r"^(?P<label>Jira)\s*\(\s*(?P<key>[A-Z][A-Z0-9]+-\d+)\s*(?:[—–-]\s*(?P<note>.*))?\)\s*$",
        line,
        re.I,
    )
    if m:
        key, note = m.group("key"), (m.group("note") or "").strip()
        href = jira_url(key)
        if href:
            return f"Jira ([{key}]({href}) — {note})" if note else f"Jira ([{key}]({href}))"

    m = re.match(
        r"^(?P<label>GitHub(?:\s+API|\s+search)?)\s*\(\s*(?P<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\s*(?:[—–-]\s*(?P<note>.*))?\)\s*$",
        line,
        re.I,
    )
    if m:
        label, repo, note = m.group("label"), m.group("repo"), (m.group("note") or "").strip()
        href = f"https://github.com/{repo}"
        return f"{label} ([{repo}]({href}) — {note})" if note else f"{label} ([{repo}]({href}))"

    m = re.match(
        r"^(?P<label>Org knowledge pack)\s*\(\s*(?P<body>.+?)\s*\)\s*$",
        line,
        re.I,
    )
    if m and knowledge_base:
        label, body = m.group("label"), m.group("body")
        parts = []
        for raw in re.split(r"\s*,\s*", body):
            name = raw.strip()
            if re.fullmatch(r"[A-Za-z0-9_.-]+\.md", name):
                parts.append(f"[{name}]({knowledge_base}/{name})")
            elif name:
                parts.append(name)
        if parts:
            return f"{label} ({', '.join(parts)})"

    def repl_jira(mo):
        key = mo.group(0)
        href = jira_url(key)
        return f"[{key}]({href})" if href else key

    out = re.sub(r"\b[A-Z][A-Z0-9]+-\d+\b", repl_jira, line)

    def repl_repo(mo):
        repo = mo.group(0)
        if "..." in repo:
            return repo
        return f"[{repo}](https://github.com/{repo})"

    return re.sub(r"\b[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\b", repl_repo, out)

print("### Data Sources")
print()
if accessed:
    print("**Accessed**")
    print()
    for item in accessed:
        print(f"- {linkify(item)}")
    print()
if missing:
    print("**Not available**")
    print()
    for item in missing:
        print(f"- {linkify(item)}")
    print()
PY
}

# Join markdown sections with blank lines (survives $(...) trailing-newline strip).
join_md_sections() {
  local first=1 section
  for section in "$@"; do
    [[ -z "${section//[$' \t\r\n']/}" ]] && continue
    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      printf '\n'
    fi
    printf '%s\n' "$section"
  done
}

# Default project for children missing target_project (parent Feature project).
_default_child_project() {
  local from_ctx=""
  if [[ -f /tmp/workspace/issue-context.json ]]; then
    from_ctx=$(jq -r '.project.key // empty' /tmp/workspace/issue-context.json 2>/dev/null || true)
  fi
  if [[ -n "$from_ctx" ]]; then
    printf '%s' "$from_ctx"
  elif [[ "${ISSUE_KEY:-}" =~ ^([A-Z][A-Z0-9]+)-[0-9]+$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "KONFLUX"
  fi
}

# Related work with recoverable links (Jira keys / PR #N survive output-scan redaction).
format_related_work_md() {
  local file="$1"
  local browse="${2:-}"
  local prod_browse="${3:-https://issues.redhat.com/browse/}"
  if [[ "$browse" == *"stage-redhat.atlassian.net"* ]]; then
    prod_browse="https://redhat.atlassian.net/browse/"
  fi
  [[ -f "$file" ]] || return 0
  local count
  count=$(jq '(.related_work // []) | length' "$file" 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]] || return 0

  local repos_json
  repos_json=$(jq -c '
    [
      (.data_sources.accessed // [])[]?
      | strings
      | capture("GitHub(?: API)? \\((?<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)")
      | .repo
    ] + [
      (.related_work // [])[]?
      | select((.key // "") | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
      | .key
    ]
    | unique
  ' "$file" 2>/dev/null || echo '[]')

  echo "### Related Work (${count})"
  echo
  python3 - "$file" "$browse" "$prod_browse" "$repos_json" <<'PY'
import json, re, sys

path, browse, prod_browse, repos_json = sys.argv[1:5]
data = json.load(open(path))
repos = json.loads(repos_json)
items = data.get("related_work") or []

# Stage Cloud hosts Konflux planning keys; everything else → prod browse.
STAGE_PROJECTS = {
    "KONFLUX", "KFLUXDP", "RHDHPLAN", "AC", "DP", "HOW", "KFLUXUI",
    "RHDH", "STONEBLD", "UI", "UUID", "KFLUXSE", "KFLUXUI",
}

def jira_url(key: str) -> str:
    if not re.match(r"^[A-Z][A-Z0-9]+-\d+$", key):
        return ""
    proj = key.split("-", 1)[0]
    base = browse if (browse and proj in STAGE_PROJECTS) else prod_browse
    if not base:
        return ""
    return base.rstrip("/") + "/" + key

def pick_repo(item: dict) -> str:
    for cand in (
        item.get("repo"),
        item.get("repository"),
        item.get("key"),
    ):
        if isinstance(cand, str) and re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", cand) and "..." not in cand:
            return cand
    for prefer in ("konflux-ui", "integration-service"):
        for cand in repos:
            if prefer in cand:
                return cand
    return repos[0] if repos else ""

def pr_url(num: str, item: dict) -> str:
    repo = pick_repo(item)
    if not repo:
        return ""
    return f"https://github.com/{repo}/pull/{num}"

def blob(item: dict) -> str:
    parts = []
    for k in ("title", "summary", "description", "relevance", "state", "note", "url", "key", "id"):
        v = item.get(k)
        if isinstance(v, str) and v:
            parts.append(v)
    return "\n".join(parts)

for item in items:
    if not isinstance(item, dict):
        print(f"- {item}")
        continue
    title = item.get("title") or item.get("summary") or item.get("description") or "Related item"
    key = item.get("key") or item.get("id") or ""
    url = item.get("url") or ""
    source = item.get("source") or ""
    typ = item.get("type") or ""
    note = item.get("relevance") or item.get("state") or ""
    text = blob(item)
    href = ""
    src_blob = f"{source} {typ}".lower()
    looks_gh = any(x in src_blob for x in ("github", "pull", " pr", "pr "))
    if isinstance(url, str) and url.startswith(("http://", "https://")):
        href = url
    # Prefer PR links for GitHub-sourced items (titles often contain Jira keys).
    if not href and looks_gh:
        m = re.search(r"(?:PR|pull request)\s*#?\s*(\d+)\b", text, re.I)
        if not m:
            m = re.search(r"#(\d{2,})\b", text)
        if m:
            href = pr_url(m.group(1), item)
    if not href and isinstance(key, str) and re.match(r"^[A-Z][A-Z0-9]+-\d+$", key):
        href = jira_url(key)
    elif not href and isinstance(key, str) and re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", key) and "..." not in key:
        href = f"https://github.com/{key}"
    if not href:
        m = re.search(r"\b([A-Z][A-Z0-9]+-\d+)\b", text)
        if m:
            href = jira_url(m.group(1))
    if not href:
        m = re.search(r"(?:PR|pull request)\s*#?\s*(\d+)\b", text, re.I)
        if not m:
            m = re.search(r"#(\d{2,})\b", text)
        if m:
            href = pr_url(m.group(1), item)
    meta = []
    if typ:
        meta.append(typ)
    elif source:
        meta.append(source)
    suffix = (" · " + " ".join(meta)) if meta else ""
    note_s = f" — {note}" if note else ""
    if href:
        print(f"- [{title}]({href}){suffix}{note_s}")
    else:
        print(f"- **{title}**{suffix}{note_s}")
PY
  echo
}

# Children plan table from refine-result.json
format_children_table_md() {
  local file="$1"
  local default_project="${2:-$(_default_child_project)}"
  [[ -f "$file" ]] || return 0
  local count
  count=$(jq '(.children // []) | length' "$file" 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]] || return 0

  echo "### Plan Summary (${count} children)"
  echo
  echo "| Type | Title | Project | Parent |"
  echo "| --- | --- | --- | --- |"
  jq -r --arg def "$default_project" '
    (.children // [])[]
    | (.type // .issue_type // "item") as $type
    | ((.title // .summary // "—") | gsub("\\|"; "/")) as $title
    | (
        .target_project // .project // $def // "—"
        | if . == null or . == "" or . == "None" or . == "null" then $def else . end
      ) as $proj
    | (
        .parent_title // ""
        | gsub("\\|"; "/")
        | if . == "" then
            (if ($type | ascii_downcase) == "epic" then "(top-level)" else "—" end)
          else . end
      ) as $parent
    | "| \($type) | \($title) | \($proj) | \($parent) |"
  ' "$file"
  echo
}

# Routing rollup table from children
format_routing_table_md() {
  local file="$1"
  local default_project="${2:-$(_default_child_project)}"
  [[ -f "$file" ]] || return 0
  local count
  count=$(jq '(.children // []) | length' "$file" 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]] || return 0

  echo "### Routing"
  echo
  echo "| Project | Children | Types |"
  echo "| --- | --- | --- |"
  jq -r --arg def "$default_project" '
    (.children // [])
    | map(. + {
        _proj: (
          .target_project // .project // $def
          | if . == null or . == "" or . == "None" or . == "null" then $def else . end
        )
      })
    | group_by(._proj)
    | sort_by(.[0]._proj)
    | .[]
    | (.[0]._proj) as $proj
    | (map(.type // .issue_type // "?") | group_by(.) | map("\(.[0]) x\(length)") | join(", ")) as $types
    | "| \($proj) | \(length) | \($types) |"
  ' "$file"
  echo
}

# Critique assessment — compact bullets for numeric scores; table when notes exist.
format_assessment_table_md() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local has
  has=$(jq '(.assessment // {}) | keys | length' "$file" 2>/dev/null || echo 0)
  [[ "$has" -gt 0 ]] || return 0

  local overall has_notes
  overall=$(jq -r '.assessment.overall // empty' "$file" 2>/dev/null || true)
  has_notes=$(jq '
    [.assessment // {} | to_entries[]
      | select(.key != "overall")
      | select((.value | type) == "object")
      | select((.value.reasoning // .value.note // "") != "")
    ] | length
  ' "$file" 2>/dev/null || echo 0)

  echo "### Assessment"
  echo
  if [[ -n "$overall" ]]; then
    echo "**Overall: ${overall}/100**"
    echo
  fi

  if [[ "${has_notes:-0}" -gt 0 ]]; then
    echo "| Dimension | Score | Notes |"
    echo "| --- | --- | --- |"
    jq -r '
      (.assessment // {})
      | to_entries[]
      | select(.key != "overall")
      | if (.value | type) == "object" then
          [
            .key,
            (.value.score // "—"),
            ((.value.reasoning // .value.note // "") | gsub("\\|"; "/") | gsub("\n"; " ") | .[0:120])
          ]
        elif (.value | type) == "number" then
          [.key, .value, ""]
        else empty end
      | "| \(.[0]) | \(.[1]) | \(.[2]) |"
    ' "$file"
  else
    jq -r '
      (.assessment // {})
      | to_entries[]
      | select(.key != "overall")
      | if (.value | type) == "object" then
          "- **\(.key):** \(.value.score // "—")"
        elif (.value | type) == "number" then
          "- **\(.key):** \(.value)"
        else empty end
    ' "$file"
  fi
  echo
}

# Critique revisions as a compact table
format_revisions_table_md() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local count
  count=$(jq '(.revisions // []) | length' "$file" 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]] || return 0

  echo "### Revisions (${count})"
  echo
  # Numbered list so sticky "Previous" history keeps full revision text readable.
  jq -r '
    (.revisions // [])
    | to_entries[]
    | .key as $i
    | .value
    | if type == "object" then
        ((.target // .type // "item") | tostring) as $t
        | ((.suggestion // .reasoning // .text // .description // "—") | tostring | gsub("\n"; " ")) as $ask
        | "\($i + 1). **\($t)** — \($ask)"
      else
        "\($i + 1). \(tostring | gsub("\n"; " "))"
      end
  ' "$file"
  echo
}

# Strip unhidden plan/routing tables from proposed_description (sticky comment owns those).
sanitize_proposed_description_md() {
  printf '%s' "$1" | python3 -c '
import re, sys
text = sys.stdin.read()
# Drop agent HTML details markers; converter also does this, but strip early for clarity.
text = re.sub(
    r"<details>\s*<summary>\s*Detailed Specification\s*</summary>\s*",
    "\n\n## Detailed Specification\n\n",
    text,
    flags=re.I,
)
text = re.sub(r"</?details\s*>", "\n\n", text, flags=re.I)
text = re.sub(r"<summary>\s*([^<]*?)\s*</summary>", r"\n\n## \1\n\n", text, flags=re.I)

# Remove leading/standalone Plan Summary or Routing sections outside Detailed Spec.
parts = re.split(r"(?im)^#{1,3}\s+Detailed Specification\s*$", text, maxsplit=1)
head = parts[0]
detail = parts[1] if len(parts) > 1 else ""

def strip_plan_blocks(md: str) -> str:
    md = re.sub(
        r"(?ims)^#{1,3}\s+Plan Summary(?:\s*\([^)]*\))?\s*\n+(?:\|.*\n)+",
        "",
        md,
    )
    md = re.sub(
        r"(?ims)^#{1,3}\s+Proposed children[^\n]*\n+(?:\|.*\n)*",
        "",
        md,
    )
    md = re.sub(
        r"(?ims)^#{1,3}\s+Routing\s*\n+(?:\|.*\n)+",
        "",
        md,
    )
    return md

head = strip_plan_blocks(head)
if detail:
    # Plan tables inside Detailed Spec are OK (collapsed by --wrap-detail).
    text = head.rstrip() + "\n\n## Detailed Specification\n\n" + detail.lstrip()
else:
    text = head
text = re.sub(r"\n{3,}", "\n\n", text).strip()
print(text)
'
}

# One short paragraph from a long agent comment (first non-heading paragraph).
format_brief_blurb_md() {
  local text="$1"
  local max_chars="${2:-400}"
  [[ -n "$text" ]] || return 0
  python3 -c '
import re, sys
text = sys.stdin.read().strip()
if not text:
    sys.exit(0)
# Drop markdown headings / tables for the blurb
lines = []
for line in text.splitlines():
    s = line.strip()
    if not s or s.startswith("#") or s.startswith("|") or s.startswith(">"):
        if lines:
            break
        continue
    lines.append(s)
    if len(" ".join(lines)) >= int(sys.argv[1]):
        break
blurb = " ".join(lines)
blurb = re.sub(r"\s+", " ", blurb).strip()
if len(blurb) > int(sys.argv[1]):
    blurb = blurb[: int(sys.argv[1])].rsplit(" ", 1)[0] + "…"
print(blurb)
' "$max_chars" <<<"$text"
}
