#!/usr/bin/env bash
# Post-script: push the fix agent's commit and process structured output.
#
# Runs on the GitHub Actions / GitLab CI runner AFTER the sandbox is destroyed.
# This script has write access to the target repo — it is the most
# security-sensitive component in the fix pipeline.
#
# Security layers (defense-in-depth):
#   - Authoritative secret scan — final gate before any push
#   - Auto-install pre-commit tool deps (from .pre-commit-tools.yaml)
#   - Authoritative pre-commit — run repo hooks on changed files
#   - Branch validation — refuse to push main/master
#   - Token isolation — PUSH_TOKEN never enters the sandbox
#
# Protected-path enforcement lives in post-review.sh: the review agent
# cannot approve PRs that touch sensitive paths (e.g. .github/, CODEOWNERS,
# agents/). The fix agent is free to propose changes to any path.
#
# Steps:
#   0. Check for agent commits
#   1. Authoritative secret scan
#   2. Auto-install pre-commit tool deps (from .pre-commit-tools.yaml)
#   3. Authoritative pre-commit check
#   4. Push branch
#   5. Process structured output
#   6. Iteration-cap warning label
#   7. Summary
#
# After pushing, this script processes agent-result.json to:
#   - Post a summary comment on the PR documenting fixes and disagreements
#   - Apply labels (needs-human) if the iteration cap is approaching
#
# Required environment variables:
#   PUSH_TOKEN        — token with contents:write + issues:write + pull-requests:write
#                       on target repo (GitHub App installation token, PAT,
#                       or GitLab personal/project access token)
#   REPO_FULL_NAME    — owner/repo
#   PR_NUMBER         — PR number
#   REPO_DIR          — path to extracted repo (default: current directory)
#   TRIGGER_SOURCE    — forge username that triggered the fix (GitHub: [bot] suffix; GitLab: _bot suffix)
#
# Optional environment variables:
#   FIX_ITERATION     — current iteration count
#   ITERATION_CAP     — max iterations (default: 5)
#   PUSH_TOKEN_SOURCE — "github-app" (for logging)
#   POST_FAILURE_DETAIL_MAX_LINES
#                     — max lines of failure detail in issue/PR comments (default: 30)
#
# Exit codes:
#   0  — branch pushed, PR updated
#   1  — validation failure or error (nothing pushed)
set -euo pipefail

SCRIPT_DIR_POST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
SCRIPT_DIR="${SCRIPT_DIR_POST}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE is required — set to 'github' or 'gitlab'}"
# shellcheck source=lib/fix-ops.lib.sh
source "${SCRIPT_DIR_POST}/lib/fix-ops.lib.sh"
# shellcheck source=lib/post-failure-report.lib.sh
source "${SCRIPT_DIR_POST}/lib/post-failure-report.lib.sh"
# shellcheck source=lib/gitleaks-install.lib.sh
source "${SCRIPT_DIR_POST}/lib/gitleaks-install.lib.sh"
# shellcheck source=lib/branch-guard.lib.sh
source "${SCRIPT_DIR_POST}/lib/branch-guard.lib.sh"


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
REPO_DIR="${REPO_DIR:-repo}"
RUN_DIR="$(pwd)"

: "${PUSH_TOKEN:?PUSH_TOKEN is required}"
: "${REPO_FULL_NAME:?REPO_FULL_NAME is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${TRIGGER_SOURCE:?TRIGGER_SOURCE is required}"
trap 'report_post_failure_to_pr' ERR

[[ "${PR_NUMBER}" =~ ^[1-9][0-9]*$ ]] || \
  post_fail_to_pr setup-error "PR_NUMBER must be numeric, got '${PR_NUMBER}'"

