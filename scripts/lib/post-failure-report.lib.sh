#!/usr/bin/env bash
# post-failure-report.lib.sh — Categorized, sanitized failure comments for post-scripts.
#
# Source from post-code.src.sh / post-fix.src.sh:
#   source "${SCRIPT_DIR}/lib/post-failure-report.lib.sh"
#
# Set POST_FAILURE_CATEGORY / POST_FAILURE_DETAIL before exit, or call post_fail.

# shellcheck shell=bash

[[ -n "${POST_FAILURE_REPORT_SH_LOADED:-}" ]] && return 0
POST_FAILURE_REPORT_SH_LOADED=1

# shellcheck source=forge-transient-retry.lib.sh
source "${BASH_SOURCE[0]%/*}/forge-transient-retry.lib.sh"

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
    signoff-rewrite-failed) echo "Signed-off-by strip failed" ;;
    push-workflow-permission) echo "Push rejected — workflows permission" ;;
    push-rejected) echo "Push rejected" ;;
    push-failed) echo "Push failed" ;;
    pr-creation-failed) echo "PR creation failed" ;;
    branch-validation) echo "Branch validation failed" ;;
    setup-error) echo "Setup error" ;;
    process-output-failed) echo "Structured output processing failed" ;;
    uncommitted-work) echo "Killed before committing" ;;
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

  if [ "${category}" = "uncommitted-work" ]; then
    cat <<EOF
⚠️ **${agent_kind} agent killed before committing** — uncommitted work discarded (exit code ${exit_code})

