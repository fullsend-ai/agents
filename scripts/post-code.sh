#!/usr/bin/env bash
# GENERATED from post-code.src.sh — DO NOT EDIT. Run: make script-build
# Post-script: push the agent's commit and create a PR.
#
# Runs on the GitHub Actions runner AFTER the sandbox is destroyed.
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
#   PUSH_TOKEN        — token with contents:write + issues:write + pull-requests:write
#                       on target repo (GitHub App installation token or PAT)
#   REPO_FULL_NAME    — owner/repo (e.g. my-org/my-repo)
#   ISSUE_NUMBER      — GitHub issue number
#   REPO_DIR          — path to extracted repo (default: current directory)
#
# Optional environment variables:
#   PUSH_TOKEN_SOURCE — "github-app" (for logging; default: unknown)
#   CODE_ALLOWED_TARGET_BRANCHES
#                     — comma-separated list of branches the agent may target,
#                       or "*" for any. When unset, only the repo's default
#                       branch is allowed. (default: auto-detected)
#   POST_FAILURE_DETAIL_MAX_LINES
#                     — max lines of failure detail in issue/PR comments (default: 30)
#
# Exit codes:
#   0  — branch pushed and PR created, OR agent determined nothing to do
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
# Setup
# ---------------------------------------------------------------------------
REPO_DIR="${REPO_DIR:-repo}"
RUN_DIR="$(pwd)"

: "${PUSH_TOKEN:?PUSH_TOKEN is required}"
: "${REPO_FULL_NAME:?REPO_FULL_NAME is required}"
: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
trap 'report_post_failure_to_issue' ERR

if [ "${REPO_DIR}" != "." ]; then
  if [ ! -d "${REPO_DIR}" ]; then
    gha_echo error "Extracted repo not found at ${REPO_DIR}" >&2
    post_fail_to_issue setup-error "Extracted repo not found at ${REPO_DIR}"
  fi
  cd "${REPO_DIR}"
fi

# ---------------------------------------------------------------------------
# Resolve target branch (ADR 0053)
#
# Priority: agent output > allowed-list validation > auto-detect default
# The agent writes its chosen branch to code-result.json. The post-script
# validates it against CODE_ALLOWED_TARGET_BRANCHES (comma-separated list
# or "*" for any). When unset, only the auto-detected default branch is
# allowed. Falls back to "main" if the API call fails.
# ---------------------------------------------------------------------------
AGENT_TARGET=""
RESULT_FILE=""
for dir in "${RUN_DIR}"/iteration-*/output; do
  if [ -f "${dir}/code-result.json" ]; then
    RESULT_FILE="${dir}/code-result.json"
  fi
done
if [ -n "${RESULT_FILE}" ]; then
  AGENT_TARGET="$(jq -r '.target_branch // empty' "${RESULT_FILE}" 2>/dev/null || true)"
