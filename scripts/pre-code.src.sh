#!/usr/bin/env bash
# Pre-script: validate workflow_dispatch inputs before the agent runs.
#
# Prevents malformed or malicious event_payload from reaching the sandbox.
# Runs on the CI runner BEFORE sandbox creation.
#
# Skip signalling uses the pre-script output protocol
# (fullsend docs/normative/prescript-output/v1, fullsend-ai/fullsend#4718):
# when an open human PR already addresses the issue, or the issue has
# sub-issues (a tracking/parent issue), this script writes skipped=true
# to the file named by FULLSEND_PRESCRIPT_OUTPUT and fullsend run stops
# before creating the sandbox. Under a CLI that predates the protocol
# the variable is unset and the write is skipped — the run proceeds,
# which matches the pre-protocol behavior.
#
# Required environment variables (set by the workflow):
#   ISSUE_NUMBER       — must be a positive integer
#   REPO_FULL_NAME     — must be owner/repo format
#   ISSUE_URL          — must be a valid issue URL for the forge
#   FULLSEND_FORGE     — "github" or "gitlab"
#
# Optional environment variables:
#   FULLSEND_APP_SET   — GitHub App identity prefix (default "fullsend-ai").
#                         Used to derive bot identities for existing-PR and
#                         move-marker checks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prescript-output.lib.sh
source "${SCRIPT_DIR}/lib/prescript-output.lib.sh"
# shellcheck source=lib/code-ops.lib.sh
source "${SCRIPT_DIR}/lib/code-ops.lib.sh"

# Sanitize a value for safe interpolation into logged output. Strips ANSI
# escapes, control chars, and newlines, and escapes :: and % so an
# attacker-controlled value can't inject a workflow command via a line break.
#
# Named distinctly from _gha_sanitize since code-ops.lib.sh transitively
# loads an older, weaker _gha_sanitize that a `declare -F` guard would keep.
_pre_code_sanitize_log() {
  printf '%s' "$1" | tr -d '\n\r' \
    | sed -E 's/\x1b\][^\x1b\x07]*(\x07|\x1b\\)?//g; s/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b.?//g' \
    | tr -d '\000-\037\177' \
    | sed 's/%/%25/g; s/::/%3A%3A/g'
}

# Close-and-recreate moves leave this marker on the original issue. The move
# handler must keep the destination in the comment text using the form shown
# below so a later /fs-code run can guide the issue to its new location.
FULLSEND_MOVE_MARKER='<!-- fullsend:move-agent -->'
FULLSEND_MOVE_AGENT_LOGIN="${FULLSEND_APP_SET:-fullsend-ai}-triage[bot]"

extract_move_location() {
  local body="$1"
  printf '%s' "${body}" | sed -nE \
    's/.*moved to `([a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+#[1-9][0-9]*)`.*/\1/p' \
    | head -1
}

