#!/usr/bin/env bash
# Pre-script for Jira-sourced code agent runs.
#
# Validates the Jira issue URL, skips the run when an open human PR already
# addresses the issue or the issue has child issues (like pre-code.sh), and
# auto-installs pre-commit tool dependencies.  The sandbox reads Jira work
# items directly through provider-backed API access — no .issue-context.json
# prefetching.
#
# Runs on the CI runner BEFORE sandbox creation.
#
# Required environment variables:
#   ISSUE_URL          — Jira browse URL (https://<host>.atlassian.net/browse/PROJ-123)
#   REPO_FULL_NAME     — target repo (owner/repo), used for the existing-PR
#                         check and pre-commit tool install
#   FULLSEND_FORGE     — "github" or "gitlab" (the target forge, NOT the source)
#
# Optional environment variables:
#   JIRA_BASE_URL      — Jira instance base URL; derived from ISSUE_URL when unset,
#                         cross-checked when set
#   JIRA_TOKEN         — Jira token for the child-issue check and the skip
#                         comment; both are skipped when it is unset
#   JIRA_USER_EMAIL    — bot-user email (Basic auth); unset means a
#                         service-account token (Bearer auth)
#   GH_TOKEN / GITLAB_TOKEN — target forge token for the existing-PR check;
#                         the check is skipped when unset
#   COMMENT_BODY       — trigger comment; when unset, read from the dispatch
#                         event payload (${FULLSEND_DIR}/dispatch/event-payload.json)
#   CODE_FORCE         — "true" bypasses the existing-PR and child-issue checks
#   FULLSEND_APP_SET   — GitHub App identity prefix (default "fullsend-ai"),
#                         used to exclude bot-authored PRs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prescript-output.lib.sh
source "${SCRIPT_DIR}/lib/prescript-output.lib.sh"

: "${ISSUE_URL:?ISSUE_URL must be set}"
: "${REPO_FULL_NAME:?REPO_FULL_NAME must be set}"

# Sanitize a value for safe use in GHA workflow commands (::error::, etc.).
# Strips ANSI escapes, newlines/carriage returns, and escapes :: to prevent injection.
_gha_sanitize() {
  printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'
}

# ---------------------------------------------------------------------------
# Validate Jira issue URL
# ---------------------------------------------------------------------------
if [[ ! "${ISSUE_URL}" =~ ^https://[a-zA-Z0-9.-]+/browse/[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
  echo "::error::ISSUE_URL does not match expected Jira pattern: $(_gha_sanitize "${ISSUE_URL}")"
  exit 1
fi

JIRA_HOST="$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')"
case "${JIRA_HOST}" in
  *.atlassian.net) ;;
  *)
    echo "::error::Jira host '${JIRA_HOST}' is not in the allowed host list (*.atlassian.net)"
    exit 1
    ;;
esac

# Derive JIRA_BASE_URL from the issue URL and cross-check the env var.
PARSED_BASE_URL="https://${JIRA_HOST}"
while [[ -n "${JIRA_BASE_URL:-}" && "${JIRA_BASE_URL}" == */ ]]; do
  JIRA_BASE_URL="${JIRA_BASE_URL%/}"
done
if [[ -n "${JIRA_BASE_URL:-}" ]] && [[ "${JIRA_BASE_URL}" != "${PARSED_BASE_URL}" ]]; then
  echo "::error::JIRA_BASE_URL ('$(_gha_sanitize "${JIRA_BASE_URL}")') does not match ISSUE_URL host ('${PARSED_BASE_URL}')"
  exit 1
fi
JIRA_BASE_URL="${PARSED_BASE_URL}"

# Parse issue key and project from the URL.
ISSUE_KEY="$(echo "${ISSUE_URL}" | sed -E 's|.*/browse/||')"
PROJECT_KEY="${ISSUE_KEY%-*}"

echo "::notice::🔗 Jira source: $(_gha_sanitize "${ISSUE_URL}") (project=$(_gha_sanitize "${PROJECT_KEY}"), key=$(_gha_sanitize "${ISSUE_KEY}"))"

