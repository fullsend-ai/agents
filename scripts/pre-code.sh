#!/usr/bin/env bash
# GENERATED from pre-code.src.sh — DO NOT EDIT. Run: make script-build
# Pre-script: validate workflow_dispatch inputs before the agent runs.
#
# Prevents malformed or malicious event_payload from reaching the sandbox.
# Runs on the GitHub Actions runner BEFORE sandbox creation.
#
# Skip signalling uses the pre-script output protocol
# (fullsend docs/normative/prescript-output/v1, fullsend-ai/fullsend#4718):
# when an open human PR already addresses the issue, this script writes
# skipped=true to the file named by FULLSEND_PRESCRIPT_OUTPUT and
# fullsend run stops before creating the sandbox. Under a CLI that
# predates the protocol the variable is unset and the write is skipped —
# the run proceeds, which matches the pre-protocol behavior.
#
# Required environment variables (set by the workflow):
#   ISSUE_NUMBER       — must be a positive integer
#   REPO_FULL_NAME     — must be owner/repo format
#   GITHUB_ISSUE_URL   — must be a valid GitHub issue URL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prescript-output.lib.sh
# BEGIN bundled: lib/prescript-output.lib.sh
# prescript-output.lib.sh — Write pre-script output protocol lines.
#
# The pre-script output protocol (fullsend docs/normative/prescript-output/v1,
# fullsend-ai/fullsend#4718) is the contract between `fullsend run` and a
# harness pre-script: the CLI exports FULLSEND_PRESCRIPT_OUTPUT naming a
# file, and the script appends key=value lines to it — `skipped=true` (plus
# an optional `reason`) stops the run before sandbox creation. Under a CLI
# that predates the protocol the variable is unset and writes are skipped,
# so the run proceeds — the protocol's version-skew contract.
#
# Source from a pre-script .src.sh:
#   source "${SCRIPT_DIR}/lib/prescript-output.lib.sh"

# shellcheck shell=bash

[[ -n "${PRESCRIPT_OUTPUT_SH_LOADED:-}" ]] && return 0
PRESCRIPT_OUTPUT_SH_LOADED=1

