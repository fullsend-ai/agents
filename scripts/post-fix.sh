#!/usr/bin/env bash
# GENERATED from post-fix.src.sh — DO NOT EDIT. Run: make script-build
# Post-script: push the fix agent's commit and process structured output.
#
# Runs on the GitHub Actions runner AFTER the sandbox is destroyed.
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
# After pushing, this script processes fix-result.json to:
#   - Post a summary comment on the PR documenting fixes and disagreements
#   - Apply labels (needs-human) if the iteration cap is approaching
#
# Required environment variables:
#   PUSH_TOKEN        — token with contents:write + issues:write + pull-requests:write
#                       on target repo (GitHub App installation token or PAT)
#   REPO_FULL_NAME    — owner/repo
#   PR_NUMBER         — PR number
#   REPO_DIR          — path to extracted repo (default: current directory)
#   TRIGGER_SOURCE    — GitHub username that triggered the fix (usernames ending in [bot] are bot triggers)
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
# shellcheck source=lib/post-failure-report.lib.sh
# BEGIN bundled: lib/post-failure-report.lib.sh
# post-failure-report.lib.sh — Categorized, sanitized failure comments for post-scripts.
#
# Source from post-code.src.sh / post-fix.src.sh:
#   source "${SCRIPT_DIR}/lib/post-failure-report.lib.sh"
#
# Set POST_FAILURE_CATEGORY / POST_FAILURE_DETAIL before exit, or call post_fail.

# shellcheck shell=bash

[[ -n "${POST_FAILURE_REPORT_SH_LOADED:-}" ]] && return 0
POST_FAILURE_REPORT_SH_LOADED=1

POST_FAILURE_CATEGORY="${POST_FAILURE_CATEGORY:-}"
POST_FAILURE_DETAIL="${POST_FAILURE_DETAIL:-}"
# Guard against duplicate posts within one script invocation (e.g. trap + explicit
# call). Intentionally not deduped across workflow re-runs: the user should see
# a fresh comment when they actively retry.
POST_FAILURE_REPORTED=false
POST_FAILURE_SECRET_SCAN_MESSAGE="Secret scan blocked the push. See workflow logs for details."

# Maximum lines of sanitized detail to include in issue/PR comments.
POST_FAILURE_DETAIL_MAX_LINES="${POST_FAILURE_DETAIL_MAX_LINES:-30}"

_sanitize_workflow_value() {
  local value="$1"
  value="${value//::/}"
  value="${value//%0A/}"
  value="${value//%0a/}"
  value="${value//%0D/}"
  value="${value//%0d/}"
  printf '%s' "${value}"
}

# Neutralize line-start GHA workflow commands in comment bodies without
# stripping mid-string :: (e.g. std::string in compiler output).
sanitize_comment_workflow_commands() {
  local value="$1"
  value="$(printf '%s\n' "${value}" | sed -E \
    -e 's/^::(warning|error|notice|debug|group|endgroup):://')"
  value="${value//%0A/}"
  value="${value//%0a/}"
  value="${value//%0D/}"
  value="${value//%0d/}"
  # printf '%s' drops trailing newline added by the pipeline above.
  printf '%s' "${value}"
}

# Strip GitHub Actions workflow-command sequences from runner log output.
sanitize_gha_log_output() {
  _sanitize_workflow_value "$1"
}

# Print sanitized command output to stdout or stderr without SC2005 echo-$(cmd) noise.
print_sanitized_gha_log() {
  local sanitized
  sanitized="$(sanitize_gha_log_output "$1")"
  if [ "${2:-}" = "stderr" ]; then
    printf '%s\n' "${sanitized}" >&2
  else
    printf '%s\n' "${sanitized}"
  fi
}

# Emit a GitHub Actions workflow command with a sanitised message body.
gha_echo() {
  local level="$1"
  shift
  printf '::%s::%s\n' "${level}" "$(sanitize_gha_log_output "$*")"
}

_redact_multiline_pem() {
  awk '
    function is_pem_begin(line) {
      return tolower(line) ~ /-----begin .*private key-----/
    }
    function is_pem_end(line) {
      return tolower(line) ~ /-----end .*private key-----/
    }
    is_pem_begin($0) {
      print "[REDACTED PRIVATE KEY]"
      in_pem = 1
      next
    }
    is_pem_end($0) {
      in_pem = 0
      next
    }
    in_pem { next }
    { print }
  '
}

