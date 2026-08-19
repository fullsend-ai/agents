#!/usr/bin/env bash
# Post-script: push the agent's commit and create a PR/MR.
#
# Runs on the CI runner AFTER the sandbox is destroyed.
# This script has write access to the target repo — it is the most
# security-sensitive component in the pipeline.
#
# Security layers (defense-in-depth):
#   1. Authoritative secret scan — final gate before any push
#   2. Authoritative pre-commit — run repo hooks on changed files
#   3. Branch validation — refuse to push main/master
#   4. Token isolation — PUSH_TOKEN never enters the sandbox
#
# Pre-commit tool deps are auto-installed from .pre-commit-tools.yaml
# before step 2 to ensure hooks have the binaries they need.
#
# Protected-path enforcement lives in post-review.sh: the review agent
# cannot approve PRs that touch sensitive paths (e.g. .github/, CODEOWNERS,
# agents/). The code agent is free to propose changes to any path.
#
# Required environment variables:
#   PUSH_TOKEN        — token with write scopes on target repo
#                       GitHub: contents:write + issues:write + pull-requests:write
#                       GitLab: api scope (project or personal access token)
#   REPO_FULL_NAME    — owner/repo or group/project path
#   ISSUE_NUMBER      — issue number (GitHub) or IID (GitLab)
#   FULLSEND_FORGE    — "github" or "gitlab"
#   REPO_DIR          — path to extracted repo (default: current directory)
#
# Optional environment variables:
#   PUSH_TOKEN_SOURCE — "github-app" (for logging; default: unknown)
#   CODE_ALLOWED_TARGET_BRANCHES
#                     — comma-separated list of branches the agent may target,
#                       or "*" for any. When unset, only the repo's default
#                       branch is allowed. (default: auto-detected)
#   CODE_NEEDS_INPUT_LABEL
#                     — label applied when the agent sets needs_input instead
#                       of committing. Forwarded from the runner environment
#                       via env.runner in harness/code.yaml. The script
#                       defaults when unset. (default: fs-code-needs-input)
#   POST_FAILURE_DETAIL_MAX_LINES
#                     — max lines of failure detail in issue/PR comments (default: 30)
#   CODE_AUTO_MERGE    — "true" to enable auto-merge on the PR/MR after
#                        creation. (default: "" — disabled)
#   CODE_AUTO_MERGE_METHOD
#                      — merge method for auto-merge: "squash", "rebase", or
#                        "merge". When unset, auto-detected from the repo's
#                        allowed merge methods (prefers squash). Ignored
#                        unless CODE_AUTO_MERGE is "true". Omitted
#                        automatically when target branch uses a merge queue.
#                        (default: auto-detected)
#
# Exit codes:
#   0  — branch pushed and PR/MR created, OR agent determined nothing to do
#   1  — validation failure or error (nothing pushed)
set -euo pipefail

SCRIPT_DIR_POST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/post-failure-report.lib.sh
source "${SCRIPT_DIR_POST}/lib/post-failure-report.lib.sh"
# shellcheck source=lib/gitleaks-install.lib.sh
source "${SCRIPT_DIR_POST}/lib/gitleaks-install.lib.sh"
# shellcheck source=lib/pr-assignee.lib.sh
source "${SCRIPT_DIR_POST}/lib/pr-assignee.lib.sh"
# shellcheck source=lib/branch-guard.lib.sh
source "${SCRIPT_DIR_POST}/lib/branch-guard.lib.sh"

# SCRIPT_DIR is used by code-ops.lib.sh dispatcher to locate forge-specific
# ops libraries. Not directly referenced in this file.
# shellcheck disable=SC2034
SCRIPT_DIR="${SCRIPT_DIR_POST}"
# shellcheck source=lib/code-ops.lib.sh
source "${SCRIPT_DIR_POST}/lib/code-ops.lib.sh"
# shellcheck source=lib/labels.lib.sh
source "${SCRIPT_DIR_POST}/lib/labels.lib.sh"

# ---------------------------------------------------------------------------
# enable_auto_merge — arm auto-merge on a PR/MR (best-effort).
#
# Guards:
#   - GitHub: PR must be in BLOCKED state (requires branch protection)
#   - GitHub: For existing PRs: skips if auto-merge is already enabled
#   - GitLab: Uses merge_when_pipeline_succeeds
#
# Merge method resolution (GitHub-specific):
#   1. If target branch has a merge queue → omit method flag (gh negotiates)
#   2. If CODE_AUTO_MERGE_METHOD is set → use it (warn on unknown values)
#   3. Otherwise → auto-detect from repo's allowed merge methods (prefer squash)
#
# Usage: enable_auto_merge <target_pr> <repo> [existing]
# Note: parameter is target_pr (not pr_number) to avoid SC2153 against PR_NUMBER.
# ---------------------------------------------------------------------------
enable_auto_merge() {
  local target_pr="$1"
  local _repo="$2"  # accepted for interface parity; forge ops use REPO_FULL_NAME
  local is_existing="${3:-}"

  if [ "${CODE_AUTO_MERGE:-}" != "true" ]; then
    return 0
  fi

  if [ "${FULLSEND_FORGE}" = "gitlab" ]; then
    echo "Auto-merge: enabling merge_when_pipeline_succeeds on MR !${target_pr}..."
    forge_enable_auto_merge "${target_pr}" ""
    return 0
  fi

  # GitHub-specific merge state checks
  local pr_json merge_state
  local _am_attempt
  for _am_attempt in 1 2 3; do
    pr_json="$(forge_get_pr_details "${target_pr}" "mergeStateStatus,autoMergeRequest,baseRefName")" || true
    if [ -z "${pr_json}" ]; then
      gha_echo warning "Auto-merge: could not query PR #${target_pr} — skipping"
      return 0
    fi

    merge_state="$(echo "${pr_json}" | jq -r '.mergeStateStatus // "UNKNOWN"')"
    if [ "${merge_state}" != "UNKNOWN" ]; then
      break
    fi
    if [ "${_am_attempt}" -lt 3 ]; then
      echo "Auto-merge: merge state is UNKNOWN (attempt ${_am_attempt}/3) — retrying in 5s..."
      sleep 5
    fi
  done

  case "${merge_state}" in
    BLOCKED) ;;
    UNKNOWN)
      gha_echo warning "Auto-merge: could not determine PR merge state after 3 attempts — skipping"
      return 0
      ;;
    *)
      gha_echo warning "Auto-merge: PR #${target_pr} is immediately mergeable (state: ${merge_state}) — skipping. Requires branch protection with required reviews or status checks."
      return 0
      ;;
  esac

  # Guard: for existing PRs, don't re-arm if auto-merge is already set.
  if [ "${is_existing}" = "existing" ]; then
    local am_request
    am_request="$(echo "${pr_json}" | jq -r '.autoMergeRequest // empty')"
    if [ -n "${am_request}" ]; then
      echo "Auto-merge already enabled on PR #${target_pr} — skipping"
      return 0
    fi
  fi

  # Resolve merge method flag.
  local method_flag=""
  local base_branch
  base_branch="$(echo "${pr_json}" | jq -r '.baseRefName // "main"')"

  # Check for merge queue on the target branch — omit method flag if present.
  local mq_id
  mq_id="$(forge_check_merge_queue "${base_branch}")"

  if [ -n "${mq_id}" ]; then
    echo "Auto-merge: merge queue detected on ${base_branch} — omitting method flag"
  else
    local method="${CODE_AUTO_MERGE_METHOD:-}"
    if [ -z "${method}" ]; then
      local repo_info
      repo_info="$(forge_get_repo_merge_methods)"
      if [ -n "${repo_info}" ]; then
        if [ "$(echo "${repo_info}" | jq -r '.s')" = "true" ]; then method="squash"
        elif [ "$(echo "${repo_info}" | jq -r '.m')" = "true" ]; then method="merge"
        elif [ "$(echo "${repo_info}" | jq -r '.r')" = "true" ]; then method="rebase"
        else method="merge"
        fi
      else
        method="merge"
      fi
    fi

    case "${method}" in
      squash) method_flag="--squash" ;;
      rebase) method_flag="--rebase" ;;
      merge)  method_flag="--merge"  ;;
      *)
        gha_echo warning "Unknown CODE_AUTO_MERGE_METHOD='${method}' — defaulting to --merge"
        method_flag="--merge"
        ;;
    esac
  fi

  echo "Auto-merge: enabling on PR #${target_pr}${method_flag:+ (${method_flag})}..."
  forge_enable_auto_merge "${target_pr}" "${method_flag}"
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
REPO_DIR="${REPO_DIR:-repo}"
RUN_DIR="$(pwd)"

