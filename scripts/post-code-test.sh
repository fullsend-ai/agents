#!/usr/bin/env bash
# post-code-test.sh — Test the PR title injection logic from post-code.sh.
#
# Extracts and tests the title-rewriting logic in isolation using shell
# functions. This avoids needing a full git repo or GitHub API access.
#
# Run from the repo root:
#   bash scripts/post-code-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"

FAILURES=0

POST_SCRIPT="$(resolve_agent_script post-code "${SCRIPT_DIR}")"
if ! grep -q 'gha_echo' "${POST_SCRIPT}" || ! grep -q 'post_fail_to_issue' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-failure-reporting"
  echo "  ${POST_SCRIPT} missing gha_echo or post_fail_to_issue"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-failure-reporting"
fi

if ! grep -q 'install_gitleaks' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-gitleaks-install"
  echo "  ${POST_SCRIPT} missing install_gitleaks"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-gitleaks-install"
fi

if ! grep -q 'maybe_assign_pr' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-pr-assignee"
  echo "  ${POST_SCRIPT} missing maybe_assign_pr"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-pr-assignee"
fi

# ---------------------------------------------------------------------------
# Test helper — reimplements the title-rewriting logic from post-code.sh
# so we can test it without a git repo or network access.
# ---------------------------------------------------------------------------
rewrite_title() {
  local commit_subject="$1"
  local issue_number="$2"

  if echo "${commit_subject}" | grep -qE '^[a-z]+\('; then
    echo "${commit_subject}"
  elif echo "${commit_subject}" | grep -qE '^[a-z]+: '; then
    echo "${commit_subject}" | sed "s/^\([a-z]*\): /\1(#${issue_number}): /"
  else
    echo "${commit_subject}"
  fi
}

run_test() {
  local test_name="$1"
  local commit_subject="$2"
  local issue_number="$3"
  local expected="$4"

  local actual
  actual="$(rewrite_title "${commit_subject}" "${issue_number}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  input:    '${commit_subject}' (issue #${issue_number})"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Test cases ---

# Plain conventional commit — should inject issue reference
run_test "fix-without-scope" \
  "fix: correct placeholder text in secrets page dropdowns" \
  "837" \
  "fix(#837): correct placeholder text in secrets page dropdowns"

run_test "feat-without-scope" \
  "feat: add CSV export support" \
  "42" \
  "feat(#42): add CSV export support"

run_test "chore-without-scope" \
  "chore: update dependencies" \
  "100" \
  "chore(#100): update dependencies"

run_test "docs-without-scope" \
  "docs: update contributing guide" \
  "55" \
  "docs(#55): update contributing guide"

run_test "refactor-without-scope" \
  "refactor: simplify error handling" \
  "200" \
  "refactor(#200): simplify error handling"

# Already has a scope — should NOT modify
run_test "already-has-issue-scope" \
  "fix(#837): correct placeholder text" \
  "837" \
  "fix(#837): correct placeholder text"

run_test "already-has-jira-scope" \
  "fix(KFLUXUI-1200): correct placeholder text" \
  "837" \
  "fix(KFLUXUI-1200): correct placeholder text"

run_test "already-has-component-scope" \
  "feat(api): add new endpoint" \
  "42" \
  "feat(api): add new endpoint"

# Non-conventional titles — should NOT modify
run_test "non-conventional-title" \
  "Add CSV export support" \
  "42" \
  "Add CSV export support"

run_test "uppercase-type" \
  "Fix: correct placeholder text" \
  "42" \
  "Fix: correct placeholder text"

run_test "no-colon" \
  "fix the placeholder text" \
  "42" \
  "fix the placeholder text"

# Edge cases
run_test "test-type" \
  "test: add unit tests for export" \
  "99" \
  "test(#99): add unit tests for export"

run_test "ci-type" \
  "ci: update workflow permissions" \
  "10" \
  "ci(#10): update workflow permissions"

# ---------------------------------------------------------------------------
# Test helper — reimplements the PR body assembly logic from post-code.sh
# so we can test it without a git repo or network access.
# ---------------------------------------------------------------------------
build_pr_body() {
  local commit_body="$1"
  local issue_number="$2"
  local branch="$3"
  local scan_range="$4"
  local pr_body_from_result="${5:-}"  # optional: agent-provided pr_body
  local pr_body_scan_status="${6:-skipped}"  # passed|blocked|error|skipped

  local description=""
  if [ -n "${pr_body_from_result}" ]; then
    # Strip Signed-off-by globally, then trailing closing-keyword footers.
    local pr_body_clean
    pr_body_clean="$(printf '%s\n' "${pr_body_from_result}" | sed '/^Signed-off-by:/d')"
    description="$(printf '%s\n' "${pr_body_clean}" | awk '
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
  fi

  # Fall back if pr_body was absent or stripped to empty
  if [ -z "${description}" ]; then
    if [ -z "${commit_body}" ]; then
      description="Automated implementation for issue #${issue_number}."
    else
      description="${commit_body}"
    fi
  fi

  local pr_body_scan_line
  case "${pr_body_scan_status}" in
    passed)  pr_body_scan_line="- [x] PR body secret scan passed (gitleaks — no-git)" ;;
    blocked) pr_body_scan_line="- [x] PR body secret scan: blocked, fell back to commit body" ;;
    error)   pr_body_scan_line="- [x] PR body secret scan: error, fell back to commit body" ;;
    *)       pr_body_scan_line="- [x] PR body secret scan: N/A (commit body path)" ;;
  esac

  echo "${description}