_redact_literal_token() {
  local detail="$1"
  local token="$2"

  if [ -z "${token}" ]; then
    printf '%s' "${detail}"
    return 0
  fi

  export REDACT_LITERAL_TOKEN="${token}"
  awk '
    BEGIN {
      token = ENVIRON["REDACT_LITERAL_TOKEN"]
      repl = "[REDACTED]"
    }
    {
      s = $0
      while ((i = index(s, token)) > 0) {
        s = substr(s, 1, i - 1) repl substr(s, i + length(token))
      }
      print s
    }
  ' <<< "${detail}" | {
    local line result=""
    while IFS= read -r line || [ -n "${line}" ]; do
      if [ -n "${result}" ]; then
        result="${result}"$'\n'"${line}"
      else
        result="${line}"
      fi
    done
    printf '%s' "${result}"
  }
  unset REDACT_LITERAL_TOKEN
}

# Strip tokens and truncate noisy command output before posting publicly.
sanitize_failure_detail() {
  local detail="$1"
  local max_lines="${2:-${POST_FAILURE_DETAIL_MAX_LINES}}"

  detail="$(printf '%s\n' "${detail}" \
    | sed -E \
      -e 's/gh[pousr]_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
      -e 's/github_pat_[A-Za-z0-9_]+/[REDACTED]/g' \
      -e 's/x-access-token:[^@[:space:]]+/x-access-token:[REDACTED]/g' \
      -e 's/(Bearer|token)[[:space:]]+[A-Za-z0-9._-]+/\1 [REDACTED]/gi' \
    | _redact_multiline_pem)"

  if [ -n "${PUSH_TOKEN:-}" ]; then
    detail="$(_redact_literal_token "${detail}" "${PUSH_TOKEN}")"
  fi
  if [ -n "${GH_TOKEN:-}" ] && [ "${GH_TOKEN}" != "${PUSH_TOKEN:-}" ]; then
    detail="$(_redact_literal_token "${detail}" "${GH_TOKEN}")"
  fi

  detail="$(sanitize_comment_workflow_commands "${detail}")"

  if [ "${max_lines}" -gt 0 ]; then
    detail="$(printf '%s\n' "${detail}" | tail -n "${max_lines}")"
  fi

  printf '%s' "${detail}"
}

set_post_failure() {
  POST_FAILURE_CATEGORY="$1"
  POST_FAILURE_DETAIL="$2"
}

categorize_push_failure() {
  local push_output="$1"

  if echo "${push_output}" | grep -qiE \
    'workflow.*without.*workflows?[[:space:]]+permission|refusing to allow.*GitHub App.*workflow'; then
    echo "push-workflow-permission"
    return 0
  fi

  if echo "${push_output}" | grep -qiE \
    'non-fast-forward|rejected|fetch first|protected branch|GH006|permission denied'; then
    echo "push-rejected"
    return 0
  fi

  echo "push-failed"
}

post_failure_category_label() {
  case "$1" in
    secret-scan) echo "Secret scan blocked" ;;
    pre-commit-blocked) echo "Pre-commit blocked" ;;
    signed-off-by) echo "Signed-off-by rejected" ;;
    push-workflow-permission) echo "Push rejected — workflows permission" ;;
    push-rejected) echo "Push rejected" ;;
    push-failed) echo "Push failed" ;;
    pr-creation-failed) echo "PR creation failed" ;;
    branch-validation) echo "Branch validation failed" ;;
    setup-error) echo "Setup error" ;;
    process-output-failed) echo "Structured output processing failed" ;;
    *) echo "Post-script failed" ;;
  esac
}

post_failure_environmental_note() {
  case "$1" in
    push-workflow-permission)
      cat <<'EOF'
> **Environmental limitation:** the GitHub App lacks `workflows` write permission on this repository. The agent's patch is not necessarily wrong — update repo or app permissions (or avoid `.github/workflows/` changes) and retry.
EOF
      ;;
    *)
      printf ''
      ;;
  esac
}

post_failure_workflow_run_url() {
  local repo_full_name="$1"
  local run_repo="${GITHUB_REPOSITORY:-${repo_full_name}}"
  printf '%s/%s/actions/runs/%s' \
    "${GITHUB_SERVER_URL:-https://github.com}" \
    "${run_repo}" \
    "${GITHUB_RUN_ID:-unknown}"
}

