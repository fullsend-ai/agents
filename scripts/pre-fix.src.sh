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
#                      A live `fullsend-fix-budget/N` PR label can lower the
#                      bot cap (never the human cap) for one PR.
#   HUMAN_INSTRUCTION  — instruction text (only for human-triggered runs)
#   FIX_CONFLICT_UPDATE_STRATEGY
#                      — merge (default) or rebase; how to publish a
#                        forge-reported merge conflict the agent reconciled
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${FULLSEND_FORGE:?FULLSEND_FORGE is required — set to 'github' or 'gitlab'}"
# shellcheck source=lib/fix-ops.lib.sh
source "${SCRIPT_DIR}/lib/fix-ops.lib.sh"

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

if [ "${FULLSEND_FORGE:-}" = "gitlab" ] && [ -n "${PR_URL:-}" ]; then
  # GITLAB_HOST / REPO_ENCODED are required by gitlab-fix-ops API helpers.
  # Validation above already confirmed PR_URL matches REPO_FULL_NAME / PR_NUMBER.
  forge_parse_pr_url "${PR_URL}"
fi

# Per-PR automatic fix budget (issue #1680): a maintainer-set
# fullsend-fix-budget/N label can only lower the bot cap. Human /fs-fix runs
# keep ITERATION_CAP_HUMAN. Labels are read live from the forge; if the read
# fails the budget is ignored and the configured bot cap applies.
FIX_BUDGET=""
if is_bot_user "${TRIGGER_SOURCE}"; then
  if PR_LABELS_LIVE="$(forge_get_pr_labels "${PR_NUMBER}")"; then
    FIX_BUDGET="$(fix_budget_from_labels "${PR_LABELS_LIVE}" "${BOT_CAP}")"
  else
    gha_echo warning "Could not read PR labels — any fullsend-fix-budget/N label is ignored for this run"
  fi
  CAP="${FIX_BUDGET:-${BOT_CAP}}"
  if [ -n "${FIX_BUDGET}" ]; then
    echo "Label fullsend-fix-budget/${FIX_BUDGET} lowers the automatic fix cap from ${BOT_CAP} to ${FIX_BUDGET}"
  fi
else
  CAP="${HUMAN_CAP}"
fi

if [[ "${ITERATION}" -gt "${CAP}" ]]; then
  if is_bot_user "${TRIGGER_SOURCE}"; then
    if [ -n "${FIX_BUDGET}" ]; then
      gha_echo error "Fix iteration ${ITERATION} exceeds the per-PR automatic fix budget of ${CAP} set by label fullsend-fix-budget/${FIX_BUDGET}. Escalating to human."
    else
      gha_echo error "Fix iteration ${ITERATION} exceeds bot cap of ${CAP}. Escalating to human."
    fi
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
