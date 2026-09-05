#!/usr/bin/env bash
# GENERATED from validate-code-output.src.sh — DO NOT EDIT. Run: make script-build
# validate-code-output.src.sh — Validate code/fix agent output: schema + pre-commit.
#
# Wraps validate-output-schema.sh's schema check with an additional pre-commit
# gate run against TARGET_REPO_DIR.  Used as the validation_loop.script for the
# code and fix harnesses so that a lint or type-check failure consumes a retry
# iteration (with feedback) instead of ending the run terminally in the
# post-script.
#
# The pre-commit check runs on the runner (not in the sandbox), so it has
# full network access and the repo's pre-commit tool dependencies are already
# installed by the pre-script.
#
# Required env vars:
#   FULLSEND_OUTPUT_SCHEMA — path to the JSON Schema file
#
# Optional env vars:
#   FULLSEND_OUTPUT_FILE   — filename to validate (default: agent-result.json)
#   TARGET_REPO_DIR        — path to the target repo (empty on sweep path)
#   TARGET_BRANCH          — branch the PR targets (for merge-base derivation)
#
# Category gating:
#   pre-commit-blocked — agent-fixable; consumes a retry iteration
#   signed-off-by      — NOT agent-fixable; soft-pass (post-script strips it)
#   secret-scan        — NOT agent-fixable; soft-pass (post-script handles terminally)
#   infra/transient    — NOT agent-fixable; soft-pass

set -euo pipefail

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
    signoff-rewrite-failed) echo "Signed-off-by strip failed" ;;
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
# shellcheck source=lib/precommit-gate.lib.sh
# BEGIN bundled: lib/precommit-gate.lib.sh
# precommit-gate.lib.sh — Shared pre-commit gate for validation loop and post-scripts.
#
# Source from validate-code-output.src.sh / post-code.src.sh / post-fix.src.sh:
#   source "${SCRIPT_DIR}/lib/precommit-gate.lib.sh"
#
# Provides:
#   precommit_install_deps  — Auto-install pre-commit tool dependencies
#   precommit_run_gate      — Run pre-commit with optional auto-fix retry
#
# Output contract (set by precommit_run_gate, read by callers):
#   PRECOMMIT_GATE_RESULT       — "pass" | "fail" | "skip"
#   PRECOMMIT_GATE_CATEGORY     — failure category
#   PRECOMMIT_GATE_DETAIL       — failure detail text
#   PRECOMMIT_GATE_SECRET_FAIL  — "true" if secret-scan failed after auto-fix
#   PRECOMMIT_GATE_SIGNOFF_FAIL — "true" if signed-off-by failed after auto-fix
#
# Optional controls (set by callers before calling precommit_run_gate):
#   PRECOMMIT_GATE_AUTOFIX      — "true" (default) to auto-fix + amend;
#                                  "false" to check-only (no git writes)

# shellcheck shell=bash

[[ -n "${PRECOMMIT_GATE_SH_LOADED:-}" ]] && return 0
PRECOMMIT_GATE_SH_LOADED=1

# ---------------------------------------------------------------------------
# Signed-off-by trailer helpers
#
# The post-scripts strip an agent's trailer instead of discarding the run.
# SCAN_RANGE can cover human commits (post-fix widens it to merge-base after a
# rebase), and a human's sign-off is a DCO attestation that must survive, so
# every helper is scoped to agent-authored commits.
# ---------------------------------------------------------------------------

# signoff_bot_email — agent's git identity, exported by the dispatch workflow.
# Empty means unknown: detection stays broad so a trailer is still noticed, but
# signoff_strip_range refuses to rewrite rather than risk a human's sign-off.
signoff_bot_email() {
  printf '%s' "${GIT_BOT_EMAIL:-${GIT_COMMITTER_EMAIL:-}}"
}

# signoff_is_bot_commit <sha> — 0 when the commit is in scope for rewriting.
# Author, not committer: a rebase re-stamps the committer onto commits the
# human wrote. Author is also what the DCO app checks when it waives bots.
signoff_is_bot_commit() {
  local _sb_bot
  _sb_bot="$(signoff_bot_email)"
  [ -z "${_sb_bot}" ] && return 0
  [ "$(git log -1 --format='%ae' "$1" 2>/dev/null)" = "${_sb_bot}" ]
}

