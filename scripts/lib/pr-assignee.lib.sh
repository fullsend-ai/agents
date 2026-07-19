#!/usr/bin/env bash
# pr-assignee.lib.sh — Resolve and assign a human owner for code-agent PRs.
#
# Source from post-code.src.sh (after post-failure-report.lib.sh for gha_echo):
#   source "${SCRIPT_DIR}/lib/pr-assignee.lib.sh"
#
# Precedence (first human match wins):
#   1. Most recent human /fs-code commenter on the issue (API lookup)
#   2. First human issue assignee
#   3. Human issue author
#
# Never assigns bots or GitHub Apps. Assignment is best-effort.
# No workflow TRIGGER_SOURCE plumbing required.

# shellcheck shell=bash

[[ -n "${PR_ASSIGNEE_SH_LOADED:-}" ]] && return 0
PR_ASSIGNEE_SH_LOADED=1

# Return 0 when login looks like a human GitHub user (not a bot/App).
is_human_github_user() {
  local login="${1:-}"
  if [[ -z "${login}" ]]; then
    return 1
  fi
  case "${login}" in
    app/*|dependabot) return 1 ;;
  esac
  if [[ "${login}" =~ \[bot\]$ ]]; then
    return 1
  fi
  return 0
}

# True when the first word of the first line is /fs-code (matches dispatch.yml).
comment_is_fs_code() {
  local body="${1:-}"
  local first_word
  first_word="$(printf '%s\n' "${body}" | head -1 | tr -d '\r' | awk '{print $1}')"
  [[ "${first_word}" == "/fs-code" ]]
}

# From a REST comments JSON array, return the most recent human /fs-code invoker.
# Accepts REST shape ({user.login, body}) or GraphQL-ish ({author.login, body}).
find_fs_code_invoker() {
  local comments_json="${1:-}"
  if [[ -z "${comments_json}" || "${comments_json}" == "null" ]]; then
    return 1
  fi

  local login
  login="$(echo "${comments_json}" | jq -r '
    def is_bot:
      (. == "dependabot") or startswith("app/") or test("\\[bot\\]$");
    def first_word:
      ((. // "") | split("\n")[0] | gsub("\r$"; "") | split(" ")[0]);
    [
      .[]
      | (.user.login // .author.login // "") as $login
      | select(($login | length > 0) and ($login | is_bot | not))
      | select((.body | first_word) == "/fs-code")
      | $login
    ] | last // empty
  ' 2>/dev/null || true)"

  if [[ -n "${login}" ]]; then
    echo "${login}"
    return 0
  fi
  return 1
}

# Resolve a human assignee from comments JSON + issue JSON.
# Prints the login on stdout, or nothing when no human matches.
# Args: comments_json issue_json
resolve_pr_assignee_from_context() {
  local comments_json="${1:-}"
  local issue_json="${2:-}"

  local invoker
  invoker="$(find_fs_code_invoker "${comments_json}" || true)"
  if is_human_github_user "${invoker}"; then
    echo "${invoker}"
    return 0
  fi

  if [[ -z "${issue_json}" ]]; then
    return 1
  fi

  local human_assignee
  human_assignee="$(echo "${issue_json}" | jq -r '
    [(.assignees // [])[]? | .login? // empty | select(
      (. | length > 0) and
      (startswith("app/") | not) and
      (test("\\[bot\\]$") | not) and
      (. != "dependabot")
    )] | .[0] // empty
  ' 2>/dev/null || true)"
  if [[ -n "${human_assignee}" ]]; then
    echo "${human_assignee}"
    return 0
  fi

  local author_login
  author_login="$(echo "${issue_json}" | jq -r '.author.login? // empty' 2>/dev/null || true)"
  if is_human_github_user "${author_login}"; then
    echo "${author_login}"
    return 0
  fi

  return 1
}

# Emit a runner warning through gha_echo when available (sanitizes :: / %0A / %0D).
# Never fall back to raw "::warning::" interpolation — that invites workflow-command injection.
_pr_assignee_warn() {
  if declare -F gha_echo >/dev/null 2>&1; then
    gha_echo warning "$*"
  else
    echo "warning: $*" >&2
  fi
}

# Fetch issue comments (paginated REST) as a single JSON array. Best-effort.
fetch_issue_comments_json() {
  local raw
  if ! raw="$(gh api --paginate \
    "repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/comments" 2>/dev/null)"; then
    echo '[]'
    return 0
  fi
  if [[ -z "${raw}" ]]; then
    echo '[]'
    return 0
  fi
  echo "${raw}" | jq -s 'add // []' 2>/dev/null || echo '[]'
}

# Resolve using issue comments + assignees/author via GitHub API.
resolve_pr_assignee() {
  local comments_json issue_json
  comments_json="$(fetch_issue_comments_json)"
  issue_json="$(gh issue view "${ISSUE_NUMBER}" --repo "${REPO_FULL_NAME}" \
    --json assignees,author 2>/dev/null || true)"
  resolve_pr_assignee_from_context "${comments_json}" "${issue_json}"
}

# Best-effort PR assignee: skip when the PR already has assignees.
# Requires REPO_FULL_NAME; uses gha_echo when available.
# Note: parameter is target_pr (not pr_number) to avoid SC2153 against PR_NUMBER
# from post-failure-report.lib.sh once both libs are bundled into post-code.sh.
maybe_assign_pr() {
  local target_pr="$1"
  local existing_count
  if ! existing_count="$(gh pr view "${target_pr}" --repo "${REPO_FULL_NAME}" \
    --json assignees --jq '.assignees | length' 2>/dev/null)"; then
    _pr_assignee_warn "Could not read assignees for PR #${target_pr} — skipping assignment"
    return 0
  fi
  if [[ "${existing_count}" != "0" ]]; then
    echo "PR #${target_pr} already has assignees — skipping assignment"
    return 0
  fi

  local assignee
  assignee="$(resolve_pr_assignee || true)"
  if [[ -z "${assignee}" ]]; then
    echo "No human assignee candidate — leaving PR #${target_pr} unassigned"
    return 0
  fi

  echo "Assigning PR #${target_pr} to ${assignee}..."
  local assign_err
  assign_err="$(gh pr edit "${target_pr}" --repo "${REPO_FULL_NAME}" \
    --add-assignee "${assignee}" 2>&1)" || {
    _pr_assignee_warn "Failed to assign PR #${target_pr} to ${assignee} — continuing"
    if [[ -n "${assign_err}" ]]; then
      _pr_assignee_warn "${assign_err}"
    fi
  }
}