check_for_moved_issue() {
  local issue_response issue_status issue_json
  local state repository_url html_url target_repo target_number
  local target_repo_normalized current_repo_normalized
  local comments move_comment move_location

  issue_response="$(forge_get_issue_movement_details)" || return 1
  [[ -n "${issue_response}" ]] || return 1

  issue_status="$(printf '%s\n' "${issue_response}" | sed -nE \
    's/^HTTP\/[0-9.]+[[:space:]]+([0-9]{3}).*/\1/p' | head -1 | tr -d '\r')"
  case "${issue_status}" in
    404)
      # A source-scoped token can receive 404 after a transfer to a
      # repository it cannot read. It is also possible that the issue was
      # deleted or is otherwise inaccessible, so do not claim a destination.
      # Return a distinct status so the caller skips the agent safely.
      return 2
      ;;
    200)
      ;;
    *)
      return 1
      ;;
  esac

  # Strip the status line and headers from the --include response. GitHub CLI
  # follows transfer redirects, so a readable destination arrives here as a
  # 200 response whose body contains the destination repository.
  issue_json="$(printf '%s\n' "${issue_response}" | awk '
    BEGIN { body = 0 }
    { sub(/\r$/, "") }
    body { print; next }
    /^$/ { body = 1 }
  ')"
  [[ -n "${issue_json}" ]] || return 1

  state="$(printf '%s' "${issue_json}" | jq -r '.state // empty' 2>/dev/null || true)"
  repository_url="$(printf '%s' "${issue_json}" | jq -r '.repository_url // empty' 2>/dev/null || true)"
  html_url="$(printf '%s' "${issue_json}" | jq -r '.html_url // empty' 2>/dev/null || true)"

  # A native GitHub transfer updates repository_url and html_url to the
  # destination repository. Compare normalized owner/repo names because
  # repository_url is an API URL, not the REPO_FULL_NAME format.
  target_repo="$(printf '%s' "${repository_url}" | sed -nE 's|.*/repos/([^/]+/[^/]+)$|\1|p')"
  target_repo_normalized="$(printf '%s' "${target_repo}" | tr '[:upper:]' '[:lower:]')"
  current_repo_normalized="$(printf '%s' "${REPO_FULL_NAME}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${target_repo}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]] \
    && [[ "${target_repo_normalized}" != "${current_repo_normalized}" ]]; then
    target_number="$(forge_extract_issue_from_url "${html_url}" 2>/dev/null || true)"
    if [[ ! "${target_number}" =~ ^[1-9][0-9]*$ ]]; then
      # Do not guess the destination issue number. GitHub may renumber an
      # issue during transfer, so the source number could identify an
      # unrelated issue in the destination repository.
      target_number="unknown"
    fi
    printf '%s\t%s\t%s\t%s\tnative\n' "${target_repo}" "${target_number}" "${target_repo}" "${target_number}"
    return 0
  fi

  # A close-and-recreate move keeps the original issue in this repository.
  # Require both the closed state and the machine marker so ordinary closed
  # issues do not stop the code agent.
  [[ "${state}" == "closed" ]] || return 0
  comments="$(forge_get_issue_comments_strict)" || return 1
  move_comment="$(printf '%s' "${comments}" | jq -r \
    --arg marker "${FULLSEND_MOVE_MARKER}" \
    --arg move_agent "${FULLSEND_MOVE_AGENT_LOGIN}" '
    [.[]
      | select((.user.login // "") == $move_agent)
      | select((.body // "") | startswith($marker))
      | .body
    ] | last // empty
  ' 2>/dev/null || true)"
  [[ -n "${move_comment}" ]] || return 0

  move_location="$(extract_move_location "${move_comment}")"
  if [[ "${move_location}" =~ ^([a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+)#([1-9][0-9]*)$ ]]; then
    target_repo="${BASH_REMATCH[1]}"
    target_number="${BASH_REMATCH[2]}"
    printf '%s\t%s\t%s\t%s\tclose-recreate\n' "${target_repo}" "${target_number}" "${REPO_FULL_NAME}" "${ISSUE_NUMBER}"
  fi
}

echo "::notice::🔗 Code target: $(_pre_code_sanitize_log "${ISSUE_URL:-}")"

errors=0

# These are unvalidated workflow inputs, so every echo of a raw value below
# goes through _pre_code_sanitize_log to prevent workflow-command injection
# via an embedded newline.
if [[ ! "${ISSUE_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::ISSUE_NUMBER must be a positive integer, got: '$(_pre_code_sanitize_log "${ISSUE_NUMBER:-}")'"
  errors=$((errors + 1))
fi

if [[ ! "${REPO_FULL_NAME:-}" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+$ ]]; then
  echo "::error::REPO_FULL_NAME must be owner/repo (or group/subgroup/project) format, got: '$(_pre_code_sanitize_log "${REPO_FULL_NAME:-}")'"
  errors=$((errors + 1))
fi

# Suppress the function's own stderr diagnostic — it echoes the raw,
# unsanitized ISSUE_URL; the sanitized "::error::" below covers it.
if ! forge_validate_issue_url "${ISSUE_URL:-}" 2>/dev/null; then
  echo "::error::ISSUE_URL format invalid, got: '$(_pre_code_sanitize_log "${ISSUE_URL:-}")'"
  errors=$((errors + 1))
fi

URL_REPO="$(forge_extract_repo_from_url "${ISSUE_URL:-}" 2>/dev/null || true)"
URL_ISSUE="$(forge_extract_issue_from_url "${ISSUE_URL:-}" 2>/dev/null || true)"

if [[ -n "${URL_REPO}" && "${URL_REPO}" != "${REPO_FULL_NAME:-}" ]]; then
  echo "::error::REPO_FULL_NAME does not match issue URL repo ('$(_pre_code_sanitize_log "${REPO_FULL_NAME:-}")' vs '$(_pre_code_sanitize_log "${URL_REPO}")')"
  errors=$((errors + 1))
fi
if [[ -n "${URL_ISSUE}" && "${URL_ISSUE}" != "${ISSUE_NUMBER:-}" ]]; then
  echo "::error::ISSUE_NUMBER does not match issue URL number ('$(_pre_code_sanitize_log "${ISSUE_NUMBER:-}")' vs '$(_pre_code_sanitize_log "${URL_ISSUE}")')"
  errors=$((errors + 1))
fi

if [[ "${errors}" -gt 0 ]]; then
  echo "::error::Input validation failed with ${errors} error(s). Aborting."
  exit 1
fi

echo "Input validation passed:"
echo "  ISSUE_NUMBER=${ISSUE_NUMBER}"
echo "  REPO_FULL_NAME=${REPO_FULL_NAME}"
echo "  ISSUE_URL=${ISSUE_URL}"

# A moved issue must be stopped before any existing-PR, sub-issue, or runner
# setup work can dispatch the code agent. This currently applies to GitHub;
# GitLab and Jira have separate move implementations in the broader epic.
if [[ "${FULLSEND_FORGE}" == "github" ]]; then
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::notice::No GitHub token set — skipping moved-issue check"
  else
    if MOVE_INFO="$(check_for_moved_issue)"; then
      :
    else
      move_check_status=$?
      if [[ ${move_check_status} -eq 2 ]]; then
        echo "::warning::Unable to verify whether issue ${ISSUE_NUMBER} was moved; skipping the code agent."
        prescript_output "skipped" "true"
        prescript_output "reason" "unable to verify issue movement"
        exit 0
      fi
      echo "::error::Unable to verify whether issue ${ISSUE_NUMBER} was moved; refusing to start the code agent."
      exit 1
    fi
    if [[ -n "${MOVE_INFO}" ]]; then
      IFS=$'\t' read -r MOVE_REPO MOVE_NUMBER COMMENT_REPO COMMENT_NUMBER MOVE_KIND <<< "${MOVE_INFO}"
      MOVE_LOCATION="${MOVE_REPO}"
      if [[ "${MOVE_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
        MOVE_LOCATION="${MOVE_REPO}#${MOVE_NUMBER}"
        if [[ "${MOVE_KIND}" == "native" ]]; then
          MOVE_GUIDANCE="This issue was transferred from \`${REPO_FULL_NAME}#${ISSUE_NUMBER}\`. Run \`/fs-code\` here."
        else
          MOVE_GUIDANCE="This issue was moved to \`${MOVE_LOCATION}\`. Run \`/fs-code\` there instead."
        fi
        forge_post_issue_comment_at "${COMMENT_REPO}" "${COMMENT_NUMBER}" "${MOVE_GUIDANCE}" || true
      else
        echo "::warning::Issue moved to ${MOVE_REPO}, but the destination issue number is unavailable; skipping guidance comment"
      fi
      MOVE_LOCATION_LOG="$(_pre_code_sanitize_log "${MOVE_LOCATION}")"
      echo "::notice::Issue moved to ${MOVE_LOCATION_LOG} — skipping code agent"
      prescript_output "skipped" "true"
      prescript_output "reason" "issue moved to ${MOVE_LOCATION}"
      exit 0
    fi
  fi
fi

# GitLab needs REPO_ENCODED and GITLAB_HOST for API calls — set them before
# any forge function that hits the API (forge_list_prs_for_issue, labels, etc.).
# Always derive GITLAB_HOST from the validated ISSUE_URL. If GITLAB_HOST is
# pre-set in the environment, verify it matches the URL host to prevent
# token exfiltration to an unintended host.
if [ "${FULLSEND_FORGE}" = "gitlab" ]; then
  # shellcheck disable=SC2034
  REPO_ENCODED="$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)"
  if [[ -n "${ISSUE_URL:-}" ]]; then
    _url_host="$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')"
    if [[ -n "${GITLAB_HOST:-}" && "${GITLAB_HOST}" != "${_url_host}" ]]; then
      echo "::error::GITLAB_HOST '${GITLAB_HOST}' does not match issue URL host '${_url_host}'"
      exit 1
    fi
    GITLAB_HOST="${_url_host}"
  fi
  GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
fi

# ---------------------------------------------------------------------------
# Check for existing human PRs and tracking issues, unless bypassed
# ---------------------------------------------------------------------------
# Best-effort checks, bypassable via --force or a missing forge token. A
# bypass must not exit the script — runner setup below still needs to run.
SKIP_EXISTING_CHECKS=0

# Skip if the forge-specific token is not available (best-effort check).
if { [ "${FULLSEND_FORGE}" = "github" ] && [ -z "${GH_TOKEN:-}" ]; } || \
   { [ "${FULLSEND_FORGE}" = "gitlab" ] && [ -z "${GITLAB_TOKEN:-}" ]; }; then
  echo "No ${FULLSEND_FORGE} token set — skipping existing-PR check"
  SKIP_EXISTING_CHECKS=1
fi

# Allow override when the trigger comment is `/fs-code --force` or CODE_FORCE
# is set. --force counts only as the command's flag token on the first line —
# the same first-line tokenization the dispatch router uses — so a comment
# merely mentioning --force (or a pasted log containing it) cannot bypass
# the existing-PR or tracking-issue checks.
FORCE_WORD=""
if [[ -n "${COMMENT_BODY:-}" ]]; then
  # Use parameter expansion instead of piping into `head -1`: a large
  # COMMENT_BODY can trigger SIGPIPE on the upstream `printf`, which
  # `set -euo pipefail` would turn into a script-ending error.
  _COMMENT_FIRST_LINE="${COMMENT_BODY%%$'\n'*}"
  FORCE_WORD="$(printf '%s' "${_COMMENT_FIRST_LINE}" | tr -d '\r' | awk '{print $2}')"
fi
echo "Evaluating force override: CODE_FORCE='$(_pre_code_sanitize_log "${CODE_FORCE:-}")' COMMENT_BODY='$(_pre_code_sanitize_log "${COMMENT_BODY:-}")'"
if [[ "${SKIP_EXISTING_CHECKS}" -eq 0 ]] \
   && { [[ "${CODE_FORCE:-}" == "true" ]] || [[ "${FORCE_WORD}" == "--force" ]]; }; then
  echo "Force override — skipping existing-PR and tracking-issue checks"
  SKIP_EXISTING_CHECKS=1
fi

if [[ "${SKIP_EXISTING_CHECKS}" -eq 0 ]]; then
  # Derive bot identities from FULLSEND_APP_SET so custom app sets (e.g.
  # "custom-app" -> "custom-app[bot]" / "custom-app-coder[bot]") are
  # recognized as bot-authored PRs instead of being misclassified as human.
  # Defaults to "fullsend-ai" to preserve the prior hardcoded identities.
  APP_SET="${FULLSEND_APP_SET:-fullsend-ai}"
  BOT_LOGIN="${APP_SET}[bot]"
  CODER_BOT_LOGIN="${APP_SET}-coder[bot]"

  echo "Checking for existing open PRs linked to issue #${ISSUE_NUMBER}..."

  HUMAN_PR_LINES="$(forge_list_prs_for_issue "${ISSUE_NUMBER}" "${BOT_LOGIN}" "${CODER_BOT_LOGIN}")"

  if [[ -n "${HUMAN_PR_LINES}" ]]; then
    # Parse the first PR for the notice.
    FIRST_PR_NUM="$(echo "${HUMAN_PR_LINES}" | head -1 | cut -f1)"
    FIRST_PR_AUTHOR="$(echo "${HUMAN_PR_LINES}" | head -1 | cut -f2)"

    # GitLab uses ! for MR references; GitHub uses #.
    _pr_prefix="#"
    if [ "${FULLSEND_FORGE}" = "gitlab" ]; then
      _pr_prefix="!"
    fi

    echo "::notice::Found existing human PR ${_pr_prefix}${FIRST_PR_NUM} by @${FIRST_PR_AUTHOR}"

    # Apply pr-open label to signal work is already underway.
    forge_create_label "pr-open" "An open PR already addresses this issue" "D4C5F9"
    forge_add_label "pr-open"

    # Build a markdown list of existing PRs.
    PR_LIST_MD=""
    while IFS=$'\t' read -r pr_num pr_author _pr_url; do
      PR_LIST_MD="${PR_LIST_MD}
- ${_pr_prefix}${pr_num} by @${pr_author}"
    done <<< "${HUMAN_PR_LINES}"

    SKIP_COMMENT="An open PR already addresses this issue — skipping automated implementation.
${PR_LIST_MD}

To override, comment \`/fs-code --force\` on this issue.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> pre-code check</sub>"

    forge_retry_transient forge_post_issue_comment "${SKIP_COMMENT}" || true

    echo "Skipping code agent — existing PR(s) found for issue #${ISSUE_NUMBER}"
    prescript_output "skipped" "true"
    prescript_output "reason" "open PR ${_pr_prefix}${FIRST_PR_NUM} by @${FIRST_PR_AUTHOR} already addresses issue #${ISSUE_NUMBER}"
    exit 0
  fi

  echo "No existing human PRs found — proceeding with code agent"

  # ---------------------------------------------------------------------------
  # Skip tracking/parent issues that have sub-issues (child work items)
  # ---------------------------------------------------------------------------
  # GitHub native sub-issues (and GitLab work-item children) mean this is a
  # tracking issue: implementation belongs on the children, not the parent.
  echo "Checking for sub-issues on issue #${ISSUE_NUMBER}..."
  HAS_SUB_ISSUES="$(forge_has_sub_issues "${ISSUE_NUMBER}")"

  if [[ "${HAS_SUB_ISSUES}" =~ ^[1-9][0-9]*$ ]]; then
    echo "::notice::Issue #${ISSUE_NUMBER} has sub-issue(s) — skipping code agent"

    SKIP_COMMENT="This issue has sub-issues — skipping automated implementation.

The code agent implements leaf work items. Use the child issues for implementation, or comment \`/fs-code --force\` to implement this parent issue anyway.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> pre-code check</sub>"

    forge_retry_transient forge_post_issue_comment "${SKIP_COMMENT}" || true

    echo "Skipping code agent — issue #${ISSUE_NUMBER} is a tracking issue with sub-issue(s)"
    prescript_output "skipped" "true"
    prescript_output "reason" "issue #${ISSUE_NUMBER} has sub-issue(s); implement the child issues instead"
    exit 0
  fi

  echo "No sub-issues found — proceeding with code agent"
fi

# ---------------------------------------------------------------------------
# Auto-detect and install pre-commit tool dependencies
# ---------------------------------------------------------------------------
TARGET_REPO="$(forge_get_repo_dir)"
RESOLVE_SCRIPT="${SCRIPT_DIR}/resolve-precommit-tools.py"
INSTALL_SCRIPT="${SCRIPT_DIR}/install-precommit-tools.sh"

# Fallback: these companion scripts were never migrated into this repo
# during the ADR 0058 extraction, so the BASH_SOURCE-relative lookup above
# always misses. The reusable workflow's "Prepare workspace" step always
# materializes the full scripts/ directory (from fullsend's own scaffold)
# at ${GITHUB_WORKSPACE}/scripts/ (per-org) or ${GITHUB_WORKSPACE}/.fullsend/scripts/
# (per-repo). Try those paths when the BASH_SOURCE-relative lookup misses.
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

# Warn instead of silently skipping when the repo needs the auto-install but
# the companions are missing everywhere — a silent skip here surfaces later
# as a confusing "Executable X not found" pre-commit failure.
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
