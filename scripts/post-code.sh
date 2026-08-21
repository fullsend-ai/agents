#!/usr/bin/env bash
# GENERATED from post-code.src.sh — DO NOT EDIT. Run: make script-build
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
      -e 's/glpat-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
      -e 's/x-access-token:[^@[:space:]]+/x-access-token:[REDACTED]/g' \
      -e 's/oauth2:[^@[:space:]]+/oauth2:[REDACTED]/g' \
      -e 's/(Bearer|token|PRIVATE-TOKEN:)[[:space:]]*[A-Za-z0-9._-]+/\1 [REDACTED]/gi' \
    | _redact_multiline_pem)"

  if [ -n "${PUSH_TOKEN:-}" ]; then
    detail="$(_redact_literal_token "${detail}" "${PUSH_TOKEN}")"
  fi
  if [ -n "${GH_TOKEN:-}" ] && [ "${GH_TOKEN}" != "${PUSH_TOKEN:-}" ]; then
    detail="$(_redact_literal_token "${detail}" "${GH_TOKEN}")"
  fi
  if [ -n "${GITLAB_TOKEN:-}" ] && [ "${GITLAB_TOKEN}" != "${PUSH_TOKEN:-}" ]; then
    detail="$(_redact_literal_token "${detail}" "${GITLAB_TOKEN}")"
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

post_failure_security_note() {
  case "$1" in
    push-workflow-permission)
      cat <<'EOF'
> **Security boundary:** the coder app intentionally lacks `workflows` write permission. Changes to `.github/workflows/` must be made outside the agent (e.g., via a manual PR). Re-run the agent without workflow file changes, or apply those changes separately.
EOF
      ;;
    *)
      printf ''
      ;;
  esac
}

