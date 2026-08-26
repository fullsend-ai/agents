#!/usr/bin/env bash
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
source "${SCRIPT_DIR}/lib/fix-ops.lib.sh"
# shellcheck source=lib/fix-budget.lib.sh
source "${SCRIPT_DIR}/lib/fix-budget.lib.sh"

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
