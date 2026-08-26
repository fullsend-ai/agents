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
#   PR_LABELS          — newline-separated PR labels; a `fullsend-fix-budget/N`
#                        label may tighten (never raise) the iteration cap
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
# END bundled: lib/fix-ops.lib.sh
# shellcheck source=lib/fix-budget.lib.sh
# BEGIN bundled: lib/fix-budget.lib.sh
# shellcheck shell=bash
# fix-budget.lib.sh — parse a per-PR fix-loop budget from PR labels.
#
# A label of the form `fullsend-fix-budget/N` (N a positive integer) lets a
# maintainer cap the review->fix loop for a single PR below the global
# iteration cap. The label can only TIGHTEN the cap, never raise it:
# enforcement lives in pre-fix, which applies min(label_budget, cap).
#
# Bundled into pre-fix.sh via bundle-sh.sh.
#
# Expected env vars (optional):
#   PR_LABELS — PR label names separated by commas and/or newlines. Absent/empty
#               is fine: parse_fix_budget then returns nothing and the cap is
#               unchanged. (The upstream dispatcher comma-joins labels; a
#               newline-joined value is also accepted.)

[[ -n "${FIX_BUDGET_SH_LOADED:-}" ]] && return 0
FIX_BUDGET_SH_LOADED=1

FIX_BUDGET_LABEL_PREFIX="fullsend-fix-budget/"

# parse_fix_budget [labels]
# Reads label names (arg 1, or PR_LABELS env when omitted) separated by commas
# and/or newlines. Echoes the smallest valid budget found, or nothing when no
# valid label is present. A malformed value (non-integer, zero, negative) is
# ignored, not fatal — a bad label must not silently drop the existing cap.
parse_fix_budget() {
  local labels="${1-${PR_LABELS:-}}"
  local best="" label n
  # Accept comma-joined labels (the upstream dispatcher format) as well as
  # newline-joined: normalize commas to newlines before splitting.
  labels="${labels//,/$'\n'}"
  while IFS= read -r label; do
    # Trim surrounding whitespace so " fullsend-fix-budget/3 " still matches.
    label="${label#"${label%%[![:space:]]*}"}"
    label="${label%"${label##*[![:space:]]}"}"
    [[ "${label}" == "${FIX_BUDGET_LABEL_PREFIX}"* ]] || continue
    n="${label#"${FIX_BUDGET_LABEL_PREFIX}"}"
    # Bound the digit count. An arbitrarily long value would overflow Bash's
    # signed 64-bit arithmetic in the `-lt` comparison (e.g. 2^64 evaluates as
    # 0), which would look "tighter" than any cap and block every fix run.
    # A budget above 99999 is meaningless next to caps of 5/10, so treat an
    # over-long value as malformed and ignore it.
    [[ "${n}" =~ ^[1-9][0-9]{0,4}$ ]] || continue
    if [[ -z "${best}" || "${n}" -lt "${best}" ]]; then
      best="${n}"
    fi
  done <<< "${labels}"
  [[ -n "${best}" ]] && printf '%s\n' "${best}"
  return 0
}
# END bundled: lib/fix-budget.lib.sh

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

# A per-PR `fullsend-fix-budget/N` label may tighten either cap (never raise it).
# Apply it to both caps before selecting one, so the human cap referenced in the
# bot-escalation message below reflects the same effective budget.
FIX_BUDGET="$(parse_fix_budget "${PR_LABELS:-}")"
if [[ -n "${FIX_BUDGET}" ]]; then
  [[ "${FIX_BUDGET}" -lt "${BOT_CAP}" ]] && BOT_CAP="${FIX_BUDGET}"
  [[ "${FIX_BUDGET}" -lt "${HUMAN_CAP}" ]] && HUMAN_CAP="${FIX_BUDGET}"
fi

if is_bot_user "${TRIGGER_SOURCE}"; then
  CAP="${BOT_CAP}"
else
  CAP="${HUMAN_CAP}"
fi

if [[ -n "${FIX_BUDGET}" && "${FIX_BUDGET}" -eq "${CAP}" ]]; then
  gha_echo notice "PR label ${FIX_BUDGET_LABEL_PREFIX}${FIX_BUDGET} caps the fix loop at ${CAP} iteration(s)."
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