# prescript_output KEY VALUE — append a protocol line, if the CLI
# supports the protocol. Values must be single-line (protocol grammar).
prescript_output() {
  if [[ -n "${FULLSEND_PRESCRIPT_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "${FULLSEND_PRESCRIPT_OUTPUT}"
  fi
}
# END bundled: lib/prescript-output.lib.sh
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

errors=0

# The validation messages below interpolate untrusted input that just
# failed its format check — use gha_echo (not raw echo) so GHA's
# workflow-command parser never sees an attacker-controlled "::" sequence
# from that input.
if [[ ! "${ISSUE_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
  gha_echo error "ISSUE_NUMBER must be a positive integer, got: '${ISSUE_NUMBER:-}'"
  errors=$((errors + 1))
fi

if [[ ! "${REPO_FULL_NAME:-}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
  gha_echo error "REPO_FULL_NAME must be owner/repo format, got: '${REPO_FULL_NAME:-}'"
  errors=$((errors + 1))
fi

if [[ ! "${GITHUB_ISSUE_URL:-}" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/issues/[0-9]+$ ]]; then
  gha_echo error "GITHUB_ISSUE_URL format invalid, got: '${GITHUB_ISSUE_URL:-}'"
  errors=$((errors + 1))
fi

URL_REPO="$(echo "${GITHUB_ISSUE_URL:-}" | sed -E 's|https://github.com/([^/]+/[^/]+)/issues/.*|\1|')"
URL_ISSUE="$(echo "${GITHUB_ISSUE_URL:-}" | sed -E 's|.*/issues/([0-9]+)$|\1|')"

if [[ -n "${URL_REPO}" && "${URL_REPO}" != "${REPO_FULL_NAME:-}" ]]; then
  gha_echo error "REPO_FULL_NAME does not match issue URL repo ('${REPO_FULL_NAME:-}' vs '${URL_REPO}')"
  errors=$((errors + 1))
fi
if [[ -n "${URL_ISSUE}" && "${URL_ISSUE}" != "${ISSUE_NUMBER:-}" ]]; then
  gha_echo error "ISSUE_NUMBER does not match issue URL number ('${ISSUE_NUMBER:-}' vs '${URL_ISSUE}')"
  errors=$((errors + 1))
fi

if [[ "${errors}" -gt 0 ]]; then
  echo "::error::Input validation failed with ${errors} error(s). Aborting."
  exit 1
fi

echo "::notice::🔗 Code target: ${GITHUB_ISSUE_URL}"

echo "Input validation passed:"
echo "  ISSUE_NUMBER=${ISSUE_NUMBER}"
echo "  REPO_FULL_NAME=${REPO_FULL_NAME}"
echo "  GITHUB_ISSUE_URL=${GITHUB_ISSUE_URL}"

# ---------------------------------------------------------------------------
# Check for existing human PRs linked to this issue
# ---------------------------------------------------------------------------
# Skip if GH_TOKEN is not available (best-effort check).
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN not set — skipping existing-PR check"
  exit 0
fi

# Allow override when the trigger comment is `/fs-code --force` or CODE_FORCE
# is set. --force counts only as the command's flag token on the first line —
# the same first-line tokenization the dispatch router uses — so a comment
# merely mentioning --force (or a pasted log containing it) cannot bypass
# the existing-PR check.
FORCE_WORD=""
if [[ -n "${COMMENT_BODY:-}" ]]; then
  FORCE_WORD="$(printf '%s\n' "${COMMENT_BODY}" | head -1 | tr -d '\r' | awk '{print $2}')"
fi
_cb="${COMMENT_BODY:-}"
echo "Evaluating force override: CODE_FORCE='${CODE_FORCE:-}' COMMENT_BODY_LENGTH='${#_cb}'"
if [[ "${CODE_FORCE:-}" == "true" ]] || [[ "${FORCE_WORD}" == "--force" ]]; then
  echo "Force override — skipping existing-PR check"
  exit 0
fi

BOT_LOGIN="fullsend-ai[bot]"
CODER_BOT_LOGIN="fullsend-ai-coder[bot]"

echo "Checking for existing open PRs linked to issue #${ISSUE_NUMBER}..."

# Search for open PRs in the repo that mention the issue number.
# This catches PRs with "Closes #N", "Fixes #N", or "#N" in the body/title.
# Use gh's built-in --jq to filter out bot-authored PRs in one call.
HUMAN_PR_LINES="$(gh pr list --repo "${REPO_FULL_NAME}" --state open \
  --search "${ISSUE_NUMBER} in:body,title" \
  --json number,url,author \
  --jq "[.[] | select(.author.login != \"${BOT_LOGIN}\" and .author.login != \"${CODER_BOT_LOGIN}\")] | .[] | \"\(.number)\t\(.author.login)\t\(.url)\"" \
  2>/dev/null || true)"

if [[ -n "${HUMAN_PR_LINES}" ]]; then
  # Parse the first PR for the notice.
  FIRST_PR_NUM="$(echo "${HUMAN_PR_LINES}" | head -1 | cut -f1)"
  FIRST_PR_AUTHOR="$(echo "${HUMAN_PR_LINES}" | head -1 | cut -f2)"

  echo "::notice::Found existing human PR #${FIRST_PR_NUM} by @${FIRST_PR_AUTHOR}"

  # Apply pr-open label to signal work is already underway.
  gh label create "pr-open" --repo "${REPO_FULL_NAME}" \
    --description "An open PR already addresses this issue" --color "D4C5F9" \
    --force 2>/dev/null || true
  gh api "repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/labels" \
    -f "labels[]=pr-open" --silent 2>/dev/null || true

  # Build a markdown list of existing PRs.
  PR_LIST_MD=""
  while IFS=$'\t' read -r pr_num pr_author _pr_url; do
    PR_LIST_MD="${PR_LIST_MD}
- #${pr_num} by @${pr_author}"
  done <<< "${HUMAN_PR_LINES}"

  SKIP_COMMENT="An open PR already addresses this issue — skipping automated implementation.
${PR_LIST_MD}

To override, comment \`/fs-code --force\` on this issue.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> pre-code check</sub>"

  printf '%s' "${SKIP_COMMENT}" | gh issue comment "${ISSUE_NUMBER}" \
    --repo "${REPO_FULL_NAME}" --body-file - 2>/dev/null || true

  echo "Skipping code agent — existing PR(s) found for issue #${ISSUE_NUMBER}"
  prescript_output "skipped" "true"
  prescript_output "reason" "open PR #${FIRST_PR_NUM} by @${FIRST_PR_AUTHOR} already addresses issue #${ISSUE_NUMBER}"
  exit 0
fi

echo "No existing human PRs found — proceeding with code agent"

# ---------------------------------------------------------------------------
# Auto-detect and install pre-commit tool dependencies
# ---------------------------------------------------------------------------
TARGET_REPO="${REPO_DIR:-${GITHUB_WORKSPACE:-}/target-repo}"
RESOLVE_SCRIPT="${SCRIPT_DIR}/resolve-precommit-tools.py"
INSTALL_SCRIPT="${SCRIPT_DIR}/install-precommit-tools.sh"

# Fallback: these companion scripts were never migrated into this repo
# during the ADR 0058 extraction, so the BASH_SOURCE-relative lookup above
# always misses. The reusable workflow's "Prepare workspace" step always
# materializes the full scripts/ directory (from fullsend's own scaffold)
# at ${GITHUB_WORKSPACE}/scripts/ (per-org) or ${GITHUB_WORKSPACE}/.fullsend/scripts/
# (per-repo). Try those paths when the BASH_SOURCE-relative lookup misses.
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
echo "${HOME}/.local/bin" >> "${GITHUB_PATH:-/dev/null}"