: "${PUSH_TOKEN:?PUSH_TOKEN is required}"
echo "::add-mask::${PUSH_TOKEN}"
if [ -n "${GITLAB_TOKEN:-}" ]; then
  echo "::add-mask::${GITLAB_TOKEN}"
fi
: "${REPO_FULL_NAME:?REPO_FULL_NAME is required}"
: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
trap 'report_post_failure_to_issue' ERR

[[ "${ISSUE_NUMBER}" =~ ^[1-9][0-9]*$ ]] || \
  post_fail_to_issue setup-error "ISSUE_NUMBER must be numeric, got '${ISSUE_NUMBER}'"

if [ "${REPO_DIR}" != "." ]; then
  if [ ! -d "${REPO_DIR}" ]; then
    gha_echo error "Extracted repo not found at ${REPO_DIR}" >&2
    post_fail_to_issue setup-error "Extracted repo not found at ${REPO_DIR}"
  fi
  cd "${REPO_DIR}"
fi

# GitLab needs REPO_ENCODED and GITLAB_HOST for API calls.
# Always derive GITLAB_HOST from the validated ISSUE_URL. If GITLAB_HOST is
# pre-set in the environment, verify it matches the URL host to prevent
# token exfiltration to an unintended host.
if [ "${FULLSEND_FORGE}" = "gitlab" ]; then
  if ! forge_validate_issue_url "${ISSUE_URL:-}"; then
    gha_echo error "ISSUE_URL format invalid for GitLab: '${ISSUE_URL:-}'"
    exit 1
  fi
  # shellcheck disable=SC2034
  REPO_ENCODED="$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)"
  # Derive GITLAB_HOST from ISSUE_URL first, then compare against any pre-set
  # value. Using exit 1 (not post_fail_to_issue) avoids sending PRIVATE-TOKEN
  # to the mismatched host.
  _url_host="$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')"
  if [[ -n "${GITLAB_HOST:-}" && "${GITLAB_HOST}" != "${_url_host}" ]]; then
    gha_echo error "GITLAB_HOST '${GITLAB_HOST}' does not match issue URL host '${_url_host}'"
    exit 1
  fi
  GITLAB_HOST="${_url_host}"
fi

