#!/usr/bin/env bash
# GENERATED from pre-fix.src.sh — DO NOT EDIT. Run: make script-build
# Pre-script: validate workflow_dispatch inputs before the fix agent runs.
#
# Runs on the GitHub Actions / GitLab CI runner BEFORE the sandbox is created.
# Prevents malformed or malicious event_payload from reaching the sandbox.
# Also enforces the iteration cap — blocks the run if too many fix cycles
# have already occurred on this PR.
#
# Required environment variables (set by the workflow):
#   PR_NUMBER          — must be a positive integer
#   REPO_FULL_NAME     — must be owner/repo format
#   TRIGGER_SOURCE     — forge username that triggered the fix (GitHub: [bot] suffix; GitLab: _bot suffix)
#   FULLSEND_FORGE     — "github" or "gitlab"
#
# Optional environment variables:
#   FIX_ITERATION      — current iteration count (default: 1)
#   ITERATION_CAP      — max bot-triggered iterations (default: 5)
#   ITERATION_CAP_HUMAN — max human-triggered iterations (default: 10)
#   HUMAN_INSTRUCTION  — instruction text (only for human-triggered runs)
#   FIX_CONFLICT_UPDATE_STRATEGY
#                      — merge (default) or rebase; how to publish a
#                        forge-reported merge conflict the agent reconciled
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${FULLSEND_FORGE:?FULLSEND_FORGE is required — set to 'github' or 'gitlab'}"
# shellcheck source=lib/fix-ops.lib.sh
# BEGIN bundled: lib/fix-ops.lib.sh
# shellcheck shell=bash
# fix-ops.lib.sh — Forge-dispatch wrapper for fix agent operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${FIX_OPS_SH_LOADED:-}" ]] && return 0
FIX_OPS_SH_LOADED=1

case "${FULLSEND_FORGE:-}" in
  github)
# BEGIN bundled: lib/github-fix-ops.lib.sh
# shellcheck shell=bash
# github-fix-ops.lib.sh — GitHub forge operations for fix agent scripts.
#
# Bundled into pre-fix.sh and post-fix.sh via fix-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected globals (set by caller):
#   REPO_FULL_NAME — owner/repo (e.g., "org/repo")
#   PR_NUMBER      — pull request number
#
# Expected env vars:
#   GH_TOKEN       — GitHub token with appropriate scopes