---

Closes #${issue_number}

### Post-script verification

- [x] Branch is not main/master (\`${branch}\`)
- [x] Secret scan passed (gitleaks — \`${scan_range}\`)
${pr_body_scan_line}
- [x] Pre-commit hooks passed (authoritative run on runner)
- [x] Tests ran inside sandbox"
}

run_body_test() {
  local test_name="$1"
  local commit_body="$2"
  local issue_number="$3"
  local branch="$4"
  local check_pattern="$5"
  local expect_present="$6"  # "yes" or "no"

  local actual
  actual="$(build_pr_body "${commit_body}" "${issue_number}" "${branch}" "abc123..def456")"

  if [ "${expect_present}" = "yes" ]; then
    if ! echo "${actual}" | grep -qF "${check_pattern}"; then
      echo "FAIL: ${test_name}"
      echo "  expected to find: '${check_pattern}'"
      echo "  in body:"
      echo "${actual}" | sed 's/^/    /'
      FAILURES=$((FAILURES + 1))
      return
    fi
  else
    if echo "${actual}" | grep -qF "${check_pattern}"; then
      echo "FAIL: ${test_name}"
      echo "  expected NOT to find: '${check_pattern}'"
      echo "  in body:"
      echo "${actual}" | sed 's/^/    /'
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

# --- PR body test cases ---

# Body should contain exactly one Closes line (the footer one)
run_body_test "closes-appears-once" \
  "Fix the widget rendering." \
  "42" "agent/42-fix-widget" \
  "Closes #42" "yes"

# Body should NOT contain a Changed files section
run_body_test "no-changed-files-section" \
  "Fix the widget rendering." \
  "42" "agent/42-fix-widget" \
  "Changed files" "no"

# Body should NOT contain a Created by footer
run_body_test "no-created-by-footer" \
  "Fix the widget rendering." \
  "42" "agent/42-fix-widget" \
  "Created by" "no"

# Empty commit body should use fallback description
run_body_test "empty-body-fallback" \
  "" \
  "99" "agent/99-add-feature" \
  "Automated implementation for issue #99." "yes"

# Empty commit body should still not have Changed files
run_body_test "empty-body-no-changed-files" \
  "" \
  "99" "agent/99-add-feature" \
  "Changed files" "no"

# Empty commit body should still not have Created by
run_body_test "empty-body-no-created-by" \
  "" \
  "99" "agent/99-add-feature" \
  "Created by" "no"

# Verify the Closes line count is exactly 1
count_closes_test() {
  local test_name="$1"
  local commit_body="$2"
  local issue_number="$3"

  local actual
  actual="$(build_pr_body "${commit_body}" "${issue_number}" "branch" "range")"
  local count
  count="$(echo "${actual}" | grep -c "Closes #${issue_number}" || true)"

  if [ "${count}" -ne 1 ]; then
    echo "FAIL: ${test_name}"
    echo "  expected exactly 1 'Closes #${issue_number}', found ${count}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

count_closes_test "single-closes-with-body" \
  "Fix rendering bug in the widget component." "42"

count_closes_test "single-closes-empty-body" \
  "" "99"

# Verify pr_body path strips Closes lines (agent may include them)
count_closes_pr_body_test() {
  local test_name="$1"
  local pr_body="$2"
  local issue_number="$3"

  local actual
  actual="$(build_pr_body "" "${issue_number}" "agent/${issue_number}-fix" "abc123..def456" "${pr_body}")"

  local count
  count=$(echo "${actual}" | grep -c "Closes #${issue_number}" || true)

  if [ "${count}" -ne 1 ]; then
    echo "FAIL: ${test_name}"
    echo "  expected exactly 1 'Closes #${issue_number}', found ${count}"
    echo "  in body:"
    echo "${actual}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

count_closes_pr_body_test "single-closes-pr-body-with-closes" \
  "## Summary

Implemented widget rendering.

Closes #42" "42"

count_closes_pr_body_test "single-closes-pr-body-with-cross-repo-closes" \
  "## Summary

Implemented widget rendering.

Closes fullsend-ai/agents#42" "42"

# --- pr_body path test cases ---

# Helper for pr_body tests (fifth arg is pr_body from result file)
run_pr_body_test() {
  local test_name="$1"
  local pr_body="$2"
  local issue_number="$3"
  local branch="$4"
  local check_pattern="$5"
  local expect_present="$6"  # "yes" or "no"

  local actual
  actual="$(build_pr_body "" "${issue_number}" "${branch}" "abc123..def456" "${pr_body}")"

  if [ "${expect_present}" = "yes" ]; then
    if ! echo "${actual}" | grep -qF "${check_pattern}"; then
      echo "FAIL: ${test_name}"
      echo "  expected to find: '${check_pattern}'"
      echo "  in body:"
      echo "${actual}" | sed 's/^/    /'
      FAILURES=$((FAILURES + 1))
      return
    fi
  else
    if echo "${actual}" | grep -qF "${check_pattern}"; then
      echo "FAIL: ${test_name}"
      echo "  expected NOT to find: '${check_pattern}'"
      echo "  in body:"
      echo "${actual}" | sed 's/^/    /'
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

# pr_body provided by agent should appear in final PR body
run_pr_body_test "pr-body-from-result" \
  $'## Summary\n\nAdded widget rendering.\n\n## Testing\n\nManual test.' \
  "42" "agent/42-widget" \
  "Added widget rendering." "yes"

# pr_body should NOT be word-wrapped (it's verbatim)
run_pr_body_test "pr-body-verbatim" \
  $'## Summary\n\nThis is a very long line that would normally be word-wrapped by the legacy commit-body awk logic but should remain intact when coming from pr_body.' \
  "42" "agent/42-widget" \
  "This is a very long line that would normally be word-wrapped by the legacy commit-body awk logic but should remain intact when coming from pr_body." "yes"

# pr_body that strips to empty should fall back to automated description
run_pr_body_test "pr-body-strips-to-empty" \
  $'Closes #42' \
  "42" "agent/42-widget" \
  "Automated implementation for issue #42." "yes"

# Cross-repo Closes in trailing footer should be stripped
run_pr_body_test "pr-body-cross-repo-closes" \
  $'## Summary\n\nImplemented widget rendering.\n\nCloses fullsend-ai/agents#42' \
  "42" "agent/42-widget" \
  "Closes fullsend-ai/agents#42" "no"

# Closes-like line in body content (not footer) should be preserved
run_pr_body_test "pr-body-closes-in-content-preserved" \
  $'## Summary\n\nThis fixes the issue where Closes #99 was not handled.\n\n## Testing\n\nManual test.' \
  "42" "agent/42-widget" \
  "Closes #99 was not handled" "yes"

# Multiple trailing blank lines before footer should all be stripped
count_closes_pr_body_test "pr-body-trailing-blanks-before-footer" \
  $'## Summary\n\nDid the thing.\n\n\n\nCloses #42' "42"

# GitHub auto-close keyword variants should be stripped from footer
run_pr_body_test "pr-body-fixes-keyword-stripped" \
  $'## Summary\n\nFixed the bug.\n\nFixes #42' \
  "42" "agent/42-widget" \
  "Fixes #42" "no"

run_pr_body_test "pr-body-resolves-keyword-stripped" \
  $'## Summary\n\nResolved the issue.\n\nResolves #42' \
  "42" "agent/42-widget" \
  "Resolves #42" "no"

# pr_body strips to empty with non-empty commit body — should fall back to
# commit body, not the generic placeholder
pr_body_fallback_test() {
  local actual
  actual="$(build_pr_body "Fix widget rendering bug in dark mode." "42" "agent/42-widget" "abc123..def456" "Closes #42")"

  if echo "${actual}" | grep -qF "Automated implementation"; then
    echo "FAIL: pr-body-strips-to-empty-falls-back-to-commit-body"
    echo "  expected commit body, got generic placeholder"
    echo "  in body:"
    echo "${actual}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! echo "${actual}" | grep -qF "Fix widget rendering bug in dark mode."; then
    echo "FAIL: pr-body-strips-to-empty-falls-back-to-commit-body"
    echo "  expected commit body content not found"
    echo "  in body:"
    echo "${actual}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: pr-body-strips-to-empty-falls-back-to-commit-body"
}
pr_body_fallback_test

# Signed-off-by mid-body should be stripped (global, not trailing-only)
run_pr_body_test "pr-body-signoff-mid-body-stripped" \
  $'## Summary\n\nDid the thing.\n\nSigned-off-by: bot <bot@noreply.github.com>\n\n## Testing\n\nManual test.' \
  "42" "agent/42-widget" \
  "Signed-off-by" "no"

# Closing keyword with trailing prose on the same line should be preserved
run_pr_body_test "pr-body-closes-trailing-prose-preserved" \
  $'## Summary\n\nDid the thing.\n\nCloses #42 but leaves a follow-up needed for the migration script.' \
  "42" "agent/42-widget" \
  "Closes #42 but leaves a follow-up needed for the migration script." "yes"

# ---------------------------------------------------------------------------
# Test helper — reimplements the no-op detection logic from post-code.sh
# so we can test it without a git repo or network access.
#
# Returns the exit code and message the postscript would produce.
# ---------------------------------------------------------------------------
detect_noop() {
  local branch="$1"
  local changed_files="$2"

  # Step 1: branch check (mirrors lines 64-67 of post-code.sh)
  if [ -z "${branch}" ] || [ "${branch}" = "main" ] || [ "${branch}" = "master" ]; then
    echo "noop:branch:Agent did not create a feature branch (current: '${branch:-detached HEAD}') — nothing to do"
    return 0
  fi

  # Step 2: changed files check (mirrors lines 84-87 of post-code.sh)
  if [ -z "${changed_files}" ]; then
    echo "noop:files:No changed files in agent's commit(s) — nothing to do"
    return 0
  fi

  echo "proceed"
  return 0
}

run_noop_test() {
  local test_name="$1"
  local branch="$2"
  local changed_files="$3"
  local expected_prefix="$4"  # "noop:branch", "noop:files", or "proceed"

  local actual
  actual="$(detect_noop "${branch}" "${changed_files}")"

  if [[ "${actual}" != ${expected_prefix}* ]]; then
    echo "FAIL: ${test_name}"
    echo "  branch:         '${branch}'"
    echo "  changed_files:  '${changed_files}'"
    echo "  expected prefix: '${expected_prefix}'"
    echo "  actual:          '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- No-op detection test cases ---

# On main with no changes → exit 0, noop via branch check
run_noop_test "noop-on-main-no-changes" \
  "main" "" "noop:branch"

# On master with no changes → exit 0, noop via branch check
run_noop_test "noop-on-master-no-changes" \
  "master" "" "noop:branch"

# Detached HEAD (empty branch) with no changes → exit 0, noop via branch check
run_noop_test "noop-detached-head" \
  "" "" "noop:branch"

# Feature branch with no file changes → exit 0, noop via files check
run_noop_test "noop-feature-branch-no-changes" \
  "agent/42-fix-widget" "" "noop:files"

# Feature branch WITH file changes → proceed (existing behavior)
run_noop_test "proceed-feature-branch-with-changes" \
  "agent/42-fix-widget" "src/widget.go" "proceed"

# On main but with changes → still noop (branch check comes first)
run_noop_test "noop-on-main-with-changes" \
  "main" "src/widget.go" "noop:branch"

# ---------------------------------------------------------------------------
# Test helper — reimplements the stale branch cleanup decision logic from
# post-code.sh section 7a. Given whether a remote branch exists and whether
# an open PR references it, returns the action the script would take.
# ---------------------------------------------------------------------------
decide_stale_branch_action() {
  local remote_ref="$1"   # non-empty if remote branch exists
  local open_pr_num="$2"  # non-empty if an open PR uses the branch

  if [ -z "${remote_ref}" ]; then
    echo "skip:no-remote-branch"
    return 0
  fi

  if [ -z "${open_pr_num}" ]; then
    echo "delete:stale-branch"
    return 0
  fi

  echo "keep:open-pr:${open_pr_num}"
  return 0
}

run_stale_branch_test() {
  local test_name="$1"
  local remote_ref="$2"
  local open_pr_num="$3"
  local expected_prefix="$4"

  local actual
  actual="$(decide_stale_branch_action "${remote_ref}" "${open_pr_num}")"

  if [[ "${actual}" != ${expected_prefix}* ]]; then
    echo "FAIL: ${test_name}"
    echo "  remote_ref:      '${remote_ref}'"
    echo "  open_pr_num:     '${open_pr_num}'"
    echo "  expected prefix: '${expected_prefix}'"
    echo "  actual:          '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Stale branch cleanup test cases ---

# No remote branch → skip (normal first push)
run_stale_branch_test "no-remote-branch" \
  "" "" "skip:no-remote-branch"

# Remote branch exists, no open PR → delete stale branch
run_stale_branch_test "stale-branch-no-pr" \
  "abc123 refs/heads/agent/42-fix-widget" "" "delete:stale-branch"

# Remote branch exists, open PR → keep branch (push will update PR)
run_stale_branch_test "branch-with-open-pr" \
  "abc123 refs/heads/agent/42-fix-widget" "99" "keep:open-pr"

# ---------------------------------------------------------------------------
# Test helper — reimplements the push retry logic from post-code.sh
# section 7b. Given a push exit code and output, returns the action.
# ---------------------------------------------------------------------------
decide_push_retry() {
  local push_rc="$1"
  local push_output="$2"

  if [ "${push_rc}" -eq 0 ]; then
    echo "success"
    return 0
  fi

  if echo "${push_output}" | grep -qi "non-fast-forward\|rejected\|fetch first"; then
    echo "retry:force-with-lease"
    return 0
  fi

  echo "fail:unexpected-error"
  return 0
}

run_push_retry_test() {
  local test_name="$1"
  local push_rc="$2"
  local push_output="$3"
  local expected_prefix="$4"

  local actual
  actual="$(decide_push_retry "${push_rc}" "${push_output}")"

  if [[ "${actual}" != ${expected_prefix}* ]]; then
    echo "FAIL: ${test_name}"
    echo "  push_rc:         '${push_rc}'"
    echo "  push_output:     '${push_output}'"
    echo "  expected prefix: '${expected_prefix}'"
    echo "  actual:          '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Push retry test cases ---

# Successful push → no retry needed
run_push_retry_test "push-success" \
  "0" "Everything up-to-date" "success"

# Non-fast-forward error → retry with --force-with-lease
run_push_retry_test "push-non-fast-forward" \
  "1" "error: failed to push some refs: non-fast-forward" "retry:force-with-lease"

# Rejected error → retry with --force-with-lease
run_push_retry_test "push-rejected" \
  "1" "! [rejected] agent/42 -> agent/42 (fetch first)" "retry:force-with-lease"

# Unknown error → fail
run_push_retry_test "push-unexpected-error" \
  "1" "fatal: repository not found" "fail:unexpected-error"

# ---------------------------------------------------------------------------
# Test helper — reimplements the agent artifact stripping logic from
# post-code.sh section 2b. Given a list of changed files, returns which
# files would be stripped as agent artifacts.
# ---------------------------------------------------------------------------
strip_agent_artifacts() {
  local changed_files="$1"
  local agent_artifact_patterns=".agentready/ .fullsend-workspace/"
  local stripped=""

  for file in ${changed_files}; do
    local is_artifact=false
    for pattern in ${agent_artifact_patterns}; do
      local dir="${pattern%/}"
      case "${file}" in
        "${dir}"/*|"${dir}") is_artifact=true; break ;;
        */"${dir}"/*|*/"${dir}") is_artifact=true; break ;;
      esac
    done
    if [ "${is_artifact}" = "true" ]; then
      stripped="${stripped} ${file}"
    fi
  done

  echo "${stripped}" | xargs
}

run_artifact_test() {
  local test_name="$1"
  local changed_files="$2"
  local expected_stripped="$3"

  local actual
  actual="$(strip_agent_artifacts "${changed_files}")"

  if [ "${actual}" != "${expected_stripped}" ]; then
    echo "FAIL: ${test_name}"
    echo "  changed_files:     '${changed_files}'"
    echo "  expected stripped: '${expected_stripped}'"
    echo "  actual stripped:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Agent artifact stripping test cases ---

# .agentready/ files should be stripped
run_artifact_test "strip-agentready-file" \
  ".agentready/assessment.json src/main.go" \
  ".agentready/assessment.json"

# .fullsend-workspace/ files should be stripped
run_artifact_test "strip-fullsend-workspace-file" \
  ".fullsend-workspace/scratch.txt src/main.go" \
  ".fullsend-workspace/scratch.txt"

# Nested paths should also be stripped
run_artifact_test "strip-nested-agentready" \
  "subdir/.agentready/data.json src/main.go" \
  "subdir/.agentready/data.json"

# Normal files should not be stripped
run_artifact_test "keep-normal-files" \
  "src/main.go internal/handler.go" \
  ""

# Multiple artifacts stripped together
run_artifact_test "strip-multiple-artifacts" \
  ".agentready/a.json .fullsend-workspace/b.txt src/main.go" \
  ".agentready/a.json .fullsend-workspace/b.txt"

# Empty input should produce no stripping
run_artifact_test "strip-empty-input" \
  "" \
  ""

# ---------------------------------------------------------------------------
# Test helper — reimplements the Signed-off-by trailer detection logic from
# post-code.sh section 3b. Given commit body text, returns whether the
# trailer was detected.
# ---------------------------------------------------------------------------
detect_signed_off_by() {
  local commit_body="$1"

  if echo "${commit_body}" | grep -q '^Signed-off-by:'; then
    echo "blocked:signed-off-by"
  else
    echo "pass"
  fi
}

run_signoff_test() {
  local test_name="$1"
  local commit_body="$2"
  local expected="$3"

  local actual
  actual="$(detect_signed_off_by "${commit_body}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  commit_body:  '${commit_body}'"
    echo "  expected:     '${expected}'"
    echo "  actual:       '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Signed-off-by detection test cases ---

# Commit with Signed-off-by trailer should be blocked
run_signoff_test "signoff-present-blocked" \
  "Fix widget rendering.

Signed-off-by: fullsend-ai-coder[bot] <123456+fullsend-ai-coder[bot]@users.noreply.github.com>" \
  "blocked:signed-off-by"

# Commit without Signed-off-by trailer should pass
run_signoff_test "signoff-absent-passes" \
  "Fix widget rendering.

Closes #42" \
  "pass"

# Empty commit body should pass
run_signoff_test "signoff-empty-body-passes" \
  "" \
  "pass"

# Signed-off-by mentioned mid-line (not a trailer) should pass
run_signoff_test "signoff-mid-line-passes" \
  "Removed the Signed-off-by: trailer from commits." \
  "pass"

# Multiple trailers including Signed-off-by should be blocked
run_signoff_test "signoff-among-other-trailers-blocked" \
  "Fix rendering bug.

Co-authored-by: someone <someone@example.com>
Signed-off-by: bot <bot@noreply.github.com>" \
  "blocked:signed-off-by"

# Variant casing should pass (detection is intentionally case-sensitive)
run_signoff_test "signoff-variant-casing-passes" \
  "Fix rendering bug.

signed-off-by: bot <bot@noreply.github.com>" \
  "pass"

# ---------------------------------------------------------------------------
# Test helper — reimplements the pre-commit auto-fix retry decision logic
# from post-code.sh section 5. Given a pre-commit exit code and whether
# unstaged changes exist, returns the action the script would take.
# ---------------------------------------------------------------------------
decide_precommit_retry() {
  local precommit_rc="$1"          # 0 = passed, 1 = failed
  local has_unstaged="$2"          # "yes" or "no"
  local retry_precommit_rc="$3"    # 0 = passed on retry, 1 = still fails (ignored if no retry)
  local retry_has_unstaged="${4:-no}"  # "yes" if retry left unstaged changes

  if [ "${precommit_rc}" -eq 0 ]; then
    echo "pass:clean"
    return 0
  fi

  # Pre-commit failed — check for auto-fixed files
  if [ "${has_unstaged}" = "yes" ]; then
    if [ "${retry_precommit_rc}" -eq 0 ]; then
      if [ "${retry_has_unstaged}" = "yes" ]; then
        echo "blocked:retry-left-unstaged"
      else
        echo "pass:auto-fixed"
      fi
    else
      echo "blocked:retry-failed"
    fi
  else
    echo "blocked:no-auto-fix"
  fi
}

run_precommit_retry_test() {
  local test_name="$1"
  local precommit_rc="$2"
  local has_unstaged="$3"
  local retry_precommit_rc="$4"
  local expected="$5"
  local retry_has_unstaged="${6:-no}"

  local actual
  actual="$(decide_precommit_retry "${precommit_rc}" "${has_unstaged}" "${retry_precommit_rc}" "${retry_has_unstaged}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  precommit_rc:         '${precommit_rc}'"
    echo "  has_unstaged:         '${has_unstaged}'"
    echo "  retry_precommit_rc:   '${retry_precommit_rc}'"
    echo "  retry_has_unstaged:   '${retry_has_unstaged}'"
    echo "  expected:             '${expected}'"
    echo "  actual:               '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Pre-commit auto-fix retry test cases ---

# Pre-commit passes on first run → no retry needed
run_precommit_retry_test "precommit-passes-first-run" \
  "0" "no" "0" "pass:clean"

# Pre-commit fails, hooks auto-fixed files, retry succeeds
run_precommit_retry_test "precommit-auto-fix-retry-succeeds" \
  "1" "yes" "0" "pass:auto-fixed"

# Pre-commit fails, hooks auto-fixed files, retry still fails
run_precommit_retry_test "precommit-auto-fix-retry-fails" \
  "1" "yes" "1" "blocked:retry-failed"

# Pre-commit fails, no unstaged changes (genuine failure)
run_precommit_retry_test "precommit-genuine-failure" \
  "1" "no" "0" "blocked:no-auto-fix"

# Pre-commit passes but unstaged changes exist (e.g. hook wrote a log file)
run_precommit_retry_test "precommit-passes-with-unstaged" \
  "0" "yes" "0" "pass:clean"

# Pre-commit fails, auto-fix retry passes, but retry left unstaged changes
run_precommit_retry_test "precommit-retry-passes-but-left-unstaged" \
  "1" "yes" "0" "blocked:retry-left-unstaged" "yes"

# ---------------------------------------------------------------------------
# Test helper — reimplements the FULLSEND_VALIDATED_ITERATION_DIR selection
# logic from post-code.src.sh's target-branch resolution. Given an env var
# value and a set of files on disk, returns which result file (if any) would
# be selected.
#
# Mirrors the three-branch logic: expected filename -> result.json fallback
# -> no silent rescan (degrades to empty, matching this script's existing
# soft-fallback-to-default-branch behavior rather than a hard failure).
# ---------------------------------------------------------------------------
resolve_code_result() {
  local validated_dir="$1"  # value of FULLSEND_VALIDATED_ITERATION_DIR ("" = unset)
  local run_dir="$2"        # directory containing iteration-*/output/

  if [ -n "${validated_dir}" ]; then
    if [ -f "${validated_dir}/code-result.json" ]; then
      echo "${validated_dir}/code-result.json"
    elif [ -f "${validated_dir}/result.json" ]; then
      echo "${validated_dir}/result.json"
    else
      echo ""
    fi
  else
    local result=""
    for dir in "${run_dir}"/iteration-*/output; do
      if [ -f "${dir}/code-result.json" ]; then
        result="${dir}/code-result.json"
      fi
    done
    echo "${result}"
  fi
}

RESOLVE_TMPDIR="$(mktemp -d)"

run_resolve_code_test() {
  local test_name="$1"
  local setup_fn="$2"
  local expected="$3"

  local run_dir="${RESOLVE_TMPDIR}/${test_name}"
  local validated_dir="${run_dir}/validated-output"
  mkdir -p "${run_dir}"

  ${setup_fn} "${run_dir}" "${validated_dir}"

  local actual
  actual="$(resolve_code_result "${validated_dir}" "${run_dir}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_resolve_code_test_unset() {
  local test_name="$1"
  local setup_fn="$2"
  local expected="$3"

  local run_dir="${RESOLVE_TMPDIR}/${test_name}"
  mkdir -p "${run_dir}"

  ${setup_fn} "${run_dir}" ""

  local actual
  actual="$(resolve_code_result "" "${run_dir}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Setup: validated dir has code-result.json
setup_code_expected() {
  local run_dir="$1"
  local validated_dir="$2"
  mkdir -p "${validated_dir}"
  echo '{}' > "${validated_dir}/code-result.json"
  # Also place a file in iteration-2 to verify it's NOT used.
  mkdir -p "${run_dir}/iteration-2/output"
  echo '{}' > "${run_dir}/iteration-2/output/code-result.json"
}

# Setup: validated dir has only result.json
setup_code_fallback() {
  local run_dir="$1"
  local validated_dir="$2"
  mkdir -p "${validated_dir}"
  echo '{}' > "${validated_dir}/result.json"
}

# Setup: validated dir has neither filename
setup_code_neither() {
  local run_dir="$1"
  local validated_dir="$2"
  mkdir -p "${validated_dir}"
}

# Setup: env var unset, iteration dirs present (backward compat)
setup_code_iteration_scan() {
  local run_dir="$1"
  mkdir -p "${run_dir}/iteration-1/output"
  mkdir -p "${run_dir}/iteration-2/output"
  echo '{}' > "${run_dir}/iteration-1/output/code-result.json"
  echo '{}' > "${run_dir}/iteration-2/output/code-result.json"
}

run_resolve_code_test "code-validated-dir-expected-filename" \
  setup_code_expected \
  "${RESOLVE_TMPDIR}/code-validated-dir-expected-filename/validated-output/code-result.json"

run_resolve_code_test "code-validated-dir-fallback-filename" \
  setup_code_fallback \
  "${RESOLVE_TMPDIR}/code-validated-dir-fallback-filename/validated-output/result.json"

run_resolve_code_test "code-validated-dir-neither-filename-degrades-to-empty" \
  setup_code_neither \
  ""

run_resolve_code_test_unset "code-unset-falls-back-to-scan" \
  setup_code_iteration_scan \
  "${RESOLVE_TMPDIR}/code-unset-falls-back-to-scan/iteration-2/output/code-result.json"

rm -rf "${RESOLVE_TMPDIR}"

# --- Summary ---

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