# shellcheck source=lib/code-ops.lib.sh
source "${SCRIPT_DIR}/lib/code-ops.lib.sh"

# ---------------------------------------------------------------------------
# Existing human-PR and child-issue checks, unless bypassed
# ---------------------------------------------------------------------------
# Mirrors pre-code.src.sh for Jira-sourced runs:
#   - an open human PR/MR on the target repo whose title or body names the
#     Jira key as a whole word (this covers the "Related to <url>" line
#     post-code.sh writes) skips the run; bot PRs do not;
#   - an issue with child issues (JQL "parent = KEY", subtasks excluded,
#     so a story split into subtasks still runs) skips the run;
#     a failed child query logs a warning and proceeds (fail open);
#   - `/fs-code --force` on the trigger comment's first line, or
#     CODE_FORCE=true, bypasses both checks.
# A skip writes skipped=true through prescript_output and posts one sticky
# comment on the Jira issue; a failed Jira write still skips. A missing
# forge token skips the PR check; a missing JIRA_TOKEN skips the child
# check and the comment.
#
# The child check and the comment use jira-triage-ops.lib.sh: Basic auth
# when JIRA_USER_EMAIL is set (bot user), Bearer when it is not (service
# account), sent to JIRA_API_URL or else JIRA_BASE_URL (#1900, #1876).
#
# On a GitLab target, the trigger comment reaches neither COMMENT_BODY nor
# the dispatch payload file, so `/fs-code --force` has no effect there until
# fullsend exports COMMENT_BODY for Jira jobs (fullsend-ai/fullsend#9187).
# The GitHub check reads the newest 500 open PRs.

# jira-triage-ops.lib.sh exits at load time without JIRA_TOKEN, so load it
# only when the token is set. JIRA_USER_EMAIL is optional.
JIRA_CREDS_OK=0
if [[ -n "${JIRA_TOKEN:-}" ]]; then
  # shellcheck source=lib/jira-triage-ops.lib.sh
  source "${SCRIPT_DIR}/lib/jira-triage-ops.lib.sh"
  JIRA_CREDS_OK=1
  # Globals tracker_post_sticky_comment reads.
  # shellcheck disable=SC2034
  REPO="${PROJECT_KEY}"
  # shellcheck disable=SC2034
  JIRA_ISSUE_NUM="${ISSUE_KEY##*-}"
else
  echo "No Jira credentials set — skipping child-issue check and skip comment"
fi

SKIP_COMMENT_MARKER="<!-- fullsend:pre-code-jira-skip -->"

# _jira_first_line_token TEXT N — print the Nth whitespace-separated token of
# the first line of TEXT. Parameter expansion instead of `head -1` avoids
# SIGPIPE on a large TEXT under pipefail.
_jira_first_line_token() {
  local first_line="${1%%$'\n'*}"
  printf '%s' "${first_line}" | tr -d '\r' | awk -v n="$2" '{print $n}'
}

# _jira_post_skip_comment BODY — post or update the sticky skip comment.
# Never fails: a skip must stay a skip when the Jira write fails.
_jira_post_skip_comment() {
  if [[ "${JIRA_CREDS_OK}" -ne 1 ]]; then
    echo "No Jira credentials set — not commenting on ${ISSUE_KEY}"
    return 0
  fi
  if ! tracker_post_sticky_comment "$1" "${SKIP_COMMENT_MARKER}" > /dev/null; then
    echo "::warning::Failed to post the skip comment on Jira issue ${ISSUE_KEY} — skipping the run anyway"
  fi
}

