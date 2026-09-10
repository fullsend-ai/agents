#!/usr/bin/env bash
# GENERATED from post-scribe.src.sh — DO NOT EDIT. Run: make script-build
# post-scribe.sh — Parse scribe agent JSON output, apply security gate,
# and write to the repository (comments on existing issues, new issues).
#
# Runs on the host after sandbox cleanup.
#
# Required env vars:
#   SCRIBE_REPO    — target repository (owner/name or group/project)
#   FULLSEND_FORGE — "github" or "gitlab"
#   SCRIBE_DRY_RUN — "true" to preview without writing (ALWAYS true during dev)
#
# Forge-specific token env vars:
#   GH_TOKEN       — GitHub token (when FULLSEND_FORGE=github)
#   GITLAB_TOKEN   — GitLab token (when FULLSEND_FORGE=gitlab)
#
# Optional env vars:
#   SCRIBE_MODE              — "all" (default), "comments_only", "new_issues_only"
#   SCRIBE_SLACK_WEBHOOK_URL — Slack incoming webhook for notification (skip if unset)
#
# SAFETY: This script REFUSES to run if SCRIBE_DRY_RUN is not explicitly set.
# This prevents accidental writes during development.

set -euo pipefail

: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scribe-ops.lib.sh
# BEGIN bundled: lib/scribe-ops.lib.sh
# shellcheck shell=bash
# scribe-ops.lib.sh — Forge-dispatch wrapper for scribe operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
SCRIBE_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

case "${FULLSEND_FORGE:-}" in
  github)
# BEGIN bundled: lib/github-scribe-ops.lib.sh
# shellcheck shell=bash
# github-scribe-ops.lib.sh — GitHub forge operations for scribe scripts.
#
# Bundled into pre-scribe.sh and post-scribe.sh via scribe-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected env vars:
#   SCRIBE_REPO  — GitHub repository (owner/name)
#   GH_TOKEN     — GitHub token with issues read/write scope

[[ -n "${GITHUB_SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_SCRIBE_OPS_SH_LOADED=1

# --- Pre-script: repo context ---

# Fetch all open items from the issues endpoint (paginated). GitHub's REST
# /issues endpoint includes pull requests — callers filter them out.
forge_fetch_open_issues_raw() {
  local repo="$1" output_file="$2"
  gh api --paginate "repos/${repo}/issues?state=open&per_page=100" \
    > "${output_file}"
}

# Filter raw issues response into the backlog format: remove PRs, extract
# fields, truncate bodies to 500 chars.
forge_filter_issues_to_backlog() {
  local raw_file="$1" backlog_file="$2"
  jq -s '[.[][] | select(.pull_request == null) | {number, title, body, labels, milestone, url: .html_url}]' "${raw_file}" \
    | jq '[.[] | .body = ((.body // "")[:500] + if ((.body // "") | length) > 500 then "…" else "" end)]' \
    > "${backlog_file}"
}

# Count total paginated items (issues + PRs on GitHub).
forge_count_paginated_total() {
  local raw_file="$1"
  jq -s '[.[][]] | length' "${raw_file}"
}

# Fetch recently closed issues.
forge_list_closed_issues() {
  local repo="$1" output_file="$2" limit="$3"
  gh issue list --repo "${repo}" --state closed \
    --json number,title,labels,url --limit "${limit}" \
    > "${output_file}"
}

# Fetch open pull requests. Normalizes output to include headRefName.
forge_list_open_prs() {
  local repo="$1" output_file="$2" limit="$3" token="$4"
  GH_TOKEN="${token}" gh pr list --repo "${repo}" --state open \
    --json number,title,labels,url,headRefName --limit "${limit}" \
    > "${output_file}"
}

# Get repo-level open_issues_count (includes PRs on GitHub) for truncation
# detection. Returns empty string on failure so callers can fall back.
forge_get_issue_count() {
  local repo="$1"
  gh api "repos/${repo}" --jq '.open_issues_count' 2>/dev/null || echo ""
}

# Fetch the repo's doc tree (markdown files under docs/).
forge_get_repo_tree() {
  local repo="$1" token="$2" output_file="$3"
  GH_TOKEN="${token}" gh api "repos/${repo}/git/trees/main?recursive=1" \
    --jq '[.tree[] | select(.path | startswith("docs/") and (.path | endswith(".md"))) | .path]' \
    > "${output_file}" 2>/dev/null || echo '[]' > "${output_file}"
}

# --- Post-script: issue/comment operations ---

# Fetch all comments on an issue (paginated). Returns a flat JSON array.
forge_list_issue_comments() {
  local repo="$1" issue_num="$2"
  gh api --paginate "repos/${repo}/issues/${issue_num}/comments" 2>/dev/null \
    | jq -s '[.[][] | {body}]'
}

# Post a comment on an issue. Body is read from stdin.
forge_post_issue_comment() {
  local repo="$1" issue_num="$2"
  gh issue comment "${issue_num}" --repo "${repo}" --body-file -
}

# Create a new issue with labels. Body is read from stdin. Returns the
# issue URL. Falls back to label-less creation if labels don't exist.
forge_create_issue() {
  local repo="$1" title="$2" labels="$3"
  local url body_file
  body_file=$(mktemp)
  cat > "${body_file}"
  url=$(gh issue create --repo "${repo}" --title "${title}" \
    --label "${labels}" --body-file "${body_file}" 2>/dev/null) || \
  url=$(gh issue create --repo "${repo}" --title "${title}" --body-file "${body_file}")
  rm -f "${body_file}"
  if [[ -z "${url}" ]]; then
    echo "ERROR: forge_create_issue: failed to create issue or missing URL in response" >&2
    return 1
  fi
  echo "${url}"
}

# Return the base URL for linking to issues.
forge_issue_url_base() {
  local repo="$1"
  echo "https://github.com/${repo}/issues"
}

# Return the CI run URL for notifications.
forge_run_url() {
  echo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-${1}}/actions/runs/${GITHUB_RUN_ID:-0}"
}
# END bundled: lib/github-scribe-ops.lib.sh
    ;;
  gitlab)