if [ "${FULLSEND_FORGE:-}" = "github" ]; then
  [[ "${REPO_FULL_NAME}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]] || \
    post_fail_to_pr setup-error "REPO_FULL_NAME must be owner/repo format, got '${REPO_FULL_NAME}'"
else
  [[ "${REPO_FULL_NAME}" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+$ ]] || \
    post_fail_to_pr setup-error "REPO_FULL_NAME must be owner/repo (or group/subgroup/project) format, got '${REPO_FULL_NAME}'"
fi
[[ ! "${REPO_FULL_NAME}" =~ (^|/)\.\.?(/|$) ]] || \
  post_fail_to_pr setup-error "REPO_FULL_NAME must not contain '.' or '..' path segments, got '${REPO_FULL_NAME}'"

if [ "${REPO_DIR}" != "." ]; then
  if [ ! -d "${REPO_DIR}" ]; then
    gha_echo error "Extracted repo not found at ${REPO_DIR}" >&2
    post_fail_to_pr setup-error "Extracted repo not found at ${REPO_DIR}"
  fi
  cd "${REPO_DIR}"
fi

TARGET_BRANCH="${TARGET_BRANCH:-main}"

forge_mask_token "${PUSH_TOKEN}"
if [ -n "${GITLAB_TOKEN:-}" ]; then
  forge_mask_token "${GITLAB_TOKEN}"
fi

# GitLab needs REPO_ENCODED and GITLAB_HOST for API calls.
# Always derive GITLAB_HOST from the validated PR_URL. If GITLAB_HOST is
# already set (e.g. by the harness), verify it matches the URL to prevent
# token exfiltration to a mismatched host.
if [ "${FULLSEND_FORGE:-}" = "gitlab" ]; then
  if [[ -z "${PR_URL:-}" ]]; then
    gha_echo error "PR_URL is required for GitLab forge"
    exit 1
  fi
  if ! forge_validate_pr_url "${PR_URL}"; then
    gha_echo error "PR_URL format invalid for GitLab: '${PR_URL}'"
    exit 1
  fi
  local_url_host="$(echo "${PR_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')"
  if [[ -n "${GITLAB_HOST:-}" && "${GITLAB_HOST}" != "${local_url_host}" ]]; then
    gha_echo error "GITLAB_HOST '${GITLAB_HOST}' does not match PR URL host '${local_url_host}'"
    exit 1
  fi
  GITLAB_HOST="${local_url_host}"
  _url_repo="$(echo "${PR_URL}" | sed -E 's|^https://[^/]+/(.+)/-/merge_requests/[0-9]+$|\1|')"
  _url_pr="$(basename "${PR_URL}")"
  if [[ -n "${_url_repo}" && "${_url_repo}" != "${REPO_FULL_NAME}" ]]; then
    gha_echo error "REPO_FULL_NAME does not match PR URL repo ('${REPO_FULL_NAME}' vs '${_url_repo}')"
    exit 1
  fi
  if [[ -n "${_url_pr}" && "${_url_pr}" != "${PR_NUMBER}" ]]; then
    gha_echo error "PR_NUMBER does not match PR URL number ('${PR_NUMBER}' vs '${_url_pr}')"
    exit 1
  fi
  REPO_ENCODED=$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)
  export GITLAB_HOST REPO_ENCODED
fi

# ---------------------------------------------------------------------------
# 0. Check for agent commits
# ---------------------------------------------------------------------------
BRANCH="$(git branch --show-current)"

if [ -z "${BRANCH}" ] || [ "${BRANCH}" = "main" ] || [ "${BRANCH}" = "master" ]; then
  gha_echo warning "Agent did not produce a commit on a feature branch (current: '${BRANCH:-detached HEAD}')"
  gha_echo warning "Processing structured output only (no push)."
  # Still process agent-result.json to post a summary comment.
  NO_PUSH=true
else
  NO_PUSH=false
fi

# ---------------------------------------------------------------------------
# 0b. Verify branch matches the PR's head ref
#
# The fix agent is dispatched to modify a specific PR. Verify the agent's
# local branch matches that PR's head ref to prevent a compromised agent
# from pushing commits to a different PR's branch.
# ---------------------------------------------------------------------------
if [ "${NO_PUSH}" = "false" ]; then
  EXPECTED_BRANCH=""
  HEAD_REF_RC=1
  for _attempt in 1 2 3; do
    # shellcheck disable=SC2153
    if EXPECTED_BRANCH="$(forge_get_pr_head_ref "${PR_NUMBER}")"; then
      HEAD_REF_RC=0
      break
    fi
    sleep 2
  done
  if [ "${HEAD_REF_RC}" -ne 0 ] || [ -z "${EXPECTED_BRANCH}" ]; then
    post_fail_to_pr branch-mismatch \
      "Could not resolve PR #${PR_NUMBER} head ref after 3 attempts — refusing to push."
  fi
  if [ "$(classify_branch_vs_pr_head "${BRANCH}" "${EXPECTED_BRANCH}")" = "mismatch" ]; then
    post_fail_to_pr branch-mismatch \
      "Agent branch '${BRANCH}' does not match PR #${PR_NUMBER} head ref '${EXPECTED_BRANCH}'. Refusing to push."
  fi
fi

# Scope to the agent's commit(s) only — not the entire branch. PRE_AGENT_HEAD
# is set by fix.yml to the HEAD SHA before the harness runs, so this diff
# captures every commit the agent made (including validation_loop retries).
# Falls back to HEAD~1 if PRE_AGENT_HEAD is unset (shouldn't happen in CI).
DIFF_BASE="${PRE_AGENT_HEAD:-$(git rev-parse HEAD~1 2>/dev/null || echo HEAD)}"
CHANGED_FILES="$(git diff --name-only "${DIFF_BASE}..HEAD" 2>/dev/null || true)"

if [ -z "${CHANGED_FILES}" ] && [ "${NO_PUSH}" = "false" ]; then
  gha_echo warning "No changed files in agent's commit(s) — nothing to push"
  NO_PUSH=true
fi

# Compute the branch's net changes relative to the target branch using
# merge-base. After a rebase, PRE_AGENT_HEAD..HEAD includes upstream
# changes (the rebase rewrites history so the old SHA is no longer an
# ancestor). The merge-base diff isolates only what the branch itself
# contributes — the same diff that will appear in the PR.
# Fallback chain mirrors post-code.sh: warn, try origin/TARGET..HEAD,
# then HEAD~1..HEAD. This keeps the two post-scripts aligned.
MERGE_BASE="$(git merge-base "origin/${TARGET_BRANCH}" HEAD 2>/dev/null)" || MERGE_BASE=""
if [ -n "${MERGE_BASE}" ]; then
  BRANCH_CHANGED_FILES="$(git diff --name-only "${MERGE_BASE}..HEAD")"
else
  gha_echo warning "Could not determine merge-base — trying origin/${TARGET_BRANCH}..HEAD"
  BRANCH_CHANGED_FILES="$(git diff --name-only "origin/${TARGET_BRANCH}..HEAD" 2>/dev/null \
    || git diff --name-only HEAD~1..HEAD 2>/dev/null || true)"
fi

if [ "${NO_PUSH}" = "false" ]; then
  echo "Changed files (agent commits):"
  echo "${CHANGED_FILES}" | sed 's/^/  /'

  if [ "${BRANCH_CHANGED_FILES}" != "${CHANGED_FILES}" ]; then
    echo "Branch-only changed files (merge-base-aware, used for pre-commit):"
    echo "${BRANCH_CHANGED_FILES}" | sed 's/^/  /'
  fi
fi

# ---------------------------------------------------------------------------
# 1. Authoritative secret scan (only if pushing)
# ---------------------------------------------------------------------------
if [ "${NO_PUSH}" = "false" ]; then
  echo "Running authoritative secret scan on agent's commit..."

  if ! install_gitleaks; then
    post_fail_to_pr setup-error "Failed to install gitleaks v${GITLEAKS_VERSION}"
  fi

  SCAN_RANGE="${DIFF_BASE}..HEAD"

  if ! GITLEAKS_OUTPUT="$(gitleaks detect --source . --log-opts="${SCAN_RANGE}" --redact 2>&1)"; then
    print_sanitized_gha_log "${GITLEAKS_OUTPUT}" stderr
    post_fail_to_pr secret-scan "${POST_FAILURE_SECRET_SCAN_MESSAGE}"
  fi
  echo "Secret scan passed — no leaks in agent's commit(s)"

  # -------------------------------------------------------------------------
  # 1b. Reject Signed-off-by trailers
  #
  # Agents must never produce Signed-off-by trailers. DCO is a human
  # attestation — the DCO app already waives the check for bot authors.
  # The bot noreply email makes the trailer ~90 characters, which causes
  # gitlint body-max-line-length failures in repos with a 72-char limit.
  # -------------------------------------------------------------------------
  echo "Checking for Signed-off-by trailers in agent's commit(s)..."
  if git log --format='%b' "${SCAN_RANGE}" | grep -q '^Signed-off-by:'; then
    post_fail_to_pr signed-off-by \
      "Agent commit contains a Signed-off-by trailer. Agents must not use 'git commit -s' or append Signed-off-by trailers."
  fi
  echo "Signed-off-by scan passed — no trailers in agent's commit(s)"
fi

# ---------------------------------------------------------------------------
# 2. Auto-install pre-commit tool dependencies
# ---------------------------------------------------------------------------
SCRIPT_DIR_POST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE_SCRIPT="${SCRIPT_DIR_POST}/resolve-precommit-tools.py"
INSTALL_SCRIPT="${SCRIPT_DIR_POST}/install-precommit-tools.sh"

# Fallback: these companion scripts were never migrated into this repo
# during the ADR 0058 extraction, so the BASH_SOURCE-relative lookup above
# always misses. In current fullsend reusable-workflow layouts, the
# "Prepare workspace" step typically materializes scripts/ at
# ${WORKSPACE_DIR}/scripts/ (per-org) or ${WORKSPACE_DIR}/.fullsend/scripts/
# (per-repo) — see fullsend-ai/.fullsend reusable workflows. Try those paths
# when the BASH_SOURCE-relative lookup misses.
WORKSPACE_DIR="$(forge_get_workspace_dir)"
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
# 3. Authoritative pre-commit check (only if pushing)
# ---------------------------------------------------------------------------
if [ "${NO_PUSH}" = "false" ] && [ -f .pre-commit-config.yaml ]; then
  echo "Running authoritative pre-commit on agent's changed files..."

  if ! command -v pre-commit >/dev/null 2>&1; then
    pip install "pre-commit==4.5.1" 2>/dev/null \
      || pip3 install "pre-commit==4.5.1" 2>/dev/null \
      || pipx install "pre-commit==4.5.1" 2>/dev/null \
      || gha_echo warning "Failed to install pre-commit"
  fi

  if command -v pre-commit >/dev/null 2>&1; then
    # SYNC: parallel retry block in post-code.sh section 5 — keep structure
    #       in sync (variable names differ: BRANCH_CHANGED_FILES here vs
    #       CHANGED_FILES there; SCAN_RANGE scopes differ by design).
    changed_array=()
    while IFS= read -r _changed_line; do
      changed_array+=("${_changed_line}")
    done <<< "${BRANCH_CHANGED_FILES}"
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
          post_fail_to_pr secret-scan "${POST_FAILURE_SECRET_SCAN_MESSAGE}"
        fi
        if git log --format='%b' "${SCAN_RANGE}" | grep -q '^Signed-off-by:'; then
          post_fail_to_pr signed-off-by \
            "Amended commit contains a Signed-off-by trailer after pre-commit auto-fix."
        fi

        if [ -n "${MERGE_BASE}" ]; then
          BRANCH_CHANGED_FILES="$(git diff --name-only "${MERGE_BASE}..HEAD")"
        else
          BRANCH_CHANGED_FILES="$(git diff --name-only "origin/${TARGET_BRANCH}..HEAD" 2>/dev/null \
            || git diff --name-only HEAD~1..HEAD 2>/dev/null || true)"
        fi
        if [ -z "${BRANCH_CHANGED_FILES}" ]; then
          post_fail_to_pr pre-commit-blocked \
            "Pre-commit hooks removed all changes; commit is now empty."
        fi
        changed_array=()
        while IFS= read -r _changed_line; do
          changed_array+=("${_changed_line}")
        done <<< "${BRANCH_CHANGED_FILES}"
        PRECOMMIT_RETRY_OUTPUT=""
        if PRECOMMIT_RETRY_OUTPUT="$(pre-commit run --files "${changed_array[@]}" 2>&1)"; then
          print_sanitized_gha_log "${PRECOMMIT_RETRY_OUTPUT}"
          if git diff --name-only -- "${changed_array[@]}" | grep -q .; then
            post_fail_to_pr pre-commit-blocked \
              "Retry pre-commit left additional unstaged changes; committed content would diverge from what pre-commit validated."
          fi
          echo "Pre-commit passed after auto-fix re-stage"
        else
          print_sanitized_gha_log "${PRECOMMIT_RETRY_OUTPUT}"
          post_fail_to_pr pre-commit-blocked "${PRECOMMIT_RETRY_OUTPUT}"
        fi
      else
        post_fail_to_pr pre-commit-blocked "${PRECOMMIT_OUTPUT}"
      fi
    fi
  else
    gha_echo warning "pre-commit not available — skipping authoritative check"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Push branch (only if we have commits)
# ---------------------------------------------------------------------------
if [ "${NO_PUSH}" = "false" ]; then
  forge_set_push_remote "${PUSH_TOKEN}"

  # Plain push first. Falls back to --force-with-lease when the push
  # is rejected (non-fast-forward), which happens after a rebase — the
  # agent rewrote history so the remote branch diverged. force-with-lease
  # is safe: it still rejects if someone else pushed in the meantime.
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
        post_fail_to_pr "${PUSH_CATEGORY}" "${PUSH_OUTPUT}
${FORCE_PUSH_OUTPUT}"
      fi
      print_sanitized_gha_log "${FORCE_PUSH_OUTPUT}"
    else
      PUSH_CATEGORY="$(categorize_push_failure "${PUSH_OUTPUT}")"
      post_fail_to_pr "${PUSH_CATEGORY}" "${PUSH_OUTPUT}"
    fi
  fi
  echo "Branch ${BRANCH} pushed successfully"
fi

# ---------------------------------------------------------------------------
# 5. Process structured output (agent-result.json)
# ---------------------------------------------------------------------------
forge_setup_push_token "${PUSH_TOKEN}"

# Locate process-fix-result.py relative to this script, with workspace fallback
# (see the "Auto-install pre-commit tool dependencies" comment above — this
# companion script was never migrated into this repo either).
PROCESS_SCRIPT="${SCRIPT_DIR_POST}/process-fix-result.py"

if [ ! -f "${PROCESS_SCRIPT}" ]; then
  if [ -n "${WORKSPACE_DIR:-}" ]; then
    for _ws_candidate in "${WORKSPACE_DIR}/scripts" "${WORKSPACE_DIR}/.fullsend/scripts"; do
      if [ -f "${_ws_candidate}/process-fix-result.py" ]; then
        PROCESS_SCRIPT="${_ws_candidate}/process-fix-result.py"
        break
      fi
    done
  fi
fi

# Find agent-result.json — prefer the validated iteration when set.
# RUN_DIR is the original cwd (runDir = <outputBase>/<sandboxName>), saved
# before we cd'd into REPO_DIR. The agent writes its structured output to
# iteration-<N>/output/agent-result.json within runDir.
#
# Trust boundary: FULLSEND_VALIDATED_ITERATION_DIR is set by the fullsend CLI
# on the runner — not by the sandbox or the agent. No containment check
# (realpath / prefix guard) is applied here; the value is trusted from the
# external harness. If the trust model changes, add a realpath prefix check.
if [ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]; then
  if [ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json" ]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
  else
    gha_echo error "FULLSEND_VALIDATED_ITERATION_DIR is set but does not contain agent-result.json"
    exit 1
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

if [ -z "${RESULT_FILE}" ] || [ ! -f "${RESULT_FILE}" ]; then
  gha_echo warning "No agent-result.json found — skipping summary comment"
elif [ ! -f "${PROCESS_SCRIPT}" ]; then
  gha_echo warning "process-fix-result.py not found at ${PROCESS_SCRIPT} — skipping"
else
  # Scan agent-result.json for secrets before posting content as a PR comment.
  # The agent could have been tricked into embedding sensitive data in the
  # structured output via prompt injection in the review body.
  if command -v gitleaks >/dev/null 2>&1; then
    echo "Scanning agent-result.json for secrets before posting..."
    SCAN_DIR="$(mktemp -d)"
    cp "${RESULT_FILE}" "${SCAN_DIR}/agent-result.json"
    if ! gitleaks detect --source "${SCAN_DIR}" --no-git --redact 2>/dev/null; then
      rm -rf "${SCAN_DIR}"
      post_fail_to_pr secret-scan "${POST_FAILURE_SECRET_SCAN_MESSAGE}"
    fi
    rm -rf "${SCAN_DIR}"
  fi

  echo "Processing agent-result.json: ${RESULT_FILE}"
  PROCESS_EXIT=0
  python3 "${PROCESS_SCRIPT}" "${RESULT_FILE}" "${REPO_FULL_NAME}" "${PR_NUMBER}" || PROCESS_EXIT=$?
  if [ "${PROCESS_EXIT}" -eq 1 ]; then
    post_fail_to_pr process-output-failed \
      "process-fix-result.py failed with exit code 1 (bad input) for PR #${PR_NUMBER} in ${REPO_FULL_NAME}"
  elif [ "${PROCESS_EXIT}" -ne 0 ]; then
    gha_echo warning "process-fix-result.py exited ${PROCESS_EXIT} — continuing with labels/summary"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Iteration-cap warning label
# ---------------------------------------------------------------------------
ITERATION="${FIX_ITERATION:-1}"
BOT_CAP="${ITERATION_CAP:-5}"
WARN_THRESHOLD=$(( BOT_CAP - 1 ))

# The needs-human label is based on the bot cap — it signals that the
# autonomous review→fix loop needs human direction. Human-triggered /fs-fix
# runs have a separate, higher cap (ITERATION_CAP_HUMAN).
if [ "${ITERATION}" -ge "${WARN_THRESHOLD}" ] && is_bot_user "${TRIGGER_SOURCE}"; then
  gha_echo warning "Fix iteration ${ITERATION} is approaching bot cap of ${BOT_CAP}"
  forge_create_label "needs-human" "Agent loop needs human intervention" "D93F0B"
  # shellcheck disable=SC2153
  forge_add_pr_label "${PR_NUMBER}" "needs-human"
fi

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
echo ""
echo "Fix post-script complete:"
echo "  Branch: ${BRANCH:-none}"
echo "  PR: #${PR_NUMBER}"
if [ "${NO_PUSH}" = "true" ]; then echo "  Pushed: no"; else echo "  Pushed: yes"; fi
echo "  Trigger: ${TRIGGER_SOURCE}"
if is_bot_user "${TRIGGER_SOURCE}"; then
  echo "  Iteration: ${ITERATION} of ${BOT_CAP} (bot cap)"
else
  echo "  Iteration: ${ITERATION} of ${ITERATION_CAP_HUMAN:-10} (human cap, total across bot+human)"
fi