post_failure_workflow_run_url() {
  local repo_full_name="$1"
  if declare -F forge_get_workflow_run_url >/dev/null 2>&1; then
    forge_get_workflow_run_url
    return 0
  fi
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
  env_note="$(post_failure_security_note "${category}")"
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
  if [ "${FULLSEND_FORGE:-}" = "gitlab" ]; then
    if [ -z "${GITLAB_TOKEN:-}" ]; then
      export GITLAB_TOKEN="${PUSH_TOKEN:-}"
    fi
  else
    if [ -z "${GH_TOKEN:-}" ]; then
      export GH_TOKEN="${PUSH_TOKEN:-}"
    fi
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
  # shellcheck disable=SC2153
  safe_issue_number="$(_sanitize_workflow_value "${ISSUE_NUMBER}")"
  # ISSUE_NUMBER and REPO_FULL_NAME are required by post-code.src.sh before sourcing.
  # shellcheck disable=SC2153
  body="$(build_post_failure_comment \
    "code" "${exit_code}" "${category}" "${detail}" \
    "${REPO_FULL_NAME}" "/fs-code")"

  gha_echo warning "Posting failure comment to issue #${safe_issue_number}..."
  if declare -F forge_post_issue_comment >/dev/null 2>&1; then
    if ! forge_post_issue_comment "${body}"; then
      gha_echo warning "Failed to post error comment to issue #${safe_issue_number}"
    fi
  else
    if ! gh issue comment "${ISSUE_NUMBER}" \
      --repo "${REPO_FULL_NAME}" \
      --body "${body}" 2>/dev/null; then
      gha_echo warning "Failed to post error comment to issue #${safe_issue_number} (check issues:write on PUSH_TOKEN)"
    fi
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
  if declare -F forge_post_pr_comment >/dev/null 2>&1; then
    if ! forge_post_pr_comment "${PR_NUMBER}" "${body}"; then
      gha_echo warning "Failed to post error comment to PR #${safe_pr_number}"
    fi
  else
    if ! gh pr comment "${PR_NUMBER}" \
      --repo "${REPO_FULL_NAME}" \
      --body "${body}" 2>/dev/null; then
      gha_echo warning "Failed to post error comment to PR #${safe_pr_number} (check pull-requests:write on PUSH_TOKEN)"
    fi
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
# shellcheck source=lib/pr-assignee.lib.sh
# BEGIN bundled: lib/pr-assignee.lib.sh
# pr-assignee.lib.sh — Resolve and assign a human owner for code-agent PRs.
#
# Source from post-code.src.sh (after post-failure-report.lib.sh for gha_echo):
#   source "${SCRIPT_DIR}/lib/pr-assignee.lib.sh"
#
# Precedence (first human match wins):
#   1. Most recent human /fs-code commenter on the issue (API lookup)
#   2. First human issue assignee
#   3. Human issue author
#
# Never assigns bots or GitHub Apps. Assignment is best-effort.
# No workflow TRIGGER_SOURCE plumbing required.

# shellcheck shell=bash

[[ -n "${PR_ASSIGNEE_SH_LOADED:-}" ]] && return 0
PR_ASSIGNEE_SH_LOADED=1

# Return 0 when login looks like a human GitHub user (not a bot/App).
is_human_github_user() {
  local login="${1:-}"
  if [[ -z "${login}" ]]; then
    return 1
  fi
  case "${login}" in
    app/*|dependabot) return 1 ;;
  esac
  if [[ "${login}" =~ \[bot\]$ ]]; then
    return 1
  fi
  return 0
}

# From a REST comments JSON array, return the most recent human /fs-code invoker.
# Accepts REST shape ({user.login, body}) or GraphQL-ish ({author.login, body}).
# Matches dispatch.yml: first word of the first line is /fs-code (leading
# whitespace ignored, same as awk '{print $1}').
find_fs_code_invoker() {
  local comments_json="${1:-}"
  if [[ -z "${comments_json}" || "${comments_json}" == "null" ]]; then
    return 1
  fi

  local login
  login="$(echo "${comments_json}" | jq -r '
    def is_bot:
      (. == "dependabot") or startswith("app/") or test("\\[bot\\]$");
    # Guard [0] // "" so null/missing bodies do not abort the whole filter.
    def first_word:
      ((. // "") | split("\n")[0] // "" | gsub("\r$"; "")
        | sub("^[[:space:]]+"; "") | split(" ")[0] // "");
    [
      .[]
      | (.user.login // .author.login // "") as $login
      | select(($login | length > 0) and ($login | is_bot | not))
      | select((.body | first_word) == "/fs-code")
      | $login
    ] | last // empty
  ' 2>/dev/null || true)"

  if [[ -n "${login}" ]]; then
    echo "${login}"
    return 0
  fi
  return 1
}

# Resolve a human assignee from comments JSON + issue JSON.
# Prints the login on stdout, or nothing when no human matches.
# Args: comments_json issue_json
resolve_pr_assignee_from_context() {
  local comments_json="${1:-}"
  local issue_json="${2:-}"

  local invoker
  invoker="$(find_fs_code_invoker "${comments_json}" || true)"
  if is_human_github_user "${invoker}"; then
    echo "${invoker}"
    return 0
  fi

  if [[ -z "${issue_json}" ]]; then
    return 1
  fi

  local human_assignee
  human_assignee="$(echo "${issue_json}" | jq -r '
    [(.assignees // [])[]? | .login? // empty | select(
      (. | length > 0) and
      (startswith("app/") | not) and
      (test("\\[bot\\]$") | not) and
      (. != "dependabot")
    )] | .[0] // empty
  ' 2>/dev/null || true)"
  if [[ -n "${human_assignee}" ]]; then
    echo "${human_assignee}"
    return 0
  fi

  local author_login
  author_login="$(echo "${issue_json}" | jq -r '.author.login? // empty' 2>/dev/null || true)"
  if is_human_github_user "${author_login}"; then
    echo "${author_login}"
    return 0
  fi

  return 1
}

# Emit a runner warning through gha_echo when available (sanitizes :: / %0A / %0D).
# Never fall back to raw "::warning::" interpolation — that invites workflow-command injection.
_pr_assignee_warn() {
  if declare -F gha_echo >/dev/null 2>&1; then
    gha_echo warning "$*"
  else
    echo "warning: $*" >&2
  fi
}

# Fetch issue comments (paginated REST) as a single JSON array. Best-effort.
fetch_issue_comments_json() {
  if declare -F forge_get_issue_comments >/dev/null 2>&1; then
    forge_get_issue_comments
    return 0
  fi
  local raw
  if ! raw="$(gh api --paginate \
    "repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/comments" 2>/dev/null)"; then
    echo '[]'
    return 0
  fi
  if [[ -z "${raw}" ]]; then
    echo '[]'
    return 0
  fi
  echo "${raw}" | jq -s 'add // []' 2>/dev/null || echo '[]'
}

# Resolve using issue comments + assignees/author via forge API.
resolve_pr_assignee() {
  local comments_json issue_json
  comments_json="$(fetch_issue_comments_json)"
  if declare -F forge_get_issue_details >/dev/null 2>&1; then
    issue_json="$(forge_get_issue_details || true)"
  else
    issue_json="$(gh issue view "${ISSUE_NUMBER}" --repo "${REPO_FULL_NAME}" \
      --json assignees,author 2>/dev/null || true)"
  fi
  resolve_pr_assignee_from_context "${comments_json}" "${issue_json}"
}

# Best-effort PR assignee: skip when the PR already has assignees.
# Requires REPO_FULL_NAME; uses gha_echo when available.
# Note: parameter is target_pr (not pr_number) to avoid SC2153 against PR_NUMBER
# from post-failure-report.lib.sh once both libs are bundled into post-code.sh.
maybe_assign_pr() {
  local target_pr="$1"
  local existing_count
  if declare -F forge_get_pr_details >/dev/null 2>&1; then
    local pr_json
    pr_json="$(forge_get_pr_details "${target_pr}" "assignees" 2>/dev/null)" || {
      _pr_assignee_warn "Could not read assignees for PR #${target_pr} — skipping assignment"
      return 0
    }
    existing_count="$(echo "${pr_json}" | jq '[.assignees // .assignee // [] | if type == "array" then .[] else . end] | length' 2>/dev/null || echo "0")"
  else
    if ! existing_count="$(gh pr view "${target_pr}" --repo "${REPO_FULL_NAME}" \
      --json assignees --jq '.assignees | length' 2>/dev/null)"; then
      _pr_assignee_warn "Could not read assignees for PR #${target_pr} — skipping assignment"
      return 0
    fi
  fi
  if [[ "${existing_count}" != "0" ]]; then
    echo "PR #${target_pr} already has assignees — skipping assignment"
    return 0
  fi

  local assignee
  assignee="$(resolve_pr_assignee || true)"
  if [[ -z "${assignee}" ]]; then
    echo "No human assignee candidate — leaving PR #${target_pr} unassigned"
    return 0
  fi
  # Defense-in-depth: only pass login-shaped values to the forge assign API.
  if [[ ! "${assignee}" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    _pr_assignee_warn "Unexpected assignee format '${assignee}' — skipping assignment"
    return 0
  fi

  echo "Assigning PR #${target_pr} to ${assignee}..."
  if declare -F forge_assign_pr >/dev/null 2>&1; then
    forge_assign_pr "${target_pr}" "${assignee}"
  else
    local assign_err
    assign_err="$(gh pr edit "${target_pr}" --repo "${REPO_FULL_NAME}" \
      --add-assignee "${assignee}" 2>&1)" || {
      _pr_assignee_warn "Failed to assign PR #${target_pr} to ${assignee} — continuing"
      if [[ -n "${assign_err}" ]]; then
        _pr_assignee_warn "${assign_err}"
      fi
    }
  fi
}
# END bundled: lib/pr-assignee.lib.sh
# shellcheck source=lib/branch-guard.lib.sh
# BEGIN bundled: lib/branch-guard.lib.sh
# shellcheck shell=bash

# enforce_branch_namespace <branch> <issue_number>
# Prints the deterministic safe branch name on stdout.
enforce_branch_namespace() {
  local branch="$1"
  local issue_number="$2"

  local slug="${branch##*/}"
  slug="${slug#"${issue_number}-"}"
  slug="$(printf '%s' "${slug}" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C tr -cs 'a-z0-9-' '-')"
  if [ "${#slug}" -gt 60 ]; then
    local hash
    hash="$(printf '%s' "${slug}" | sha1sum | head -c 8)"
    slug="$(printf '%s' "${slug}" | head -c 51)-${hash}"
  fi
  slug="$(printf '%s' "${slug}" | sed 's/^-*//;s/-*$//')"
  if [ -z "${slug}" ]; then
    slug="impl"
  fi
  echo "agent/${issue_number}-${slug}"
}