# ---------------------------------------------------------------------------
# Needs-input comment helper
#
# Posts a comment on the source issue, applies the needs-input label, and
# removes ready-to-code when the agent stops before implementing a fix
# because it needs human input (broken tooling or a genuinely
# uninterpretable issue). Defined here — before branch validation, before
# any git/gh-branch/secret-scan work — since the early-exit check that uses
# it must run first. Best-effort — a failure to post does not change the
# exit code.
# ---------------------------------------------------------------------------
post_needs_input_comment() {
  local needs_input="$1"
  local safe_issue_number
  safe_issue_number="$(_sanitize_workflow_value "${ISSUE_NUMBER}")"

  _post_failure_ensure_token

  local label="${CODE_NEEDS_INPUT_LABEL:-fs-code-needs-input}"
  # Defense-in-depth: validate the label name against a safe-charset regex
  # before using it in API calls and interpolating into the comment body.
  # The env var is controlled by the repository owner (acceptable trust
  # boundary), but a typo or adversarial override could inject unexpected
  # characters into gh API calls or the posted Markdown comment.
  local _label_re='^[a-zA-Z0-9._:/ -]+$'
  if [[ ! "${label}" =~ ${_label_re} ]]; then
    gha_echo warning "CODE_NEEDS_INPUT_LABEL contains unexpected characters ('${label}'); falling back to default"
    label="fs-code-needs-input"
  fi
  gh label create "${label}" --repo "${REPO_FULL_NAME}" \
    --description "Code agent needs human input to proceed" --color "D93F0B" \
    --force 2>/dev/null || gha_echo warning "Failed to create/update label '${label}' on ${REPO_FULL_NAME}"
  gh api "repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/labels" \
    -f "labels[]=${label}" --silent 2>/dev/null || \
    gha_echo warning "Failed to apply label '${label}' to issue #${safe_issue_number}"
  gh api "repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/labels/ready-to-code" \
    -X DELETE --silent 2>/dev/null || \
    gha_echo warning "Failed to remove 'ready-to-code' label from issue #${safe_issue_number}"

  # Guard against a contract violation: needs_input means "stop before
  # implementing," so there should be no local commits and no open PR for
  # this branch. Check anyway — cheaply — so a violation surfaces to the
  # human instead of silently discarding the agent's work or leaving
  # contradictory state (an open PR alongside a "no PR" comment).
  local caveat=""
  local current_branch
  current_branch="$(git branch --show-current 2>/dev/null || true)"
  if [ -n "${current_branch}" ]; then
    # current_branch is chosen by the code agent inside the sandbox while
    # processing potentially adversarial issue content, and git ref names
    # permit backticks — never interpolate it raw into the comment body
    # below. Same safe-charset check already applied to AGENT_TARGET.
    local display_branch="${current_branch}"
    if [[ ! "${current_branch}" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
      display_branch="(branch name omitted — contains unexpected characters, see workflow log)"
      gha_echo warning "needs_input set on a branch with unexpected characters in its name; omitting the raw name from the issue comment"
    fi
    local existing_pr_url
    existing_pr_url="$(gh pr list --repo "${REPO_FULL_NAME}" --head "${current_branch}" \
      --json url --jq '.[0].url // empty' 2>/dev/null || true)"
    if [ -n "${existing_pr_url}" ]; then
      # Sanitize existing_pr_url before interpolating into the comment body.
      # The value comes from the GitHub/GitLab API (constrained to https://
      # URLs), so exploitation is practically impossible — but defense-in-depth
      # against injection matches the treatment applied to current_branch above.
      existing_pr_url="$(_sanitize_workflow_value "${existing_pr_url}")"
      if [[ ! "${existing_pr_url}" =~ ^https://[a-zA-Z0-9._:/-]+$ ]]; then
        gha_echo warning "needs_input: existing PR URL contains unexpected characters; omitting from issue comment"
        existing_pr_url="(PR URL omitted — unexpected format, see workflow log)"
      fi
      caveat="⚠️ An open PR already exists for branch \`${display_branch}\`: ${existing_pr_url}. The agent set \`needs_input\` on this run — check whether that PR is still current."
      gha_echo warning "needs_input set but an open PR already exists for branch '${current_branch}': ${existing_pr_url}"
    else
      local default_branch commits_ahead
      if ! default_branch="$(gh api "repos/${REPO_FULL_NAME}" --jq '.default_branch' 2>/dev/null)"; then
        default_branch="main"
        gha_echo warning "Failed to determine default branch for ${REPO_FULL_NAME}; assuming 'main' — the discarded-commits check may be inaccurate"
      fi
      # Check for commits ahead of origin/default regardless of whether
      # current_branch equals default_branch — the agent might leave
      # local-only commits on the default branch too, and
      # origin/${default_branch}..HEAD is still meaningful in that case.
      commits_ahead=""
      if ! commits_ahead="$(git rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null)"; then
        gha_echo warning "Failed to count commits ahead of origin/${default_branch} — discarded-commits check skipped"
      fi
      if [ -n "${commits_ahead}" ] && [ "${commits_ahead}" -gt 0 ]; then
        caveat="⚠️ The agent made ${commits_ahead} local commit(s) on branch \`${display_branch}\` before setting \`needs_input\` — these were not pushed and will be discarded."
        gha_echo warning "needs_input set but ${commits_ahead} local commit(s) exist on branch '${current_branch}' — discarding"
      fi
      # Also check for uncommitted-but-unstaged changes — if the agent
      # modified files without committing, those changes are silently
      # lost. Surface them so the human knows work was discarded.
      local dirty_files
      dirty_files="$(git status --porcelain 2>/dev/null || true)"
      if [ -n "${dirty_files}" ]; then
        local dirty_count
        dirty_count="$(echo "${dirty_files}" | wc -l | tr -d ' ')"
        if [ -z "${caveat}" ]; then
          caveat="⚠️ The agent left ${dirty_count} uncommitted file(s) in the working tree before setting \`needs_input\` — these will be discarded."
        else
          caveat="${caveat}
⚠️ Additionally, the agent left ${dirty_count} uncommitted file(s) in the working tree — these will also be discarded."
        fi
        gha_echo warning "needs_input set but ${dirty_count} uncommitted file(s) exist in the working tree — discarding"
      fi
    fi
  fi

  local sanitized_input
  # max_lines=0 disables tail-based truncation: needs_input is forward,
  # human-authored prose already length-capped by the schema (maxLength
  # 4000), not command/log output where tail-ing to recent lines makes
  # sense. Truncating from the tail would silently drop the opening
  # framing of a long explanation.
  sanitized_input="$(sanitize_failure_detail "${needs_input}" 0)"

  # Secret-scan needs_input — same category of free-form, agent-authored,
  # out-of-git-tree prose as pr_body, also posted as a public issue comment.
  # Run gitleaks to catch secrets that sanitize_failure_detail's fixed
  # pattern set does not cover (e.g. AWS keys, DB passwords).
  #
  # install_gitleaks is a no-op when gitleaks is already on PATH (sandbox
  # images pre-install it).  On CI runners without a pre-installed binary
  # it downloads and verifies the pinned release — the same function the
  # main secret-scan step (step 3) calls later, but that step is past the
  # needs_input early-exit, so we must ensure the binary is available here.
  if ! install_gitleaks; then
    gha_echo warning "Failed to install gitleaks for needs_input scan; replacing content with generic message"
    sanitized_input="(Content redacted — secret scan of the agent's explanation could not run because gitleaks installation failed. Check the workflow log for details.)"
  else
    local ni_tmp gl_stderr gl_rc
    ni_tmp="$(mktemp)"
    printf '%s\n' "${sanitized_input}" > "${ni_tmp}"
    gl_stderr="$(mktemp)"
    gl_rc=0
    gitleaks detect --source "${ni_tmp}" --no-git --redact 2>"${gl_stderr}" || gl_rc=$?
    if [ -s "${gl_stderr}" ]; then
      sed 's/^/::debug::gitleaks: /' "${gl_stderr}"
    fi
    rm -f "${gl_stderr}"
    if [ "${gl_rc}" -eq 1 ]; then
      gha_echo warning "BLOCKED — secret detected in needs_input text; replacing with generic message"
      sanitized_input="(Content redacted — the agent's explanation contained a potential secret. Check the workflow log for details.)"
    elif [ "${gl_rc}" -gt 1 ]; then
      gha_echo warning "gitleaks scan of needs_input failed (exit ${gl_rc}); replacing with generic message"
      sanitized_input="(Content redacted — secret scan of the agent's explanation failed. Check the workflow log for details.)"
    fi
    rm -f "${ni_tmp}"
  fi

  local caveat_block=""
  if [ -n "${caveat}" ]; then
    caveat_block="
${caveat}
"
    # Apply a machine-queryable conflict label so dashboards/automation can
    # distinguish "clean needs_input" from "agent violated the needs_input
    # contract" without reading comment prose.
    local conflict_label="${label}-conflict"
    gh label create "${conflict_label}" --repo "${REPO_FULL_NAME}" \
      --description "Code agent set needs_input but left local commits or an open PR" --color "E4E669" \
      --force 2>/dev/null || true
    gh api "repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/labels" \
      -f "labels[]=${conflict_label}" --silent 2>/dev/null || \
      gha_echo warning "Failed to apply conflict label '${conflict_label}' to issue #${safe_issue_number}"
  fi

  local body
  body="🚧 **Code agent needs input** — issue #${safe_issue_number}

The code agent stopped before implementing a fix because it needs input from a human before it can proceed safely.

**What it needs:**
${sanitized_input}
${caveat_block}
Once this is resolved, remove the \`${label}\` label and re-trigger with \`/fs-code\`."

  if ! gh issue comment "${ISSUE_NUMBER}" \
    --repo "${REPO_FULL_NAME}" \
    --body "${body}" 2>/dev/null; then
    gha_echo warning "Failed to post needs-input comment to issue #${safe_issue_number}"
  fi
}

# ---------------------------------------------------------------------------
# Resolve target branch (ADR 0053)
#
# Priority: agent output > allowed-list validation > auto-detect default
# The agent writes its chosen branch to agent-result.json. The post-script
# validates it against CODE_ALLOWED_TARGET_BRANCHES (comma-separated list
# or "*" for any). When unset, only the auto-detected default branch is
# allowed. Falls back to "main" if the API call fails.
# ---------------------------------------------------------------------------
AGENT_TARGET=""
# Prefer the validated iteration when set. Trust boundary:
# FULLSEND_VALIDATED_ITERATION_DIR is set by the fullsend CLI on the runner —
# not by the sandbox or the agent. No containment check (realpath / prefix
# guard) is applied here; the value is trusted from the external harness.
# If the trust model changes, add a realpath prefix check.
if [ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]; then
  if [ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json" ]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
  else
    # No silent rescan: an env var pointing at a dir without the expected
    # filename must not fall back to scanning other iterations, which could
    # pick up a different (possibly invalid) iteration's output. Degrade to
    # no result the same as the "nothing found" case below — this script
    # already falls back to the auto-detected default branch when
    # RESULT_FILE is empty, so this isn't a hard failure.
    RESULT_FILE=""
  fi
else
  # Backward compatibility: scan iteration-N/ subdirectories for the last
  # iteration's output (glob order = naturally ascending iteration numbers).
  RESULT_FILE=""
  for dir in "${RUN_DIR}"/iteration-*/output; do
    if [ -f "${dir}/agent-result.json" ]; then
      RESULT_FILE="${dir}/agent-result.json"
    fi
  done
fi
CLOSES_ISSUE="true"
NEEDS_INPUT=""
if [ -n "${RESULT_FILE}" ]; then
  AGENT_TARGET="$(jq -r '.target_branch // empty' "${RESULT_FILE}" 2>/dev/null || true)"
  AGENT_CLOSES="$(jq -r '.closes_issue // empty' "${RESULT_FILE}" 2>/dev/null || true)"
  NEEDS_INPUT="$(jq -r '.needs_input // empty' "${RESULT_FILE}" 2>/dev/null || true)"
  if [ "${AGENT_CLOSES}" = "false" ]; then
    CLOSES_ISSUE="false"
  fi
fi

if [ -n "${NEEDS_INPUT}" ]; then
  gha_echo notice "Agent needs input — posting comment and stopping (no PR)"
  post_needs_input_comment "${NEEDS_INPUT}"
  exit 0
fi

if [[ -n "${AGENT_TARGET}" && ! "${AGENT_TARGET}" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
  post_fail_to_issue branch-validation \
    "Invalid branch name from agent output: '${AGENT_TARGET}'"
fi

DEFAULT_BRANCH="$(forge_get_default_branch "${PUSH_TOKEN}")"

if [ -n "${AGENT_TARGET}" ]; then
  if [ -n "${CODE_ALLOWED_TARGET_BRANCHES:-}" ]; then
    # Explicit allowed list — hard-fail if agent's choice is not in it.
    if [ "${CODE_ALLOWED_TARGET_BRANCHES}" = "*" ] \
       || echo ",${CODE_ALLOWED_TARGET_BRANCHES}," | grep -qF ",${AGENT_TARGET},"; then
      TARGET_BRANCH="${AGENT_TARGET}"
      echo "Agent requested branch '${TARGET_BRANCH}' — allowed"
    else
      post_fail_to_issue branch-validation \
        "Agent requested branch '${AGENT_TARGET}' but allowed branches are: ${CODE_ALLOWED_TARGET_BRANCHES}"
    fi
  else
    # No explicit list — auto-correct to API-discovered default when mismatched.
    if [ "${AGENT_TARGET}" = "${DEFAULT_BRANCH}" ]; then
      TARGET_BRANCH="${AGENT_TARGET}"
      echo "Agent requested branch '${TARGET_BRANCH}' — matches default"
    else
      TARGET_BRANCH="${DEFAULT_BRANCH}"
      gha_echo warning "Agent requested branch '${AGENT_TARGET}' but default branch is '${DEFAULT_BRANCH}' — auto-correcting"
    fi
  fi
else
  TARGET_BRANCH="${DEFAULT_BRANCH}"
  echo "No agent branch preference — using repo default: ${TARGET_BRANCH}"
fi

# ---------------------------------------------------------------------------
# No-op comment helper
#
# Posts an informational comment on the source issue when the agent
# determines no changes are needed (no-op exit path). Best-effort —
# a failure to post does not change the exit code.
# ---------------------------------------------------------------------------
post_noop_comment() {
  local reason="$1"
  local safe_issue_number
  safe_issue_number="$(_sanitize_workflow_value "${ISSUE_NUMBER}")"

  _post_failure_ensure_token

  local run_url
  run_url="$(forge_get_workflow_run_url)"

  # Try to extract agent reasoning from result file.
  # Note: RESULT_FILE is set at the top of the script and may point to a
  # prior iteration's output when the current run exits before producing one.
  # This is acceptable — context is sanitized and the comment is best-effort.
  local agent_context=""
  if [ -n "${RESULT_FILE:-}" ] && [ -f "${RESULT_FILE}" ]; then
    agent_context="$(jq -r '.pr_body // empty' "${RESULT_FILE}" 2>/dev/null || true)"
  fi

  local detail_block=""
  if [ -n "${agent_context}" ]; then
    local sanitized_context
    sanitized_context="$(sanitize_failure_detail "${agent_context}")"
    detail_block="

**Agent context:**
${sanitized_context}"
  fi

  local body
  body="ℹ️ **No PR created** — agent determined no changes needed

The code agent ran and evaluated issue #${safe_issue_number}, but did not produce changes to submit as a pull request.

**Reason:** ${reason}
${detail_block}

**Workflow run:** ${run_url}

Retry with \`/fs-code\` if appropriate."

  if ! forge_post_issue_comment "${body}"; then
    gha_echo warning "Failed to post no-op comment to issue #${safe_issue_number}"
  fi
}

# ---------------------------------------------------------------------------
# 1. Verify feature branch
# ---------------------------------------------------------------------------
BRANCH="$(git branch --show-current)"

if [ -z "${BRANCH}" ] || [ "${BRANCH}" = "main" ] || [ "${BRANCH}" = "master" ]; then
  gha_echo notice "Agent did not create a feature branch (current: '${BRANCH:-detached HEAD}') — nothing to do"
  post_noop_comment "Agent did not create a feature branch (current: '${BRANCH:-detached HEAD}')"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1b. Enforce agent/<ISSUE_NUMBER>-* branch namespace
#
# The agent chooses its own branch name inside the sandbox. Rename it
# deterministically using the trusted ISSUE_NUMBER (sourced from the
# CI event, not from agent output) so agent-authored pushes are
# confined to this issue's namespace.
# ---------------------------------------------------------------------------
SAFE_BRANCH="$(enforce_branch_namespace "${BRANCH}" "${ISSUE_NUMBER}")"
if [ "${BRANCH}" != "${SAFE_BRANCH}" ]; then
  gha_echo warning "Renaming agent branch '${BRANCH}' to '${SAFE_BRANCH}'"
  git branch -M "${SAFE_BRANCH}"
fi
BRANCH="${SAFE_BRANCH}"

echo "Branch: ${BRANCH}"
echo "Token source: ${PUSH_TOKEN_SOURCE:-unknown}"

# ---------------------------------------------------------------------------
# 2. Compute changed files
# ---------------------------------------------------------------------------
MERGE_BASE="$(git merge-base "origin/${TARGET_BRANCH}" HEAD 2>/dev/null)" || MERGE_BASE=""
if [ -n "${MERGE_BASE}" ]; then
  CHANGED_FILES="$(git diff --name-only "${MERGE_BASE}..HEAD")"
else
  gha_echo warning "Could not determine merge-base — trying origin/${TARGET_BRANCH}..HEAD"
  CHANGED_FILES="$(git diff --name-only "origin/${TARGET_BRANCH}..HEAD" 2>/dev/null \
    || git diff --name-only HEAD~1..HEAD 2>/dev/null || true)"
fi

if [ -z "${CHANGED_FILES}" ]; then
  gha_echo notice "No changed files in agent's commit(s) — nothing to do"
  post_noop_comment "No changed files in agent's commit(s)"
  exit 0
fi

echo "Changed files:"
echo "${CHANGED_FILES}" | sed 's/^/  /'

# ---------------------------------------------------------------------------
# 2b. Strip agent working directories (defense-in-depth)
#
# Agent working dirs (.agentready/, .fullsend-workspace/) should never
# appear in commits. The harness excludes them via .git/info/exclude, but
# if an agent manages to stage them anyway, strip them here before push.
# ---------------------------------------------------------------------------
AGENT_ARTIFACT_PATTERNS=".agentready/ .fullsend-workspace/"
STRIPPED_FILES=""
for file in ${CHANGED_FILES}; do
  is_artifact=false
  for pattern in ${AGENT_ARTIFACT_PATTERNS}; do
    dir="${pattern%/}"  # strip trailing slash for prefix matching
    case "${file}" in
      "${dir}"/*|"${dir}") is_artifact=true; break ;;
      */"${dir}"/*|*/"${dir}") is_artifact=true; break ;;
    esac
  done
  if [ "${is_artifact}" = "true" ]; then
    gha_echo warning "Stripping agent artifact from commit: ${file}"
    STRIPPED_FILES="${STRIPPED_FILES} ${file}"
  fi
done

if [ -n "${STRIPPED_FILES}" ]; then
  gha_echo warning "Agent committed working directory artifacts — stripping before push"
  # shellcheck disable=SC2086
  git rm --cached --quiet ${STRIPPED_FILES}
  git commit --amend --no-edit

  # Rebuild CHANGED_FILES without the stripped artifacts.
  CLEAN_FILES=""
  for file in ${CHANGED_FILES}; do
    is_stripped=false
    for sf in ${STRIPPED_FILES}; do
      if [ "${file}" = "${sf}" ]; then
        is_stripped=true
        break
      fi
    done
    if [ "${is_stripped}" = "false" ]; then
      CLEAN_FILES="${CLEAN_FILES}${CLEAN_FILES:+
}${file}"
    fi
  done
  CHANGED_FILES="${CLEAN_FILES}"

  if [ -z "${CHANGED_FILES}" ]; then
    gha_echo notice "All changed files were agent artifacts — nothing to push"
    post_noop_comment "All changed files were agent artifacts — only working directory files were present"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# 3. Authoritative secret scan
# ---------------------------------------------------------------------------
echo "Running authoritative secret scan on agent's commit..."

if ! install_gitleaks; then
  post_fail_to_issue setup-error "Failed to install gitleaks v${GITLEAKS_VERSION}"
fi

if [ -n "${MERGE_BASE}" ]; then
  SCAN_RANGE="${MERGE_BASE}..HEAD"
else
  SCAN_RANGE="HEAD~1..HEAD"
fi

if ! GITLEAKS_OUTPUT="$(gitleaks detect --source . --log-opts="${SCAN_RANGE}" --redact 2>&1)"; then
  print_sanitized_gha_log "${GITLEAKS_OUTPUT}" stderr
  post_fail_to_issue secret-scan "${POST_FAILURE_SECRET_SCAN_MESSAGE}"
fi
echo "Secret scan passed — no leaks in agent's commit(s)"

# ---------------------------------------------------------------------------
# 3b. Reject Signed-off-by trailers
#
# Agents must never produce Signed-off-by trailers. DCO is a human
# attestation — the DCO app already waives the check for bot authors.
# The bot noreply email makes the trailer ~90 characters, which causes
# gitlint body-max-line-length failures in repos with a 72-char limit.
# ---------------------------------------------------------------------------
echo "Checking for Signed-off-by trailers in agent's commit(s)..."
if git log --format='%b' "${SCAN_RANGE}" | grep -q '^Signed-off-by:'; then
  post_fail_to_issue signed-off-by \
    "Agent commit contains a Signed-off-by trailer. Agents must not use 'git commit -s' or append Signed-off-by trailers."
fi
echo "Signed-off-by scan passed — no trailers in agent's commit(s)"

# ---------------------------------------------------------------------------
# 4. Auto-install pre-commit tool dependencies
# ---------------------------------------------------------------------------
SCRIPT_DIR_POST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE_SCRIPT="${SCRIPT_DIR_POST}/resolve-precommit-tools.py"
INSTALL_SCRIPT="${SCRIPT_DIR_POST}/install-precommit-tools.sh"

# Fallback: these companion scripts were never migrated into this repo
# during the ADR 0058 extraction, so the BASH_SOURCE-relative lookup above
# always misses. In current fullsend reusable-workflow layouts, the
# "Prepare workspace" step typically materializes scripts/ at
# ${GITHUB_WORKSPACE}/scripts/ (per-org) or ${GITHUB_WORKSPACE}/.fullsend/scripts/
# (per-repo) — see fullsend-ai/.fullsend reusable workflows. Try those paths
# when the BASH_SOURCE-relative lookup misses.
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
if [ -f .pre-commit-config.yaml ] \
   && { [ ! -f "${RESOLVE_SCRIPT}" ] || [ ! -f "${INSTALL_SCRIPT}" ]; }; then
  gha_echo warning "Pre-commit tool auto-install skipped: companion scripts not found"
  gha_echo warning "Expected ${RESOLVE_SCRIPT} and ${INSTALL_SCRIPT}"
  gha_echo warning "Pre-commit hooks requiring system tools (e.g. lychee) may fail"
fi

if [ -f .pre-commit-config.yaml ] \
   && [ -f "${RESOLVE_SCRIPT}" ] \
   && [ -f "${INSTALL_SCRIPT}" ]; then
  MANIFEST="$(mktemp)"
  LOCAL_REG="$(mktemp)"
  RESOLVE_ARGS=(".")
  if git show "origin/${TARGET_BRANCH}:.pre-commit-tools.yaml" > "${LOCAL_REG}" 2>/dev/null; then
    RESOLVE_ARGS+=("--local-registry" "${LOCAL_REG}")
  fi
  if python3 "${RESOLVE_SCRIPT}" "${RESOLVE_ARGS[@]}" > "${MANIFEST}"; then
    if [ -s "${MANIFEST}" ] && jq -e '.tools | length > 0' "${MANIFEST}" >/dev/null 2>&1; then
      bash "${INSTALL_SCRIPT}" "${MANIFEST}"
    fi
  else
    gha_echo warning "Pre-commit tool resolution failed — continuing without auto-install"
  fi
  rm -f "${MANIFEST}" "${LOCAL_REG}"
fi
export PATH="${HOME}/.local/bin:${PATH}"

# ---------------------------------------------------------------------------
# 5. Authoritative pre-commit check
# ---------------------------------------------------------------------------
if [ -f .pre-commit-config.yaml ]; then
  echo "Running authoritative pre-commit on agent's changed files..."

  if ! command -v pre-commit >/dev/null 2>&1; then
    echo "Installing pre-commit..."
    pip install "pre-commit==4.5.1" 2>/dev/null \
      || pip3 install "pre-commit==4.5.1" 2>/dev/null \
      || pipx install "pre-commit==4.5.1" 2>/dev/null \
      || gha_echo warning "Failed to install pre-commit"
  fi

  if command -v pre-commit >/dev/null 2>&1; then
    changed_array=()
    while IFS= read -r _changed_line; do
      changed_array+=("${_changed_line}")
    done <<< "${CHANGED_FILES}"
    # SYNC: parallel retry block in post-fix.sh section 3 — keep structure
    #       in sync (variable names differ: CHANGED_FILES here vs
    #       BRANCH_CHANGED_FILES there; SCAN_RANGE scopes differ by design).
    PRECOMMIT_OUTPUT=""
    if PRECOMMIT_OUTPUT="$(pre-commit run --files "${changed_array[@]}" 2>&1)"; then
      print_sanitized_gha_log "${PRECOMMIT_OUTPUT}"
      echo "Pre-commit passed — all hooks clean"
    else
      print_sanitized_gha_log "${PRECOMMIT_OUTPUT}"
      # Single retry only — do not convert to a loop without adding a cap.
      # Scope detection/staging to changed_array so hooks can't inject files
      # outside the pre-commit scope into the commit.
      if git diff --name-only -- "${changed_array[@]}" | grep -q .; then
        gha_echo warning "Pre-commit hooks auto-fixed files — re-staging and retrying"
        echo "Auto-fixed files:"
        git diff --name-only -- "${changed_array[@]}" | sed 's/^/  /'
        git diff --name-only -z -- "${changed_array[@]}" | xargs -0 -r git add --
        git commit --amend --no-edit

        echo "Re-running secret scan on amended commit..."
        GITLEAKS_OUTPUT=""
        if ! GITLEAKS_OUTPUT="$(gitleaks detect --source . --log-opts="${SCAN_RANGE}" --redact 2>&1)"; then
          print_sanitized_gha_log "${GITLEAKS_OUTPUT}" stderr
          post_fail_to_issue secret-scan "${POST_FAILURE_SECRET_SCAN_MESSAGE}"
        fi
        if git log --format='%b' "${SCAN_RANGE}" | grep -q '^Signed-off-by:'; then
          post_fail_to_issue signed-off-by \
            "Amended commit contains a Signed-off-by trailer after pre-commit auto-fix."
        fi

        if [ -n "${MERGE_BASE}" ]; then
          CHANGED_FILES="$(git diff --name-only "${MERGE_BASE}..HEAD")"
        else
          CHANGED_FILES="$(git diff --name-only "origin/${TARGET_BRANCH}..HEAD" 2>/dev/null \
            || git diff --name-only HEAD~1..HEAD 2>/dev/null || true)"
        fi
        if [ -z "${CHANGED_FILES}" ]; then
          post_fail_to_issue pre-commit-blocked \
            "Pre-commit hooks removed all changes; commit is now empty."
        fi
        changed_array=()
        while IFS= read -r _changed_line; do
          changed_array+=("${_changed_line}")
        done <<< "${CHANGED_FILES}"
        PRECOMMIT_RETRY_OUTPUT=""
        if PRECOMMIT_RETRY_OUTPUT="$(pre-commit run --files "${changed_array[@]}" 2>&1)"; then
          print_sanitized_gha_log "${PRECOMMIT_RETRY_OUTPUT}"
          if git diff --name-only -- "${changed_array[@]}" | grep -q .; then
            post_fail_to_issue pre-commit-blocked \
              "Retry pre-commit left additional unstaged changes; committed content would diverge from what pre-commit validated."
          fi
          echo "Pre-commit passed after auto-fix re-stage"
        else
          print_sanitized_gha_log "${PRECOMMIT_RETRY_OUTPUT}"
          post_fail_to_issue pre-commit-blocked "${PRECOMMIT_RETRY_OUTPUT}"
        fi
      else
        post_fail_to_issue pre-commit-blocked "${PRECOMMIT_OUTPUT}"
      fi
    fi
  else
    gha_echo warning "pre-commit not available on runner — skipping authoritative check"
    gha_echo warning "CI pre-commit will still run on the PR"
  fi
else
  echo "No .pre-commit-config.yaml — skipping pre-commit check"
fi

# ---------------------------------------------------------------------------
# 6. Push branch
# ---------------------------------------------------------------------------
forge_set_push_remote "${PUSH_TOKEN}"

# Set token for forge CLI (GitHub uses GH_TOKEN, GitLab uses GITLAB_TOKEN)
if [ "${FULLSEND_FORGE}" = "github" ]; then
  export GH_TOKEN="${PUSH_TOKEN}"
else
  export GITLAB_TOKEN="${PUSH_TOKEN}"
fi

# ---------------------------------------------------------------------------
# 7a. Delete stale remote branch if it exists with no open PR/MR.
#
# When a human closes a code agent PR/MR and re-triggers /fs-code, the old
# remote branch still exists. A plain push will fail with non-fast-forward
# because the local branch was created fresh from origin/main. Delete the
# stale remote branch so the push succeeds.
# ---------------------------------------------------------------------------
REMOTE_REF_LINE="$(forge_check_remote_branch "${BRANCH}")"
if [ -n "${REMOTE_REF_LINE}" ]; then
  echo "Remote branch ${BRANCH} already exists — checking for open PRs..."
  PR_LIST_RC=0
  OPEN_PR="$(forge_list_prs_for_branch "${BRANCH}")" || PR_LIST_RC=$?
  if [ "${PR_LIST_RC}" -ne 0 ]; then
    post_fail_to_issue api-error \
      "Could not query open PRs for branch '${BRANCH}' — refusing to push."
  fi
  if [ -z "${OPEN_PR}" ]; then
    if [[ "${BRANCH}" != agent/${ISSUE_NUMBER}-* ]]; then
      post_fail_to_issue branch-namespace-violation \
        "Branch '${BRANCH}' is outside agent/${ISSUE_NUMBER}-* namespace — refusing to delete."
    fi
    echo "No open PR uses ${BRANCH} — deleting stale remote branch"
    forge_delete_remote_branch "${BRANCH}"
  else
    # Verify the open PR belongs to this issue. With deterministic branch
    # naming (agent/<ISSUE_NUMBER>-*) this should always hold, but check
    # anyway as defense-in-depth against cross-issue commit injection.
    PR_BODY_TEXT="$(forge_get_pr_details "${OPEN_PR}" "body" | jq -r '.body // .description // empty' 2>/dev/null || true)"
    PR_CLOSES_THIS_ISSUE=false
    if pr_body_refs_issue "${PR_BODY_TEXT}" "${ISSUE_NUMBER}"; then
      PR_CLOSES_THIS_ISSUE=true
    fi
    if [ "${PR_CLOSES_THIS_ISSUE}" = "false" ]; then
      post_fail_to_issue branch-collision \
        "Remote branch '${BRANCH}' backs open PR #${OPEN_PR}, which does not reference issue #${ISSUE_NUMBER}. Refusing to push to avoid cross-issue commit injection."
    fi
    echo "Open PR #${OPEN_PR} uses ${BRANCH} and references issue #${ISSUE_NUMBER} — keeping remote branch"
  fi
fi

# ---------------------------------------------------------------------------
# 7b. Push, with --force-with-lease fallback for non-fast-forward errors.
# ---------------------------------------------------------------------------
echo "Pushing branch ${BRANCH}..."
PUSH_OUTPUT="$(git push -u origin -- "${BRANCH}" 2>&1)" && PUSH_RC=0 || PUSH_RC=$?
print_sanitized_gha_log "${PUSH_OUTPUT}"

if [ "${PUSH_RC}" -ne 0 ]; then
  if echo "${PUSH_OUTPUT}" | grep -qi "non-fast-forward\|rejected\|fetch first"; then
    gha_echo warning "Plain push failed (non-fast-forward) — retrying with --force-with-lease"
    FORCE_PUSH_OUTPUT=""
    if ! FORCE_PUSH_OUTPUT="$(git push --force-with-lease -u origin -- "${BRANCH}" 2>&1)"; then
      print_sanitized_gha_log "${FORCE_PUSH_OUTPUT}"
      PUSH_CATEGORY="$(categorize_push_failure "${PUSH_OUTPUT}
${FORCE_PUSH_OUTPUT}")"
      post_fail_to_issue "${PUSH_CATEGORY}" "${PUSH_OUTPUT}
${FORCE_PUSH_OUTPUT}"
    fi
    print_sanitized_gha_log "${FORCE_PUSH_OUTPUT}"
  else
    PUSH_CATEGORY="$(categorize_push_failure "${PUSH_OUTPUT}")"
    post_fail_to_issue "${PUSH_CATEGORY}" "${PUSH_OUTPUT}"
  fi
fi

# ---------------------------------------------------------------------------
# 8. Create PR/MR
# ---------------------------------------------------------------------------

EXISTING_PR_NUM="$(forge_list_prs_for_branch "${BRANCH}")" || true

if [ -n "${EXISTING_PR_NUM}" ]; then
  EXISTING_PR_URL="$(forge_get_pr_url "${EXISTING_PR_NUM}")"
  echo "PR #${EXISTING_PR_NUM} already exists — branch updated with new commits"
  echo "PR: ${EXISTING_PR_URL}"
  forge_write_output "pr_url" "${EXISTING_PR_URL}"

  enable_auto_merge "${EXISTING_PR_NUM}" "${REPO_FULL_NAME}" existing
  maybe_assign_pr "${EXISTING_PR_NUM}"
  exit 0
fi

echo "Creating PR..."

COMMIT_SUBJECT="$(git log -1 --format='%s' HEAD)"

# Read pr_body from agent output. Fall back to commit body if absent.
PR_BODY_FROM_RESULT=""
if [ -n "${RESULT_FILE}" ]; then
  if ! PR_BODY_FROM_RESULT="$(jq -r '.pr_body // empty' "${RESULT_FILE}" 2>/dev/null)"; then
    gha_echo notice "Failed to parse pr_body from result file; using commit body"
    PR_BODY_FROM_RESULT=""
  fi
fi

# Secret-scan pr_body — it lives outside the git tree so gitleaks (step 3)
# never sees it, but it becomes a public PR description.
PR_BODY_SCAN_STATUS="skipped"
if [ -n "${PR_BODY_FROM_RESULT}" ]; then
  PR_BODY_TMP="$(mktemp)"
  printf '%s\n' "${PR_BODY_FROM_RESULT}" > "${PR_BODY_TMP}"
  GL_STDERR="$(mktemp)"
  GL_RC=0
  gitleaks detect --source "${PR_BODY_TMP}" --no-git --redact 2>"${GL_STDERR}" || GL_RC=$?
  if [ -s "${GL_STDERR}" ]; then
    sed 's/^/::debug::gitleaks: /' "${GL_STDERR}"
  fi
  rm -f "${GL_STDERR}"
  if [ "${GL_RC}" -eq 0 ]; then
    PR_BODY_SCAN_STATUS="passed"
  elif [ "${GL_RC}" -eq 1 ]; then
    gha_echo warning "BLOCKED — secret detected in pr_body; falling back to commit body"
    PR_BODY_FROM_RESULT=""
    PR_BODY_SCAN_STATUS="blocked"
  else
    gha_echo warning "gitleaks scan failed (exit ${GL_RC}); falling back to commit body"
    PR_BODY_FROM_RESULT=""
    PR_BODY_SCAN_STATUS="error"
  fi
  rm -f "${PR_BODY_TMP}"
fi

extract_commit_body() {
  local raw
  raw="$(git log -1 --format='%b' HEAD \
    | sed '/^Signed-off-by:/d' \
    | sed '/^Closes #/d' \
    | sed '/^Related to #/d' \
    | sed -e :a -e '/^\n*$/{ $d; N; ba; }')"
  echo "${raw}" | awk '
    /^$/           { if (buf) print buf; print; buf=""; next }
    /^[-*#>]|^  /  { if (buf) print buf; buf=""; print; next }
    /^Closes /     { if (buf) print buf; buf=""; print; next }
    /^Related to / { if (buf) print buf; buf=""; print; next }
                   { buf = (buf ? buf " " $0 : $0) }
    END            { if (buf) print buf }
  '
}

if [ -n "${PR_BODY_FROM_RESULT}" ]; then
  # Strip Signed-off-by globally (agents must never produce DCO trailers),
  # then strip trailing closing-keyword footer lines so the script appends
  # them once. Closing keywords mid-body are preserved intentionally.
  # Only exact GitHub auto-close syntax is matched (e.g. "Closes #42",
  # "Fixes org/repo#1"). Variants like "Closes: #42" or "closes(#42)"
  # are intentionally ignored — they don't trigger GitHub auto-close.
  PR_BODY_CLEAN="$(printf '%s\n' "${PR_BODY_FROM_RESULT}" | sed '/^Signed-off-by:/d')"
  COMMIT_BODY="$(printf '%s\n' "${PR_BODY_CLEAN}" | awk '
    { lines[NR] = $0 }
    END {
      end = NR
      while (end > 0) {
        l = lines[end]
        if (l == "" || l ~ /^[Cc]lose[sd]? (#|[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+#)[0-9]+$/ || l ~ /^[Ff]ix(e[sd])? (#|[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+#)[0-9]+$/ || l ~ /^[Rr]esolve[sd]? (#|[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+#)[0-9]+$/ || l ~ /^[Rr]elated to (#|[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+#)[0-9]+$/)
          end--
        else
          break
      }
      for (i = 1; i <= end; i++)
        print lines[i]
    }
  ')"
else
  COMMIT_BODY="$(extract_commit_body)"
fi

# ---------------------------------------------------------------------------
# Ensure PR title includes an issue reference.
#
# Many repos enforce PR title conventions like "type(TICKET): description".
# The code agent may produce a plain "type: description" commit subject that
# omits the issue reference. When the title follows conventional commit format
# (word + colon), inject the issue number as a scope if no scope is present.
# ---------------------------------------------------------------------------
if echo "${COMMIT_SUBJECT}" | grep -qE '^[a-z]+\('; then
  # Already has a scope — e.g. "fix(#42): ..." or "feat(PROJ-123): ..."
  PR_TITLE="${COMMIT_SUBJECT}"
elif echo "${COMMIT_SUBJECT}" | grep -qE '^[a-z]+: '; then
  # Conventional commit without scope — inject issue reference
  PR_TITLE="$(echo "${COMMIT_SUBJECT}" | sed "s/^\([a-z]*\): /\1(#${ISSUE_NUMBER}): /")"
else
  # Non-conventional title — leave as-is
  PR_TITLE="${COMMIT_SUBJECT}"
fi

if [ -z "${COMMIT_BODY}" ]; then
  COMMIT_BODY="$(extract_commit_body)"
fi

if [ -z "${COMMIT_BODY}" ]; then
  DESCRIPTION="Automated implementation for issue #${ISSUE_NUMBER}."
else
  DESCRIPTION="${COMMIT_BODY}"
fi

case "${PR_BODY_SCAN_STATUS}" in
  passed)  PR_BODY_SCAN_LINE="- [x] PR body secret scan passed (gitleaks — no-git)" ;;
  blocked) PR_BODY_SCAN_LINE="- [x] PR body secret scan: blocked, fell back to commit body" ;;
  error)   PR_BODY_SCAN_LINE="- [x] PR body secret scan: error, fell back to commit body" ;;
  *)       PR_BODY_SCAN_LINE="- [x] PR body secret scan: N/A (commit body path)" ;;
esac

if [ "${CLOSES_ISSUE}" = "false" ]; then
  ISSUE_REF_KEYWORD="Related to"
else
  ISSUE_REF_KEYWORD="Closes"
fi

PR_BODY="${DESCRIPTION}

---

${ISSUE_REF_KEYWORD} #${ISSUE_NUMBER}

### Post-script verification

- [x] Branch is not main/master (\`${BRANCH}\`)
- [x] Secret scan passed (gitleaks — \`${SCAN_RANGE}\`)
${PR_BODY_SCAN_LINE}"

PR_CREATE_STDERR=$(mktemp)
if ! PR_URL=$(forge_create_pr \
  "${TARGET_BRANCH}" \
  "${BRANCH}" \
  "${PR_TITLE}" \
  "${PR_BODY}" 2>"${PR_CREATE_STDERR}"); then
  PR_CREATE_OUTPUT="$(cat "${PR_CREATE_STDERR}")"
  rm -f "${PR_CREATE_STDERR}"
  post_fail_to_issue pr-creation-failed "${PR_CREATE_OUTPUT}"
fi
rm -f "${PR_CREATE_STDERR}"

echo "PR created: ${PR_URL}"
forge_write_output "pr_url" "${PR_URL}"

# Apply ready-for-review label so the review agent is dispatched via the
# issues.labeled path. pull_request_target.opened requires the PR author to
# pass authorization checks that often exclude bot accounts; the label path
# is used instead (label application requires repo write access). See
# .github/scripts/check-e2e-authorization-test.sh for trusted-actor rules.
# Note: variable name is PR_NUMBER_FROM_URL (not PR_NUMBER) to avoid SC2153.
PR_NUMBER_FROM_URL="${PR_URL##*/}"
forge_ensure_label "ready-for-review"
forge_add_label "ready-for-review" "pr" "${PR_NUMBER_FROM_URL}"

# ---------------------------------------------------------------------------
# 9. Auto-merge
# ---------------------------------------------------------------------------
enable_auto_merge "${PR_NUMBER_FROM_URL}" "${REPO_FULL_NAME}"

maybe_assign_pr "${PR_NUMBER_FROM_URL}"