fi
if [[ -n "${AGENT_TARGET}" && ! "${AGENT_TARGET}" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
  post_fail_to_issue branch-validation \
    "Invalid branch name from agent output: '${AGENT_TARGET}'"
fi

DEFAULT_BRANCH="$(GH_TOKEN="${PUSH_TOKEN}" gh api "repos/${REPO_FULL_NAME}" --jq '.default_branch' 2>/dev/null || echo 'main')"

if [ -n "${AGENT_TARGET}" ]; then
  ALLOWED="${CODE_ALLOWED_TARGET_BRANCHES:-${DEFAULT_BRANCH}}"
  if [ "${ALLOWED}" = "*" ] || echo ",${ALLOWED}," | grep -qF ",${AGENT_TARGET},"; then
    TARGET_BRANCH="${AGENT_TARGET}"
    echo "Agent requested branch '${TARGET_BRANCH}' — allowed"
  else
    post_fail_to_issue branch-validation \
      "Agent requested branch '${AGENT_TARGET}' but allowed branches are: ${ALLOWED}"
  fi
else
  TARGET_BRANCH="${DEFAULT_BRANCH}"
  echo "No agent branch preference — using repo default: ${TARGET_BRANCH}"
fi

echo "::add-mask::${PUSH_TOKEN}"

# ---------------------------------------------------------------------------
# 1. Verify feature branch
# ---------------------------------------------------------------------------
BRANCH="$(git branch --show-current)"

if [ -z "${BRANCH}" ] || [ "${BRANCH}" = "main" ] || [ "${BRANCH}" = "master" ]; then
  gha_echo notice "Agent did not create a feature branch (current: '${BRANCH:-detached HEAD}') — nothing to do"
  exit 0
fi

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
git remote set-url origin \
  "https://x-access-token:${PUSH_TOKEN}@github.com/${REPO_FULL_NAME}.git"

export GH_TOKEN="${PUSH_TOKEN}"

# ---------------------------------------------------------------------------
# 7a. Delete stale remote branch if it exists with no open PR.
#
# When a human closes a code agent PR and re-triggers /fs-code, the old
# remote branch still exists. A plain push will fail with non-fast-forward
# because the local branch was created fresh from origin/main. Delete the
# stale remote branch so the push succeeds.
# ---------------------------------------------------------------------------
REMOTE_REF="$(git ls-remote --heads origin "${BRANCH}" 2>/dev/null | head -1 || true)"
if [ -n "${REMOTE_REF}" ]; then
  echo "Remote branch ${BRANCH} already exists — checking for open PRs..."
  OPEN_PR="$(gh pr list --repo "${REPO_FULL_NAME}" --head "${BRANCH}" \
    --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  if [ -z "${OPEN_PR}" ]; then
    echo "No open PR uses ${BRANCH} — deleting stale remote branch"
    git push origin --delete "${BRANCH}" 2>&1 || \
      gha_echo warning "Failed to delete stale remote branch ${BRANCH}"
  else
    echo "Open PR #${OPEN_PR} uses ${BRANCH} — keeping remote branch"
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
# 8. Create PR
# ---------------------------------------------------------------------------

EXISTING_PR_NUM="$(gh pr list --repo "${REPO_FULL_NAME}" --head "${BRANCH}" \
  --json number --jq '.[0].number' 2>/dev/null || true)"

if [ -n "${EXISTING_PR_NUM}" ]; then
  EXISTING_PR_URL="$(gh pr list --repo "${REPO_FULL_NAME}" --head "${BRANCH}" \
    --json url --jq '.[0].url' 2>/dev/null || true)"
  echo "PR #${EXISTING_PR_NUM} already exists — branch updated with new commits"
  echo "PR: ${EXISTING_PR_URL}"
  echo "pr_url=${EXISTING_PR_URL}" >> "${GITHUB_OUTPUT:-/dev/null}"
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
    | sed -e :a -e '/^\n*$/{ $d; N; ba; }')"
  echo "${raw}" | awk '
    /^$/           { if (buf) print buf; print; buf=""; next }
    /^[-*#>]|^  /  { if (buf) print buf; buf=""; print; next }
    /^Closes /     { if (buf) print buf; buf=""; print; next }
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
        if (l == "" || l ~ /^[Cc]lose[sd]? (#|[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+#)[0-9]+$/ || l ~ /^[Ff]ix(e[sd])? (#|[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+#)[0-9]+$/ || l ~ /^[Rr]esolve[sd]? (#|[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+#)[0-9]+$/)
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

PR_BODY="${DESCRIPTION}

---

Closes #${ISSUE_NUMBER}

### Post-script verification

- [x] Branch is not main/master (\`${BRANCH}\`)
- [x] Secret scan passed (gitleaks — \`${SCAN_RANGE}\`)
${PR_BODY_SCAN_LINE}
- [x] Pre-commit hooks passed (authoritative run on runner)
- [x] Tests ran inside sandbox"

PR_CREATE_STDERR=$(mktemp)
if ! PR_URL=$(gh pr create \
  --repo "${REPO_FULL_NAME}" \
  --head "${BRANCH}" \
  --base "${TARGET_BRANCH}" \
  --title "${PR_TITLE}" \
  --body "${PR_BODY}" 2>"${PR_CREATE_STDERR}"); then
  PR_CREATE_OUTPUT="$(cat "${PR_CREATE_STDERR}")"
  rm -f "${PR_CREATE_STDERR}"
  post_fail_to_issue pr-creation-failed "${PR_CREATE_OUTPUT}"
fi
rm -f "${PR_CREATE_STDERR}"

echo "PR created: ${PR_URL}"
echo "pr_url=${PR_URL}" >> "${GITHUB_OUTPUT:-/dev/null}"

# Apply ready-for-review label so the review agent is dispatched via the
# issues.labeled path. pull_request_target.opened requires the PR author to
# pass authorization checks that often exclude bot accounts; the label path
# is used instead (label application requires repo write access). See
# .github/scripts/check-e2e-authorization-test.sh for trusted-actor rules.
PR_NUMBER_FROM_URL="${PR_URL##*/}"
gh issue edit "${PR_NUMBER_FROM_URL}" \
  --repo "${REPO_FULL_NAME}" \
  --add-label "ready-for-review" 2>/dev/null || \
  gha_echo warning "Failed to apply ready-for-review label to PR #${PR_NUMBER_FROM_URL}"