# pr_body_refs_issue <pr_body> <issue_number>
# Returns 0 if the PR body references the issue, non-zero otherwise.
pr_body_refs_issue() {
  local pr_body="$1"
  local issue_number="$2"

  printf '%s' "${pr_body}" | tr -d '\r' \
    | grep -qiE "(Close[sd]?|Fix(e[sd])?|Resolve[sd]?|Related to)[[:space:]]+#${issue_number}([^0-9]|$)"
}

# classify_branch_vs_pr_head <branch> <expected_branch>
# Prints one of: "skip", "match", or "mismatch".
classify_branch_vs_pr_head() {
  local branch="$1"
  local expected_branch="$2"

  if [ -z "${expected_branch}" ]; then
    echo "skip"
  elif [ "${branch}" = "${expected_branch}" ]; then
    echo "match"
  else
    echo "mismatch"
  fi
}
# END bundled: lib/branch-guard.lib.sh

# SCRIPT_DIR is used by code-ops.lib.sh dispatcher to locate forge-specific
# ops libraries. Not directly referenced in this file.
# shellcheck disable=SC2034
SCRIPT_DIR="${SCRIPT_DIR_POST}"
# shellcheck source=lib/code-ops.lib.sh
# BEGIN bundled: lib/code-ops.lib.sh
# shellcheck shell=bash
# code-ops.lib.sh — Forge-dispatch wrapper for code agent operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${CODE_OPS_SH_LOADED:-}" ]] && return 0
CODE_OPS_SH_LOADED=1

case "${FULLSEND_FORGE:-}" in
  github)
# BEGIN bundled: lib/github-code-ops.lib.sh
# shellcheck shell=bash
# github-code-ops.lib.sh — GitHub forge operations for code agent scripts.
#
# Bundled into pre-code.sh and post-code.sh via code-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected globals (set by caller or forge_parse_issue_url):
#   REPO_FULL_NAME — owner/repo (e.g., "org/repo")
#   ISSUE_NUMBER   — issue number
#
# Expected env vars:
#   GH_TOKEN       — GitHub token with appropriate scopes

[[ -n "${GITHUB_CODE_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_CODE_OPS_SH_LOADED=1

# --- URL handling ---

forge_validate_issue_url() {
  local url="${1:-${ISSUE_URL:-}}"
  if [[ ! "${url}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected GitHub pattern: ${url}" >&2
    return 1
  fi
}

forge_parse_issue_url() {
  local url="${1:-${ISSUE_URL:-}}"
  REPO_FULL_NAME=$(echo "${url}" | sed 's|https://github.com/||; s|/issues/.*||')
  ISSUE_NUMBER=$(basename "${url}")
}

forge_extract_repo_from_url() {
  local url="$1"
  echo "${url}" | sed -E 's|https://github.com/([^/]+/[^/]+)/issues/.*|\1|'
}

forge_extract_issue_from_url() {
  local url="$1"
  echo "${url}" | sed -E 's|.*/issues/([0-9]+)$|\1|'
}

# --- Label operations ---

forge_add_label() {
  local label="$1"
  local target="${2:-issue}"
  local number="${3:-${ISSUE_NUMBER}}"
  if [ "${target}" = "pr" ]; then
    gh issue edit "${number}" --repo "${REPO_FULL_NAME}" \
      --add-label "${label}" 2>/dev/null || \
      gha_echo warning "Failed to apply ${label} label to PR #${number}"
  else
    gh api "repos/${REPO_FULL_NAME}/issues/${number}/labels" \
      -f "labels[]=${label}" --silent 2>/dev/null || true
  fi
}

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  gh label create "${name}" --repo "${REPO_FULL_NAME}" \
    --description "${description}" --color "${color}" \
    --force 2>/dev/null || true
}

# --- Comment operations ---

forge_post_issue_comment() {
  local body="$1"
  printf '%s' "${body}" | gh issue comment "${ISSUE_NUMBER}" \
    --repo "${REPO_FULL_NAME}" --body-file - 2>/dev/null
}

forge_post_pr_comment() {
  local target_pr="$1"
  local body="$2"
  gh pr comment "${target_pr}" \
    --repo "${REPO_FULL_NAME}" \
    --body "${body}" 2>/dev/null
}

# --- PR/MR lifecycle ---

forge_list_prs_for_issue() {
  local issue_number="$1"
  local bot_login="${2:-fullsend-ai[bot]}"
  local coder_bot_login="${3:-fullsend-ai-coder[bot]}"
  local owner="${REPO_FULL_NAME%%/*}"
  local name="${REPO_FULL_NAME##*/}"
  # Use closedByPullRequestsReferences to find only PRs with closing keywords
  # (Fixes #N, Closes #N, etc.) for this issue. This avoids false positives
  # from text-search matching (e.g., #1 matching #12 in a PR title).
  gh api graphql \
    -f owner="${owner}" -f name="${name}" -F number="${issue_number}" \
    -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) {
          closedByPullRequestsReferences(first: 50) {
            nodes {
              number
              url
              author { login }
              state
            }
          }
        }
      }
    }' --arg bot "${bot_login}" --arg coder "${coder_bot_login}" --jq '
    .data.repository.issue.closedByPullRequestsReferences.nodes
    | [.[] | select(.state == "OPEN")
           | select(.author.login != $bot
               and .author.login != $coder)]
    | .[] | "\(.number)\t\(.author.login)\t\(.url)"
  ' 2>/dev/null || true
}