build_post_failure_comment() {
  local agent_kind="$1"       # code | fix
  local exit_code="$2"
  local category="$3"
  local detail="$4"
  local repo_full_name="$5"
  local retry_command="$6"

  local label env_note sanitized_detail run_url detail_block indented_detail

  label="$(post_failure_category_label "${category}")"
  env_note="$(post_failure_environmental_note "${category}")"
  run_url="$(post_failure_workflow_run_url "${repo_full_name}")"

  if [ "${category}" = "secret-scan" ]; then
    sanitized_detail="${POST_FAILURE_SECRET_SCAN_MESSAGE}"
  else
    sanitized_detail="$(sanitize_failure_detail "${detail}")"
  fi

  if [ -n "${sanitized_detail}" ]; then
    indented_detail="$(printf '%s\n' "${sanitized_detail}" | sed 's/^/    /')"
    detail_block="$(cat <<EOF

**Details:**
${indented_detail}
EOF
)"
  else
    detail_block=""
  fi

  if [ -n "${env_note}" ]; then
    env_note="${env_note}

"
  fi

  cat <<EOF
⚠️ **Post-${agent_kind} script failed** — ${label} (exit code ${exit_code})

The ${agent_kind} agent completed, but the post-${agent_kind} script failed before finishing.

${env_note}**Workflow run:** ${run_url}
${detail_block}
Please check the workflow logs for full details and retry with \`${retry_command}\` if appropriate.
EOF
}

_post_failure_ensure_token() {
  if [ -z "${GH_TOKEN:-}" ]; then
    export GH_TOKEN="${PUSH_TOKEN:-}"
  fi
}

report_post_failure_to_issue() {
  local exit_code="${1:-$?}"
  local safe_issue_number

  if [ "${POST_FAILURE_REPORTED}" = "true" ]; then
    return 0
  fi
  POST_FAILURE_REPORTED=true

  _post_failure_ensure_token

  local category="${POST_FAILURE_CATEGORY:-post-script-error}"
  local detail="${POST_FAILURE_DETAIL:-Post-code script failed before push or PR creation completed.}"
  local body
  safe_issue_number="$(_sanitize_workflow_value "${ISSUE_NUMBER}")"
  # ISSUE_NUMBER and REPO_FULL_NAME are required by post-code.src.sh before sourcing.
  # shellcheck disable=SC2153
  body="$(build_post_failure_comment \
    "code" "${exit_code}" "${category}" "${detail}" \
    "${REPO_FULL_NAME}" "/fs-code")"

  gha_echo warning "Posting failure comment to issue #${safe_issue_number}..."
  if ! gh issue comment "${ISSUE_NUMBER}" \
    --repo "${REPO_FULL_NAME}" \
    --body "${body}" 2>/dev/null; then
    gha_echo warning "Failed to post error comment to issue #${safe_issue_number} (check issues:write on PUSH_TOKEN)"
  fi
}

report_post_failure_to_pr() {
  local exit_code="${1:-$?}"
  local safe_pr_number

  if [ "${POST_FAILURE_REPORTED}" = "true" ]; then
    return 0
  fi
  POST_FAILURE_REPORTED=true

  _post_failure_ensure_token

  local category="${POST_FAILURE_CATEGORY:-post-script-error}"
  local detail="${POST_FAILURE_DETAIL:-Post-fix script failed before push or PR update completed.}"
  local body
  safe_pr_number="$(_sanitize_workflow_value "${PR_NUMBER}")"
  # PR_NUMBER and REPO_FULL_NAME are required by post-fix.src.sh before sourcing.
  # shellcheck disable=SC2153
  body="$(build_post_failure_comment \
    "fix" "${exit_code}" "${category}" "${detail}" \
    "${REPO_FULL_NAME}" "/fs-fix")"

  gha_echo warning "Posting failure comment to PR #${safe_pr_number}..."
  if ! gh pr comment "${PR_NUMBER}" \
    --repo "${REPO_FULL_NAME}" \
    --body "${body}" 2>/dev/null; then
    gha_echo warning "Failed to post error comment to PR #${safe_pr_number} (check pull-requests:write on PUSH_TOKEN)"
  fi
}

post_fail_to_issue() {
  local category="$1"
  local detail="${2:-}"
  set_post_failure "${category}" "${detail}"
  report_post_failure_to_issue 1
  exit 1
}

post_fail_to_pr() {
  local category="$1"
  local detail="${2:-}"
  set_post_failure "${category}" "${detail}"
  report_post_failure_to_pr 1
  exit 1
}
# END bundled: lib/post-failure-report.lib.sh
# shellcheck source=lib/gitleaks-install.lib.sh
# BEGIN bundled: lib/gitleaks-install.lib.sh
# gitleaks-install.lib.sh — Platform-aware gitleaks download and verification.
#
# Source from post-code.src.sh / post-fix.src.sh:
#   source "${SCRIPT_DIR_POST}/lib/gitleaks-install.lib.sh"
#
# Provides:
#   resolve_platform   — detect OS/arch and print a platform key (e.g. linux_x64)
#   gitleaks_sha256    — print the SHA-256 checksum for a given platform key
#   verify_checksum    — verify a file against an expected SHA-256 hash
#   install_gitleaks   — download, verify, and install the gitleaks binary
#
# Uses case statements (not declare -A / mapfile) so the script runs on
# bash 3.2 (macOS system bash).

# shellcheck shell=bash

[[ -n "${GITLEAKS_INSTALL_SH_LOADED:-}" ]] && return 0
GITLEAKS_INSTALL_SH_LOADED=1

GITLEAKS_VERSION="8.30.1"

gitleaks_sha256() {
  case "$1" in
    linux_x64)    echo "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb" ;;
    linux_arm64)  echo "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080" ;;
    darwin_x64)   echo "dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709" ;;
    darwin_arm64) echo "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5" ;;
    *) return 1 ;;
  esac
}

resolve_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)
      echo "::error::Unsupported OS for gitleaks: ${os}" >&2
      return 1
      ;;
  esac

  case "${arch}" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "::error::Unsupported architecture for gitleaks: ${arch}" >&2
      return 1
      ;;
  esac

  echo "${os}_${arch}"
}

verify_checksum() {
  local file="$1"
  local expected="$2"

  if command -v sha256sum >/dev/null 2>&1; then
    echo "${expected}  ${file}" | sha256sum -c -
  elif command -v shasum >/dev/null 2>&1; then
    echo "${expected}  ${file}" | shasum -a 256 -c -
  else
    echo "::error::Neither sha256sum nor shasum found — cannot verify gitleaks checksum" >&2
    return 1
  fi
}

install_gitleaks() {
  if command -v gitleaks >/dev/null 2>&1; then
    return 0
  fi

  echo "Installing gitleaks v${GITLEAKS_VERSION}..."
  local platform checksum tarball
  platform="$(resolve_platform)"
  checksum="$(gitleaks_sha256 "${platform}" || true)"
  if [ -z "${checksum}" ]; then
    echo "::error::No gitleaks checksum for platform: ${platform}" >&2
    return 1
  fi
  mkdir -p "${HOME}/.local/bin"
  tarball="$(mktemp)"
  if ! curl -fsSL \
       "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${platform}.tar.gz" \
       -o "${tarball}" \
     || ! verify_checksum "${tarball}" "${checksum}" \
     || ! tar xzf "${tarball}" -C "${HOME}/.local/bin" gitleaks; then
    rm -f "${tarball}"
    echo "::error::Failed to download and verify gitleaks v${GITLEAKS_VERSION} (${platform})" >&2
    return 1
  fi
  rm -f "${tarball}"
  export PATH="${HOME}/.local/bin:${PATH}"
}
# END bundled: lib/gitleaks-install.lib.sh

# ---------------------------------------------------------------------------
# Helper: Bot user detection
# ---------------------------------------------------------------------------
is_bot_user() {
  [[ "${1:-}" =~ \[bot\]$ ]]
}

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

if [ "${REPO_DIR}" != "." ]; then
  if [ ! -d "${REPO_DIR}" ]; then
    gha_echo error "Extracted repo not found at ${REPO_DIR}" >&2
    post_fail_to_pr setup-error "Extracted repo not found at ${REPO_DIR}"
  fi
  cd "${REPO_DIR}"
fi

TARGET_BRANCH="${TARGET_BRANCH:-main}"

echo "::add-mask::${PUSH_TOKEN}"

# ---------------------------------------------------------------------------
# 0. Check for agent commits
# ---------------------------------------------------------------------------
BRANCH="$(git branch --show-current)"

if [ -z "${BRANCH}" ] || [ "${BRANCH}" = "main" ] || [ "${BRANCH}" = "master" ]; then
  gha_echo warning "Agent did not produce a commit on a feature branch (current: '${BRANCH:-detached HEAD}')"
  gha_echo warning "Processing structured output only (no push)."
  # Still process fix-result.json to post a summary comment.
  NO_PUSH=true
else
  NO_PUSH=false
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
# ${GITHUB_WORKSPACE}/scripts/ (per-org) or ${GITHUB_WORKSPACE}/.fullsend/scripts/
# (per-repo) — see fullsend-ai/.fullsend reusable workflows. Try those paths
# when the BASH_SOURCE-relative lookup misses.
if [ ! -f "${RESOLVE_SCRIPT}" ] || [ ! -f "${INSTALL_SCRIPT}" ]; then
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    for _ws_candidate in "${GITHUB_WORKSPACE}/scripts" "${GITHUB_WORKSPACE}/.fullsend/scripts"; do
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
  git remote set-url origin \
    "https://x-access-token:${PUSH_TOKEN}@github.com/${REPO_FULL_NAME}.git"

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
# 5. Process structured output (fix-result.json)
# ---------------------------------------------------------------------------
export GH_TOKEN="${PUSH_TOKEN}"

# Locate process-fix-result.py relative to this script, with workspace fallback
# (see the "Auto-install pre-commit tool dependencies" comment above — this
# companion script was never migrated into this repo either).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_SCRIPT="${SCRIPT_DIR}/process-fix-result.py"

if [ ! -f "${PROCESS_SCRIPT}" ]; then
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    for _ws_candidate in "${GITHUB_WORKSPACE}/scripts" "${GITHUB_WORKSPACE}/.fullsend/scripts"; do
      if [ -f "${_ws_candidate}/process-fix-result.py" ]; then
        PROCESS_SCRIPT="${_ws_candidate}/process-fix-result.py"
        break
      fi
    done
  fi
fi

# Find fix-result.json in the output directory.
# RUN_DIR is the original cwd (runDir = <outputBase>/<sandboxName>), saved
# before we cd'd into REPO_DIR. The agent writes its structured output to
# iteration-<N>/output/fix-result.json within runDir. Uses glob order
# (naturally ascending iteration numbers) to find the last iteration,
# matching the pattern in post-triage.sh.
RESULT_FILE=""
for dir in "${RUN_DIR}"/iteration-*/output; do
  if [ -f "${dir}/fix-result.json" ]; then
    RESULT_FILE="${dir}/fix-result.json"
  fi
done

if [ -z "${RESULT_FILE}" ] || [ ! -f "${RESULT_FILE}" ]; then
  gha_echo warning "No fix-result.json found — skipping summary comment"
elif [ ! -f "${PROCESS_SCRIPT}" ]; then
  gha_echo warning "process-fix-result.py not found at ${PROCESS_SCRIPT} — skipping"
else
  # Scan fix-result.json for secrets before posting content as a PR comment.
  # The agent could have been tricked into embedding sensitive data in the
  # structured output via prompt injection in the review body.
  if command -v gitleaks >/dev/null 2>&1; then
    echo "Scanning fix-result.json for secrets before posting..."
    SCAN_DIR="$(mktemp -d)"
    cp "${RESULT_FILE}" "${SCAN_DIR}/fix-result.json"
    if ! gitleaks detect --source "${SCAN_DIR}" --no-git --redact 2>/dev/null; then
      rm -rf "${SCAN_DIR}"
      post_fail_to_pr secret-scan "${POST_FAILURE_SECRET_SCAN_MESSAGE}"
    fi
    rm -rf "${SCAN_DIR}"
  fi

  echo "Processing fix-result.json: ${RESULT_FILE}"
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
  gh label create "needs-human" --repo "${REPO_FULL_NAME}" \
    --description "Agent loop needs human intervention" --color "D93F0B" \
    2>/dev/null || true
  gh pr edit "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" \
    --add-label "needs-human" 2>/dev/null || true
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