The ${agent_kind} agent left uncommitted changes in the extracted repo and produced no commit to push. The run was likely killed (timeout) before \`git commit\` executed, so this work was discarded and no PR was opened.

This is not a successful no-op: staged or untracked files were present when the sandbox was extracted.

${env_note}**Workflow run:** ${run_url}
${detail_block}
Retry with \`${retry_command}\` if appropriate.
EOF
    return 0
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

# Create the last-resort label directly against the forge API. Deliberately
# does not call forge_create_label: that helper swallows errors
# (`2>/dev/null || true` on every forge), so we would never know whether the
# label actually got created. A create failure here is non-fatal (the label
# may already exist), but it must be visible, not silently eaten.
_post_failure_create_label() {
  local label="$1"
  local description="$2"

  if [ "${FULLSEND_FORGE:-}" = "gitlab" ]; then
    if [ -z "${REPO_ENCODED:-}" ]; then
      return 1
    fi
    if declare -F _gitlab_code_api >/dev/null 2>&1; then
      forge_retry_transient _gitlab_code_api POST "/projects/${REPO_ENCODED}/labels" \
        --data-urlencode "name=${label}" \
        --data-urlencode "description=${description}" \
        --data-urlencode "color=#B60205" >/dev/null
      return $?
    fi
    if declare -F _gitlab_api >/dev/null 2>&1; then
      forge_retry_transient _gitlab_api POST "/projects/${REPO_ENCODED}/labels" \
        --data-urlencode "name=${label}" \
        --data-urlencode "description=${description}" \
        --data-urlencode "color=#B60205" >/dev/null
      return $?
    fi
    return 1
  fi

  forge_retry_transient gh label create "${label}" --repo "${REPO_FULL_NAME}" \
    --description "${description}" --color "B60205" --force >/dev/null
}

# Apply the last-resort label directly against the forge API and report the
# real exit status. Deliberately does not call forge_add_label or
# forge_add_pr_label: those helpers are the best-effort production paths
# (github-code-ops.lib.sh / gitlab-code-ops.lib.sh / github-fix-ops.lib.sh /
# gitlab-fix-ops.lib.sh) and unconditionally swallow forge errors
# (`2>/dev/null || true`), so a failure during the same outage that already
# failed the retried comment would go unnoticed no matter how it's wrapped.
# Always go straight to the direct API calls below, wrapped in
# forge_retry_transient, so a persistent failure is actually surfaced.
_post_failure_add_label() {
  local label="$1"
  local target="$2"
  local number="$3"

  if [ "${FULLSEND_FORGE:-}" = "gitlab" ]; then
    if [ -z "${REPO_ENCODED:-}" ]; then
      return 1
    fi
    local endpoint
    if [ "${target}" = "pr" ]; then
      endpoint="/projects/${REPO_ENCODED}/merge_requests/${number}"
    else
      endpoint="/projects/${REPO_ENCODED}/issues/${number}"
    fi
    if declare -F _gitlab_code_api >/dev/null 2>&1; then
      forge_retry_transient _gitlab_code_api PUT "${endpoint}" \
        --data-urlencode "add_labels=${label}" >/dev/null
      return $?
    fi
    if declare -F _gitlab_api >/dev/null 2>&1; then
      forge_retry_transient _gitlab_api PUT "${endpoint}" \
        --data-urlencode "add_labels=${label}" >/dev/null
      return $?
    fi
    return 1
  fi

  if [ "${target}" = "pr" ]; then
    forge_retry_transient gh pr edit "${number}" --repo "${REPO_FULL_NAME}" \
      --add-label "${label}" >/dev/null
    return $?
  fi
  forge_retry_transient gh api "repos/${REPO_FULL_NAME}/issues/${number}/labels" \
    -f "labels[]=${label}" --silent
}

# Last-resort discoverability when even the retried failure comment fails.
# A label survives when every comment attempt is swallowed by a forge outage.
_post_failure_apply_failed_label() {
  local label="$1"
  local target="${2:-issue}"
  local number description

  if [ "${target}" = "pr" ]; then
    number="${PR_NUMBER:-}"
    description="Fix agent post-script failed"
  else
    number="${ISSUE_NUMBER:-}"
    description="Code agent post-script failed"
  fi

  if [ -z "${number}" ] || [ -z "${REPO_FULL_NAME:-}" ]; then
    gha_echo warning "Cannot apply last-resort ${label} label (missing issue/PR number or repo)"
    return 1
  fi

  gha_echo warning "Applying last-resort ${label} label so the failure is discoverable"

  if ! _post_failure_create_label "${label}" "${description}"; then
    gha_echo warning "Failed to create last-resort ${label} label (may already exist)"
  fi

  if _post_failure_add_label "${label}" "${target}" "${number}"; then
    return 0
  fi

  gha_echo warning "Failed to apply last-resort ${label} label to ${target} #${number}"
  return 1
}

report_post_failure_to_issue() {
  local exit_code="${1:-$?}"
  local safe_issue_number

  if [ "${POST_FAILURE_REPORTED}" = "true" ]; then
    return 0
  fi
  POST_FAILURE_REPORTED=true

  # An external tracker may have no corresponding target-forge issue. The
  # workflow status notification remains the source-of-truth; do not guess a
  # target issue number and risk commenting on unrelated work.
  if [ "${EXTERNAL_WORK_ITEM:-false}" = "true" ]; then
    gha_echo warning "Post-code failure for ${WORK_ITEM_KEY:-external work item}; see workflow logs"
    return 0
  fi

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
    if ! forge_retry_transient forge_post_issue_comment "${body}"; then
      gha_echo warning "Failed to post error comment to issue #${safe_issue_number}"
      _post_failure_apply_failed_label "code-agent-failed" "issue"
    fi
  else
    if ! forge_retry_transient gh issue comment "${ISSUE_NUMBER}" \
      --repo "${REPO_FULL_NAME}" \
      --body "${body}"; then
      gha_echo warning "Failed to post error comment to issue #${safe_issue_number}"
      _post_failure_apply_failed_label "code-agent-failed" "issue"
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
    if ! forge_retry_transient forge_post_pr_comment "${PR_NUMBER}" "${body}"; then
      gha_echo warning "Failed to post error comment to PR #${safe_pr_number}"
      _post_failure_apply_failed_label "fix-agent-failed" "pr"
    fi
  else
    if ! forge_retry_transient gh pr comment "${PR_NUMBER}" \
      --repo "${REPO_FULL_NAME}" \
      --body "${body}"; then
      gha_echo warning "Failed to post error comment to PR #${safe_pr_number}"
      _post_failure_apply_failed_label "fix-agent-failed" "pr"
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