forge_list_prs_for_branch() {
  local branch="$1"
  local owner="${REPO_FULL_NAME%%/*}"
  gh pr list --repo "${REPO_FULL_NAME}" --head "${branch}" \
    --state open --json number,headRepositoryOwner \
    --jq "[.[] | select(.headRepositoryOwner.login == \"${owner}\")] | .[0].number // empty" \
    2>/dev/null
}

forge_create_pr() {
  local base="$1"
  local head="$2"
  local title="$3"
  local body="$4"
  gh pr create \
    --repo "${REPO_FULL_NAME}" \
    --head "${head}" \
    --base "${base}" \
    --title "${title}" \
    --body "${body}"
}

forge_get_pr_url() {
  local target_pr="$1"
  gh pr view "${target_pr}" --repo "${REPO_FULL_NAME}" \
    --json url --jq '.url' 2>/dev/null || true
}

forge_get_pr_details() {
  local target_pr="$1"
  local fields="$2"
  gh pr view "${target_pr}" --repo "${REPO_FULL_NAME}" \
    --json "${fields}" 2>/dev/null
}

forge_assign_pr() {
  local target_pr="$1"
  local assignee="$2"
  local assign_err
  assign_err="$(gh pr edit "${target_pr}" --repo "${REPO_FULL_NAME}" \
    --add-assignee "${assignee}" 2>&1)" || {
    _pr_assignee_warn "Failed to assign PR #${target_pr} to ${assignee} — continuing"
    if [[ -n "${assign_err}" ]]; then
      _pr_assignee_warn "${assign_err}"
    fi
  }
}

# --- Repository operations ---

forge_get_default_branch() {
  local token="${1:-${PUSH_TOKEN:-}}"
  GH_TOKEN="${token}" gh api "repos/${REPO_FULL_NAME}" --jq '.default_branch' 2>/dev/null || echo 'main'
}

forge_set_push_remote() {
  local token="$1"
  git remote set-url origin \
    "https://x-access-token:${token}@github.com/${REPO_FULL_NAME}.git"
}

forge_check_remote_branch() {
  local branch="$1"
  git ls-remote origin "refs/heads/${branch}" 2>/dev/null | head -1 || true
}

forge_delete_remote_branch() {
  local branch="$1"
  local _del_output
  _del_output="$(git push origin --delete "${branch}" 2>&1)" || {
    # Sanitize before logging — git may echo the x-access-token:<token>@ remote URL.
    if declare -F print_sanitized_gha_log >/dev/null 2>&1; then
      print_sanitized_gha_log "${_del_output}"
    fi
    gha_echo warning "Failed to delete stale remote branch ${branch}"
  }
}

# --- Merge queue / auto-merge ---

forge_check_merge_queue() {
  local base_branch="$1"
  local owner="${REPO_FULL_NAME%%/*}"
  local name="${REPO_FULL_NAME##*/}"
  gh api graphql -f query="
    query { repository(owner: \"${owner}\", name: \"${name}\") {
      mergeQueue(branch: \"${base_branch}\") { id }
    }}" --jq '.data.repository.mergeQueue.id // empty' 2>/dev/null || true
}

forge_get_repo_merge_methods() {
  gh api "repos/${REPO_FULL_NAME}" \
    --jq '{s:.allow_squash_merge,m:.allow_merge_commit,r:.allow_rebase_merge}' 2>/dev/null || true
}

forge_enable_auto_merge() {
  local target_pr="$1"
  local method_flag="$2"
  local merge_output
  # shellcheck disable=SC2086
  if ! merge_output="$(gh pr merge "${target_pr}" --auto ${method_flag} \
    --repo "${REPO_FULL_NAME}" 2>&1)"; then
    print_sanitized_gha_log "${merge_output}"
    gha_echo warning "Failed to enable auto-merge on PR #${target_pr} — continuing"
  else
    print_sanitized_gha_log "${merge_output}"
  fi
}

# --- Issue operations ---

forge_get_issue_comments() {
  local raw
  if ! raw="$(gh api --paginate \
    "repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/comments" 2>/dev/null)"; then
    echo '[]'
    return 0
  fi
  if [[ -z "${raw}" ]]; then
    echo '[]'
    return 0
  fi
  echo "${raw}" | jq -s 'add // []' 2>/dev/null || echo '[]'
}

forge_get_issue_details() {
  gh issue view "${ISSUE_NUMBER}" --repo "${REPO_FULL_NAME}" \
    --json assignees,author 2>/dev/null || true
}

# --- CI operations ---

forge_get_workflow_run_url() {
  local run_repo="${GITHUB_REPOSITORY:-${REPO_FULL_NAME}}"
  printf '%s/%s/actions/runs/%s' \
    "${GITHUB_SERVER_URL:-https://github.com}" \
    "${run_repo}" \
    "${GITHUB_RUN_ID:-unknown}"
}

# --- Output operations ---

forge_write_output() {
  local key="$1"
  local value="$2"
  echo "${key}=${value}" >> "${GITHUB_OUTPUT:-/dev/null}"
}

# --- Workspace operations ---

forge_get_workspace_dir() {
  echo "${GITHUB_WORKSPACE:-}"
}

forge_get_repo_dir() {
  echo "${REPO_DIR:-${GITHUB_WORKSPACE:-}/target-repo}"
}

forge_append_path() {
  local dir="$1"
  echo "${dir}" >> "${GITHUB_PATH:-/dev/null}"
}
# END bundled: lib/github-code-ops.lib.sh
    ;;
  gitlab)