# signoff_count_range <range> — number of in-scope commits carrying a trailer.
signoff_count_range() {
  local _sc_n=0 _sc_sha
  for _sc_sha in $(git rev-list "$1" 2>/dev/null); do
    if signoff_is_bot_commit "${_sc_sha}" \
       && git log -1 --format='%B' "${_sc_sha}" | grep -q '^Signed-off-by:'; then
      _sc_n=$((_sc_n + 1))
    fi
  done
  printf '%s' "${_sc_n}"
}

# signoff_present_in_range <range> — 0 when an in-scope commit carries one.
signoff_present_in_range() {
  [ "$(signoff_count_range "$1")" -gt 0 ]
}

# signoff_strip_range <range> — drop the trailer from in-scope messages.
# Diagnoses to stderr and returns non-zero on rewrite failure so callers fail
# closed. Never touches commits below the range's base.
signoff_strip_range() {
  local _ss_range="$1" _ss_bot _ss_tmp _ss_sed _ss_sha
  local _ss_base="" _ss_tip_n=0 _ss_in_tip=1 _ss_below=0
  _ss_bot="$(signoff_bot_email)"
  # Skip line 1 so a message whose subject IS the trailer keeps a subject.
  _ss_sed='1!{/^Signed-off-by:/d;}'

  # Without an identity every commit looks like the agent's, and the range can
  # hold a human's DCO sign-off. Refuse rather than guess.
  if [ -z "${_ss_bot}" ]; then
    echo "signoff-strip: agent git identity unavailable (GIT_BOT_EMAIL unset)" >&2
    return 1
  fi

  # Narrow the rewrite to the contiguous run of agent commits at the tip.
  # filter-branch re-creates every commit it is handed even when the filter is
  # cat, and commit-tree cannot reproduce gpgsig, so a human commit inside the
  # range would lose its signature and change SHA. Agent commits sit at the
  # tip in practice; an in-scope trailer below a human commit fails closed.
  for _ss_sha in $(git rev-list "${_ss_range}" 2>/dev/null); do
    if [ "${_ss_in_tip}" -eq 1 ] && signoff_is_bot_commit "${_ss_sha}"; then
      _ss_tip_n=$((_ss_tip_n + 1))
      _ss_base="${_ss_sha}"
    else
      _ss_in_tip=0
      if signoff_is_bot_commit "${_ss_sha}" \
         && git log -1 --format='%B' "${_ss_sha}" | grep -q '^Signed-off-by:'; then
        _ss_below=1
      fi
    fi
  done
  if [ "${_ss_below}" -eq 1 ]; then
    echo "signoff-strip: an agent commit with a trailer sits below a non-agent commit; refusing to rewrite past it" >&2
    return 1
  fi
  [ "${_ss_tip_n}" -eq 0 ] && return 0

  # filter-branch refuses on unstaged changes; refresh first because
  # diff-files is stat-based and a fresh checkout can look dirty.
  git update-index -q --refresh >/dev/null 2>&1 || true
  if ! git diff-files --quiet; then
    echo "signoff-strip: worktree has unstaged changes to tracked files" >&2
    return 1
  fi

  if [ "${_ss_tip_n}" -eq 1 ]; then
    _ss_tmp="$(mktemp)"
    if ! git log -1 --format='%B' HEAD | sed "${_ss_sed}" > "${_ss_tmp}"; then
      rm -f "${_ss_tmp}"
      echo "signoff-strip: could not read the commit message" >&2
      return 1
    fi
    # --amend re-stamps the committer, so carry the original across.
    # --only keeps it to the message; a bare --amend would sweep staged
    # files in past the secret scan.
    if ! GIT_COMMITTER_NAME="$(git log -1 --format='%cn' HEAD)" \
         GIT_COMMITTER_EMAIL="$(git log -1 --format='%ce' HEAD)" \
         GIT_COMMITTER_DATE="$(git log -1 --format='%cD' HEAD)" \
         git commit --amend --only --no-verify -F "${_ss_tmp}" >/dev/null; then
      rm -f "${_ss_tmp}"
      echo "signoff-strip: git commit --amend failed" >&2
      return 1
    fi
    rm -f "${_ss_tmp}"
    return 0
  fi

  # filter-branch also refuses on a dirty index. The single-commit path above
  # tolerates one, because --only keeps staged files out of the commit.
  if ! git diff-index --quiet --cached HEAD; then
    echo "signoff-strip: index has staged changes" >&2
    return 1
  fi

  # The narrowed range is agent-only by construction; the author check in the
  # filter is a second line of defence. filter-branch exports each original
  # commit's identity, so $GIT_AUTHOR_EMAIL is the commit being rewritten. The
  # bot address goes through the environment, not the filter text: it
  # contains "[bot]" and "+".
  if ! FILTER_BRANCH_SQUELCH_WARNING=1 SIGNOFF_BOT_EMAIL="${_ss_bot}" \
       git filter-branch -f \
       --msg-filter 'if [ "${GIT_AUTHOR_EMAIL}" = "${SIGNOFF_BOT_EMAIL}" ]; then sed '"'${_ss_sed}'"'; else cat; fi' \
       -- "${_ss_base}^..HEAD" >/dev/null; then
    echo "signoff-strip: git filter-branch failed" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# precommit_install_deps <target_branch>
#
# Auto-install pre-commit tool dependencies from .pre-commit-tools.yaml.
# Looks for resolve-precommit-tools.py and install-precommit-tools.sh
# relative to the calling script, then in workspace fallback paths.
# ---------------------------------------------------------------------------
precommit_install_deps() {
  local _pid_target_branch="${1:-main}"

  if [ ! -f .pre-commit-config.yaml ]; then
    return 0
  fi

  # Locate companion scripts.  The BASH_SOURCE-relative lookup covers the
  # case where the caller (post-code.sh, post-fix.sh) sits next to them;
  # the workspace fallback covers the common CI layout.
  local _pid_resolve="" _pid_install=""
  local _pid_script_dir
  # BASH_SOURCE[1] is the direct caller of this function (the sourcing
  # script).  Fall back to BASH_SOURCE[0] (this lib itself, which the
  # bundler inlines into the caller).
  _pid_script_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"

  if [ -f "${_pid_script_dir}/resolve-precommit-tools.py" ] \
     && [ -f "${_pid_script_dir}/install-precommit-tools.sh" ]; then
    _pid_resolve="${_pid_script_dir}/resolve-precommit-tools.py"
    _pid_install="${_pid_script_dir}/install-precommit-tools.sh"
  fi

  # Workspace fallback — these companion scripts were never migrated into
  # this repo, so the BASH_SOURCE lookup above usually misses.
  if [ -z "${_pid_resolve}" ] || [ -z "${_pid_install}" ]; then
    local _pid_ws="${CI_PROJECT_DIR:-${GITHUB_WORKSPACE:-}}"
    if [ -n "${_pid_ws}" ]; then
      local _pid_cand
      for _pid_cand in "${_pid_ws}/scripts" "${_pid_ws}/.fullsend/scripts"; do
        if [ -f "${_pid_cand}/resolve-precommit-tools.py" ] \
           && [ -f "${_pid_cand}/install-precommit-tools.sh" ]; then
          _pid_resolve="${_pid_cand}/resolve-precommit-tools.py"
          _pid_install="${_pid_cand}/install-precommit-tools.sh"
          break
        fi
      done
    fi
  fi

  if [ -z "${_pid_resolve}" ] || [ -z "${_pid_install}" ]; then
    gha_echo warning "Pre-commit tool auto-install skipped: companion scripts not found"
    gha_echo warning "Pre-commit hooks requiring system tools (e.g. lychee) may fail"
    return 0
  fi

  local _pid_manifest _pid_local_reg
  _pid_manifest="$(mktemp)"
  _pid_local_reg="$(mktemp)"
  local _pid_args=(".")
  if git show "origin/${_pid_target_branch}:.pre-commit-tools.yaml" \
       > "${_pid_local_reg}" 2>/dev/null; then
    _pid_args+=("--local-registry" "${_pid_local_reg}")
  fi
  if python3 "${_pid_resolve}" "${_pid_args[@]}" > "${_pid_manifest}"; then
    if [ -s "${_pid_manifest}" ] \
       && jq -e '.tools | length > 0' "${_pid_manifest}" >/dev/null 2>&1; then
      bash "${_pid_install}" "${_pid_manifest}"
    fi
  else
    gha_echo warning "Pre-commit tool resolution failed — continuing without auto-install"
  fi
  rm -f "${_pid_manifest}" "${_pid_local_reg}"
}

# ---------------------------------------------------------------------------
# precommit_run_gate <changed_files_var> <scan_range> <target_branch> <merge_base>
#
# Run pre-commit on changed files with optional auto-fix retry.
#
# Parameters:
#   $1 — name of a bash array variable holding changed file paths (nameref)
#   $2 — git range for gitleaks re-scan after auto-fix (e.g. "abc123..HEAD")
#   $3 — target branch name (for fallback diff derivation)
#   $4 — merge-base commit (for diff derivation after auto-fix)
#
# The function always returns 0.  Callers inspect the output variables to
# decide what to do (post_fail_to_issue, exit 1, etc.).
#
# When PRECOMMIT_GATE_AUTOFIX is "false", no git writes occur — the
# function runs pre-commit once and reports the result.  This is the
# mode used by the validation-loop script, where the repo is an
# extracted copy and git amends would be invisible to the sandbox agent.
# ---------------------------------------------------------------------------
precommit_run_gate() {
  local -n _pg_files=$1
  local _pg_scan_range="$2"
  local _pg_target_branch="$3"
  local _pg_merge_base="$4"

  # Output contract — callers read these after the function returns.
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_RESULT="skip"
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_CATEGORY=""
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_DETAIL=""
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_SECRET_FAIL="false"
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_SIGNOFF_FAIL="false"

  if [ ! -f .pre-commit-config.yaml ]; then
    echo "No .pre-commit-config.yaml — skipping pre-commit check"
    return 0
  fi

  if ! command -v pre-commit >/dev/null 2>&1; then
    echo "Installing pre-commit..."
    pip install "pre-commit==4.5.1" 2>/dev/null \
      || pip3 install "pre-commit==4.5.1" 2>/dev/null \
      || pipx install "pre-commit==4.5.1" 2>/dev/null \
      || gha_echo warning "Failed to install pre-commit"
  fi

  if ! command -v pre-commit >/dev/null 2>&1; then
    gha_echo warning "pre-commit not available — skipping authoritative check"
    return 0
  fi

  echo "Running pre-commit on changed files..."
  local _pg_output=""
  if _pg_output="$(pre-commit run --files "${_pg_files[@]}" 2>&1)"; then
    print_sanitized_gha_log "${_pg_output}"
    echo "Pre-commit passed — all hooks clean"
    # shellcheck disable=SC2034
    PRECOMMIT_GATE_RESULT="pass"
    return 0
  fi

  print_sanitized_gha_log "${_pg_output}"

  # --- Auto-fix retry (only when PRECOMMIT_GATE_AUTOFIX is not "false") ---
  if [ "${PRECOMMIT_GATE_AUTOFIX:-true}" != "false" ] \
     && git diff --name-only -- "${_pg_files[@]}" | grep -q .; then
    gha_echo warning "Pre-commit hooks auto-fixed files — re-staging and retrying"
    echo "Auto-fixed files:"
    git diff --name-only -- "${_pg_files[@]}" | sed 's/^/  /'
    git diff --name-only -z -- "${_pg_files[@]}" | xargs -0 -r git add --
    git commit --amend --no-edit

    # Re-run secret scan on the amended commit.
    echo "Re-running secret scan on amended commit..."
    local _pg_gl_output=""
    if ! _pg_gl_output="$(gitleaks detect --source . \
           --log-opts="${_pg_scan_range}" --redact 2>&1)"; then
      print_sanitized_gha_log "${_pg_gl_output}" stderr
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_SECRET_FAIL="true"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_RESULT="fail"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_CATEGORY="secret-scan"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_DETAIL="${POST_FAILURE_SECRET_SCAN_MESSAGE}"
      return 0
    fi

    # Re-check signed-off-by trailers — strip if present (defense-in-depth).
    # The auto-fix amend above can only have re-added a trailer to HEAD (a repo
    # commit-msg hook); section 3b already cleaned the rest of the range.
    if signoff_present_in_range "${_pg_scan_range}"; then
      gha_echo warning "Signed-off-by trailer found after auto-fix amend — stripping"
      if ! signoff_strip_range "${_pg_scan_range}"; then
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_SIGNOFF_FAIL="true"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_RESULT="fail"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_CATEGORY="signoff-rewrite-failed"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_DETAIL="Could not strip the Signed-off-by trailer added after pre-commit auto-fix."
        return 0
      fi
      # Re-scan: fail only if a trailer survives a rewrite that reported success
      if signoff_present_in_range "${_pg_scan_range}"; then
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_SIGNOFF_FAIL="true"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_RESULT="fail"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_CATEGORY="signed-off-by"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_DETAIL="Signed-off-by trailer persists after rewrite attempt."
        return 0
      fi
      echo "Signed-off-by trailer removed after auto-fix amend"
    fi

    # Re-derive changed files after the amend.
    local _pg_new_changed=""
    if [ -n "${_pg_merge_base}" ]; then
      _pg_new_changed="$(git diff --name-only "${_pg_merge_base}..HEAD")"
    else
      _pg_new_changed="$(git diff --name-only \
        "origin/${_pg_target_branch}..HEAD" 2>/dev/null \
        || git diff --name-only HEAD~1..HEAD 2>/dev/null || true)"
    fi

    if [ -z "${_pg_new_changed}" ]; then
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_RESULT="fail"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_CATEGORY="pre-commit-blocked"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_DETAIL="Pre-commit hooks removed all changes; commit is now empty."
      return 0
    fi

    # Rebuild the caller's array with the updated file list.
    _pg_files=()
    while IFS= read -r _pg_line; do
      _pg_files+=("${_pg_line}")
    done <<< "${_pg_new_changed}"

    # Single retry.
    local _pg_retry_output=""
    if _pg_retry_output="$(pre-commit run --files "${_pg_files[@]}" 2>&1)"; then
      print_sanitized_gha_log "${_pg_retry_output}"
      if git diff --name-only -- "${_pg_files[@]}" | grep -q .; then
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_RESULT="fail"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_CATEGORY="pre-commit-blocked"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_DETAIL="Retry pre-commit left additional unstaged changes; committed content would diverge from what pre-commit validated."
        return 0
      fi
      echo "Pre-commit passed after auto-fix re-stage"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_RESULT="pass"
      return 0
    else
      print_sanitized_gha_log "${_pg_retry_output}"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_RESULT="fail"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_CATEGORY="pre-commit-blocked"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_DETAIL="${_pg_retry_output}"
      return 0
    fi
  fi

  # No auto-fix attempted (either disabled or no files were modified by hooks).
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_RESULT="fail"
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_CATEGORY="pre-commit-blocked"
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_DETAIL="${_pg_output}"
}
# END bundled: lib/precommit-gate.lib.sh

# ============================================================================
# Part 1: Schema validation (inline from validate-output-schema.sh)
# ============================================================================

: "${FULLSEND_OUTPUT_SCHEMA:?FULLSEND_OUTPUT_SCHEMA must be set}"

OUTPUT_DIR="output"
if [[ ! -d "${OUTPUT_DIR}" ]]; then
  echo "FAIL: output directory not found"
  exit 1
fi

_output_file="${FULLSEND_OUTPUT_FILE:-agent-result.json}"
_output_file="$(basename "${_output_file}")"
RESULT_FILE="${OUTPUT_DIR}/${_output_file}"
if [[ ! -f "${RESULT_FILE}" ]]; then
  echo "FAIL: ${RESULT_FILE} not found"
  exit 1
fi
echo "Validating: ${RESULT_FILE} against ${FULLSEND_OUTPUT_SCHEMA}"

if ! python3 -m json.tool "${RESULT_FILE}" > /dev/null 2>&1; then
  echo "FAIL: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

if ! python3 -c "import jsonschema" 2>/dev/null; then
  echo "FAIL: python3 jsonschema package is not installed (required by ADR 0022)"
  exit 1
fi

if ! python3 -c "
import json, sys
from jsonschema import validate, ValidationError

with open(sys.argv[1]) as f:
    instance = json.load(f)
with open(sys.argv[2]) as f:
    schema = json.load(f)
try:
    validate(instance=instance, schema=schema)
    print('PASS: output validated against schema')
except ValidationError as e:
    print(f'FAIL: schema validation error: {e.message}')
    if e.path:
        print(f'  at: {\".\".join(str(p) for p in e.path)}')
    if 'properties' in e.schema:
        allowed = ', '.join(sorted(e.schema['properties'].keys()))
        print(f'  allowed properties: {allowed}')
    sys.exit(1)
" "${RESULT_FILE}" "${FULLSEND_OUTPUT_SCHEMA}"; then
  exit 1
fi

# ============================================================================
# Part 2: Pre-commit gate against TARGET_REPO_DIR
# ============================================================================

# Soft-pass when TARGET_REPO_DIR is empty or absent.  The post-loop sweep
# re-validates earlier iterations with the repo dir unavailable — the
# schema half is still valuable, but the pre-commit half has nothing to
# check.
if [ -z "${TARGET_REPO_DIR:-}" ] || [ ! -d "${TARGET_REPO_DIR}" ]; then
  echo "TARGET_REPO_DIR empty or absent — skipping pre-commit gate (sweep path)"
  exit 0
fi

# Resolve the branch to diff against BEFORE leaving the iteration directory.
# The agent declares its target in the structured output Part 1 just
# validated, and that is the branch post-code.src.sh will gate against; the
# TARGET_BRANCH env var is the workflow's default (hard-coded "main" for the
# code harness) and only a fallback. Diffing against the wrong base here
# would lint a different file set from the authoritative post-script gate,
# and the two must agree. Allowlist policy stays in post-code — this is
# just "which ref do I diff against", and an unknown ref falls through the
# merge-base fallback chain below.
AGENT_TARGET="$(jq -r '.target_branch // empty' "${RESULT_FILE}" 2>/dev/null || true)"
TARGET_BRANCH="${AGENT_TARGET:-${TARGET_BRANCH:-main}}"

# The validation script starts in the iteration directory, not the repo.
cd "${TARGET_REPO_DIR}"

# --- Derive changed files (merge-base fallback chain per post-code.src.sh) ---

MERGE_BASE="$(git merge-base "origin/${TARGET_BRANCH}" HEAD 2>/dev/null)" \
  || MERGE_BASE=""
if [ -n "${MERGE_BASE}" ]; then
  CHANGED_FILES="$(git diff --name-only "${MERGE_BASE}..HEAD")"
  SCAN_RANGE="${MERGE_BASE}..HEAD"
else
  gha_echo warning "Could not determine merge-base — trying origin/${TARGET_BRANCH}..HEAD"
  CHANGED_FILES="$(git diff --name-only "origin/${TARGET_BRANCH}..HEAD" 2>/dev/null \
    || git diff --name-only HEAD~1..HEAD 2>/dev/null || true)"
  SCAN_RANGE="HEAD~1..HEAD"
fi

if [ -z "${CHANGED_FILES}" ]; then
  echo "No changed files — skipping pre-commit gate"
  exit 0
fi

echo "Changed files for pre-commit gate:"
echo "${CHANGED_FILES}" | sed 's/^/  /'

# --- Check for Signed-off-by trailers ---
#
# Soft-pass, same bucket as secret-scan: NOT agent-fixable here, handled
# terminally by the post-script. TARGET_REPO_DIR is an extracted copy, so a
# rewrite here would be invisible to the sandbox agent anyway (see the
# PRECOMMIT_GATE_AUTOFIX="false" contract below) — and post-code.sh section 3b
# / post-fix.sh section 1b now STRIP the trailer instead of rejecting.
# Failing here would burn a validation iteration for something already
# repaired downstream, which is the retry half of the #1184 cost.
echo "Checking for Signed-off-by trailers..."
if git log --format='%B' "${SCAN_RANGE}" | grep -q '^Signed-off-by:'; then
  gha_echo warning "Signed-off-by trailer present — deferring to post-script (strips it); not consuming an iteration"
fi

# --- Install pre-commit tool dependencies ---
precommit_install_deps "${TARGET_BRANCH}"
export PATH="${HOME}/.local/bin:${PATH}"

# --- Run pre-commit gate (check-only, no auto-fix) ---
# The validation loop feeds failures back to the agent via feedback_mode:
# append.  Auto-fix + amend is not appropriate here because TARGET_REPO_DIR
# is an extracted copy — changes would be invisible to the sandbox agent.
# shellcheck disable=SC2034
PRECOMMIT_GATE_AUTOFIX="false"

changed_array=()
while IFS= read -r _line; do
  changed_array+=("${_line}")
done <<< "${CHANGED_FILES}"

precommit_run_gate changed_array "${SCAN_RANGE}" "${TARGET_BRANCH}" "${MERGE_BASE}"

# --- Category gating ---
#
# In check-only mode the lib never reaches its auto-fix branch, which is the
# only place it sets a category other than pre-commit-blocked. So the
# classification the header promises (secret-scan and infra soft-pass) has
# to be derived here, from the hook output itself:
#
#   secret-scan — every failed hook is a secret scanner. The agent cannot
#                 usefully act on a gitleaks/detect-secrets verdict inside a
#                 retry, and the post-script owns terminal handling of it.
#   infra       — pre-commit itself failed before running any hook (no
#                 "- hook id:" lines): bad manifest/config, or a hook-repo
#                 fetch failure on the runner. Nothing the agent can fix.
#
# A hook that fails with "Executable ... not found" still carries a hook id
# and is deliberately NOT soft-passed here: it usually sits alongside
# fixable failures, and dropping the whole iteration would lose those.
# That case is #3746's to classify.
classify_checkonly_failure() {
  local detail="$1"
  local hook_ids
  hook_ids="$(printf '%s\n' "${detail}" | sed -n 's/^- hook id: //p')"
  if [ -z "${hook_ids}" ]; then
    if printf '%s' "${detail}" | grep -qE \
         'An unexpected error has occurred|Invalid(Manifest|Config)Error|Could not resolve host|unable to access|Failed to fetch|failed to clone'; then
      echo "infra"; return 0
    fi
    echo "pre-commit-blocked"; return 0
  fi
  if ! printf '%s\n' "${hook_ids}" | grep -qvE 'gitleaks|detect-secrets|detect-private-key|secret'; then
    echo "secret-scan"; return 0
  fi
  echo "pre-commit-blocked"
}

case "${PRECOMMIT_GATE_RESULT}" in
  pass|skip)
    # All good — nothing to gate.
    ;;
  fail)
    CATEGORY="${PRECOMMIT_GATE_CATEGORY}"
    if [ "${CATEGORY}" = "pre-commit-blocked" ]; then
      CATEGORY="$(classify_checkonly_failure "${PRECOMMIT_GATE_DETAIL}")"
    fi
    case "${CATEGORY}" in
      pre-commit-blocked)
        # Agent-fixable: consume a retry iteration with feedback. The lib
        # already printed the sanitised hook output above — do not echo it
        # again: this stream is truncated to 10 KiB before it becomes the
        # next iteration's prompt, and a second copy halves what the agent
        # gets to see of a verbose linter.
        echo "FAIL: ${CATEGORY} — fix the hook failures reported above"
        exit 1
        ;;
      secret-scan)
        gha_echo warning "secret-scan hook failure — deferring to post-script (terminal); not consuming an iteration"
        ;;
      infra)
        gha_echo warning "pre-commit itself failed before running hooks (infra/transient) — soft-pass; not consuming an iteration"
        ;;
    esac
    ;;
esac