[[ -n "${GITHUB_FIX_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_FIX_OPS_SH_LOADED=1

if ! declare -F gha_echo >/dev/null 2>&1; then
  gha_echo() {
    local lvl="$1"; shift
    local msg="${*//::/ }"
    msg="${msg//%0A/}"; msg="${msg//%0a/}"
    msg="${msg//%0D/}"; msg="${msg//%0d/}"
    printf '::%s::%s\n' "${lvl}" "${msg}"
  }
fi

# --- PR/MR operations ---

forge_validate_pr_url() {
  local url="${1:-${PR_URL:-}}"
  if [[ ! "${url}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/pull/[1-9][0-9]*$ ]]; then
    echo "ERROR: PR_URL does not match expected GitHub pattern: ${url}" >&2
    return 1
  fi
}

forge_parse_pr_url() {
  local url="${1:-${PR_URL:-}}"
  REPO_FULL_NAME=$(echo "${url}" | sed 's|https://github.com/||; s|/pull/.*||')
  # shellcheck disable=SC2034
  PR_NUMBER=$(basename "${url}")
}

forge_get_pr_head_ref() {
  local pr_number="$1"
  GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh pr view "${pr_number}" \
    --repo "${REPO_FULL_NAME}" --json headRefName --jq '.headRefName' 2>/dev/null
}

# forge_get_pr_base_branch PR_NUMBER — PR base branch (not the repo default).
# Empty on API failure; callers fall back to TARGET_BRANCH / main.
forge_get_pr_base_branch() {
  local pr_number="$1"
  GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh pr view "${pr_number}" \
    --repo "${REPO_FULL_NAME}" --json baseRefName --jq '.baseRefName // empty' 2>/dev/null
}

# forge_get_pr_merge_state PR_NUMBER — GitHub GraphQL MergeableState
# (MERGEABLE | CONFLICTING | UNKNOWN). Prints "unknown" on API failure or
# empty response so callers never treat a missing signal as a conflict.
forge_get_pr_merge_state() {
  local pr_number="$1"
  local mergeable
  mergeable="$(GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh pr view "${pr_number}" \
    --repo "${REPO_FULL_NAME}" --json mergeable --jq '.mergeable // empty' 2>/dev/null)" || {
    echo "unknown"
    return 0
  }
  if [ -z "${mergeable}" ]; then
    echo "unknown"
    return 0
  fi
  echo "${mergeable}"
}

# forge_pr_has_merge_conflict PR_NUMBER — return 0 only when GitHub reports
# mergeable=CONFLICTING. BLOCKED / BEHIND / UNSTABLE / UNKNOWN / MERGEABLE
# and API failures are not conflicts (issue #1518).
forge_pr_has_merge_conflict() {
  local pr_number="$1"
  local mergeable
  mergeable="$(forge_get_pr_merge_state "${pr_number}")" || return 1
  [ "${mergeable}" = "CONFLICTING" ]
}

# --- Push operations ---

forge_set_push_remote() {
  local token="$1"
  git remote set-url origin \
    "https://x-access-token:${token}@github.com/${REPO_FULL_NAME}.git"
}

forge_setup_push_token() {
  local token="$1"
  export GH_TOKEN="${token}"
}

forge_mask_token() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    local token="${1:-${GH_TOKEN:-}}"
    echo "::add-mask::${token}"
  fi
}

# --- Label operations ---

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  gh label create "${name}" --repo "${REPO_FULL_NAME}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

forge_add_pr_label() {
  local pr_number="$1"
  local label="$2"
  gh pr edit "${pr_number}" --repo "${REPO_FULL_NAME}" \
    --add-label "${label}" 2>/dev/null || true
}

# --- Comment operations ---

forge_post_pr_comment() {
  local pr_number="$1"
  local body="$2"
  gh pr comment "${pr_number}" \
    --repo "${REPO_FULL_NAME}" \
    --body "${body}" 2>/dev/null
}

# --- Workspace operations ---

forge_get_workflow_run_url() {
  local run_repo="${GITHUB_REPOSITORY:-${REPO_FULL_NAME}}"
  printf '%s/%s/actions/runs/%s' \
    "${GITHUB_SERVER_URL:-https://github.com}" \
    "${run_repo}" \
    "${GITHUB_RUN_ID:-unknown}"
}

forge_get_workspace_dir() {
  echo "${GITHUB_WORKSPACE:-}"
}

forge_append_path() {
  local dir="$1"
  echo "${dir}" >> "${GITHUB_PATH:-/dev/null}"
}
# END bundled: lib/github-fix-ops.lib.sh
    ;;
  gitlab)
# BEGIN bundled: lib/gitlab-fix-ops.lib.sh
# shellcheck shell=bash
# gitlab-fix-ops.lib.sh — GitLab forge operations for fix agent scripts.
#
# Bundled into pre-fix.sh and post-fix.sh via fix-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected globals (set by caller or forge_parse_pr_url):
#   REPO_FULL_NAME — plain project path (e.g., "group/project")
#   REPO_ENCODED   — URL-encoded project path (e.g., "group%2Fproject")
#   PR_NUMBER      — merge request IID
#   GITLAB_HOST    — API host (e.g., "gitlab.com")
#
# Expected env vars:
#   PR_URL         — HTML URL of the merge request
#   GITLAB_TOKEN   — GitLab personal/project access token
#
# Token scopes: GITLAB_TOKEN requires minimum scopes:
#   - api (read/write merge requests, labels, notes)

[[ -n "${GITLAB_FIX_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_FIX_OPS_SH_LOADED=1

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
# Also derives the trusted origin (scheme, host, and optional port) from
# CI_SERVER_URL so self-managed instances on non-default HTTPS ports work.
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

# Prints the trusted GitLab origin (https://host[:port]) for API requests
# and generated links. Derived from CI_SERVER_URL, a GitLab CI predefined
# variable that carries any non-default port; falls back to
# https://${CI_SERVER_HOST} when CI_SERVER_URL is unset. Fails closed when
# the origin is not HTTPS or its host does not match CI_SERVER_HOST.
_gitlab_trusted_origin() {
  _validate_gitlab_host "${CI_SERVER_HOST:-}" || return 1
  local origin="${CI_SERVER_URL:-https://${CI_SERVER_HOST}}"
  if [[ ! "${origin}" =~ ^https://([a-zA-Z0-9._-]+)(:[0-9]+)?$ ]]; then
    echo "ERROR: CI_SERVER_URL is not an HTTPS origin (https://host[:port]): $(_gha_sanitize "${origin}")" >&2
    return 1
  fi
  local host="${BASH_REMATCH[1]}"
  _validate_gitlab_host "${host}" || return 1
  printf '%s\n' "${origin}"
}

# Validates an origin (https://host[:port]) parsed from an untrusted URL
# against the trusted CI server origin. Scheme, host, and port must all
# match: a URL without a port only matches a trusted origin without one.
_validate_gitlab_origin() {
  local origin="$1" trusted
  trusted=$(_gitlab_trusted_origin) || return 1
  if [[ "${origin,,}" != "${trusted,,}" ]]; then
    echo "ERROR: GitLab origin '$(_gha_sanitize "${origin}")' does not match CI server origin '$(_gha_sanitize "${trusted}")'" >&2
    return 1
  fi
}
# END bundled: lib/gitlab-host-validation.lib.sh

if ! declare -F gha_echo >/dev/null 2>&1; then
  gha_echo() {
    local lvl="$1"; shift
    local msg="${*//::/ }"
    msg="${msg//%0A/}"; msg="${msg//%0a/}"
    msg="${msg//%0D/}"; msg="${msg//%0d/}"
    printf '::%s::%s\n' "${lvl}" "${msg}"
  }
fi

_gitlab_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  if [[ -z "${GITLAB_HOST:-}" ]]; then
    echo "ERROR: GITLAB_HOST is not set — call forge_parse_pr_url first" >&2
    return 1
  fi
  _validate_gitlab_host "${GITLAB_HOST}" || return 1
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
    "$@"
}

# --- PR/MR operations ---

forge_validate_pr_url() {
  local url="${1:-${PR_URL:-}}"
  if [[ ! "${url}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+){2,}/-/merge_requests/[1-9][0-9]*$ ]]; then
    echo "ERROR: PR_URL does not match expected GitLab MR pattern: $(_gha_sanitize "${url}")" >&2
    return 1
  fi
  local host
  host=$(echo "${url}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  _validate_gitlab_host "${host}" || return 1
}

forge_parse_pr_url() {
  local url="${1:-${PR_URL:-}}"
  GITLAB_HOST=$(echo "${url}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  REPO_FULL_NAME=$(echo "${url}" | sed -E 's|^https://[^/]+/(.+)/-/merge_requests/[0-9]+$|\1|')
  REPO_ENCODED=$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)
  # shellcheck disable=SC2034
  PR_NUMBER=$(basename "${url}")
}

forge_get_pr_head_ref() {
  local pr_number="$1"
  (
    # shellcheck disable=SC2030
    GITLAB_TOKEN="${PUSH_TOKEN:-${GITLAB_TOKEN:-}}"
    _gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${pr_number}" 2>/dev/null
  ) | jq -r '.source_branch // empty'
}

# forge_get_pr_base_branch PR_NUMBER — MR target_branch (not the repo default).
# Empty on API failure; callers fall back to TARGET_BRANCH / main.
forge_get_pr_base_branch() {
  local pr_number="$1"
  (
    # shellcheck disable=SC2030,SC2031
    GITLAB_TOKEN="${PUSH_TOKEN:-${GITLAB_TOKEN:-}}"
    _gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${pr_number}" 2>/dev/null
  ) | jq -r '.target_branch // empty'
}

# forge_get_pr_merge_state PR_NUMBER — GitLab detailed_merge_status, or
# "unknown" when the field is absent / the API fails. Callers must not treat
# not_approved, ci_must_pass, need_rebase, checking, or unknown as a conflict.
forge_get_pr_merge_state() {
  local pr_number="$1"
  local json status
  json="$(
    # shellcheck disable=SC2030,SC2031
    GITLAB_TOKEN="${PUSH_TOKEN:-${GITLAB_TOKEN:-}}"
    _gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${pr_number}" 2>/dev/null
  )" || {
    echo "unknown"
    return 0
  }
  status="$(echo "${json}" | jq -r '.detailed_merge_status // empty')"
  if [ -z "${status}" ]; then
    echo "unknown"
    return 0
  fi
  echo "${status}"
}

# forge_pr_has_merge_conflict PR_NUMBER — return 0 only when GitLab reports
# a real merge conflict. Prefer detailed_merge_status=conflict. Fall back to
# has_conflicts=true only when detailed_merge_status is absent and the older
# merge_status is cannot_be_merged (not checking / unchecked).
forge_pr_has_merge_conflict() {
  local pr_number="$1"
  local json status has_conflicts merge_status
  json="$(
    # shellcheck disable=SC2030,SC2031
    GITLAB_TOKEN="${PUSH_TOKEN:-${GITLAB_TOKEN:-}}"
    _gitlab_api GET "/projects/${REPO_ENCODED}/merge_requests/${pr_number}" 2>/dev/null
  )" || return 1
  status="$(echo "${json}" | jq -r '.detailed_merge_status // empty')"
  if [ "${status}" = "conflict" ]; then
    return 0
  fi
  if [ -n "${status}" ]; then
    return 1
  fi
  has_conflicts="$(echo "${json}" | jq -r '.has_conflicts // false')"
  merge_status="$(echo "${json}" | jq -r '.merge_status // empty')"
  [ "${has_conflicts}" = "true" ] && [ "${merge_status}" = "cannot_be_merged" ]
}

# --- Push operations ---

forge_set_push_remote() {
  local token="$1"
  [[ -n "${GITLAB_HOST:-}" ]] || { echo "ERROR: GITLAB_HOST is not set — call forge_parse_pr_url first" >&2; return 1; }
  _validate_gitlab_host "${GITLAB_HOST}" || return 1
  git remote set-url origin \
    "https://oauth2:${token}@${GITLAB_HOST}/${REPO_FULL_NAME}.git"
}

forge_setup_push_token() {
  local token="$1"
  # shellcheck disable=SC2031
  export GITLAB_TOKEN="${token}"
}

forge_mask_token() {
  # ::add-mask:: is GHA-specific; skip on GitLab CI to avoid printing tokens
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    local token="${1:-${GITLAB_TOKEN:-}}"
    echo "::add-mask::${token}"
  fi
}

# --- Label operations ---

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  local clean_color="${color#\#}"
  _gitlab_api POST "/projects/${REPO_ENCODED}/labels" \
    --data-urlencode "name=${name}" \
    --data-urlencode "description=${description}" \
    --data-urlencode "color=#${clean_color}" > /dev/null 2>/dev/null || true
}

forge_add_pr_label() {
  local pr_number="$1"
  local label="$2"
  _gitlab_api PUT "/projects/${REPO_ENCODED}/merge_requests/${pr_number}" \
    --data-urlencode "add_labels=${label}" > /dev/null 2>/dev/null || true
}

# --- Comment operations ---

forge_post_pr_comment() {
  local mr_iid="$1"
  local body="$2"
  _gitlab_api POST "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}/notes" \
    --data-urlencode "body=${body}" > /dev/null 2>/dev/null
}

# --- Workspace operations ---

forge_get_workflow_run_url() {
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    local run_repo="${GITHUB_REPOSITORY:-${REPO_FULL_NAME}}"
    printf '%s/%s/actions/runs/%s' \
      "${GITHUB_SERVER_URL:-https://github.com}" "${run_repo}" "${GITHUB_RUN_ID}"
    return 0
  fi
  local server_url="${CI_SERVER_URL:-https://gitlab.com}"
  local project_path="${CI_PROJECT_PATH:-${REPO_FULL_NAME}}"
  local pipeline_id="${CI_PIPELINE_ID:-unknown}"
  local job_id="${CI_JOB_ID:-}"
  if [[ -n "${job_id}" ]]; then
    printf '%s/%s/-/jobs/%s' "${server_url}" "${project_path}" "${job_id}"
  else
    printf '%s/%s/-/pipelines/%s' "${server_url}" "${project_path}" "${pipeline_id}"
  fi
}

forge_get_workspace_dir() {
  echo "${CI_PROJECT_DIR:-${GITHUB_WORKSPACE:-}}"
}

forge_append_path() {
  local dir="$1"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "${dir}" >> "${GITHUB_PATH}"
  fi
  # On GitLab CI, PATH is modified directly (already done by caller)
}
# END bundled: lib/gitlab-fix-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac

is_bot_user() {
  if [ "${FULLSEND_FORGE:-}" = "gitlab" ]; then
    [[ "${1:-}" =~ _bot$ ]]
  else
    [[ "${1:-}" =~ \[bot\]$ ]]
  fi
}

# is_human_rebase_request INSTRUCTION — true if a harness-captured human
# /fs-fix instruction asked for a rebase or merge-conflict resolution (see
# agents/fix.md's "Rebase onto the target branch" and docs/fix.md's
# "Rebasing a stale PR"). The instruction text is HUMAN_INSTRUCTION, which
# the triggering workflow sets from the literal PR/MR comment before the
# sandbox is created — the fix agent cannot alter it during its own run,
# unlike agent-result.json (PR #1296 auth-bypass finding: a non-bot
# TRIGGER_SOURCE alone does not prove the run's instruction was a rebase
# request, so callers must check this in addition to TRIGGER_SOURCE).
is_human_rebase_request() {
  local instruction
  instruction="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "${instruction}" == *"rebase"* || "${instruction}" == *"merge conflict"* ]]
}

# is_human_squash_request INSTRUCTION — true if a harness-captured human
# /fs-fix instruction asked to squash fix-agent commits (see
# agents/fix.md's "Rewrite fix-agent history" and docs/fix.md's
# "Squashing or redoing fix-agent commits"). Same trust boundary as
# is_human_rebase_request: HUMAN_INSTRUCTION is set from the literal
# PR/MR comment before the sandbox exists.
is_human_squash_request() {
  local instruction
  instruction="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "${instruction}" == *"squash"* ]]
}

# is_human_reset_request INSTRUCTION — true if a harness-captured human
# /fs-fix instruction asked to redo the fix-agent work from scratch or
# start over. Matches the phrases in agents/fix.md; bare "reset" is not
# enough (too generic).
is_human_reset_request() {
  local instruction
  instruction="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "${instruction}" == *"from scratch"* \
    || "${instruction}" == *"start over"* \
    || "${instruction}" == *"redo"* ]]
}

# is_human_history_rewrite_request INSTRUCTION — squash or redo/reset.
# Used by the post-script to authorize skipping replay onto origin/BRANCH
# after the agent rewrote the authorized fix-agent range.
is_human_history_rewrite_request() {
  is_human_squash_request "${1:-}" || is_human_reset_request "${1:-}"
}

# fix_conflict_update_strategy — prints merge or rebase.
# FIX_CONFLICT_UPDATE_STRATEGY is the harness-configured reconciliation
# strategy used when the forge reports a real merge conflict (issue #1518).
# Empty/unset and unrecognized values fall back to merge, which preserves
# existing PR/MR commit history. rebase rewrites the branch onto the target.
fix_conflict_update_strategy() {
  local raw
  raw="$(printf '%s' "${FIX_CONFLICT_UPDATE_STRATEGY:-merge}" | tr '[:upper:]' '[:lower:]')"
  case "${raw}" in
    rebase) printf '%s\n' "rebase" ;;
    *) printf '%s\n' "merge" ;;
  esac
}

# fix_conflict_update_strategy_raw_is_known — true when the configured
# value is empty (default) or a supported enum member. Used to warn on typos
# without failing the run.
fix_conflict_update_strategy_raw_is_known() {
  local raw
  raw="$(printf '%s' "${FIX_CONFLICT_UPDATE_STRATEGY:-}" | tr '[:upper:]' '[:lower:]')"
  [ -z "${raw}" ] || [ "${raw}" = "merge" ] || [ "${raw}" = "rebase" ]
}
# END bundled: lib/fix-ops.lib.sh

errors=0

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
if [[ ! "${PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
  gha_echo error "PR_NUMBER must be a positive integer, got: '${PR_NUMBER:-}'"
  errors=$((errors + 1))
fi

if [ "${FULLSEND_FORGE:-}" = "github" ]; then
  if [[ ! "${REPO_FULL_NAME:-}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
    gha_echo error "REPO_FULL_NAME must be owner/repo format, got: '${REPO_FULL_NAME:-}'"
    errors=$((errors + 1))
  fi
else
  if [[ ! "${REPO_FULL_NAME:-}" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+$ ]]; then
    gha_echo error "REPO_FULL_NAME must be owner/repo (or group/subgroup/project) format, got: '${REPO_FULL_NAME:-}'"
    errors=$((errors + 1))
  fi
fi
if [[ "${REPO_FULL_NAME:-}" =~ (^|/)\.\.?(/|$) ]]; then
  gha_echo error "REPO_FULL_NAME must not contain '.' or '..' path segments, got: '${REPO_FULL_NAME:-}'"
  errors=$((errors + 1))
fi

if [[ -z "${TRIGGER_SOURCE:-}" ]]; then
  gha_echo error "TRIGGER_SOURCE is required (forge username that triggered the fix)"
  errors=$((errors + 1))
fi

# GitLab: validate PR_URL format, host allowlist, and cross-check against inputs
if [ "${FULLSEND_FORGE:-}" = "gitlab" ]; then
  if [[ -z "${PR_URL:-}" ]]; then
    gha_echo error "PR_URL is required for GitLab forge"
    errors=$((errors + 1))
  elif ! forge_validate_pr_url "${PR_URL}"; then
    gha_echo error "PR_URL format/host invalid, got: '${PR_URL}'"
    errors=$((errors + 1))
  else
    _url_repo="$(echo "${PR_URL}" | sed -E 's|^https://[^/]+/(.+)/-/merge_requests/[0-9]+$|\1|')"
    _url_pr="$(basename "${PR_URL}")"
    if [[ -n "${_url_repo}" && "${_url_repo}" != "${REPO_FULL_NAME:-}" ]]; then
      gha_echo error "REPO_FULL_NAME does not match PR URL repo ('${REPO_FULL_NAME:-}' vs '${_url_repo}')"
      errors=$((errors + 1))
    fi
    if [[ -n "${_url_pr}" && "${_url_pr}" != "${PR_NUMBER:-}" ]]; then
      gha_echo error "PR_NUMBER does not match PR URL number ('${PR_NUMBER:-}' vs '${_url_pr}')"
      errors=$((errors + 1))
    fi
  fi
fi

if [[ "${errors}" -gt 0 ]]; then
  gha_echo error "Input validation failed with ${errors} error(s). Aborting."
  exit 1
fi

# ---------------------------------------------------------------------------
# Human instruction length cap (defense against DoS via oversized input)
# ---------------------------------------------------------------------------
MAX_INSTRUCTION_BYTES=10000
if ! is_bot_user "${TRIGGER_SOURCE}" && [[ -n "${HUMAN_INSTRUCTION:-}" ]]; then
  INSTRUCTION_LEN="${#HUMAN_INSTRUCTION}"
  if [[ "${INSTRUCTION_LEN}" -gt "${MAX_INSTRUCTION_BYTES}" ]]; then
    gha_echo error "HUMAN_INSTRUCTION is ${INSTRUCTION_LEN} bytes (max: ${MAX_INSTRUCTION_BYTES}). Truncate the instruction."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Iteration cap check
# ---------------------------------------------------------------------------
ITERATION="${FIX_ITERATION:-1}"
BOT_CAP="${ITERATION_CAP:-5}"
HUMAN_CAP="${ITERATION_CAP_HUMAN:-10}"

if is_bot_user "${TRIGGER_SOURCE}"; then
  CAP="${BOT_CAP}"
else
  CAP="${HUMAN_CAP}"
fi

if [[ "${ITERATION}" -gt "${CAP}" ]]; then
  if is_bot_user "${TRIGGER_SOURCE}"; then
    gha_echo error "Fix iteration ${ITERATION} exceeds bot cap of ${CAP}. Escalating to human."
    gha_echo error "The review→fix loop has run ${ITERATION} times without converging."
    gha_echo error "A human can still direct the agent with /fs-fix (up to ${HUMAN_CAP} total iterations)."
  else
    gha_echo error "Fix iteration ${ITERATION} exceeds human cap of ${CAP}."
    gha_echo error "The /fs-fix loop has run ${ITERATION} times. Further attempts are blocked."
  fi
  exit 1
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "Input validation passed:"
echo "  PR_NUMBER=${PR_NUMBER}"
echo "  REPO_FULL_NAME=${REPO_FULL_NAME}"
echo "  TRIGGER_SOURCE=${TRIGGER_SOURCE}"
echo "  FULLSEND_FORGE=${FULLSEND_FORGE:-github}"
echo "  FIX_ITERATION=${ITERATION} of ${CAP}"
if ! is_bot_user "${TRIGGER_SOURCE}" && [[ -n "${HUMAN_INSTRUCTION:-}" ]]; then
  # Truncate instruction in logs to avoid leaking long user input.
  INSTR_PREVIEW="${HUMAN_INSTRUCTION:0:200}"
  echo "  HUMAN_INSTRUCTION=${INSTR_PREVIEW}..."
fi

# ---------------------------------------------------------------------------
# Auto-detect and install pre-commit tool dependencies
# ---------------------------------------------------------------------------
# Ensures tools required by the target repo's pre-commit hooks are
# available on the runner for the authoritative post-script check.
WORKSPACE_DIR="$(forge_get_workspace_dir)"
TARGET_REPO="${REPO_DIR:-${WORKSPACE_DIR:-.}/target-repo}"

# _prefix_redact_literal_token <text> <token> — redact every literal
# occurrence of <token> in <text>, printed to stdout. Used where a runner
# credential could reach a log line and GHA's own ::add-mask:: masking
# (forge_mask_token) does not apply (GitLab CI). Plain bash
# ${text//${token}/repl} is not safe here: parameter-expansion replacement
# treats the pattern as a glob, so a token containing *, ?, or [ would over-
# or under-match instead of being matched literally.
_prefix_redact_literal_token() {
  local text="$1" token="$2"
  if [ -z "${token}" ]; then
    printf '%s' "${text}"
    return 0
  fi
  REDACT_LITERAL_TOKEN="${token}" awk '
    BEGIN { token = ENVIRON["REDACT_LITERAL_TOKEN"]; repl = "[REDACTED]" }
    {
      s = $0
      while ((i = index(s, token)) > 0) {
        s = substr(s, 1, i - 1) repl substr(s, i + length(token))
      }
      print s
    }
  ' <<< "${text}"
}

# ---------------------------------------------------------------------------
# Forge merge-conflict detection (issue #1518)
#
# Query the PR/MR's native mergeability. Only a positive conflict signal
# (GitHub mergeable=CONFLICTING, GitLab detailed_merge_status=conflict)
# causes us to fetch the latest target branch into the checkout the sandbox
# will see. Approval/check gating, a merely stale branch, unknown, and API
# failures are not conflicts and must not trigger a fetch/merge/rebase.
# ---------------------------------------------------------------------------
if [ "${FULLSEND_FORGE:-}" = "gitlab" ] && [ -n "${PR_URL:-}" ]; then
  # GITLAB_HOST / REPO_ENCODED are required by gitlab-fix-ops API helpers.
  # Validation above already confirmed PR_URL matches REPO_FULL_NAME / PR_NUMBER.
  forge_parse_pr_url "${PR_URL}"
fi

if ! fix_conflict_update_strategy_raw_is_known; then
  gha_echo warning "Unknown FIX_CONFLICT_UPDATE_STRATEGY='${FIX_CONFLICT_UPDATE_STRATEGY}' — defaulting to merge"
fi
FIX_CONFLICT_STRATEGY="$(fix_conflict_update_strategy)"

FORGE_PR_BASE_BRANCH="$(forge_get_pr_base_branch "${PR_NUMBER}" 2>/dev/null || true)"
if [ -z "${FORGE_PR_BASE_BRANCH}" ]; then
  FORGE_PR_BASE_BRANCH="${TARGET_BRANCH:-main}"
  echo "Could not read PR/MR base branch from forge — using ${FORGE_PR_BASE_BRANCH}"
fi

FORGE_PR_MERGE_STATE="$(forge_get_pr_merge_state "${PR_NUMBER}" 2>/dev/null || echo unknown)"
FORGE_PR_HAS_CONFLICT=false
if forge_pr_has_merge_conflict "${PR_NUMBER}"; then
  FORGE_PR_HAS_CONFLICT=true
fi

echo "Forge mergeability:"
echo "  base_branch=${FORGE_PR_BASE_BRANCH}"
echo "  merge_state=${FORGE_PR_MERGE_STATE}"
echo "  conflict=${FORGE_PR_HAS_CONFLICT}"
echo "  strategy=${FIX_CONFLICT_STRATEGY}"

if [ "${FORGE_PR_HAS_CONFLICT}" = "true" ]; then
  # Assign directly into TARGET_BRANCH (mirroring post-fix.src.sh) so the
  # pre-commit tool base-branch resolution below (which reads TARGET_BRANCH)
  # uses the resolved PR/MR base instead of falling back to origin/HEAD.
  # Scoped to the conflict-reconciliation path only, matching
  # post-fix.src.sh's own scope-creep fix — TARGET_BRANCH must keep coming
  # from harness config on ordinary (non-conflict) runs.
  TARGET_BRANCH="${FORGE_PR_BASE_BRANCH}"

  if [ -d "${TARGET_REPO}/.git" ] || [ -f "${TARGET_REPO}/.git" ]; then
    echo "Fetching latest target branch ${FORGE_PR_BASE_BRANCH} for conflict reconciliation..."
    # TARGET_REPO is the checkout the runner mounts into the sandbox
    # (docs/fix.md) — PUSH_TOKEN must never persist there (post-fix.src.sh's
    # "Token isolation: PUSH_TOKEN never enters the sandbox" contract). Save
    # the pre-existing origin URL and restore it right after the fetch,
    # regardless of whether the fetch succeeds, instead of leaving the
    # credentialed URL in .git/config.
    _restore_origin_url=""
    if [ -n "${PUSH_TOKEN:-}" ]; then
      # Mask before the credentialed URL can ever reach a log line — matches
      # post-fix.src.sh, which masks PUSH_TOKEN before its own credentialed
      # fetch. Without this, a git error that prints the remote URL below
      # would not be redacted in GHA logs.
      forge_mask_token "${PUSH_TOKEN}"
      _restore_origin_url="$(git -C "${TARGET_REPO}" remote get-url origin 2>/dev/null || true)"
      if ! (cd "${TARGET_REPO}" && forge_set_push_remote "${PUSH_TOKEN}"); then
        gha_echo warning "Could not set authenticated origin URL before fetching ${FORGE_PR_BASE_BRANCH}"
        _restore_origin_url=""
      fi
    fi
    # Capture stdout/stderr instead of letting the fetch write straight to
    # the job log: forge_mask_token's ::add-mask:: above only redacts on
    # GitHub Actions (GITHUB_ACTIONS=true) — gitlab-fix-ops.lib.sh's
    # forge_mask_token is a documented no-op otherwise — so on GitLab a git
    # error that echoes the credentialed remote URL would reach the job log
    # verbatim. Redact the literal PUSH_TOKEN value (including any
    # URL-embedded form) ourselves before printing, matching
    # post-fix.src.sh's print_sanitized_gha_log discipline around its own
    # target-branch fetch.
    if _conflict_fetch_output="$(git -C "${TARGET_REPO}" fetch origin "+refs/heads/${FORGE_PR_BASE_BRANCH}:refs/remotes/origin/${FORGE_PR_BASE_BRANCH}" 2>&1)"; then
      _conflict_fetch_rc=0
    else
      _conflict_fetch_rc=$?
    fi
    if [ -n "${_conflict_fetch_output}" ]; then
      if [ -n "${PUSH_TOKEN:-}" ]; then
        # Not `${_conflict_fetch_output//${PUSH_TOKEN}/[REDACTED]}`: bash
        # parameter-expansion replacement treats the pattern as a glob, so a
        # token containing *, ?, or [ would over- or under-match instead of
        # being matched literally.
        _conflict_fetch_output="$(_prefix_redact_literal_token "${_conflict_fetch_output}" "${PUSH_TOKEN}")"
      fi
      echo "${_conflict_fetch_output}"
    fi
    if [ "${_conflict_fetch_rc}" -eq 0 ]; then
      _conflict_target_sha="$(git -C "${TARGET_REPO}" rev-parse "refs/remotes/origin/${FORGE_PR_BASE_BRANCH}" 2>/dev/null || true)"
      echo "Fetched origin/${FORGE_PR_BASE_BRANCH} (${_conflict_target_sha}) before fix validation"
    else
      gha_echo warning "Could not fetch target branch ${FORGE_PR_BASE_BRANCH} — sandbox may not have the latest tip"
    fi
    if [ -n "${_restore_origin_url}" ]; then
      # Fatal, not warn-and-continue: TARGET_REPO is mounted into the sandbox,
      # so a failed restore would leave the credentialed origin URL in a
      # checkout the sandbox can read, contradicting the token-isolation
      # contract above.
      if ! git -C "${TARGET_REPO}" remote set-url origin "${_restore_origin_url}"; then
        gha_echo error "Could not restore original origin URL for ${TARGET_REPO} after fetch — refusing to continue with a credentialed origin URL mounted into the sandbox"
        exit 1
      fi
    fi
  else
    gha_echo warning "Target repo not found at ${TARGET_REPO} — skipping target-branch fetch"
  fi
fi

RESOLVE_SCRIPT="${SCRIPT_DIR}/resolve-precommit-tools.py"
INSTALL_SCRIPT="${SCRIPT_DIR}/install-precommit-tools.sh"

# Fallback: these companion scripts were never migrated into this repo
# during the ADR 0058 extraction, so the BASH_SOURCE-relative lookup above
# always misses. The reusable workflow's "Prepare workspace" step always
# materializes the full scripts/ directory (from fullsend's own scaffold)
# at ${WORKSPACE_DIR}/scripts/ (per-org) or ${WORKSPACE_DIR}/.fullsend/scripts/
# (per-repo). Try those paths when the BASH_SOURCE-relative lookup misses.
if [ ! -f "${RESOLVE_SCRIPT}" ] || [ ! -f "${INSTALL_SCRIPT}" ]; then
  if [ -n "${WORKSPACE_DIR:-}" ]; then
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
  gha_echo warning "Pre-commit tool auto-install skipped: companion scripts not found"
  gha_echo warning "Expected ${RESOLVE_SCRIPT} and ${INSTALL_SCRIPT}"
  gha_echo warning "Pre-commit hooks requiring system tools (e.g. lychee) may fail"
fi

if [ -f "${TARGET_REPO}/.pre-commit-config.yaml" ] \
   && [ -f "${RESOLVE_SCRIPT}" ] \
   && [ -f "${INSTALL_SCRIPT}" ]; then
  echo "Resolving pre-commit tool dependencies..."
  MANIFEST="$(mktemp)"
  LOCAL_REG="$(mktemp)"
  RESOLVE_ARGS=("${TARGET_REPO}")
  _BASE_BR="${TARGET_BRANCH:-}"
  if [ -z "${_BASE_BR}" ]; then
    _BASE_BR="$(git -C "${TARGET_REPO}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')" || _BASE_BR=""
  fi
  if [ -n "${_BASE_BR}" ] \
     && git -C "${TARGET_REPO}" show "origin/${_BASE_BR}:.pre-commit-tools.yaml" > "${LOCAL_REG}" 2>/dev/null; then
    RESOLVE_ARGS+=("--local-registry" "${LOCAL_REG}")
  fi
  if python3 "${RESOLVE_SCRIPT}" "${RESOLVE_ARGS[@]}" > "${MANIFEST}"; then
    if [ -s "${MANIFEST}" ] && jq -e '.tools | length > 0' "${MANIFEST}" >/dev/null 2>&1; then
      bash "${INSTALL_SCRIPT}" "${MANIFEST}"
    else
      echo "No additional pre-commit tools needed"
    fi
  else
    gha_echo warning "Pre-commit tool resolution failed — continuing without auto-install"
  fi
  rm -f "${MANIFEST}" "${LOCAL_REG}"
fi
export PATH="${HOME}/.local/bin:${PATH}"
forge_append_path "${HOME}/.local/bin"