# BEGIN bundled: lib/gitlab-code-ops.lib.sh
# shellcheck shell=bash
# gitlab-code-ops.lib.sh — GitLab forge operations for code agent scripts.
#
# Bundled into pre-code.sh and post-code.sh via code-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected globals (set by caller or forge_parse_issue_url):
#   REPO_FULL_NAME — plain project path (e.g., "group/project")
#   REPO_ENCODED   — URL-encoded project path (e.g., "group%2Fproject")
#   ISSUE_NUMBER   — issue IID
#   GITLAB_HOST    — API host (e.g., "gitlab.com")
#
# Expected env vars:
#   ISSUE_URL      — HTML URL of the issue
#   GITLAB_TOKEN   — GitLab personal/project access token
#
# Token scopes: GITLAB_TOKEN requires minimum scopes:
#   - api (read/write issues, labels, notes, merge requests)

[[ -n "${GITLAB_CODE_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_CODE_OPS_SH_LOADED=1

if ! declare -F gha_echo >/dev/null 2>&1; then
  gha_echo() { echo "::${1}::${2:-}"; }
fi

_gitlab_code_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
    "$@"
}

_gitlab_code_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local err_file
  err_file=$(mktemp)
  local raw
  raw=$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "https://${GITLAB_HOST}/api/v4${endpoint}" \
    "$@" 2>"${err_file}") || {
    echo "GitLab API error: curl failed — $(cat "${err_file}")" >&2
    rm -f "${err_file}"
    return 1
  }
  rm -f "${err_file}"
  local http_code
  http_code=$(echo "${raw}" | tail -1)
  local body
  body=$(echo "${raw}" | sed '$d')
  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    local _truncated
    _truncated=$(printf '%.200s' "${body}")
    echo "GitLab API error (HTTP ${http_code}): ${_truncated}" >&2
    return 1
  fi
  echo "${body}"
}

# --- URL handling ---

forge_validate_issue_url() {
  local url="${1:-${ISSUE_URL:-}}"
  if [[ ! "${url}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+/-/issues/[0-9]+$ ]]; then
    echo "ERROR: ISSUE_URL does not match expected GitLab pattern: ${url}" >&2
    return 1
  fi
  local host
  host=$(echo "${url}" | sed -E 's|^https://([^/]+)/.*|\1|')
  # Allowed GitLab hosts. To support a self-hosted instance, add it here
  # AND in the network policy (policies/gitlab/code.yaml).
  case "${host}" in
    gitlab.com|gitlab.cee.redhat.com) ;;
    *) echo "ERROR: GitLab host '${host}' is not in the allowed host list (see gitlab-code-ops.lib.sh and policies/gitlab/code.yaml)" >&2; return 1 ;;
  esac
}

forge_parse_issue_url() {
  local url="${1:-${ISSUE_URL:-}}"
  GITLAB_HOST=$(echo "${url}" | sed -E 's|^https://([^/]+)/.*|\1|')
  REPO_FULL_NAME=$(echo "${url}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
  REPO_ENCODED=$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)
  ISSUE_NUMBER=$(basename "${url}")
}

forge_extract_repo_from_url() {
  local url="$1"
  echo "${url}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|'
}

forge_extract_issue_from_url() {
  local url="$1"
  echo "${url}" | sed -E 's|.*/issues/([0-9]+)$|\1|'
}

# --- Label operations ---

forge_add_label() {
  local label="$1"
  local target="${2:-issue}"
  local number="${3:-${ISSUE_NUMBER}}"
  if [ "${target}" = "pr" ]; then
    # On GitLab, MRs use the same label update mechanism
    local mr_iid="${number}"
    _gitlab_code_api PUT "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}" \
      --data-urlencode "add_labels=${label}" > /dev/null 2>/dev/null || \
      gha_echo warning "Failed to apply ${label} label to MR !${mr_iid}"
  else
    _gitlab_code_api PUT "/projects/${REPO_ENCODED}/issues/${number}" \
      --data-urlencode "add_labels=${label}" > /dev/null 2>/dev/null || true
  fi
}

forge_create_label() {
  local name="$1"
  local description="$2"
  local color="$3"
  local clean_color="${color#\#}"
  _gitlab_code_api POST "/projects/${REPO_ENCODED}/labels" \
    --data-urlencode "name=${name}" \
    --data-urlencode "description=${description}" \
    --data-urlencode "color=#${clean_color}" > /dev/null 2>/dev/null || true
}

# --- Comment operations ---