# _jira_list_human_prs KEY BOT_LOGIN CODER_BOT_LOGIN — print one
# "number<TAB>author<TAB>url" line per open human PR/MR on the target repo
# whose title or body contains KEY as a whole word (PROJ-12 does not match
# PROJ-123). Fails open: an API error prints a warning and no lines.
_jira_list_human_prs() {
  local key="$1"
  local bot="${2%\[bot\]}"
  local coder="${3%\[bot\]}"
  local prs=""
  case "${FULLSEND_FORGE}" in
    github)
      prs="$(gh pr list --repo "${REPO_FULL_NAME}" --state open --limit 500 \
        --json number,title,body,url,author 2>/dev/null \
        | jq -c '[.[] | {number, title, body, url, author: (.author.login // ""), is_bot: (.author.is_bot // false)}]' 2>/dev/null)" \
        || prs=""
      ;;
    gitlab)
      # An external work item has no GitLab issue URL to derive the host from;
      # the MR target is the GitLab instance running this job (as post-code.sh).
      # shellcheck disable=SC2034
      GITLAB_HOST="${CI_SERVER_HOST:-}"
      REPO_ENCODED="$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)"
      local all_mrs="[]" page=1 batch count
      while [[ "${page}" -le 10 ]]; do
        batch="$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/merge_requests?state=opened&per_page=100&page=${page}" 2>/dev/null)" \
          || { all_mrs=""; break; }
        count="$(printf '%s' "${batch}" | jq 'length' 2>/dev/null)" || { all_mrs=""; break; }
        [[ "${count}" -eq 0 ]] && break
        all_mrs="$(printf '%s\n%s' "${all_mrs}" "${batch}" | jq -s 'add')" || { all_mrs=""; break; }
        page=$((page + 1))
      done
      # Same bot-username patterns as forge_list_prs_for_issue on GitLab.
      if [[ -n "${all_mrs}" ]]; then
        prs="$(printf '%s' "${all_mrs}" | jq -c '[.[]
          | {number: .iid, title, body: .description, url: .web_url, author: (.author.username // "")}
          | select((.author | test("\\[bot\\]$|^fullsend|_bot$")) | not)]' 2>/dev/null)" || prs=""
      fi
      ;;
  esac
  if [[ -z "${prs}" ]]; then
    echo "::warning::Could not list open PRs on $(_gha_sanitize "${REPO_FULL_NAME}") — failing open (treating as no existing PRs)" >&2
    return 0
  fi
  # Case-insensitive, so "fix/proj-42-..." matches PROJ-42. Any bot author
  # is dropped (as pre-code.sh does), plus the app-set logins.
  printf '%s' "${prs}" | jq -r --arg key "${key}" --arg bot "${bot}" --arg coder "${coder}" '
    ("(^|[^A-Za-z0-9_])" + $key + "($|[^A-Za-z0-9_])") as $re
    | .[]
    | select(((.title // "") | test($re; "i")) or ((.body // "") | test($re; "i")))
    | select((.is_bot // false) | not)
    | select((.author | sub("^app/"; "") | sub("\\[bot\\]$"; "")) as $login
        | $login != $bot and $login != $coder)
    | "\(.number)\t\(.author)\t\(.url)"' 2>/dev/null || true
}

# _jira_child_count — print the number of children found for ISSUE_KEY
# (0 or 1: one result is enough to know the issue is a parent). Returns
# non-zero when the count cannot be read.
_jira_child_count() {
  local resp
  resp="$(_jira_api POST "/search/jql" \
    --data "$(jq -cn --arg jql "parent = ${ISSUE_KEY} AND issuetype not in subTaskIssueTypes()" '{jql: $jql, maxResults: 1, fields: ["key"]}')" 2>/dev/null)" \
    || return 1
  printf '%s' "${resp}" | jq -er '.issues | length' 2>/dev/null
}

# --force counts only as the command's flag token on the trigger comment's
# first line, the same tokenization as pre-code.src.sh. COMMENT_BODY wins
# when set; otherwise read the dispatch event payload. A label-triggered run
# has no comment and therefore no --force.
FORCE_WORD=""
if [[ -n "${COMMENT_BODY:-}" ]]; then
  FORCE_WORD="$(_jira_first_line_token "${COMMENT_BODY}" 2)"
else
  EVENT_PAYLOAD_FILE=""
  for _payload_candidate in \
    "${FULLSEND_DIR:+${FULLSEND_DIR}/dispatch/event-payload.json}" \
    "${GITHUB_WORKSPACE:-.}/.fullsend/dispatch/event-payload.json"; do
    if [[ -n "${_payload_candidate}" && -f "${_payload_candidate}" ]]; then
      EVENT_PAYLOAD_FILE="${_payload_candidate}"
      break
    fi
  done
  if [[ -n "${EVENT_PAYLOAD_FILE}" ]]; then
    # .comment.body is the full comment ("/fs-code --force ..."); the
    # normalized instruction is the rest of line 1 after the command.
    _trigger_line="$(jq -r '(.comment.body // "") | (split("\n")[0] // "")' "${EVENT_PAYLOAD_FILE}" 2>/dev/null)" || _trigger_line=""
    if [[ -n "${_trigger_line}" ]]; then
      FORCE_WORD="$(_jira_first_line_token "${_trigger_line}" 2)"
    else
      _trigger_line="$(jq -r '(._normalized_event.transition.comment.instruction // "") | (split("\n")[0] // "")' "${EVENT_PAYLOAD_FILE}" 2>/dev/null)" || _trigger_line=""
      FORCE_WORD="$(_jira_first_line_token "${_trigger_line}" 1)"
    fi
  fi
fi

SKIP_EXISTING_CHECKS=0
if [[ "${CODE_FORCE:-}" == "true" ]] || [[ "${FORCE_WORD}" == "--force" ]]; then
  echo "Force override — skipping existing-PR and child-issue checks"
  SKIP_EXISTING_CHECKS=1
fi

if [[ "${SKIP_EXISTING_CHECKS}" -eq 0 ]]; then
  if { [ "${FULLSEND_FORGE}" = "github" ] && [ -z "${GH_TOKEN:-}" ]; } || \
     { [ "${FULLSEND_FORGE}" = "gitlab" ] && [ -z "${GITLAB_TOKEN:-}" ]; }; then
    echo "No ${FULLSEND_FORGE} token set — skipping existing-PR check"
  else
    APP_SET="${FULLSEND_APP_SET:-fullsend-ai}"
    echo "Checking for existing open PRs that reference ${ISSUE_KEY}..."
    HUMAN_PR_LINES="$(_jira_list_human_prs "${ISSUE_KEY}" "${APP_SET}[bot]" "${APP_SET}-coder[bot]")"

    if [[ -n "${HUMAN_PR_LINES}" ]]; then
      _pr_prefix="#"
      if [ "${FULLSEND_FORGE}" = "gitlab" ]; then
        _pr_prefix="!"
      fi
      FIRST_PR_NUM="$(printf '%s\n' "${HUMAN_PR_LINES}" | head -1 | cut -f1)"
      FIRST_PR_AUTHOR="$(printf '%s\n' "${HUMAN_PR_LINES}" | head -1 | cut -f2)"
      echo "::notice::Found existing human PR ${_pr_prefix}${FIRST_PR_NUM} by @${FIRST_PR_AUTHOR}"

      PR_LIST_MD=""
      while IFS=$'\t' read -r _pr_num _pr_author pr_url; do
        PR_LIST_MD="${PR_LIST_MD}
- ${pr_url}"
      done <<< "${HUMAN_PR_LINES}"

      _jira_post_skip_comment "An open pull request already addresses ${ISSUE_KEY} — skipping automated implementation.
${PR_LIST_MD}

To override, comment \`/fs-code --force\` on this issue."

      echo "Skipping code agent — existing PR(s) found for ${ISSUE_KEY}"
      prescript_output "skipped" "true"
      prescript_output "reason" "open PR ${_pr_prefix}${FIRST_PR_NUM} by @${FIRST_PR_AUTHOR} already addresses ${ISSUE_KEY}"
      exit 0
    fi
    echo "No existing human PRs found"
  fi

  if [[ "${JIRA_CREDS_OK}" -eq 1 ]]; then
    echo "Checking for child issues of ${ISSUE_KEY}..."
    if ! CHILD_COUNT="$(_jira_child_count)" || [[ ! "${CHILD_COUNT}" =~ ^[0-9]+$ ]]; then
      echo "::warning::Could not read child issues of ${ISSUE_KEY} — proceeding with code agent"
    elif [[ "${CHILD_COUNT}" -gt 0 ]]; then
      echo "::notice::${ISSUE_KEY} has child issue(s) — skipping code agent"

      _jira_post_skip_comment "${ISSUE_KEY} has child issues — skipping automated implementation.

The code agent implements leaf work items. Use the child issues for implementation, or comment \`/fs-code --force\` to implement this parent issue anyway."

      prescript_output "skipped" "true"
      prescript_output "reason" "${ISSUE_KEY} has child issue(s); implement the child issues instead"
      exit 0
    else
      echo "No child issues found"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Auto-detect and install pre-commit tool dependencies
# ---------------------------------------------------------------------------
# This section is shared with the forge pre-script — the target repo is
# the same regardless of whether the source issue is Jira or a forge.

TARGET_REPO="$(forge_get_repo_dir)"
RESOLVE_SCRIPT="${SCRIPT_DIR}/resolve-precommit-tools.py"
INSTALL_SCRIPT="${SCRIPT_DIR}/install-precommit-tools.sh"

WORKSPACE_DIR="$(forge_get_workspace_dir)"
if [ ! -f "${RESOLVE_SCRIPT}" ] || [ ! -f "${INSTALL_SCRIPT}" ]; then
  if [ -n "${WORKSPACE_DIR}" ]; then
    for _ws_candidate in "${WORKSPACE_DIR}/scripts" "${WORKSPACE_DIR}/.fullsend/scripts"; do
      if [ -f "${_ws_candidate}/resolve-precommit-tools.py" ] \
         && [ -f "${_ws_candidate}/install-precommit-tools.sh" ]; then
        RESOLVE_SCRIPT="${_ws_candidate}/resolve-precommit-tools.py"
        INSTALL_SCRIPT="${_ws_candidate}/install-precommit-tools.sh"
        break
      fi
    done
  fi
fi

if [ -f "${TARGET_REPO}/.pre-commit-config.yaml" ] \
   && { [ ! -f "${RESOLVE_SCRIPT}" ] || [ ! -f "${INSTALL_SCRIPT}" ]; }; then
  echo "::warning::Pre-commit tool auto-install skipped: companion scripts not found"
  echo "::warning::Expected ${RESOLVE_SCRIPT} and ${INSTALL_SCRIPT}"
  echo "::warning::Pre-commit hooks requiring system tools (e.g. lychee) may fail"
fi

if [ -f "${TARGET_REPO}/.pre-commit-config.yaml" ] \
   && [ -f "${RESOLVE_SCRIPT}" ] \
   && [ -f "${INSTALL_SCRIPT}" ]; then
  echo "Resolving pre-commit tool dependencies..."
  MANIFEST="$(mktemp)"
  LOCAL_REG="$(mktemp)"
  RESOLVE_ARGS=("${TARGET_REPO}")
  DEFAULT_BR="$(git -C "${TARGET_REPO}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')" || DEFAULT_BR=""
  if [ -n "${DEFAULT_BR}" ] \
     && git -C "${TARGET_REPO}" show "origin/${DEFAULT_BR}:.pre-commit-tools.yaml" > "${LOCAL_REG}" 2>/dev/null; then
    RESOLVE_ARGS+=("--local-registry" "${LOCAL_REG}")
  fi
  if python3 "${RESOLVE_SCRIPT}" "${RESOLVE_ARGS[@]}" > "${MANIFEST}"; then
    if [ -s "${MANIFEST}" ] && jq -e '.tools | length > 0' "${MANIFEST}" >/dev/null 2>&1; then
      bash "${INSTALL_SCRIPT}" "${MANIFEST}"
    else
      echo "No additional pre-commit tools needed"
    fi
  else
    echo "::warning::Pre-commit tool resolution failed — continuing without auto-install"
  fi
  rm -f "${MANIFEST}" "${LOCAL_REG}"
fi
export PATH="${HOME}/.local/bin:${PATH}"
forge_append_path "${HOME}/.local/bin"