# BEGIN bundled: lib/gitlab-scribe-ops.lib.sh
# shellcheck shell=bash
# gitlab-scribe-ops.lib.sh — GitLab forge operations for scribe scripts.
#
# Bundled into pre-scribe.sh and post-scribe.sh via scribe-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected env vars:
#   SCRIBE_REPO    — GitLab project path (group/project)
#   GITLAB_TOKEN   — GitLab personal/project access token
#   CI_SERVER_HOST — GitLab CI predefined variable (set by runner)

[[ -n "${GITLAB_SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_SCRIBE_OPS_SH_LOADED=1

# shellcheck source=gitlab-host-validation.lib.sh
# BEGIN bundled: lib/gitlab-host-validation.lib.sh
# shellcheck shell=bash
# gitlab-host-validation.lib.sh — Shared host validation for GitLab ops.
#
# Validates a hostname against CI_SERVER_HOST, a GitLab CI predefined
# variable set automatically by the runner.
#
# Fails closed: rejects when CI_SERVER_HOST is not set.
#
# Sourced by all gitlab-*-ops.lib.sh files and inlined by the bundler.

[[ -n "${GITLAB_HOST_VALIDATION_SH_LOADED:-}" ]] && return 0
GITLAB_HOST_VALIDATION_SH_LOADED=1

if ! declare -F _gha_sanitize >/dev/null 2>&1; then
  _gha_sanitize() {
    printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'
  }
fi

_validate_gitlab_host() {
  local host="$1"
  if [[ -z "${CI_SERVER_HOST:-}" ]]; then
    echo "ERROR: CI_SERVER_HOST is not set (set by GitLab CI runner)" >&2
    return 1
  fi
  if [[ ! "${CI_SERVER_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: CI_SERVER_HOST contains invalid characters" >&2
    return 1
  fi
  if [[ "${host,,}" != "${CI_SERVER_HOST,,}" ]]; then
    echo "ERROR: GitLab host '$(_gha_sanitize "${host}")' does not match CI_SERVER_HOST" >&2
    return 1
  fi
}
# END bundled: lib/gitlab-host-validation.lib.sh

_gitlab_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  # Scribe has no input URL to cross-reference — validates CI_SERVER_HOST format only.
  _validate_gitlab_host "${CI_SERVER_HOST:-}" || return 1
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "https://${CI_SERVER_HOST}/api/v4${endpoint}" \
    "$@"
}

# Paginate a GitLab GET endpoint, collecting all pages into a single JSON
# array written to the given output file. Uses page-counter increment.
_gitlab_paginate() {
  local endpoint="$1" output_file="$2"
  local page=1 max_pages=100
  local tmp_file
  tmp_file=$(mktemp)
  echo '[]' > "${output_file}"
  while [[ "${page}" -le "${max_pages}" ]]; do
    local sep="?"
    [[ "${endpoint}" == *"?"* ]] && sep="&"
    local batch
    batch=$(_gitlab_api GET "${endpoint}${sep}per_page=100&page=${page}") || { echo "WARNING: _gitlab_paginate: API call failed on page ${page}" >&2; break; }
    local count
    count=$(echo "${batch}" | jq 'length') || break
    [[ "${count}" -eq 0 ]] && break
    jq -s 'add' "${output_file}" <(echo "${batch}") > "${tmp_file}"
    mv "${tmp_file}" "${output_file}"
    page=$((page + 1))
  done
  rm -f "${tmp_file}"
}

# --- Pre-script: repo context ---

# Fetch all open issues (paginated). GitLab's /issues endpoint does NOT
# include merge requests — no PR filtering needed. Output is saved as a
# flat JSON array matching the GitHub raw format for downstream processing.
forge_fetch_open_issues_raw() {
  local repo="$1" output_file="$2"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_paginate "/projects/${repo_encoded}/issues?state=opened&order_by=created_at&sort=desc" "${output_file}"
}

# Filter/normalize raw issues into the backlog format. GitLab fields are
# normalized to match the GitHub output schema: iid→number,
# description→body, web_url→url, labels (strings)→label objects.
forge_filter_issues_to_backlog() {
  local raw_file="$1" backlog_file="$2"
  jq '[.[] | {
    number: .iid,
    title,
    body: (.description // ""),
    labels: [.labels[]? | {name: .}],
    milestone,
    url: .web_url
  } | .body = ((.body // "")[:500] + if ((.body // "") | length) > 500 then "…" else "" end)]' \
    "${raw_file}" > "${backlog_file}"
}

# Count total paginated items. On GitLab, the issues endpoint only returns
# issues (no MRs), so this equals the issue count.
forge_count_paginated_total() {
  local raw_file="$1"
  jq 'length' "${raw_file}"
}

# Fetch recently closed issues, normalized to common schema.
forge_list_closed_issues() {
  local repo="$1" output_file="$2" limit="$3"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_api GET "/projects/${repo_encoded}/issues?state=closed&order_by=updated_at&sort=desc&per_page=${limit}" 2>/dev/null \
    | jq '[.[] | {
        number: .iid,
        title,
        labels: [.labels[]? | {name: .}],
        url: .web_url
      }]' > "${output_file}" || echo '[]' > "${output_file}"
}

# Fetch open merge requests, normalized to match the PR schema. The
# source_branch field is mapped to headRefName for forge-neutral agent use.
forge_list_open_prs() {
  local repo="$1" output_file="$2" limit="$3" _token="$4"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_api GET "/projects/${repo_encoded}/merge_requests?state=opened&per_page=${limit}" 2>/dev/null \
    | jq '[.[] | {
        number: .iid,
        title,
        labels: [.labels[]? | {name: .}],
        url: .web_url,
        headRefName: .source_branch
      }]' > "${output_file}" || echo '[]' > "${output_file}"
}

# Get the project's open_issues_count (issues only on GitLab, no MRs).
forge_get_issue_count() {
  local repo="$1"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_api GET "/projects/${repo_encoded}" 2>/dev/null \
    | jq '.open_issues_count // empty' 2>/dev/null || echo ""
}

# Fetch the repo's doc tree (markdown files under docs/).
forge_get_repo_tree() {
  local repo="$1" _token="$2" output_file="$3"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  local tmp_file
  tmp_file=$(mktemp)
  _gitlab_paginate "/projects/${repo_encoded}/repository/tree?recursive=true&ref=main" "${tmp_file}"
  jq '[.[] | select(.path | startswith("docs/") and (.path | endswith(".md"))) | .path]' \
    "${tmp_file}" > "${output_file}" 2>/dev/null || echo '[]' > "${output_file}"
  rm -f "${tmp_file}"
}

# --- Post-script: issue/comment operations ---

# Fetch all notes (comments) on an issue. Returns a flat JSON array
# with field projection to match the GitHub comments shape.
forge_list_issue_comments() {
  local repo="$1" issue_num="$2"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  local tmp_file
  tmp_file=$(mktemp)
  trap 'rm -f "${tmp_file}"' RETURN
  _gitlab_paginate "/projects/${repo_encoded}/issues/${issue_num}/notes?sort=asc" "${tmp_file}"
  jq '[.[] | select(.system != true) | {body}]' "${tmp_file}"
}

# Post a note (comment) on an issue. Body is read from stdin.
forge_post_issue_comment() {
  local repo="$1" issue_num="$2"
  local repo_encoded body_file rc=0
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  body_file=$(mktemp)
  cat > "${body_file}"
  _gitlab_api POST "/projects/${repo_encoded}/issues/${issue_num}/notes" \
    --data-urlencode "body@${body_file}" > /dev/null || rc=$?
  rm -f "${body_file}"
  return "${rc}"
}

# Create a new issue with labels. Body is read from stdin. Returns the
# issue web URL.
forge_create_issue() {
  local repo="$1" title="$2" labels="$3"
  local repo_encoded body_file
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  body_file=$(mktemp)
  cat > "${body_file}"
  local response
  response=$(_gitlab_api POST "/projects/${repo_encoded}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "labels=${labels}" \
    --data-urlencode "description@${body_file}" 2>/dev/null) || \
  response=$(_gitlab_api POST "/projects/${repo_encoded}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description@${body_file}")
  rm -f "${body_file}"
  local url
  url=$(echo "${response}" | jq -r '.web_url // empty')
  if [[ -z "${url}" ]]; then
    echo "ERROR: forge_create_issue: failed to create issue or missing web_url in response" >&2
    return 1
  fi
  echo "${url}"
}

# Return the base URL for linking to issues.
forge_issue_url_base() {
  local repo="$1"
  _validate_gitlab_host "${CI_SERVER_HOST:-}" || return 1
  echo "https://${CI_SERVER_HOST}/${repo}/-/issues"
}

# Return the CI run/job URL for notifications.
forge_run_url() {
  if [[ -n "${CI_JOB_URL:-}" ]]; then
    echo "${CI_JOB_URL}"
  else
    _validate_gitlab_host "${CI_SERVER_HOST:-}" || return 1
    echo "https://${CI_SERVER_HOST}/${1}"
  fi
}
# END bundled: lib/gitlab-scribe-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '$(_gha_sanitize "${FULLSEND_FORGE:-}")' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
# END bundled: lib/scribe-ops.lib.sh

if [[ -n "${GH_TOKEN:-}" ]]; then
  echo "::add-mask::${GH_TOKEN}"
fi
if [[ -n "${GITLAB_TOKEN:-}" ]]; then
  echo "::add-mask::${GITLAB_TOKEN}"
fi

# ============================================================
# HARD SAFETY GATE — refuse to write if dry-run is not set
# ============================================================
if [[ -z "${SCRIBE_DRY_RUN:-}" ]]; then
  echo "ERROR: SCRIBE_DRY_RUN is not set. Refusing to run."
  echo "Set SCRIBE_DRY_RUN=true for preview or SCRIBE_DRY_RUN=false for live writes."
  exit 1
fi

DRY_RUN="true"
if [[ "${SCRIBE_DRY_RUN}" == "false" ]]; then
  DRY_RUN="false"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "::notice::DRY RUN — no repository writes will be performed"
fi

WOULD_BE=""
[[ "${DRY_RUN}" == "true" ]] && WOULD_BE="would be "

# ============================================================
# Mode: comments_only, new_issues_only, or all (default)
# ============================================================
SCRIBE_MODE="${SCRIBE_MODE:-all}"
case "${SCRIBE_MODE}" in
  all|comments_only|new_issues_only) ;;
  *)
    echo "ERROR: SCRIBE_MODE must be 'all', 'comments_only', or 'new_issues_only' (got: ${SCRIBE_MODE})"
    exit 1
    ;;