forge_post_issue_comment() {
  local body="$1"
  _gitlab_code_api POST "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes" \
    --data-urlencode "body=${body}" > /dev/null 2>/dev/null
}

forge_post_pr_comment() {
  local mr_iid="$1"
  local body="$2"
  _gitlab_code_api POST "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}/notes" \
    --data-urlencode "body=${body}" > /dev/null 2>/dev/null
}

# --- MR lifecycle ---

forge_list_prs_for_issue() {
  local issue_number="$1"
  local bot_login="${2:-}"
  local coder_bot_login="${3:-}"
  # GitLab API: search MRs referencing the issue. Best-effort — GitLab does not
  # have a direct "MRs linked to issue" endpoint. Fetch open MRs and filter for
  # closing keywords (Close, Fix, Resolve variants) targeting #<IID>. Plain
  # mentions without closing keywords are excluded to avoid false positives.
  local all_mrs="[]"
  local page=1 max_pages=10
  while [[ "${page}" -le "${max_pages}" ]]; do
    local batch
    batch=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/merge_requests?state=opened&per_page=100&page=${page}" 2>/dev/null) || {
      if [ "${page}" -eq 1 ]; then
        gha_echo warning "forge_list_prs_for_issue: GitLab API failed on first page — failing closed"
        return 1
      fi
      break
    }
    local count
    count=$(echo "${batch}" | jq 'length' 2>/dev/null) || break
    [[ "${count}" -eq 0 ]] && break
    all_mrs=$(echo "${all_mrs}" "${batch}" | jq -s 'add') || break
    page=$((page + 1))
  done
  # Filter for MRs with closing keywords (Closes, Fixes, Resolves, etc.)
  # targeting #<IID>. Plain mentions without closing keywords are excluded
  # to avoid false positives (e.g., "Related: #42" should not block).
  echo "${all_mrs}" | jq -r --arg issue_number "${issue_number}" \
    --arg bot1 "${bot_login}" --arg bot2 "${coder_bot_login}" '
    [.[] | select(
      ((.title // "") | test("\\b(?:close[sd]?|closing|fix(?:e[sd])?|fixing|resolve[sd]?|resolving):?\\s+(?:(?:[a-zA-Z0-9._/-]+)?#\\d+(?:\\s*,\\s*))*(?:[a-zA-Z0-9._/-]+)?#" + $issue_number + "(?:$|\\W)"; "i")) or
      ((.description // "") | test("\\b(?:close[sd]?|closing|fix(?:e[sd])?|fixing|resolve[sd]?|resolving):?\\s+(?:(?:[a-zA-Z0-9._/-]+)?#\\d+(?:\\s*,\\s*))*(?:[a-zA-Z0-9._/-]+)?#" + $issue_number + "(?:$|\\W)"; "i"))
    ) | select(
      ((.source_branch // "") | test("^agent/" + $issue_number + "-") | not)
    ) | select(
      (if $bot1 != "" then (.author.username // "") != $bot1 else true end) and
      (if $bot2 != "" then (.author.username // "") != $bot2 else true end) and
      (.author.username // "" | test("\\[bot\\]$") | not) and
      (.author.username // "" | test("^fullsend") | not) and
      (.author.username // "" | test("_bot$") | not)
    )] | .[] | "\(.iid)\t\(.author.username)\t\(.web_url)"
  ' 2>/dev/null || true
}

forge_list_prs_for_branch() {
  local branch="$1"
  local branch_encoded
  branch_encoded=$(printf '%s' "${branch}" | jq -sRr @uri)
  local mrs
  mrs=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/merge_requests?state=opened&source_branch=${branch_encoded}" 2>/dev/null) || return 1
  # Filter to same-project MRs only (exclude fork MRs) — mirrors the GitHub
  # implementation which filters by headRepositoryOwner.
  local project_id
  project_id=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}" 2>/dev/null | jq -r '.id // empty') || true
  if [[ -z "${project_id}" ]]; then
    gha_echo warning "Could not resolve project ID for fork-MR filtering — failing closed"
    return 1
  fi
  echo "${mrs}" | jq -r --arg pid "${project_id}" \
    '[.[] | select(.source_project_id == ($pid | tonumber))] | .[0].iid // empty'
}

forge_create_pr() {
  local base="$1"
  local head="$2"
  local title="$3"
  local body="$4"
  local response
  response=$(_gitlab_code_api_with_status POST "/projects/${REPO_ENCODED}/merge_requests" \
    --data-urlencode "source_branch=${head}" \
    --data-urlencode "target_branch=${base}" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description=${body}") || return 1
  local url
  url=$(echo "${response}" | jq -r '.web_url // empty')
  if [[ -z "${url}" ]]; then
    echo "GitLab API error: MR created but response missing web_url" >&2
    return 1
  fi
  echo "${url}"
}

forge_get_pr_url() {
  local mr_iid="$1"
  local mr_json
  mr_json=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}" 2>/dev/null) || {
    echo ""
    return 0
  }
  echo "${mr_json}" | jq -r '.web_url // empty' 2>/dev/null || true
}

forge_get_pr_details() {
  local mr_iid="$1"
  local _fields="$2"  # accepted for interface parity but GitLab returns all fields
  _gitlab_code_api GET "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}" 2>/dev/null
}

forge_assign_pr() {
  local mr_iid="$1"
  local assignee="$2"
  # Resolve assignee username to user ID for GitLab
  local user_json user_id
  local assignee_encoded
  assignee_encoded=$(printf '%s' "${assignee}" | jq -sRr @uri)
  user_json=$(_gitlab_code_api GET "/users?username=${assignee_encoded}" 2>/dev/null) || {
    _pr_assignee_warn "Failed to resolve GitLab user '${assignee}' — skipping assignment"
    return 0
  }
  user_id=$(echo "${user_json}" | jq -r '.[0].id // empty' 2>/dev/null)
  if [[ -z "${user_id}" ]]; then
    _pr_assignee_warn "GitLab user '${assignee}' not found — skipping assignment"
    return 0
  fi
  if ! _gitlab_code_api PUT "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}" \
    --data-urlencode "assignee_ids[]=${user_id}" > /dev/null 2>/dev/null; then
    _pr_assignee_warn "Failed to assign MR !${mr_iid} to ${assignee} — continuing"
  fi
}

# --- Repository operations ---

forge_get_default_branch() {
  local token="${1:-${GITLAB_TOKEN:-}}"
  local project_json
  project_json=$(GITLAB_TOKEN="${token}" _gitlab_code_api GET "/projects/${REPO_ENCODED}" 2>/dev/null) || {
    echo 'main'
    return 0
  }
  echo "${project_json}" | jq -r '.default_branch // "main"' 2>/dev/null || echo 'main'
}

forge_set_push_remote() {
  local token="$1"
  git remote set-url origin \
    "https://oauth2:${token}@${GITLAB_HOST}/${REPO_FULL_NAME}.git"
}

forge_check_remote_branch() {
  local branch="$1"
  git ls-remote origin "refs/heads/${branch}" 2>/dev/null | head -1 || true
}

forge_delete_remote_branch() {
  local branch="$1"
  local _del_output
  _del_output="$(git push origin --delete "${branch}" 2>&1)" || {
    # Sanitize before logging — git may echo the oauth2:<token>@ remote URL.
    if declare -F print_sanitized_gha_log >/dev/null 2>&1; then
      print_sanitized_gha_log "${_del_output}"
    fi
    gha_echo warning "Failed to delete stale remote branch ${branch}"
  }
}

# --- Auto-merge ---

forge_check_merge_queue() {
  # GitLab does not have a merge queue equivalent; merge trains are configured
  # per-project but have no API query like GitHub's mergeQueue.
  echo ""
}

forge_get_repo_merge_methods() {
  local project_json
  project_json=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}" 2>/dev/null) || {
    echo ""
    return 0
  }
  local method
  method=$(echo "${project_json}" | jq -r '.merge_method // "merge"' 2>/dev/null)
  # Map GitLab merge_method to the same JSON shape as GitHub for compat
  case "${method}" in
    merge) echo '{"s":false,"m":true,"r":false}' ;;
    rebase_merge) echo '{"s":false,"m":false,"r":true}' ;;
    ff)    echo '{"s":false,"m":false,"r":true}' ;;
    *)     echo '{"s":false,"m":true,"r":false}' ;;
  esac
}

forge_enable_auto_merge() {
  local mr_iid="$1"
  local _method_flag="$2"

  # Safety guard: merge_when_pipeline_succeeds merges immediately when the
  # pipeline has already passed or no pipeline exists.  Match the GitHub path's
  # BLOCKED-state guard by requiring that the MR is not immediately mergeable.
  # Retry up to 3 times — new MRs may report "none" briefly.
  local mr_json pipeline_status _am_attempt
  for _am_attempt in 1 2 3; do
    mr_json=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}" 2>/dev/null) || {
      gha_echo warning "Auto-merge: could not query MR !${mr_iid} — skipping"
      return 0
    }
    pipeline_status=$(echo "${mr_json}" | jq -r '.head_pipeline.status // "none"')

    case "${pipeline_status}" in
      running|pending|created|preparing|waiting_for_resource|scheduled)
        break
        ;;
      none)
        if [ "${_am_attempt}" -lt 3 ]; then
          echo "Auto-merge: MR !${mr_iid} pipeline status is 'none' (attempt ${_am_attempt}/3) — retrying in 5s..."
          sleep 5
          continue
        fi
        gha_echo warning "Auto-merge: MR !${mr_iid} has no pipeline after 3 attempts — skipping (would merge immediately)"
        return 0
        ;;
      success)
        break
        ;;
      failed|canceled)
        gha_echo warning "Auto-merge: MR !${mr_iid} pipeline status '${pipeline_status}' — skipping"
        return 0
        ;;
      *)
        gha_echo warning "Auto-merge: MR !${mr_iid} unrecognized pipeline status '${pipeline_status}' — skipping"
        return 0
        ;;
    esac
  done

  # BLOCKED guard (parity with GitHub's mergeStateStatus check)
  local merge_status
  merge_status=$(echo "${mr_json}" | jq -r '.detailed_merge_status // .merge_status // "unknown"')
  case "${merge_status}" in
    mergeable|can_be_merged)
      gha_echo warning "Auto-merge: MR !${mr_iid} is immediately mergeable — skipping. Requires merge request approvals or pipeline checks."
      return 0
      ;;
    not_approved|ci_must_pass|ci_still_running|discussions_not_resolved|blocked_status|need_rebase)
      ;;
    checking|unchecked|preparing)
      if [ "${pipeline_status}" = "success" ]; then
        gha_echo warning "Auto-merge: MR !${mr_iid} merge status '${merge_status}' not settled but pipeline passed — skipping (could merge immediately)"
        return 0
      fi
      ;;
    *)
      gha_echo warning "Auto-merge: MR !${mr_iid} unrecognized merge status '${merge_status}' — skipping"
      return 0
      ;;
  esac

  if [ "${pipeline_status}" = "success" ]; then
    echo "Auto-merge: MR !${mr_iid} pipeline passed but MR is blocked (${merge_status}) — arming auto-merge"
  fi

  if ! _gitlab_code_api PUT "/projects/${REPO_ENCODED}/merge_requests/${mr_iid}/merge" \
    --data-urlencode "merge_when_pipeline_succeeds=true" > /dev/null 2>/dev/null; then
    gha_echo warning "Failed to enable auto-merge on MR !${mr_iid} — continuing"
  fi
}