esac
echo "Mode: ${SCRIBE_MODE}"

# Find the agent result JSON — prefer the validated iteration when set.
# Trust boundary: FULLSEND_VALIDATED_ITERATION_DIR is set by the fullsend CLI
# on the runner — not by the sandbox or the agent. No containment check
# (realpath / prefix guard) is applied here; the value is trusted from the
# external harness. If the trust model changes, add a realpath prefix check.
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  if [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
  elif [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/result.json" ]]; then
    # Agents sometimes write "result.json" instead of "agent-result.json";
    # validate-output-schema.sh accepts that filename as a fallback without
    # renaming it (scribe.yaml uses the default agent-result.json filename,
    # so this fallback is reachable in practice).
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

echo "Reading scribe result from: ${RESULT_FILE}"

if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

# ============================================================
# Security gate — deterministic checks on every topic
# ============================================================

MIN_CONFIDENCE="${SCRIBE_MIN_CONFIDENCE:-0.6}"
MAX_COMMENT_LEN=2000
MAX_BODY_LEN=15000
MAX_TITLE_LEN=200

is_valid_confidence() {
  [[ "${1}" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

if ! is_valid_confidence "${MIN_CONFIDENCE}"; then
  echo "ERROR: SCRIBE_MIN_CONFIDENCE must be a number between 0.0 and 1.0 (got: ${MIN_CONFIDENCE})"
  exit 1
fi
if (( $(echo "${MIN_CONFIDENCE} < 0 || ${MIN_CONFIDENCE} > 1" | bc -l) )); then
  echo "ERROR: SCRIBE_MIN_CONFIDENCE must be between 0.0 and 1.0 (got: ${MIN_CONFIDENCE})"
  exit 1
fi
echo "Confidence threshold: ${MIN_CONFIDENCE}"
REJECTED=0

contains_sensitive() {
  local text="$1"
  # GitHub PATs, AWS access keys, private keys
  echo "${text}" \
    | grep -qEi '(ghp|gho|ghs|ghr)_[A-Za-z0-9_]{36,}|\b(AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b|-----BEGIN.*(PRIVATE KEY)' \
    && return 0
  # Email addresses
  echo "${text}" \
    | grep -qE '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b' \
    && return 0
  # SSN
  echo "${text}" \
    | grep -qE '\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b' \
    && return 0
  # Slack webhooks
  echo "${text}" \
    | grep -qE 'https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+' \
    && return 0
  # JWTs
  echo "${text}" \
    | grep -qE '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b' \
    && return 0
  # Generic key=value secrets
  echo "${text}" \
    | grep -qEi '(api[_-]?key|token|secret|password|bearer)[[:space:]]*[:=][[:space:]]*['"'"'"]?[A-Za-z0-9_.~+/-]{20,}' \
    && return 0
  return 1
}

contains_suspicious_unicode() {
  local text="$1"
  # Tag characters (U+E0000–E007F), zero-width chars, BOM, bidi overrides/isolates
  echo "${text}" \
    | perl -e 'binmode(STDIN, q(:encoding(UTF-8))); while (<STDIN>) { if (/[\x{E0000}-\x{E007F}\x{200B}\x{200C}\x{200D}\x{FEFF}\x{202A}-\x{202E}\x{2066}-\x{2069}]/) { exit 0 } } exit 1' \
    && return 0
  return 1
}

# Escape Slack mrkdwn metacharacters in link labels.
sanitize_slack_mrkdwn() {
  local val="$1"
  val="${val//&/&amp;}"
  val="${val//</&lt;}"
  val="${val//>/&gt;}"
  val="${val//|/¦}"
  printf '%s' "${val}"
}

CONTENT_GATE_REJECTIONS=0

gate_reject() {
  local topic="$1" reason="$2"
  topic=$(_gha_sanitize "${topic}")
  reason=$(_gha_sanitize "${reason}")
  echo "  GATE REJECTED: [${topic}] — ${reason}"
  REJECTED=$((REJECTED + 1))
}

gate_reject_content() {
  local index="$1" total="$2" category="$3"
  category=$(_gha_sanitize "${category}")
  echo "  GATE REJECTED: item ${index} of ${total} — content gate: ${category}"
  REJECTED=$((REJECTED + 1))
  CONTENT_GATE_REJECTIONS=$((CONTENT_GATE_REJECTIONS + 1))
}

# ============================================================
# Dedup: merge topics referencing the same existing issue
# ============================================================
# If the LLM produces multiple entries for the same issue despite being asked
# not to, merge them: combine summaries, keep the highest confidence, keep
# public_safe=false if any entry is unsafe.
DEDUP_FILE="${RESULT_FILE}.deduped"
jq --argjson max_len "${MAX_COMMENT_LEN}" '
  .topics as $all |
  ($all | map(select(.existing_issue != null)) | group_by(.existing_issue) |
    map(
      if length == 1 then .[0]
      else
        reduce .[1:][] as $t (.[0];
          .summary = ((.summary // "") + (if (.summary // "") != "" and ($t.summary // "") != "" then "\n\n" else "" end) + ($t.summary // "")) |
          .confidence = ([.confidence, $t.confidence] | max) |
          if $t.public_safe == false then .public_safe = false | .public_safe_category = $t.public_safe_category else . end
        )
      end
      | if ((.summary // "") | length) > $max_len then
          .summary = ((.summary // "")[0:($max_len - 16)] + "\n\n_(truncated)_")
        else . end
    )
  ) as $merged |
  ($all | map(select(.existing_issue == null))) as $rest |
  . + {topics: ($merged + $rest)}
' "${RESULT_FILE}" > "${DEDUP_FILE}"

ORIG_COUNT=$(jq '.topics | length' "${RESULT_FILE}")
DEDUP_COUNT=$(jq '.topics | length' "${DEDUP_FILE}")
if [[ "${ORIG_COUNT}" -ne "${DEDUP_COUNT}" ]]; then
  echo "Dedup: merged ${ORIG_COUNT} → ${DEDUP_COUNT} topics ($(( ORIG_COUNT - DEDUP_COUNT )) duplicates)"
  RESULT_FILE="${DEDUP_FILE}"
else
  rm -f "${DEDUP_FILE}"
fi

# Tracking arrays for step summary (parallel indexed lists)
COMMENT_TOPICS=()
COMMENT_ISSUES=()
NEW_ISSUE_TITLES=()
NEW_ISSUE_URLS=()
SKIPPED_NEW_ISSUES=0

# ============================================================
# Process comment topics (existing issues)
# ============================================================
TOPIC_COUNT=$(jq '.topics | length' "${RESULT_FILE}")

if [[ "${SCRIBE_MODE}" == "new_issues_only" ]]; then
  echo "Skipping ${TOPIC_COUNT} comment topics (mode: new_issues_only)"
  TOPIC_COUNT=0
else
  echo "Processing ${TOPIC_COUNT} topics for existing issues..."
fi

for i in $(seq 0 $((TOPIC_COUNT - 1))); do
  # Read public_safe FIRST — if false, we must not log topic title or content
  PUBLIC_SAFE=$(jq -r ".topics[${i}].public_safe" "${RESULT_FILE}")
  PUBLIC_SAFE_CAT=$(jq -r ".topics[${i}].public_safe_category // empty" "${RESULT_FILE}")

  if [[ "${PUBLIC_SAFE}" == "false" ]]; then
    if [[ -z "${PUBLIC_SAFE_CAT}" || "${PUBLIC_SAFE_CAT}" == "null" ]]; then
      PUBLIC_SAFE_CAT="unspecified"
    fi
    gate_reject_content "$((i + 1))" "${TOPIC_COUNT}" "${PUBLIC_SAFE_CAT}"
    continue
  fi

  TOPIC=$(jq -r ".topics[${i}].topic" "${RESULT_FILE}")
  SUMMARY=$(jq -r ".topics[${i}].summary" "${RESULT_FILE}")
  CONFIDENCE=$(jq -r ".topics[${i}].confidence" "${RESULT_FILE}")
  ISSUE_NUM=$(jq -r ".topics[${i}].existing_issue // empty" "${RESULT_FILE}")
  OMIT=$(jq -r ".topics[${i}].omit_reason // empty" "${RESULT_FILE}")

  if [[ -n "${OMIT}" ]]; then
    echo "  OMITTED: [$(_gha_sanitize "${TOPIC}")] — $(_gha_sanitize "${OMIT}")"
    continue
  fi

  if [[ -z "${ISSUE_NUM}" || "${ISSUE_NUM}" == "null" ]]; then
    continue
  fi

  if [[ ! "${ISSUE_NUM}" =~ ^[1-9][0-9]*$ ]]; then
    gate_reject "${TOPIC}" "invalid existing_issue number"
    continue
  fi

  if [[ -z "${SUMMARY}" || "${SUMMARY}" == "null" ]]; then
    gate_reject "${TOPIC}" "missing or null summary for existing issue comment"
    continue
  fi

  # Gate: confidence
  if ! is_valid_confidence "${CONFIDENCE}"; then
    gate_reject "${TOPIC}" "invalid confidence value"
    continue
  fi
  if (( $(echo "${CONFIDENCE} < ${MIN_CONFIDENCE}" | bc -l) )); then
    gate_reject "${TOPIC}" "confidence ${CONFIDENCE} below threshold ${MIN_CONFIDENCE}"
    continue
  fi

  # Gate: sensitive content (deterministic PII/secret patterns)
  if contains_sensitive "${SUMMARY}" || contains_sensitive "${TOPIC}"; then
    gate_reject "${TOPIC}" "contains sensitive content (PII, secrets)"
    continue
  fi

  # Gate: suspicious Unicode (prompt injection defense)
  if contains_suspicious_unicode "${SUMMARY}" || contains_suspicious_unicode "${TOPIC}"; then
    gate_reject "${TOPIC}" "contains suspicious Unicode (potential prompt injection)"
    continue
  fi

  # Gate: length
  SUMMARY_LEN=${#SUMMARY}
  if [[ ${SUMMARY_LEN} -gt ${MAX_COMMENT_LEN} ]]; then
    gate_reject "${TOPIC}" "summary length ${SUMMARY_LEN} exceeds max ${MAX_COMMENT_LEN}"
    continue
  fi

  # Gate: code blocks in comments
  if echo "${SUMMARY}" | grep -q '```'; then
    gate_reject "${TOPIC}" "comment contains code block (unexpected in meeting summary)"
    continue
  fi

  SAFE_TOPIC=$(_gha_sanitize "${TOPIC}")
  SAFE_CONFIDENCE=$(_gha_sanitize "${CONFIDENCE}")
  echo "  PASS: [${SAFE_TOPIC}] → comment on #${ISSUE_NUM} (confidence: ${SAFE_CONFIDENCE})"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY RUN] Would post comment to ${SCRIBE_REPO}#${ISSUE_NUM}"
    COMMENT_TOPICS+=("${SAFE_TOPIC}")
    COMMENT_ISSUES+=("${ISSUE_NUM}")
  else
    # Idempotency: prefer notes URL; fall back to issue + topic + meeting date
    NOTES_URL=$(printf '%s' "${SUMMARY}" | grep -oP '\[Meeting notes\]\(\K[^)]+' || echo "")
    MEETING_DATE=$(printf '%s' "${SUMMARY}" | grep -oP '(?<=\*\*Meeting update — ).*?(?=\*\*)' || echo "")
    EXISTING=0
    COMMENTS_JSON=$(forge_list_issue_comments "${SCRIBE_REPO}" "${ISSUE_NUM}")
    if [[ -n "${NOTES_URL}" ]]; then
      EXISTING=$(echo "${COMMENTS_JSON}" \
        | jq --arg url "${NOTES_URL}" '[.[] | select(.body | contains($url))] | length' \
        2>/dev/null || echo "0")
    elif [[ -n "${MEETING_DATE}" ]]; then
      EXISTING=$(echo "${COMMENTS_JSON}" \
        | jq --arg date "${MEETING_DATE}" --arg topic "${TOPIC}" \
          '[.[] | select(.body | contains("**Meeting update — " + $date + "**") and contains($topic))] | length' \
          2>/dev/null || echo "0")
    fi
    if [[ "${EXISTING}" -gt 0 ]]; then
      echo "    SKIP: duplicate comment (already posted for this meeting/issue)"
      continue
    fi

    printf '%s' "${SUMMARY}" | forge_post_issue_comment "${SCRIBE_REPO}" "${ISSUE_NUM}"
    COMMENT_TOPICS+=("${SAFE_TOPIC}")
    COMMENT_ISSUES+=("${ISSUE_NUM}")
  fi
done

# ============================================================
# Process new issues
# ============================================================
NEW_COUNT=$(jq '.new_issues | length' "${RESULT_FILE}")

if [[ "${SCRIBE_MODE}" == "comments_only" ]]; then
  echo "Skipping ${NEW_COUNT} new issue proposals (mode: comments_only)"
  SKIPPED_NEW_ISSUES=${NEW_COUNT}
  NEW_COUNT=0
else
  echo "Processing ${NEW_COUNT} new issue proposals..."
fi

for i in $(seq 0 $((NEW_COUNT - 1))); do
  # Read public_safe FIRST — if false, suppress all content from logs
  PUBLIC_SAFE=$(jq -r ".new_issues[${i}].public_safe" "${RESULT_FILE}")
  PUBLIC_SAFE_CAT=$(jq -r ".new_issues[${i}].public_safe_category // empty" "${RESULT_FILE}")

  if [[ "${PUBLIC_SAFE}" == "false" ]]; then
    if [[ -z "${PUBLIC_SAFE_CAT}" || "${PUBLIC_SAFE_CAT}" == "null" ]]; then
      PUBLIC_SAFE_CAT="unspecified"
    fi
    gate_reject_content "$((i + 1))" "${NEW_COUNT}" "${PUBLIC_SAFE_CAT}"
    continue
  fi

  TITLE=$(jq -r ".new_issues[${i}].title" "${RESULT_FILE}")
  BODY=$(jq -r ".new_issues[${i}].body" "${RESULT_FILE}")
  CONFIDENCE=$(jq -r ".new_issues[${i}].confidence" "${RESULT_FILE}")
  LABELS=$(jq -r ".new_issues[${i}].labels // [\"meeting-notes\"] | join(\",\")" "${RESULT_FILE}")

  # Gate: confidence
  if ! is_valid_confidence "${CONFIDENCE}"; then
    gate_reject "${TITLE}" "invalid confidence value"
    continue
  fi
  if (( $(echo "${CONFIDENCE} < ${MIN_CONFIDENCE}" | bc -l) )); then
    gate_reject "${TITLE}" "confidence ${CONFIDENCE} below threshold ${MIN_CONFIDENCE}"
    continue
  fi

  # Gate: sensitive content (deterministic PII/secret patterns)
  if contains_sensitive "${TITLE}" || contains_sensitive "${BODY}"; then
    gate_reject "${TITLE}" "contains sensitive content"
    continue
  fi

  # Gate: suspicious Unicode (prompt injection defense)
  if contains_suspicious_unicode "${TITLE}" || contains_suspicious_unicode "${BODY}"; then
    gate_reject "${TITLE}" "contains suspicious Unicode (potential prompt injection)"
    continue
  fi

  # Gate: lengths
  TITLE_LEN=${#TITLE}
  BODY_LEN=${#BODY}
  if [[ ${TITLE_LEN} -gt ${MAX_TITLE_LEN} ]]; then
    gate_reject "${TITLE}" "title length ${TITLE_LEN} exceeds max ${MAX_TITLE_LEN}"
    continue
  fi
  if [[ ${BODY_LEN} -gt ${MAX_BODY_LEN} ]]; then
    gate_reject "${TITLE}" "body length ${BODY_LEN} exceeds max ${MAX_BODY_LEN}"
    continue
  fi

  # Gate: code blocks in issue bodies
  if echo "${BODY}" | grep -q '```'; then
    gate_reject "${TITLE}" "issue body contains code block (unexpected in meeting summary)"
    continue
  fi

  SAFE_TITLE=$(_gha_sanitize "${TITLE}")
  SAFE_CONFIDENCE=$(_gha_sanitize "${CONFIDENCE}")
  echo "  PASS: [${SAFE_TITLE}] → new issue (confidence: ${SAFE_CONFIDENCE})"
  NEW_ISSUE_TITLES+=("${SAFE_TITLE}")

  # Prepend auto-generated banner so reviewers know this was machine-created
  BANNER='> [!NOTE]
> This issue was automatically generated from meeting notes by the scribe agent.
> Please review, edit, and add any missing context before prioritizing.

'
  FULL_BODY="${BANNER}${BODY}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY RUN] Would create issue: ${SAFE_TITLE}"
    echo "    [DRY RUN] Labels: $(_gha_sanitize "${LABELS}")"
    echo "    [DRY RUN] Body length: ${BODY_LEN} chars"
    NEW_ISSUE_URLS+=("")
  else
    ISSUE_URL=$(printf '%s' "${FULL_BODY}" | forge_create_issue "${SCRIBE_REPO}" "${TITLE}" "${LABELS}")
    echo "    Created: ${ISSUE_URL}"
    NEW_ISSUE_URLS+=("${ISSUE_URL}")
  fi
done

# ============================================================
# Summary (console)
# ============================================================
RUN_MODE_LABEL="LIVE"
[[ "${DRY_RUN}" == "true" ]] && RUN_MODE_LABEL="DRY RUN"

echo ""
echo "=== Scribe Post-Script Summary ==="
echo "  Run mode: ${RUN_MODE_LABEL}"
echo "  Agent mode: ${SCRIBE_MODE}"
echo "  Topics processed: ${TOPIC_COUNT}"
echo "  Comments ${WOULD_BE}posted: ${#COMMENT_TOPICS[@]}"
echo "  New issues ${WOULD_BE}created: ${#NEW_ISSUE_TITLES[@]}"
echo "  Gate rejections: ${REJECTED}"
echo "    Content gate: ${CONTENT_GATE_REJECTIONS}"
echo "  New proposals reviewed: ${NEW_COUNT}"
[[ "${SKIPPED_NEW_ISSUES}" -gt 0 ]] && echo "  Skipped new issues (mode): ${SKIPPED_NEW_ISSUES}"
echo "=================================="

# ============================================================
# Step summary — markdown report for CI job page
# ============================================================
ISSUE_BASE=$(forge_issue_url_base "${SCRIBE_REPO}")
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
{
  echo "### Scribe agent report (${RUN_MODE_LABEL})"
  echo ""
  echo "| Metric | Count |"
  echo "|--------|------:|"
  echo "| Topics processed | ${TOPIC_COUNT} |"
  echo "| Comments ${WOULD_BE}posted | ${#COMMENT_TOPICS[@]} |"
  echo "| New issues ${WOULD_BE}created | ${#NEW_ISSUE_TITLES[@]} |"
  echo "| Gate rejections | ${REJECTED} |"
  echo "| Content gate rejections | ${CONTENT_GATE_REJECTIONS} |"
  if [[ "${SKIPPED_NEW_ISSUES}" -gt 0 ]]; then
    echo "| Skipped (${SCRIBE_MODE}) | ${SKIPPED_NEW_ISSUES} |"
  fi
  echo ""

  if [[ ${#COMMENT_TOPICS[@]} -gt 0 ]]; then
    echo "**Comments ${WOULD_BE}posted:** ${#COMMENT_TOPICS[@]}"
    for idx in "${!COMMENT_TOPICS[@]}"; do
      echo "- [#${COMMENT_ISSUES[$idx]} — ${COMMENT_TOPICS[$idx]}](${ISSUE_BASE}/${COMMENT_ISSUES[$idx]})"
    done
    echo ""
  fi

  if [[ ${#NEW_ISSUE_TITLES[@]} -gt 0 ]]; then
    echo "**New issues ${WOULD_BE}filed:** ${#NEW_ISSUE_TITLES[@]}"
    for idx in "${!NEW_ISSUE_TITLES[@]}"; do
      if [[ -n "${NEW_ISSUE_URLS[$idx]:-}" ]]; then
        echo "- [${NEW_ISSUE_TITLES[$idx]}](${NEW_ISSUE_URLS[$idx]})"
      else
        echo "- ${NEW_ISSUE_TITLES[$idx]}"
      fi
    done
    echo ""
  fi

  if [[ "${REJECTED}" -gt 0 ]]; then
    echo "> **${REJECTED}** topic(s) rejected by the security gate."
    if [[ "${CONTENT_GATE_REJECTIONS}" -gt 0 ]]; then
      echo "> ${CONTENT_GATE_REJECTIONS} rejected by content gate (details suppressed for safety)."
    fi
    echo ""
  fi

  echo "_Confidence threshold: ${MIN_CONFIDENCE} · Mode: ${SCRIBE_MODE}_"
} >> "${GITHUB_STEP_SUMMARY}"
  echo "Step summary written to GITHUB_STEP_SUMMARY"
fi

# ============================================================
# Slack notification (optional — skip silently if no webhook)
# ============================================================
SLACK_WEBHOOK="${SCRIBE_SLACK_WEBHOOK_URL:-${SLACK_WEBHOOK_URL:-}}"
if [[ -n "${SLACK_WEBHOOK}" ]]; then
  echo "::add-mask::${SLACK_WEBHOOK}"
  RUN_URL=$(forge_run_url "${SCRIBE_REPO}")

  SLACK_TEXT=":memo: *Scribe agent* (${RUN_MODE_LABEL})"
  SLACK_TEXT+="\nMode: \`${SCRIBE_MODE}\` · Confidence: \`${MIN_CONFIDENCE}\`"
  SLACK_TEXT+="\n• Topics processed: *${TOPIC_COUNT}*"
  SLACK_TEXT+="\n• Comments: *${#COMMENT_TOPICS[@]}*"
  SLACK_TEXT+="\n• New issues: *${#NEW_ISSUE_TITLES[@]}*"
  SLACK_TEXT+="\n• Gate rejections: *${REJECTED}*"
  if [[ "${CONTENT_GATE_REJECTIONS}" -gt 0 ]]; then
    SLACK_TEXT+=" (${CONTENT_GATE_REJECTIONS} content)"
  fi
  if [[ "${SKIPPED_NEW_ISSUES}" -gt 0 ]]; then
    SLACK_TEXT+="\n• Skipped (${SCRIBE_MODE}): *${SKIPPED_NEW_ISSUES}*"
  fi

  if [[ ${#COMMENT_TOPICS[@]} -gt 0 ]]; then
    SLACK_TEXT+="\n\n*Comments:*"
    for idx in "${!COMMENT_TOPICS[@]}"; do
      SLACK_TOPIC=$(sanitize_slack_mrkdwn "${COMMENT_TOPICS[$idx]}")
      SLACK_TEXT+="\n  • <${ISSUE_BASE}/${COMMENT_ISSUES[$idx]}|#${COMMENT_ISSUES[$idx]} — ${SLACK_TOPIC}>"
    done
  fi

  if [[ ${#NEW_ISSUE_TITLES[@]} -gt 0 ]]; then
    SLACK_TEXT+="\n\n*New issues:*"
    for idx in "${!NEW_ISSUE_TITLES[@]}"; do
      SLACK_TITLE=$(sanitize_slack_mrkdwn "${NEW_ISSUE_TITLES[$idx]}")
      if [[ -n "${NEW_ISSUE_URLS[$idx]:-}" ]]; then
        SLACK_TEXT+="\n  • <${NEW_ISSUE_URLS[$idx]}|${SLACK_TITLE}>"
      else
        SLACK_TEXT+="\n  • ${SLACK_TITLE}"
      fi
    done
  fi

  SLACK_TEXT+="\n\n<${RUN_URL}|View run>"

  SLACK_PAYLOAD=$(printf '%b' "${SLACK_TEXT}" | jq -Rs '{text: .}')
  if printf '%s' "${SLACK_PAYLOAD}" \
      | curl -fsSL -X POST -H 'Content-Type: application/json' \
        --data-binary @- "${SLACK_WEBHOOK}" >/dev/null 2>&1; then
    echo "Slack notification sent"
  else
    echo "WARNING: Slack notification failed (non-fatal)"
  fi
  unset SLACK_WEBHOOK
else
  echo "No SCRIBE_SLACK_WEBHOOK_URL set — skipping Slack notification"
fi