# --- Issue operations ---

forge_get_issue_comments() {
  local notes="[]"
  local page=1 max_pages=50
  while [[ "${page}" -le "${max_pages}" ]]; do
    local batch
    batch=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes?per_page=100&sort=asc&page=${page}" 2>/dev/null) || break
    local count
    count=$(echo "${batch}" | jq 'length') || break
    [[ "${count}" -eq 0 ]] && break
    notes=$(echo "${notes}" "${batch}" | jq -s 'add') || break
    page=$((page + 1))
  done
  # Remap GitLab shape to match GitHub expected shape for pr-assignee.lib.sh;
  # exclude system notes (timeline events GitHub doesn't return).
  echo "${notes}" | jq '[.[] | select(.system != true) | {user: {login: .author.username}, body: .body}]' 2>/dev/null || echo '[]'
}

forge_get_issue_details() {
  local issue_json
  issue_json=$(_gitlab_code_api GET "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}" 2>/dev/null) || {
    echo ""
    return 0
  }
  # Remap GitLab shape to match GitHub expected shape for pr-assignee.lib.sh
  echo "${issue_json}" | jq '{
    assignees: [(.assignees // [])[] | {login: .username}],
    author: {login: (.author.username // "")}
  }' 2>/dev/null || true
}

# --- CI operations ---

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

# --- Output operations ---

forge_write_output() {
  local key="$1"
  local value="$2"
  # GitLab CI uses artifacts or dotenv for output; write to GITHUB_OUTPUT
  # if available (hybrid compatibility), otherwise no-op.
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${key}=${value}" >> "${GITHUB_OUTPUT}"
  fi
}

# --- Workspace operations ---

forge_get_workspace_dir() {
  echo "${CI_PROJECT_DIR:-${GITHUB_WORKSPACE:-}}"
}

forge_get_repo_dir() {
  echo "${REPO_DIR:-${CI_PROJECT_DIR:-${GITHUB_WORKSPACE:-}/target-repo}}"
}

forge_append_path() {
  local dir="$1"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "${dir}" >> "${GITHUB_PATH}"
  fi
  # On GitLab CI, PATH is modified directly (already done by caller)
}
# END bundled: lib/gitlab-code-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
# END bundled: lib/code-ops.lib.sh
# shellcheck source=lib/labels.lib.sh
# BEGIN bundled: lib/labels.lib.sh
# labels.lib.sh — Mandatory label management for fullsend agent scripts.
#
# Provides forge_ensure_label() which creates mandatory dispatch labels
# without --force, preserving admin customizations. Non-mandatory labels
# are silently skipped (no-op).

# shellcheck shell=bash

[[ -n "${LABELS_SH_LOADED:-}" ]] && return 0
LABELS_SH_LOADED=1

MANDATORY_LABELS=("ready-for-review" "ready-to-code" "ready-for-triage")

_labels_mandatory_defaults() {
  printf '%s\t%s\t%s\n' \
    "ready-for-review" "Triggers review agent dispatch" "0E8A16" \
    "ready-to-code" "Triggers code agent dispatch" "0E8A16" \
    "ready-for-triage" "Triggers triage agent dispatch" "0E8A16"
}

forge_ensure_label() {
  local name="$1"
  local description="${2:-}"
  local color="${3:-}"

  local is_mandatory=false
  local m
  for m in "${MANDATORY_LABELS[@]}"; do
    [[ "${m}" == "${name}" ]] && is_mandatory=true && break
  done
  if [[ "${is_mandatory}" != "true" ]]; then
    return 0
  fi

  if [[ -z "${description}" || -z "${color}" ]]; then
    local line
    line=$(_labels_mandatory_defaults | grep "^${name}	" || true)
    if [[ -n "${line}" ]]; then
      [[ -z "${description}" ]] && description=$(printf '%s' "${line}" | cut -f2)
      [[ -z "${color}" ]] && color=$(printf '%s' "${line}" | cut -f3)
    fi
  fi

  local create_args=("${name}" --repo "${REPO_FULL_NAME:-${REPO}}")
  [[ -n "${description}" ]] && create_args+=(--description "${description}")
  [[ -n "${color}" ]] && create_args+=(--color "${color}")

  local err
  if ! err=$(gh label create "${create_args[@]}" 2>&1); then
    case "${err}" in
      *already\ exists*) ;;
      *)
        err="${err//$'\n'/ }"
        err="${err//::/:}"
        err="${err//%0A/}"
        err="${err//%0a/}"
        err="${err//%0D/}"
        err="${err//%0d/}"
        echo "Warning: gh label create ${name}: ${err}" >&2
        ;;
    esac
  fi
}
# END bundled: lib/labels.lib.sh

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
if [ -n "${RESULT_FILE}" ]; then
  AGENT_TARGET="$(jq -r '.target_branch // empty' "${RESULT_FILE}" 2>/dev/null || true)"
  AGENT_CLOSES="$(jq -r '.closes_issue // empty' "${RESULT_FILE}" 2>/dev/null || true)"
  if [ "${AGENT_CLOSES}" = "false" ]; then
    CLOSES_ISSUE="false"
  fi
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

echo "::add-mask::${PUSH_TOKEN}"
if [ -n "${GITLAB_TOKEN:-}" ]; then
  echo "::add-mask::${GITLAB_TOKEN}"
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
