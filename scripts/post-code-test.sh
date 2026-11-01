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

if ! grep -q 'forge_push_branch' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-signed-push"
  echo "  ${POST_SCRIPT} missing forge_push_branch"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-signed-push"
fi

# The Authored-by trailer the signed publish adds must not reach the PR body.
if ! grep -qF "sed '/^Authored-by:/d'" "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-strips-authored-by"
  echo "  ${POST_SCRIPT} does not drop Authored-by from the commit body"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-strips-authored-by"
fi

# The switch that keeps the publish on git push unless enabled.
if ! grep -q 'GITHUB_SIGNED_COMMITS' "${SCRIPT_DIR}/post-code.sh"; then
  echo "FAIL: bundled-script-has-signed-commits-switch"
  echo "  scripts/post-code.sh does not carry the GITHUB_SIGNED_COMMITS switch"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-signed-commits-switch"
fi

# harness/code.yaml ships GITHUB_SIGNED_COMMITS off, in its GitHub overlay
# only; the eval overlay the root config.yaml registers turns it on so the
# functional evals keep exercising the API path.
CODE_HARNESS="${SCRIPT_DIR}/../harness/code.yaml"
CODE_EVAL_HARNESS="${SCRIPT_DIR}/../eval/harness/code.yaml"
ROOT_CONFIG="${SCRIPT_DIR}/../config.yaml"
if [ "$(yq -r '[.overlays[] | select(.when == "runtime.forge == \"github\"") | .env.runner.GITHUB_SIGNED_COMMITS] | join(",")' "${CODE_HARNESS}")" = "false" ] \
   && [ "$(yq -r '[.env.runner.GITHUB_SIGNED_COMMITS, .env.sandbox.GITHUB_SIGNED_COMMITS, (.overlays[] | select(.when != "runtime.forge == \"github\"") | .env.runner.GITHUB_SIGNED_COMMITS, .env.sandbox.GITHUB_SIGNED_COMMITS)] | map(select(. != null)) | length' "${CODE_HARNESS}")" = "0" ]; then
  echo "PASS: code-harness-signed-commits-default-off"
else
  echo "FAIL: code-harness-signed-commits-default-off — GITHUB_SIGNED_COMMITS must be \"false\" in the GitHub overlay of harness/code.yaml and set nowhere else"
  FAILURES=$((FAILURES + 1))
fi
if yq -e '.base == "../../harness/code.yaml" and .env.runner.GITHUB_SIGNED_COMMITS == "true"' "${CODE_EVAL_HARNESS}" >/dev/null \
   && yq -e '.agents[] | select(.source == "eval/harness/code.yaml")' "${ROOT_CONFIG}" >/dev/null; then
  echo "PASS: eval-code-harness-signed-commits-on"
else
  echo "FAIL: eval-code-harness-signed-commits-on — eval/harness/code.yaml must extend harness/code.yaml with GITHUB_SIGNED_COMMITS \"true\" and be registered in config.yaml"
  FAILURES=$((FAILURES + 1))
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

if ! grep -q 'CODE_AUTO_MERGE' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-auto-merge"
  echo "  ${POST_SCRIPT} missing CODE_AUTO_MERGE"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-auto-merge"
fi

if ! grep -q 'forge_ensure_label' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-ensure-label"
  echo "  ${POST_SCRIPT} missing forge_ensure_label"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-ensure-label"
fi

# Lib-defined code is only inlined into the bundle: in bundled mode check the
# bundle (so a stale bundle is caught), in source mode check the lib itself.
if [[ "${SCRIPT_TEST_TARGET:-source}" == "bundled" ]]; then
  CODE_OPS_TARGET="${POST_SCRIPT}"
  FAILURE_LIB_TARGET="${POST_SCRIPT}"
else
  CODE_OPS_TARGET="${SCRIPT_DIR}/lib/github-code-ops.lib.sh"
  FAILURE_LIB_TARGET="${SCRIPT_DIR}/lib/post-failure-report.lib.sh"
fi

if ! grep -q 'forge_retry_transient gh pr create' "${CODE_OPS_TARGET}"; then
  echo "FAIL: create-pr-wrapped-in-transient-retry"
  echo "  ${CODE_OPS_TARGET} does not wrap gh pr create with forge_retry_transient"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: create-pr-wrapped-in-transient-retry"
fi

if ! grep -q 'code-agent-failed' "${FAILURE_LIB_TARGET}"; then
  echo "FAIL: post-failure-has-last-resort-label"
  echo "  ${FAILURE_LIB_TARGET} missing code-agent-failed last-resort label"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: post-failure-has-last-resort-label"
fi

# ---------------------------------------------------------------------------
# Test helper — reimplements the title-rewriting logic from post-code.sh
# so we can test it without a git repo or network access.
# ---------------------------------------------------------------------------
rewrite_title() {
  local commit_subject="$1"
  local issue_number="$2"
  local identity_mode="${3:-forge-native}"
  local inject_issue_scope="${4:-true}"

  if echo "${commit_subject}" | grep -qE '^[a-z]+\('; then
    echo "${commit_subject}"
  elif echo "${commit_subject}" | grep -qE '^[a-z]+: '; then
    if [ "${inject_issue_scope}" = "false" ]; then
      echo "${commit_subject}"
    elif [ "${identity_mode}" = "external" ]; then
      echo "${commit_subject}" | sed "s/^\([a-z]*\): /\1(${issue_number}): /"
    else
      echo "${commit_subject}" | sed "s/^\([a-z]*\): /\1(#${issue_number}): /"
    fi
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

actual_external_title="$(rewrite_title "fix: handle cross-forge work" "FSENDAI-4804" external)"
if [ "${actual_external_title}" != "fix(FSENDAI-4804): handle cross-forge work" ]; then
  echo "FAIL: external-tracker-title-uses-work-item-key"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: external-tracker-title-uses-work-item-key"
fi

# inject_issue_scope=false — leave a conventional-commit subject unchanged
actual_no_inject="$(rewrite_title "feat: add copy buttons" "2854" forge-native false)"
if [ "${actual_no_inject}" != "feat: add copy buttons" ]; then
  echo "FAIL: inject-issue-scope-false-skips-injection"
  echo "  expected: 'feat: add copy buttons'"
  echo "  actual:   '${actual_no_inject}'"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: inject-issue-scope-false-skips-injection"
fi

actual_no_inject_area="$(rewrite_title "feat(ui): add copy buttons" "2854" forge-native false)"
if [ "${actual_no_inject_area}" != "feat(ui): add copy buttons" ]; then
  echo "FAIL: inject-issue-scope-false-preserves-area-scope"
  echo "  expected: 'feat(ui): add copy buttons'"
  echo "  actual:   '${actual_no_inject_area}'"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: inject-issue-scope-false-preserves-area-scope"
fi

actual_no_inject_external="$(rewrite_title "fix: handle cross-forge work" "FSENDAI-4804" external false)"
if [ "${actual_no_inject_external}" != "fix: handle cross-forge work" ]; then
  echo "FAIL: inject-issue-scope-false-skips-external-injection"
  echo "  expected: 'fix: handle cross-forge work'"
  echo "  actual:   '${actual_no_inject_external}'"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: inject-issue-scope-false-skips-external-injection"
fi

# Default (unset / true) still injects — covered by fix-without-scope above.
# Reading the flag from agent-result.json mirrors post-code.src.sh.
resolve_inject_issue_scope() {
  local result_json="$1"
  local value
  value="$(printf '%s' "${result_json}" | jq -r '.inject_issue_scope')"
  if [ "${value}" = "false" ]; then
    echo "false"
  else
    echo "true"
  fi
}

if [ "$(resolve_inject_issue_scope '{"target_branch":"main"}')" != "true" ]; then
  echo "FAIL: inject-issue-scope-absent-defaults-true"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: inject-issue-scope-absent-defaults-true"
fi

if [ "$(resolve_inject_issue_scope '{"target_branch":"main","inject_issue_scope":true}')" != "true" ]; then
  echo "FAIL: inject-issue-scope-true-stays-true"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: inject-issue-scope-true-stays-true"
fi

if [ "$(resolve_inject_issue_scope '{"target_branch":"main","inject_issue_scope":false}')" != "false" ]; then
  echo "FAIL: inject-issue-scope-false-reads-false"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: inject-issue-scope-false-reads-false"
fi

# closes_issue is read the same way: jq `//` would turn JSON false into
# "empty", so a partial implementation's opt-out would be lost.
resolve_closes_issue() {
  local value
  value="$(printf '%s' "$1" | jq -r '.closes_issue')"
  if [ "${value}" = "false" ]; then echo "false"; else echo "true"; fi
}

if [ "$(resolve_closes_issue '{"target_branch":"main"}')" != "true" ]; then
  echo "FAIL: closes-issue-absent-defaults-true"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: closes-issue-absent-defaults-true"
fi

if [ "$(resolve_closes_issue '{"target_branch":"main","closes_issue":false}')" != "false" ]; then
  echo "FAIL: closes-issue-false-reads-false"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: closes-issue-false-reads-false"
fi

if grep -q "closes_issue // empty" "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-reads-closes-issue-without-jq-alternative"
  echo "  ${POST_SCRIPT} still parses closes_issue with jq //, which drops JSON false"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-reads-closes-issue-without-jq-alternative"
fi

if ! grep -q 'inject_issue_scope' "${POST_SCRIPT}"; then
  echo "FAIL: bundled-script-has-inject-issue-scope"
  echo "  ${POST_SCRIPT} missing inject_issue_scope"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: bundled-script-has-inject-issue-scope"
fi

SKILL_FILE="${SCRIPT_DIR}/../skills/code-implementation/SKILL.md"
if grep -q 'Always include the issue number as a scope' "${SKILL_FILE}"; then
  echo "FAIL: skill-no-longer-always-injects-issue-scope"
  echo "  ${SKILL_FILE} still always injects the issue number as scope"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: skill-no-longer-always-injects-issue-scope"
fi

if ! grep -q 'inject_issue_scope: false' "${SKILL_FILE}"; then
  echo "FAIL: skill-documents-inject-issue-scope-opt-out"
  echo "  ${SKILL_FILE} missing inject_issue_scope: false guidance"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: skill-documents-inject-issue-scope-opt-out"
fi

if ! grep -q 'A scope MUST consist of a noun' "${SKILL_FILE}" \
  || ! grep -q 'describing a section of the codebase' "${SKILL_FILE}"; then
  echo "FAIL: skill-quotes-cc-v1-item-4-scope"
  echo "  ${SKILL_FILE} missing Conventional Commits v1.0.0 item 4 quote"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: skill-quotes-cc-v1-item-4-scope"
fi

if ! grep -q 'fix(parser):' "${SKILL_FILE}" || ! grep -q 'feat(#1234):' "${SKILL_FILE}"; then
  echo "FAIL: skill-has-cc-scope-examples"
  echo "  ${SKILL_FILE} missing area-scope/ticket-scope examples"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: skill-has-cc-scope-examples"
fi

# ---------------------------------------------------------------------------
# Test helper — reimplements the multi-commit title selection logic from
# post-code.sh so we can test it without a git repo or network access.
#
# Given a list of commit subjects (one per line) and a commit count,
# returns which subject would be used for the PR title.
# ---------------------------------------------------------------------------
select_commit_subject() {
  local commit_subjects="$1"  # newline-separated, in chronological order
  # Production code always picks the first commit's subject: for single-
  # commit PRs it is the only one; for multi-commit PRs it is the primary
  # work (later commits are follow-ups like lint fixes).
  echo "${commit_subjects}" | head -1
}

run_commit_select_test() {
  local test_name="$1"
  local commit_subjects="$2"
  local commit_count="$3"
  local expected="$4"

  local actual
  actual="$(select_commit_subject "${commit_subjects}" "${commit_count}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  commit_count: ${commit_count}"
    echo "  expected:     '${expected}'"
    echo "  actual:       '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Single commit — uses the only commit's subject (existing behavior)
run_commit_select_test "single-commit-uses-only-subject" \
  "feat(#42): add primary feature" \
  "1" \
  "feat(#42): add primary feature"

# Multiple commits — uses the first commit's subject (primary work)
run_commit_select_test "multi-commit-uses-first-subject" \
  "feat(#42): add primary feature
fix(#42): suppress lint warning" \
  "2" \
  "feat(#42): add primary feature"

# Three commits — still uses the first commit's subject
run_commit_select_test "three-commits-uses-first-subject" \
  "feat(#42): add dispatch triage support
fix(#42): suppress SC2153 shellcheck warning
chore(#42): update test fixtures" \
  "3" \
  "feat(#42): add dispatch triage support"

# ---------------------------------------------------------------------------
# Integration test — exercises the multi-commit title selection using a real
# git repo to verify the git log --reverse pipeline produces the correct
# subject.
# ---------------------------------------------------------------------------
MC_TMPDIR="$(mktemp -d)"

MC_REAL_GIT="$(which git)"
_mc_repo="${MC_TMPDIR}/repo"
${MC_REAL_GIT} init -q -b main "${_mc_repo}"
${MC_REAL_GIT} -C "${_mc_repo}" config user.email "test@example.com"
${MC_REAL_GIT} -C "${_mc_repo}" config user.name "Test"
echo "init" > "${_mc_repo}/README.md"
${MC_REAL_GIT} -C "${_mc_repo}" add README.md
${MC_REAL_GIT} -C "${_mc_repo}" commit -q -m "init"

_mc_merge_base="$(${MC_REAL_GIT} -C "${_mc_repo}" rev-parse HEAD)"

${MC_REAL_GIT} -C "${_mc_repo}" checkout -q -b agent/42-test
echo "feature" > "${_mc_repo}/feature.txt"
${MC_REAL_GIT} -C "${_mc_repo}" add feature.txt
${MC_REAL_GIT} -C "${_mc_repo}" commit -q -m "feat(#42): add primary feature"
echo "fix" > "${_mc_repo}/fix.txt"
${MC_REAL_GIT} -C "${_mc_repo}" add fix.txt
${MC_REAL_GIT} -C "${_mc_repo}" commit -q -m "fix(#42): suppress lint warning"

# Reimplement the multi-commit title selection from post-code.src.sh
_mc_count="$(${MC_REAL_GIT} -C "${_mc_repo}" rev-list --count "${_mc_merge_base}..HEAD")"
if [ "${_mc_count}" -gt 1 ]; then
  _mc_subject="$(${MC_REAL_GIT} -C "${_mc_repo}" log --format='%s' --reverse "${_mc_merge_base}..HEAD" | head -1)"
else
  _mc_subject="$(${MC_REAL_GIT} -C "${_mc_repo}" log -1 --format='%s' HEAD)"
fi

if [ "${_mc_subject}" = "feat(#42): add primary feature" ]; then
  echo "PASS: multi-commit-git-integration-uses-first"
else
  echo "FAIL: multi-commit-git-integration-uses-first"
  echo "  commit_count: ${_mc_count}"
  echo "  expected:     'feat(#42): add primary feature'"
  echo "  actual:       '${_mc_subject}'"
  FAILURES=$((FAILURES + 1))
fi

# Single-commit case: rewind to one commit and verify
${MC_REAL_GIT} -C "${_mc_repo}" reset -q --hard HEAD~1
_mc_count_single="$(${MC_REAL_GIT} -C "${_mc_repo}" rev-list --count "${_mc_merge_base}..HEAD")"
if [ "${_mc_count_single}" -gt 1 ]; then
  _mc_subject_single="$(${MC_REAL_GIT} -C "${_mc_repo}" log --format='%s' --reverse "${_mc_merge_base}..HEAD" | head -1)"
else
  _mc_subject_single="$(${MC_REAL_GIT} -C "${_mc_repo}" log -1 --format='%s' HEAD)"
fi

if [ "${_mc_subject_single}" = "feat(#42): add primary feature" ]; then
  echo "PASS: single-commit-git-integration-uses-last"
else
  echo "FAIL: single-commit-git-integration-uses-last"
  echo "  commit_count: ${_mc_count_single}"
  echo "  expected:     'feat(#42): add primary feature'"
  echo "  actual:       '${_mc_subject_single}'"
  FAILURES=$((FAILURES + 1))
fi

rm -rf "${MC_TMPDIR}"

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
  local closes_issue="${7:-true}"  # optional: "true" or "false"
  local identity_mode="${8:-forge-native}"
  local issue_url="${9:-}"

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
          if (l == "" || l ~ /^[Cc]lose[sd]? (#|[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+#)[0-9]+$/ || l ~ /^[Ff]ix(e[sd])? (#|[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+#)[0-9]+$/ || l ~ /^[Rr]esolve[sd]? (#|[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+#)[0-9]+$/ || l ~ /^[Rr]elated to (#|[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+#)[0-9]+$/)
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
      if [ "${identity_mode}" = "external" ]; then
        description="Automated implementation for ${issue_number}."
      else
        description="Automated implementation for issue #${issue_number}."
      fi
    else
      description="${commit_body}"
    fi
  fi

  local issue_reference
  if [ "${identity_mode}" = "external" ]; then
    issue_reference="Related to ${issue_url}"
  elif [ "${closes_issue}" = "false" ]; then
    issue_reference="Related to #${issue_number}"
  else
    issue_reference="Closes #${issue_number}"
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

${issue_reference}

### Post-script verification

- [x] Branch is not main/master (\`${branch}\`)
- [x] Secret scan passed (gitleaks — \`${scan_range}\`)
${pr_body_scan_line}"
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

external_body="$(build_pr_body "" "FSENDAI-4804" "agent/FSENDAI-4804-fix" "abc123..def456" "" skipped true external "https://redhat.atlassian.net/browse/FSENDAI-4804")"
if ! grep -qF "Related to https://redhat.atlassian.net/browse/FSENDAI-4804" <<<"${external_body}" \
   || grep -qF "Closes #" <<<"${external_body}"; then
  echo "FAIL: external-tracker-body-links-work-item-without-forge-close"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: external-tracker-body-links-work-item-without-forge-close"
fi

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
# closes_issue=false test cases — partial implementations should use
# "Related to" instead of "Closes" in the PR body footer.
# ---------------------------------------------------------------------------
run_closes_issue_test() {
  local test_name="$1"
  local commit_body="$2"
  local issue_number="$3"
  local closes_issue="$4"
  local check_pattern="$5"
  local expect_present="$6"  # "yes" or "no"

  local actual
  actual="$(build_pr_body "${commit_body}" "${issue_number}" "agent/${issue_number}-fix" "abc123..def456" "" "skipped" "${closes_issue}")"

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

# Full implementation (default) — should use "Closes"
run_closes_issue_test "closes-issue-true-uses-closes" \
  "Fix the widget rendering." "42" "true" \
  "Closes #42" "yes"

# Full implementation — should NOT contain "Related to"
run_closes_issue_test "closes-issue-true-no-related-to" \
  "Fix the widget rendering." "42" "true" \
  "Related to #42" "no"

# Partial implementation — should use "Related to"
run_closes_issue_test "closes-issue-false-uses-related-to" \
  "Partial fix for the widget rendering." "42" "false" \
  "Related to #42" "yes"

# Partial implementation — should NOT contain "Closes"
run_closes_issue_test "closes-issue-false-no-closes" \
  "Partial fix for the widget rendering." "42" "false" \
  "Closes #42" "no"

# Default (omitted) — should use "Closes"
run_closes_issue_test_default() {
  local actual
  actual="$(build_pr_body "Fix rendering." "99" "agent/99-fix" "abc..def")"

  if ! echo "${actual}" | grep -qF "Closes #99"; then
    echo "FAIL: closes-issue-default-uses-closes"
    echo "  expected 'Closes #99' in body"
    echo "  in body:"
    echo "${actual}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: closes-issue-default-uses-closes"
}
run_closes_issue_test_default

# Partial implementation with pr_body from result — should use "Related to"
closes_issue_pr_body_test() {
  local actual
  actual="$(build_pr_body "" "42" "agent/42-fix" "abc..def" \
    $'## Summary\n\nPartial implementation.' "passed" "false")"

  if ! echo "${actual}" | grep -qF "Related to #42"; then
    echo "FAIL: closes-issue-false-with-pr-body"
    echo "  expected 'Related to #42' in body"
    echo "  in body:"
    echo "${actual}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi
  if echo "${actual}" | grep -qF "Closes #42"; then
    echo "FAIL: closes-issue-false-with-pr-body"
    echo "  expected NO 'Closes #42' in body"
    echo "  in body:"
    echo "${actual}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: closes-issue-false-with-pr-body"
}
closes_issue_pr_body_test

# ---------------------------------------------------------------------------
# Test: commit-body fallback with closes_issue=false and 'Related to #N'
# in commit body — verifies the resulting PR body contains exactly one
# 'Related to' reference (no duplication).
#
# Reimplements extract_commit_body without git, then feeds the result
# through build_pr_body to test the full pipeline.
# ---------------------------------------------------------------------------
count_related_to_commit_body_test() {
  local test_name="$1"
  local raw_commit_body="$2"
  local issue_number="$3"

  # Reimplement extract_commit_body without git (mirrors post-code.src.sh)
  local processed
  processed="$(printf '%s\n' "${raw_commit_body}" \
    | sed '/^Signed-off-by:/d' \
    | sed '/^Authored-by:/d' \
    | sed '/^Closes #/d' \
    | sed '/^Related to #/d' \
    | sed -e :a -e '/^\n*$/{ $d; N; ba; }')"
  processed="$(echo "${processed}" | awk '
    /^$/           { if (buf) print buf; print; buf=""; next }
    /^[-*#>]|^  /  { if (buf) print buf; buf=""; print; next }
    /^Closes /     { if (buf) print buf; buf=""; print; next }
    /^Related to / { if (buf) print buf; buf=""; print; next }
                   { buf = (buf ? buf " " $0 : $0) }
    END            { if (buf) print buf }
  ')"

  local actual
  actual="$(build_pr_body "${processed}" "${issue_number}" "agent/${issue_number}-fix" "abc123..def456" "" "skipped" "false")"

  local count
  count=$(echo "${actual}" | grep -c "Related to #${issue_number}" || true)

  if [ "${count}" -ne 1 ]; then
    echo "FAIL: ${test_name}"
    echo "  expected exactly 1 'Related to #${issue_number}', found ${count}"
    echo "  in body:"
    echo "${actual}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

count_related_to_commit_body_test "single-related-to-commit-body-fallback" \
  "Partial fix for widget rendering.

Related to #42" "42"

# Test: pr_body path with closes_issue=false and trailing 'Related to #N'
# footer — verifies the footer stripping awk removes it before the script
# appends its own, so the final PR body contains exactly one reference.
count_related_to_pr_body_test() {
  local test_name="$1"
  local pr_body="$2"
  local issue_number="$3"

  local actual
  actual="$(build_pr_body "" "${issue_number}" "agent/${issue_number}-fix" "abc123..def456" "${pr_body}" "passed" "false")"

  local count
  count=$(echo "${actual}" | grep -c "Related to #${issue_number}" || true)

  if [ "${count}" -ne 1 ]; then
    echo "FAIL: ${test_name}"
    echo "  expected exactly 1 'Related to #${issue_number}', found ${count}"
    echo "  in body:"
    echo "${actual}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

count_related_to_pr_body_test "single-related-to-pr-body-with-related-to" \
  "## Summary

Partial implementation.

Related to #42" "42"

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
# Test helper — reimplements uncommitted-work detection from post-code.src.sh
# so we can test porcelain filtering without a git repo.
# ---------------------------------------------------------------------------
AGENT_ARTIFACT_PATTERNS=".agentready/ .fullsend-workspace/"

is_agent_artifact_path() {
  local file="$1"
  local pattern dir
  for pattern in ${AGENT_ARTIFACT_PATTERNS}; do
    dir="${pattern%/}"
    case "${file}" in
      "${dir}"/*|"${dir}") return 0 ;;
      */"${dir}"/*|*/"${dir}") return 0 ;;
    esac
  done
  return 1
}

filter_uncommitted_work() {
  local porcelain="$1"
  if [ -z "${porcelain}" ]; then
    printf ''
    return 0
  fi

  local filtered="" line path
  while IFS= read -r line || [ -n "${line}" ]; do
    [ -z "${line}" ] && continue
    path="${line#???}"
    case "${path}" in
      *" -> "*) path="${path##* -> }" ;;
    esac
    path="${path#\"}"
    path="${path%\"}"
    if is_agent_artifact_path "${path}"; then
      continue
    fi
    if [ -n "${filtered}" ]; then
      filtered="${filtered}"$'\n'"${line}"
    else
      filtered="${line}"
    fi
  done <<< "${porcelain}"
  printf '%s' "${filtered}"
}

decide_uncommitted_work() {
  local branch="$1"
  local changed_files="$2"
  local porcelain="$3"

  local dirty
  dirty="$(filter_uncommitted_work "${porcelain}")"

  if [ -z "${branch}" ] || [ "${branch}" = "main" ] || [ "${branch}" = "master" ]; then
    if [ -n "${dirty}" ]; then
      echo "fail:uncommitted:${dirty}"
      return 1
    fi
    echo "noop:branch"
    return 0
  fi

  if [ -z "${changed_files}" ]; then
    if [ -n "${dirty}" ]; then
      echo "fail:uncommitted:${dirty}"
      return 1
    fi
    echo "noop:files"
    return 0
  fi

  echo "proceed"
  return 0
}

run_uncommitted_work_test() {
  local test_name="$1"
  local branch="$2"
  local changed_files="$3"
  local porcelain="$4"
  local expected_prefix="$5"
  local expect_rc="$6"

  local actual rc=0
  actual="$(decide_uncommitted_work "${branch}" "${changed_files}" "${porcelain}")" || rc=$?

  if [ "${rc}" -ne "${expect_rc}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected rc: ${expect_rc}"
    echo "  actual rc:   ${rc}"
    echo "  actual:      ${actual}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [[ "${actual}" != ${expected_prefix}* ]]; then
    echo "FAIL: ${test_name}"
    echo "  expected prefix: '${expected_prefix}'"
    echo "  actual:          '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Staged files on a feature branch with no commits → fail, not no-op
run_uncommitted_work_test "uncommitted-staged-on-feature-fails" \
  "agent/42-fix-widget" "" $'M  src/widget.go' \
  "fail:uncommitted" 1

# Untracked files on a feature branch with no commits → fail
run_uncommitted_work_test "uncommitted-untracked-on-feature-fails" \
  "agent/42-fix-widget" "" $'?? scripts/openshell_job.sh' \
  "fail:uncommitted" 1

# Staged files on main (no feature branch) → fail, not no-op
run_uncommitted_work_test "uncommitted-staged-on-main-fails" \
  "main" "" $'A  src/widget.go' \
  "fail:uncommitted" 1

# Clean tree on a feature branch with no commits → still a genuine no-op
run_uncommitted_work_test "clean-feature-branch-still-noop" \
  "agent/42-fix-widget" "" "" \
  "noop:files" 0

# Agent working-dir artifacts only → still a genuine no-op
run_uncommitted_work_test "agent-artifact-untracked-still-noop" \
  "agent/42-fix-widget" "" $'?? .agentready/scratch.txt' \
  "noop:files" 0

# Mixed real files + artifacts → fail and keep the real file in the listing
run_uncommitted_work_test "mixed-real-and-artifact-fails" \
  "agent/42-fix-widget" "" $'M  src/widget.go\n?? .fullsend-workspace/tmp' \
  "fail:uncommitted:M  src/widget.go" 1

# Renames in porcelain use "old -> new"; the destination must be checked
run_uncommitted_work_test "rename-to-real-file-fails" \
  "agent/42-fix-widget" "" $'R  old.go -> src/new.go' \
  "fail:uncommitted" 1

run_uncommitted_work_test "rename-to-artifact-still-noop" \
  "agent/42-fix-widget" "" $'R  scratch.txt -> .agentready/scratch.txt' \
  "noop:files" 0

# Feature branch WITH commits proceeds even if the tree is also dirty
run_uncommitted_work_test "committed-changes-proceed" \
  "agent/42-fix-widget" "src/widget.go" $' M src/widget.go' \
  "proceed" 0

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

# Signed-off-by trailer stripping is covered by scripts/signoff-strip-test.sh,
# which exercises the real rewrite (git filter-branch / git commit --amend)
# against real repositories: identity and date preservation, commit counts,
# authorship scoping, the folded-subject case, and the failure paths.

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
# Mirrors the two-branch logic: expected filename (agent-result.json)
# -> no silent rescan (degrades to empty, matching this script's existing
# soft-fallback-to-default-branch behavior rather than a hard failure).
# ---------------------------------------------------------------------------
resolve_code_result() {
  local validated_dir="$1"  # value of FULLSEND_VALIDATED_ITERATION_DIR ("" = unset)
  local run_dir="$2"        # directory containing iteration-*/output/

  if [ -n "${validated_dir}" ]; then
    if [ -f "${validated_dir}/agent-result.json" ]; then
      echo "${validated_dir}/agent-result.json"
    else
      echo ""
    fi
  else
    local result=""
    for dir in "${run_dir}"/iteration-*/output; do
      if [ -f "${dir}/agent-result.json" ]; then
        result="${dir}/agent-result.json"
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

# Setup: validated dir has agent-result.json
setup_code_expected() {
  local run_dir="$1"
  local validated_dir="$2"
  mkdir -p "${validated_dir}"
  echo '{}' > "${validated_dir}/agent-result.json"
  # Also place a file in iteration-2 to verify it's NOT used.
  mkdir -p "${run_dir}/iteration-2/output"
  echo '{}' > "${run_dir}/iteration-2/output/agent-result.json"
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
  echo '{}' > "${run_dir}/iteration-1/output/agent-result.json"
  echo '{}' > "${run_dir}/iteration-2/output/agent-result.json"
}

run_resolve_code_test "code-validated-dir-expected-filename" \
  setup_code_expected \
  "${RESOLVE_TMPDIR}/code-validated-dir-expected-filename/validated-output/agent-result.json"

run_resolve_code_test "code-validated-dir-neither-filename-degrades-to-empty" \
  setup_code_neither \
  ""

run_resolve_code_test_unset "code-unset-falls-back-to-scan" \
  setup_code_iteration_scan \
  "${RESOLVE_TMPDIR}/code-unset-falls-back-to-scan/iteration-2/output/agent-result.json"

rm -rf "${RESOLVE_TMPDIR}"

# ---------------------------------------------------------------------------
# Test helper — reimplements the no-op comment body construction from
# post-code.sh so we can test it without a GitHub API.
# ---------------------------------------------------------------------------
build_noop_comment() {
  local reason="$1"
  local issue_number="$2"
  local repo_full_name="$3"
  local agent_context="${4:-}"

  local detail_block=""
  if [ -n "${agent_context}" ]; then
    detail_block="

**Agent context:**
${agent_context}"
  fi

  cat <<EOF
ℹ️ **No PR created** — agent determined no changes needed

The code agent ran and evaluated issue #${issue_number}, but did not produce changes to submit as a pull request.

**Reason:** ${reason}
${detail_block}

**Workflow run:** https://github.com/${repo_full_name}/actions/runs/unknown

Retry with \`/fs-code\` if appropriate.
EOF
}

run_noop_comment_test() {
  local test_name="$1"
  local reason="$2"
  local issue_number="$3"
  local repo_full_name="$4"
  local check_pattern="$5"
  local expect_present="$6"  # "yes" or "no"
  local agent_context="${7:-}"

  local actual
  actual="$(build_noop_comment "${reason}" "${issue_number}" "${repo_full_name}" "${agent_context}")"

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

# ---------------------------------------------------------------------------
# Test helper — reimplements the branch validation logic from post-code.src.sh
# to test the auto-correct vs hard-fail behavior. Given an agent target, a
# default branch, and an optional allowed list, returns the decision.
# ---------------------------------------------------------------------------
validate_target_branch() {
  local agent_target="$1"
  local default_branch="$2"
  local allowed_list="$3"  # empty string means unset

  if [ -n "${agent_target}" ]; then
    if [ -n "${allowed_list}" ]; then
      # Explicit allowed list — hard-fail if not in it.
      if [ "${allowed_list}" = "*" ] \
         || echo ",${allowed_list}," | grep -qF ",${agent_target},"; then
        echo "accept:${agent_target}"
      else
        echo "reject:${agent_target}:allowed=${allowed_list}"
      fi
    else
      # No explicit list — auto-correct to default when mismatched.
      if [ "${agent_target}" = "${default_branch}" ]; then
        echo "accept:${agent_target}"
      else
        echo "auto-correct:${default_branch}"
      fi
    fi
  else
    echo "default:${default_branch}"
  fi
}

run_branch_validation_test() {
  local test_name="$1"
  local agent_target="$2"
  local default_branch="$3"
  local allowed_list="$4"
  local expected_prefix="$5"

  local actual
  actual="$(validate_target_branch "${agent_target}" "${default_branch}" "${allowed_list}")"

  if [[ "${actual}" != ${expected_prefix}* ]]; then
    echo "FAIL: ${test_name}"
    echo "  agent_target:    '${agent_target}'"
    echo "  default_branch:  '${default_branch}'"
    echo "  allowed_list:    '${allowed_list}'"
    echo "  expected prefix: '${expected_prefix}'"
    echo "  actual:          '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- No-op comment test cases ---

# Comment should include the reason for no feature branch
run_noop_comment_test "noop-comment-includes-branch-reason" \
  "Agent did not create a feature branch (current: 'main')" \
  "42" "my-org/my-repo" \
  "Agent did not create a feature branch" "yes"

# Comment should include the reason for no changed files
run_noop_comment_test "noop-comment-includes-files-reason" \
  "No changed files in agent's commit(s)" \
  "42" "my-org/my-repo" \
  "No changed files" "yes"

# Comment should include issue number
run_noop_comment_test "noop-comment-includes-issue-number" \
  "No changed files in agent's commit(s)" \
  "505" "my-org/my-repo" \
  "#505" "yes"

# Comment should include workflow run URL
run_noop_comment_test "noop-comment-includes-run-url" \
  "No changed files" \
  "42" "my-org/my-repo" \
  "my-org/my-repo/actions/runs/" "yes"

# Comment should include agent context when provided
run_noop_comment_test "noop-comment-includes-agent-context" \
  "No changed files" \
  "42" "my-org/my-repo" \
  "Issue is already fixed by recent commit abc123" "yes" \
  "Issue is already fixed by recent commit abc123"

# Comment should include "Agent context:" header when context provided
run_noop_comment_test "noop-comment-has-context-header" \
  "No changed files" \
  "42" "my-org/my-repo" \
  "Agent context:" "yes" \
  "The bug was already fixed."

# Comment should NOT include "Agent context:" section when none provided
run_noop_comment_test "noop-comment-no-context-when-empty" \
  "No changed files" \
  "42" "my-org/my-repo" \
  "Agent context:" "no"

# Comment should NOT contain PUSH_TOKEN reference
run_noop_comment_test "noop-comment-no-token-leak" \
  "No changed files" \
  "42" "my-org/my-repo" \
  "PUSH_TOKEN" "no"

# Comment should include retry instruction
run_noop_comment_test "noop-comment-includes-retry" \
  "No changed files" \
  "42" "my-org/my-repo" \
  "/fs-code" "yes"

# Comment for all-artifacts case should include the right reason
run_noop_comment_test "noop-comment-artifacts-reason" \
  "All changed files were agent artifacts — only working directory files were present" \
  "42" "my-org/my-repo" \
  "agent artifacts" "yes"

# Verify post_noop_comment is present in the post-code script
if ! grep -q 'post_noop_comment' "${POST_SCRIPT}"; then
  echo "FAIL: script-has-noop-comment"
  echo "  ${POST_SCRIPT} missing post_noop_comment"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: script-has-noop-comment"
fi

# Verify timeout-kill / uncommitted-work detection is present
if ! grep -q 'fail_if_uncommitted_work' "${POST_SCRIPT}"; then
  echo "FAIL: script-has-uncommitted-work-guard"
  echo "  ${POST_SCRIPT} missing fail_if_uncommitted_work"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: script-has-uncommitted-work-guard"
fi

if ! grep -q 'uncommitted-work' "${POST_SCRIPT}"; then
  echo "FAIL: script-has-uncommitted-work-category"
  echo "  ${POST_SCRIPT} missing uncommitted-work category"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: script-has-uncommitted-work-category"
fi

# --- Branch validation test cases ---

# Auto-correct: agent writes main, default is master, no allowed list → corrected
run_branch_validation_test "auto-correct-to-default" \
  "main" "master" "" "auto-correct:master"

# Explicit list enforced: agent writes main, allowed=release-1,release-2 → reject
run_branch_validation_test "explicit-list-rejects-mismatch" \
  "main" "master" "release-1,release-2" "reject:main"

# Match: agent matches default, no allowed list → accepted
run_branch_validation_test "agent-matches-default" \
  "main" "main" "" "accept:main"

# Wildcard: allowed=*, agent writes develop → accepted
run_branch_validation_test "wildcard-allows-any" \
  "develop" "main" "*" "accept:develop"

# No agent target: falls back to default
run_branch_validation_test "no-agent-target-uses-default" \
  "" "master" "" "default:master"

# Agent matches explicit list
run_branch_validation_test "explicit-list-accepts-match" \
  "release-1" "main" "release-1,release-2" "accept:release-1"

# Agent matches default with explicit list that also includes default
run_branch_validation_test "explicit-list-includes-default" \
  "main" "main" "main,develop" "accept:main"

# No agent target with explicit list still uses default.
run_branch_validation_test "no-agent-target-ignores-allowed-list" \
  "" "main" "release-1,release-2" "default:main"

# Substring mismatch: agent writes "release" but only "release-1","release-2"
# are allowed — comma-wrapping must reject the partial match.
run_branch_validation_test "substring-not-accepted" \
  "release" "main" "release-1,release-2" "reject:release"

# ---------------------------------------------------------------------------
# Branch-safety helpers under test come from the SAME lib the shipped script
# sources, so these cases exercise production logic rather than a copy.
# ---------------------------------------------------------------------------
# shellcheck source=lib/branch-guard.lib.sh
source "${SCRIPT_DIR}/lib/branch-guard.lib.sh"

run_namespace_test() {
  local test_name="$1"
  local branch="$2"
  local issue_number="$3"
  local expected="$4"

  local actual
  actual="$(enforce_branch_namespace "${branch}" "${issue_number}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  branch:    '${branch}'"
    echo "  issue:     '${issue_number}'"
    echo "  expected:  '${expected}'"
    echo "  actual:    '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Branch namespace enforcement test cases ---

# Already conforming branch name should be unchanged
run_namespace_test "namespace-already-conforming" \
  "agent/42-fix-widget" "42" "agent/42-fix-widget"

# Branch with wrong issue number gets rewritten
run_namespace_test "namespace-wrong-issue-number" \
  "agent/99-fix-widget" "42" "agent/42-99-fix-widget"

# Branch missing agent/ prefix gets rewritten
run_namespace_test "namespace-missing-prefix" \
  "fix-widget" "42" "agent/42-fix-widget"

# Arbitrary branch name gets namespaced
run_namespace_test "namespace-arbitrary-name" \
  "my-feature-branch" "123" "agent/123-my-feature-branch"

# Uppercase gets lowercased
run_namespace_test "namespace-uppercase" \
  "agent/42-Fix-Widget" "42" "agent/42-fix-widget"

# Branch name that is just the issue number gets fallback slug
run_namespace_test "namespace-just-issue-number" \
  "agent/42" "42" "agent/42-42"

# Colliding branch from different issue gets rewritten with this issue's number
run_namespace_test "namespace-cross-issue-collision" \
  "agent/99-add-feature" "42" "agent/42-99-add-feature"

# Special characters get stripped
run_namespace_test "namespace-special-chars" \
  "agent/42-fix_widget@v2" "42" "agent/42-fix-widget-v2"

# Bare issue number inside slug is NOT stripped (avoids mangling e.g. "42nd")
run_namespace_test "namespace-bare-number-preserved" \
  "agent/42-42nd-street-fix" "42" "agent/42-42nd-street-fix"

# Idempotency: enforcing an already-enforced name produces the same result
_idem_once="$(enforce_branch_namespace "agent/42-fix-widget" "42")"
_idem_twice="$(enforce_branch_namespace "${_idem_once}" "42")"
if [ "${_idem_once}" != "${_idem_twice}" ]; then
  echo "FAIL: namespace-idempotent"
  echo "  once:  '${_idem_once}'"
  echo "  twice: '${_idem_twice}'"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: namespace-idempotent"
fi

# Idempotency for long inputs (truncation with hash suffix)
_long_input="agent/42-$(printf 'a%.0s' {1..70})"
_long_once="$(enforce_branch_namespace "${_long_input}" "42")"
_long_twice="$(enforce_branch_namespace "${_long_once}" "42")"
if [ "${_long_once}" != "${_long_twice}" ]; then
  echo "FAIL: namespace-idempotent-long"
  echo "  once:  '${_long_once}'"
  echo "  twice: '${_long_twice}'"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: namespace-idempotent-long"
fi

# Two long branches with different suffixes must not collide
_col_a="agent/42-$(printf 'a%.0s' {1..70})-alpha"
_col_b="agent/42-$(printf 'a%.0s' {1..70})-beta"
_col_a_out="$(enforce_branch_namespace "${_col_a}" "42")"
_col_b_out="$(enforce_branch_namespace "${_col_b}" "42")"
if [ "${_col_a_out}" = "${_col_b_out}" ]; then
  echo "FAIL: namespace-no-collision"
  echo "  a: '${_col_a_out}'"
  echo "  b: '${_col_b_out}'"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: namespace-no-collision"
fi

# ---------------------------------------------------------------------------
# Thin wrapper over the shipped pr_body_refs_issue (from
# branch-guard.lib.sh), so these cases exercise production logic.
# ---------------------------------------------------------------------------
check_pr_issue_ref() {
  local pr_body="$1"
  local issue_number="$2"

  if pr_body_refs_issue "${pr_body}" "${issue_number}"; then
    echo "match"
  else
    echo "no-match"
  fi
}

run_pr_issue_ref_test() {
  local test_name="$1"
  local pr_body="$2"
  local issue_number="$3"
  local expected="$4"

  local actual
  actual="$(check_pr_issue_ref "${pr_body}" "${issue_number}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  issue:     '${issue_number}'"
    echo "  expected:  '${expected}'"
    echo "  actual:    '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Cross-issue PR detection test cases ---

run_pr_issue_ref_test "pr-ref-closes-match" \
  $'Fix rendering.\n\n---\n\nCloses #42' "42" "match"

run_pr_issue_ref_test "pr-ref-related-to-match" \
  $'Partial fix.\n\n---\n\nRelated to #42' "42" "match"

run_pr_issue_ref_test "pr-ref-fixes-match" \
  $'Fix rendering.\n\n---\n\nFixes #42' "42" "match"

run_pr_issue_ref_test "pr-ref-resolves-match" \
  $'Fix rendering.\n\n---\n\nResolves #42' "42" "match"

run_pr_issue_ref_test "pr-ref-different-issue" \
  $'Fix rendering.\n\n---\n\nCloses #99' "42" "no-match"

run_pr_issue_ref_test "pr-ref-no-footer" \
  "Fix rendering." "42" "no-match"

run_pr_issue_ref_test "pr-ref-substring-not-matched" \
  $'Fix rendering.\n\n---\n\nCloses #421' "42" "no-match"

# Trailing punctuation after issue number
run_pr_issue_ref_test "pr-ref-trailing-punctuation" \
  $'Fix rendering.\n\n---\n\nCloses #42.' "42" "match"

# Lowercase closing keyword (GitHub's own keywords are case-insensitive)
run_pr_issue_ref_test "pr-ref-lowercase" \
  $'Fix rendering.\n\n---\n\ncloses #42' "42" "match"

# CRLF body (web UI normalises to \r\n)
run_pr_issue_ref_test "pr-ref-crlf-body" \
  $'Fix rendering.\r\n\r\n---\r\n\r\nCloses #42\r\n' "42" "match"

# ---------------------------------------------------------------------------
# ISSUE_NUMBER numeric validation
# ---------------------------------------------------------------------------

run_numeric_validation_test() {
  local test_name="$1"
  local input="$2"
  local should_pass="$3"

  if [[ "${input}" =~ ^[1-9][0-9]*$ ]]; then
    if [ "${should_pass}" = "true" ]; then
      echo "PASS: ${test_name}"
    else
      echo "FAIL: ${test_name} — '${input}' should have been rejected"
      FAILURES=$((FAILURES + 1))
    fi
  else
    if [ "${should_pass}" = "false" ]; then
      echo "PASS: ${test_name}"
    else
      echo "FAIL: ${test_name} — '${input}' should have been accepted"
      FAILURES=$((FAILURES + 1))
    fi
  fi
}

run_numeric_validation_test "issue-number-valid" "42" "true"
run_numeric_validation_test "issue-number-large" "12345" "true"
run_numeric_validation_test "issue-number-regex-injection" ".*" "false"
run_numeric_validation_test "issue-number-alpha" "abc" "false"
run_numeric_validation_test "issue-number-zero" "0" "false"
run_numeric_validation_test "issue-number-leading-zero" "042" "false"
run_numeric_validation_test "issue-number-empty" "" "false"
run_numeric_validation_test "issue-number-negative" "-1" "false"
run_numeric_validation_test "issue-number-decimal" "1.5" "false"
run_numeric_validation_test "issue-number-shell-injection" "1;echo pwned" "false"

# ---------------------------------------------------------------------------
# Security integration tests — verify that security controls fail closed.
# These run the REAL post-code.sh against a minimal repo with mock binaries.
# ---------------------------------------------------------------------------

SEC_CODE_TMPDIR="$(mktemp -d)"
SEC_CODE_MOCK_BIN="${SEC_CODE_TMPDIR}/bin"
mkdir -p "${SEC_CODE_MOCK_BIN}"
# Git Data API calls from forge_push_branch are served from the bare remote.
export FAKE_GH_GIT_API="${SCRIPT_DIR}/test-fixtures/fake-gh-git-api.sh"

cat > "${SEC_CODE_MOCK_BIN}/sleep" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${SEC_CODE_MOCK_BIN}/sleep"

cat > "${SEC_CODE_MOCK_BIN}/gitleaks" <<'MOCKEOF'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then echo 8.30.1; exit 0; fi
exit 0
MOCKEOF
chmod +x "${SEC_CODE_MOCK_BIN}/gitleaks"

REAL_GIT="$(which git)"
cat > "${SEC_CODE_MOCK_BIN}/git" <<MOCKEOF
#!/usr/bin/env bash
if [[ "\$1" == "remote" && "\$2" == "set-url" ]]; then
  exit 0
fi
exec ${REAL_GIT} "\$@"
MOCKEOF
chmod +x "${SEC_CODE_MOCK_BIN}/git"

# Create a cloned repo with a feature branch and actual file changes.
# Usage: setup_sec_code_repo <run_dir> <branch_name>
setup_sec_code_repo() {
  local run_dir="$1"
  local branch_name="${2:-evil-branch}"
  local bare_dir="${run_dir}/remote.git"
  local repo_dir="${run_dir}/repo"

  ${REAL_GIT} init -q --bare -b main "${bare_dir}"
  ${REAL_GIT} clone -q "${bare_dir}" "${repo_dir}"
  ${REAL_GIT} -C "${repo_dir}" config user.email "test@example.com"
  ${REAL_GIT} -C "${repo_dir}" config user.name "Test"
  echo "init" > "${repo_dir}/README.md"
  ${REAL_GIT} -C "${repo_dir}" add README.md
  ${REAL_GIT} -C "${repo_dir}" commit -q -m "init"
  ${REAL_GIT} -C "${repo_dir}" push -q origin main

  ${REAL_GIT} -C "${repo_dir}" checkout -q -b "${branch_name}"
  echo "changed content" > "${repo_dir}/file.txt"
  ${REAL_GIT} -C "${repo_dir}" add -f file.txt
  ${REAL_GIT} -C "${repo_dir}" commit -q -m "fix: test change"
}

# --- Namespace enforcement: arbitrary branch is renamed to agent/<issue>-* ---
cat > "${SEC_CODE_MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api -X")      exec bash "${FAKE_GH_GIT_API}" "$@" ;;
  "api repos/"*) echo "main"; exit 0 ;;
  "pr list")     echo ""; exit 0 ;;
  "pr create")   echo "https://github.com/test-org/test-repo/pull/1"; exit 0 ;;
  "issue comment"|"pr comment") printf '%s\n' "$@"; exit 0 ;;
  *)             exit 0 ;;
esac
MOCKEOF
chmod +x "${SEC_CODE_MOCK_BIN}/gh"

_sec_ns_dir="${SEC_CODE_TMPDIR}/run-namespace"
setup_sec_code_repo "${_sec_ns_dir}" "evil-branch"

_sec_ns_rc=0
# shellcheck disable=SC2030
(
  cd "${_sec_ns_dir}"
  export HOME="${SEC_CODE_TMPDIR}"
  export PATH="${SEC_CODE_MOCK_BIN}:${PATH}"
  export PUSH_TOKEN="fake-token"
  export REPO_FULL_NAME="test-org/test-repo"
  export ISSUE_NUMBER="99"
  export REPO_DIR="repo"
  export FULLSEND_FORGE="github"
  export GITHUB_SIGNED_COMMITS="true"
  bash "${POST_SCRIPT}"
) > "${SEC_CODE_TMPDIR}/stdout-namespace.log" 2>&1 || _sec_ns_rc=$?

_sec_ns_safe="$(${REAL_GIT} -C "${_sec_ns_dir}/remote.git" branch --list "agent/99-evil-branch" 2>/dev/null)"
_sec_ns_evil="$(${REAL_GIT} -C "${_sec_ns_dir}/remote.git" branch --list "evil-branch" 2>/dev/null)"
# The fake API authors every commit it creates as the App bot, so the
# author of the remote tip proves the publish went through the API path.
_sec_ns_author="$(${REAL_GIT} -C "${_sec_ns_dir}/remote.git" log -1 --format=%an refs/heads/agent/99-evil-branch 2>/dev/null || true)"

if [ -n "${_sec_ns_safe}" ] && [ -z "${_sec_ns_evil}" ] && [ "${_sec_ns_author}" = "fullsend-ai-coder[bot]" ]; then
  echo "PASS: security-namespace-enforcement"
else
  echo "FAIL: security-namespace-enforcement"
  echo "  exit code:      ${_sec_ns_rc}"
  echo "  agent/99-*:     '${_sec_ns_safe}'"
  echo "  evil-branch:    '${_sec_ns_evil}'"
  echo "  tip author:     '${_sec_ns_author}' (want fullsend-ai-coder[bot])"
  echo "  remote refs:    $(${REAL_GIT} -C "${_sec_ns_dir}/remote.git" branch --list)"
  cat "${SEC_CODE_TMPDIR}/stdout-namespace.log"
  FAILURES=$((FAILURES + 1))
fi

# --- GITHUB_SIGNED_COMMITS off (the harness default): plain git push -----
# Any Git Data API call on this path fails the run.
cat > "${SEC_CODE_MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api -X")      echo "unexpected Git Data API call on the plain-push path: $*" >&2; exit 99 ;;
  "api repos/"*) echo "main"; exit 0 ;;
  "pr list")     echo ""; exit 0 ;;
  "pr create")   echo "https://github.com/test-org/test-repo/pull/1"; exit 0 ;;
  "issue comment"|"pr comment") printf '%s\n' "$@"; exit 0 ;;
  *)             exit 0 ;;
esac
MOCKEOF
chmod +x "${SEC_CODE_MOCK_BIN}/gh"

_sec_off_dir="${SEC_CODE_TMPDIR}/run-signed-commits-off"
setup_sec_code_repo "${_sec_off_dir}" "agent/99-test-fix"

_sec_off_rc=0
# shellcheck disable=SC2030,SC2031
(
  cd "${_sec_off_dir}"
  export HOME="${SEC_CODE_TMPDIR}"
  export PATH="${SEC_CODE_MOCK_BIN}:${PATH}"
  export PUSH_TOKEN="fake-token"
  export REPO_FULL_NAME="test-org/test-repo"
  export ISSUE_NUMBER="99"
  export REPO_DIR="repo"
  export FULLSEND_FORGE="github"
  export GITHUB_SIGNED_COMMITS="false"
  bash "${POST_SCRIPT}"
) > "${SEC_CODE_TMPDIR}/stdout-signed-commits-off.log" 2>&1 || _sec_off_rc=$?

# The remote tip is the sandbox commit itself, with its own author, not a
# commit rebuilt under the App bot.
_sec_off_remote="$(${REAL_GIT} -C "${_sec_off_dir}/remote.git" rev-parse --verify --quiet refs/heads/agent/99-test-fix || true)"
_sec_off_local="$(${REAL_GIT} -C "${_sec_off_dir}/repo" rev-parse HEAD)"
_sec_off_author="$(${REAL_GIT} -C "${_sec_off_dir}/remote.git" log -1 --format=%an refs/heads/agent/99-test-fix 2>/dev/null || true)"
if [ "${_sec_off_rc}" -eq 0 ] && [ -n "${_sec_off_remote}" ] && [ "${_sec_off_remote}" = "${_sec_off_local}" ] \
   && [ "${_sec_off_author}" = "Test" ]; then
  echo "PASS: signed-commits-off-plain-push"
else
  echo "FAIL: signed-commits-off-plain-push"
  echo "  exit code:  ${_sec_off_rc}"
  echo "  remote tip: '${_sec_off_remote}' local HEAD: '${_sec_off_local}'"
  echo "  tip author: '${_sec_off_author}' (want Test)"
  cat "${SEC_CODE_TMPDIR}/stdout-signed-commits-off.log"
  FAILURES=$((FAILURES + 1))
fi

# --- gh pr list API failure → fail closed (not delete branch and proceed) ---
cat > "${SEC_CODE_MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/"*) echo "main"; exit 0 ;;
  "pr list")     exit 1 ;;
  "issue comment"|"pr comment") printf '%s\n' "$@"; cat 2>/dev/null || true; exit 0 ;;
  *)             exit 0 ;;
esac
MOCKEOF
chmod +x "${SEC_CODE_MOCK_BIN}/gh"

_sec_api_dir="${SEC_CODE_TMPDIR}/run-api-failure"
setup_sec_code_repo "${_sec_api_dir}" "agent/99-test-fix"
${REAL_GIT} -C "${_sec_api_dir}/repo" push -q origin agent/99-test-fix

_sec_api_rc=0
# shellcheck disable=SC2030,SC2031
(
  cd "${_sec_api_dir}"
  export HOME="${SEC_CODE_TMPDIR}"
  export PATH="${SEC_CODE_MOCK_BIN}:${PATH}"
  export PUSH_TOKEN="fake-token"
  export REPO_FULL_NAME="test-org/test-repo"
  export ISSUE_NUMBER="99"
  export REPO_DIR="repo"
  export FULLSEND_FORGE="github"
  export GITHUB_SIGNED_COMMITS="true"
  bash "${POST_SCRIPT}"
) > "${SEC_CODE_TMPDIR}/stdout-api-failure.log" 2>&1 || _sec_api_rc=$?

if [ "${_sec_api_rc}" -eq 0 ]; then
  echo "FAIL: security-api-failure-pr-list-fails-closed — expected non-zero exit"
  cat "${SEC_CODE_TMPDIR}/stdout-api-failure.log"
  FAILURES=$((FAILURES + 1))
elif grep -q "Could not query" "${SEC_CODE_TMPDIR}/stdout-api-failure.log"; then
  echo "PASS: security-api-failure-pr-list-fails-closed (expected failure, got exit ${_sec_api_rc})"
else
  echo "FAIL: security-api-failure-pr-list-fails-closed — rejected but wrong reason"
  cat "${SEC_CODE_TMPDIR}/stdout-api-failure.log"
  FAILURES=$((FAILURES + 1))
fi

# --- Timeout-kill: staged files, no commit → fail (not Success / no-op) ---
cat > "${SEC_CODE_MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/"*) echo "main"; exit 0 ;;
  "pr list")     echo ""; exit 0 ;;
  "issue comment"|"pr comment")
    printf '%s\n' "$@"
    cat 2>/dev/null || true
    exit 0 ;;
  *)             exit 0 ;;
esac
MOCKEOF
chmod +x "${SEC_CODE_MOCK_BIN}/gh"

_sec_kill_dir="${SEC_CODE_TMPDIR}/run-killed-before-commit"
setup_sec_code_repo "${_sec_kill_dir}" "agent/99-timeout-kill"
# Drop the committed change and leave it staged instead — the timeout-kill
# fingerprint from #1256 (git add, then killed before git commit).
${REAL_GIT} -C "${_sec_kill_dir}/repo" reset --soft HEAD~1

_sec_kill_rc=0
# shellcheck disable=SC2030,SC2031
(
  cd "${_sec_kill_dir}"
  export HOME="${SEC_CODE_TMPDIR}"
  export PATH="${SEC_CODE_MOCK_BIN}:${PATH}"
  export PUSH_TOKEN="fake-token"
  export REPO_FULL_NAME="test-org/test-repo"
  export ISSUE_NUMBER="99"
  export REPO_DIR="repo"
  export FULLSEND_FORGE="github"
  export GITHUB_SIGNED_COMMITS="true"
  bash "${POST_SCRIPT}"
) > "${SEC_CODE_TMPDIR}/stdout-killed.log" 2>&1 || _sec_kill_rc=$?

_sec_kill_log="${SEC_CODE_TMPDIR}/stdout-killed.log"
if [ "${_sec_kill_rc}" -eq 0 ]; then
  echo "FAIL: killed-before-commit-staged-exits-nonzero — expected non-zero exit"
  cat "${_sec_kill_log}"
  FAILURES=$((FAILURES + 1))
elif ! grep -q "killed before committing" "${_sec_kill_log}"; then
  echo "FAIL: killed-before-commit-staged-exits-nonzero — missing failure heading"
  cat "${_sec_kill_log}"
  FAILURES=$((FAILURES + 1))
elif grep -q "agent determined no changes needed" "${_sec_kill_log}"; then
  echo "FAIL: killed-before-commit-staged-exits-nonzero — posted no-op comment"
  cat "${_sec_kill_log}"
  FAILURES=$((FAILURES + 1))
elif ! grep -q "file.txt" "${_sec_kill_log}"; then
  echo "FAIL: killed-before-commit-staged-exits-nonzero — staged file not listed"
  cat "${_sec_kill_log}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: killed-before-commit-staged-exits-nonzero (exit ${_sec_kill_rc})"
fi

# --- Genuine no-op: feature branch, no commits, clean tree → exit 0 ---
_sec_noop_dir="${SEC_CODE_TMPDIR}/run-genuine-noop"
setup_sec_code_repo "${_sec_noop_dir}" "agent/99-already-fixed"
${REAL_GIT} -C "${_sec_noop_dir}/repo" reset --hard HEAD~1

_sec_noop_rc=0
# shellcheck disable=SC2030,SC2031
(
  cd "${_sec_noop_dir}"
  export HOME="${SEC_CODE_TMPDIR}"
  export PATH="${SEC_CODE_MOCK_BIN}:${PATH}"
  export PUSH_TOKEN="fake-token"
  export REPO_FULL_NAME="test-org/test-repo"
  export ISSUE_NUMBER="99"
  export REPO_DIR="repo"
  export FULLSEND_FORGE="github"
  export GITHUB_SIGNED_COMMITS="true"
  bash "${POST_SCRIPT}"
) > "${SEC_CODE_TMPDIR}/stdout-genuine-noop.log" 2>&1 || _sec_noop_rc=$?

_sec_noop_log="${SEC_CODE_TMPDIR}/stdout-genuine-noop.log"
if [ "${_sec_noop_rc}" -ne 0 ]; then
  echo "FAIL: genuine-noop-clean-tree-exits-zero — expected exit 0, got ${_sec_noop_rc}"
  cat "${_sec_noop_log}"
  FAILURES=$((FAILURES + 1))
elif ! grep -q "agent determined no changes needed" "${_sec_noop_log}"; then
  echo "FAIL: genuine-noop-clean-tree-exits-zero — missing no-op comment"
  cat "${_sec_noop_log}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: genuine-noop-clean-tree-exits-zero"
fi

# --- git status failure: swallowed error must not look like a clean tree ---
# Regression for the false "Success"/no-op this PR closes: if `git status`
# itself fails, the script must fail closed, not report a genuine no-op.
cat > "${SEC_CODE_MOCK_BIN}/git" <<MOCKEOF
#!/usr/bin/env bash
# Skip leading "-c NAME=VALUE" pairs (uncommitted_work_status pins trusted
# git config ahead of the subcommand) before matching on the subcommand.
_args=("\$@")
_i=0
while [[ "\${_args[\$_i]:-}" == "-c" ]]; do
  _i=\$((_i + 2))
done
if [[ "\${_args[\$_i]:-}" == "status" ]]; then
  echo "fatal: index file smaller than expected" >&2
  exit 128
fi
if [[ "\${_args[\$_i]:-}" == "remote" && "\${_args[\$((_i + 1))]:-}" == "set-url" ]]; then
  exit 0
fi
exec ${REAL_GIT} "\$@"
MOCKEOF
chmod +x "${SEC_CODE_MOCK_BIN}/git"

_sec_gitstatus_dir="${SEC_CODE_TMPDIR}/run-git-status-fails"
setup_sec_code_repo "${_sec_gitstatus_dir}" "agent/99-status-fails"
${REAL_GIT} -C "${_sec_gitstatus_dir}/repo" reset --hard HEAD~1

_sec_gitstatus_rc=0
# shellcheck disable=SC2030,SC2031
(
  cd "${_sec_gitstatus_dir}"
  export HOME="${SEC_CODE_TMPDIR}"
  export PATH="${SEC_CODE_MOCK_BIN}:${PATH}"
  export PUSH_TOKEN="fake-token"
  export REPO_FULL_NAME="test-org/test-repo"
  export ISSUE_NUMBER="99"
  export REPO_DIR="repo"
  export FULLSEND_FORGE="github"
  export GITHUB_SIGNED_COMMITS="true"
  bash "${POST_SCRIPT}"
) > "${SEC_CODE_TMPDIR}/stdout-git-status-fails.log" 2>&1 || _sec_gitstatus_rc=$?

_sec_gitstatus_log="${SEC_CODE_TMPDIR}/stdout-git-status-fails.log"
if [ "${_sec_gitstatus_rc}" -eq 0 ]; then
  echo "FAIL: git-status-failure-exits-nonzero — expected non-zero exit"
  cat "${_sec_gitstatus_log}"
  FAILURES=$((FAILURES + 1))
elif grep -q "agent determined no changes needed" "${_sec_gitstatus_log}"; then
  echo "FAIL: git-status-failure-exits-nonzero — posted no-op comment despite git status failure"
  cat "${_sec_gitstatus_log}"
  FAILURES=$((FAILURES + 1))
elif ! grep -qi "git status failed" "${_sec_gitstatus_log}"; then
  echo "FAIL: git-status-failure-exits-nonzero — missing git-status-failure diagnostic"
  cat "${_sec_gitstatus_log}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: git-status-failure-exits-nonzero (exit ${_sec_gitstatus_rc})"
fi

# ---------------------------------------------------------------------------
# Push retry (post-code.sh §7b) against the real script.
#
# GITHUB_SIGNED_COMMITS=false so forge_push_branch is git push. A git
# wrapper supplies the first-push failure text so each wording of the
# production grep is hit; the retry is the real `git push --force-with-lease`.
# ---------------------------------------------------------------------------
run_code_push_retry_test() {
  local test_name="$1"
  local first_push_fail="${2:-}"
  local expect_retry="$3"
  local expect_exit="$4"

  local run_dir="${SEC_CODE_TMPDIR}/run-${test_name}"
  setup_sec_code_repo "${run_dir}" "agent/99-push-retry"
  local mock_bin="${run_dir}/mock-bin"
  local push_log="${run_dir}/push-calls.log"
  mkdir -p "${mock_bin}"
  : > "${push_log}"
  # gitleaks-install prepends the directory it found gitleaks in to PATH.
  # Keep gitleaks in this same mock-bin as the git wrapper so that prepend
  # cannot resurrect SEC_CODE_MOCK_BIN/git (which execs the real git).
  cp "${SEC_CODE_MOCK_BIN}/gitleaks" "${SEC_CODE_MOCK_BIN}/sleep" "${mock_bin}/"

  cat > "${mock_bin}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api -X")      echo "unexpected Git Data API call on the plain-push path: $*" >&2; exit 99 ;;
  "api repos/"*) echo "main"; exit 0 ;;
  "pr list")     echo ""; exit 0 ;;
  "pr create")   echo "https://github.com/test-org/test-repo/pull/1"; exit 0 ;;
  "pr view")     echo "https://github.com/test-org/test-repo/pull/1"; exit 0 ;;
  "issue comment"|"pr comment")
    printf '%s\n' "$@"
    cat 2>/dev/null || true
    exit 0 ;;
  *)             exit 0 ;;
esac
MOCKEOF
  chmod +x "${mock_bin}/gh"

  cat > "${mock_bin}/git" <<MOCKEOF
#!/usr/bin/env bash
if [[ "\$1" == "remote" && "\$2" == "set-url" ]]; then
  exit 0
fi
if [[ "\$1" == "push" ]]; then
  printf 'git %s\n' "\$*" >> "${push_log}"
  _force=false
  for _a in "\$@"; do
    if [[ "\$_a" == "--force-with-lease" ]]; then
      _force=true
    fi
  done
  if [[ "\${_force}" == true ]]; then
    exec ${REAL_GIT} "\$@"
  fi
  if [[ -n "\${MOCK_PUSH_FAIL:-}" ]]; then
    echo "\${MOCK_PUSH_FAIL}" >&2
    exit 1
  fi
  exec ${REAL_GIT} "\$@"
fi
exec ${REAL_GIT} "\$@"
MOCKEOF
  chmod +x "${mock_bin}/git"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export HOME="${SEC_CODE_TMPDIR}"
    export PATH="${mock_bin}:${PATH}"
    export PUSH_TOKEN="fake-token"
    export REPO_FULL_NAME="test-org/test-repo"
    export ISSUE_NUMBER="99"
    export REPO_DIR="repo"
    export FULLSEND_FORGE="github"
    export GITHUB_SIGNED_COMMITS="false"
    if [[ -n "${first_push_fail}" ]]; then
      export MOCK_PUSH_FAIL="${first_push_fail}"
    else
      unset MOCK_PUSH_FAIL
    fi
    bash "${POST_SCRIPT}"
  ) > "${SEC_CODE_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  local log="${SEC_CODE_TMPDIR}/stdout-${test_name}.log"
  local retried=false
  if [[ -s "${push_log}" ]] && grep -q -- '--force-with-lease' "${push_log}"; then
    retried=true
  fi

  if [[ "${exit_code}" -ne "${expect_exit}" ]]; then
    echo "FAIL: ${test_name} — exit ${exit_code}, want ${expect_exit}"
    cat "${log}"
    echo "push calls:"; cat "${push_log}" 2>/dev/null || true
    FAILURES=$((FAILURES + 1))
    return
  fi

  # The script must have attempted a plain push first (a line without
  # --force-with-lease); otherwise these tests could pass without any push.
  local plain_push_line force_push_line
  plain_push_line="$(grep -n -- '^git push' "${push_log}" \
    | grep -v -e '--force-with-lease' -e '--delete' \
    | head -n1 | cut -d: -f1 || true)"
  force_push_line="$(grep -n -- '--force-with-lease' "${push_log}" \
    | head -n1 | cut -d: -f1 || true)"
  if [[ -z "${plain_push_line}" ]]; then
    echo "FAIL: ${test_name} — expected a plain git push in the push log"
    cat "${log}"
    echo "push calls:"; cat "${push_log}" 2>/dev/null || true
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [[ "${expect_retry}" == "true" ]] \
    && [[ -n "${force_push_line}" ]] \
    && (( plain_push_line >= force_push_line )); then
    echo "FAIL: ${test_name} — plain git push must precede --force-with-lease retry"
    cat "${log}"
    echo "push calls:"; cat "${push_log}" 2>/dev/null || true
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ "${expect_retry}" == "true" ]]; then
    if [[ "${retried}" != true ]]; then
      echo "FAIL: ${test_name} — expected --force-with-lease retry"
      cat "${log}"
      echo "push calls:"; cat "${push_log}" 2>/dev/null || true
      FAILURES=$((FAILURES + 1))
      return
    fi
    if ! grep -qF "retrying with --force-with-lease" "${log}"; then
      echo "FAIL: ${test_name} — missing retry warning"
      cat "${log}"
      FAILURES=$((FAILURES + 1))
      return
    fi
  else
    if [[ "${retried}" == true ]]; then
      echo "FAIL: ${test_name} — unexpected --force-with-lease"
      cat "${log}"
      echo "push calls:"; cat "${push_log}"
      FAILURES=$((FAILURES + 1))
      return
    fi
    if grep -qF "retrying with --force-with-lease" "${log}"; then
      echo "FAIL: ${test_name} — unexpected retry warning"
      cat "${log}"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

run_code_push_retry_test "push-success" \
  "" "false" 0
run_code_push_retry_test "push-non-fast-forward" \
  "error: failed to push some refs: non-fast-forward" "true" 0
run_code_push_retry_test "push-rejected" \
  "! [rejected] agent/42 -> agent/42 (fetch first)" "true" 0
run_code_push_retry_test "push-api-not-a-fast-forward" \
  "gh: Update is not a fast forward (HTTP 422)" "true" 0
run_code_push_retry_test "push-unexpected-error" \
  "fatal: repository not found" "false" 1

rm -rf "${SEC_CODE_TMPDIR}"

# ---------------------------------------------------------------------------
# Test helper — reimplements the auto-merge decision logic from post-code.sh
# section 9. Given the CODE_AUTO_MERGE env var value, returns the action.
# ---------------------------------------------------------------------------
decide_auto_merge() {
  local code_auto_merge="$1"

  if [ "${code_auto_merge}" = "true" ]; then
    echo "enable"
  else
    echo "skip"
  fi
}

run_auto_merge_test() {
  local test_name="$1"
  local code_auto_merge="$2"
  local expected="$3"

  local actual
  actual="$(decide_auto_merge "${code_auto_merge}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  code_auto_merge: '${code_auto_merge}'"
    echo "  expected:        '${expected}'"
    echo "  actual:          '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Auto-merge test cases ---

# CODE_AUTO_MERGE=true → enable auto-merge
run_auto_merge_test "auto-merge-enabled" \
  "true" "enable"

# CODE_AUTO_MERGE unset/empty → skip
run_auto_merge_test "auto-merge-unset" \
  "" "skip"

# CODE_AUTO_MERGE=false → skip (only "true" enables)
run_auto_merge_test "auto-merge-false" \
  "false" "skip"

# CODE_AUTO_MERGE=TRUE → skip (case-sensitive)
run_auto_merge_test "auto-merge-uppercase" \
  "TRUE" "skip"

# CODE_AUTO_MERGE=1 → skip (only exact "true" match)
run_auto_merge_test "auto-merge-numeric" \
  "1" "skip"

# ---------------------------------------------------------------------------
# Test helper — reimplements the merge method flag resolution from the
# enable_auto_merge function's case statement. Given a CODE_AUTO_MERGE_METHOD
# value, returns the flag (and "WARN" prefix for unknown values).
# ---------------------------------------------------------------------------
resolve_merge_method_flag() {
  local method="${1:-}"
  case "${method}" in
    squash) echo "--squash" ;;
    rebase) echo "--rebase" ;;
    merge|"") echo "--merge"  ;;
    *)      echo "WARN:--merge"  ;;
  esac
}

run_merge_method_test() {
  local test_name="$1"
  local method="$2"
  local expected="$3"

  local actual
  actual="$(resolve_merge_method_flag "${method}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  method:   '${method}'"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Merge method test cases ---

run_merge_method_test "merge-method-squash" \
  "squash" "--squash"

run_merge_method_test "merge-method-merge" \
  "merge" "--merge"

run_merge_method_test "merge-method-rebase" \
  "rebase" "--rebase"

run_merge_method_test "merge-method-default" \
  "" "--merge"

run_merge_method_test "merge-method-unknown" \
  "fast-forward" "WARN:--merge"

# ---------------------------------------------------------------------------
# Test helper — reimplements the auto-detect priority logic from
# enable_auto_merge: squash > merge > rebase, fallback to merge.
# ---------------------------------------------------------------------------
resolve_auto_detect_method() {
  local allow_squash="$1"
  local allow_merge="$2"
  local allow_rebase="$3"

  if [ "${allow_squash}" = "true" ]; then echo "squash"
  elif [ "${allow_merge}" = "true" ]; then echo "merge"
  elif [ "${allow_rebase}" = "true" ]; then echo "rebase"
  else echo "merge"
  fi
}

run_auto_detect_test() {
  local test_name="$1"
  local allow_squash="$2"
  local allow_merge="$3"
  local allow_rebase="$4"
  local expected="$5"

  local actual
  actual="$(resolve_auto_detect_method "${allow_squash}" "${allow_merge}" "${allow_rebase}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  squash=${allow_squash} merge=${allow_merge} rebase=${allow_rebase}"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Auto-detect priority test cases ---

run_auto_detect_test "auto-detect-all-enabled" \
  "true" "true" "true" "squash"

run_auto_detect_test "auto-detect-merge-and-rebase" \
  "false" "true" "true" "merge"

run_auto_detect_test "auto-detect-rebase-only" \
  "false" "false" "true" "rebase"

run_auto_detect_test "auto-detect-none-enabled" \
  "false" "false" "false" "merge"

run_auto_detect_test "auto-detect-squash-only" \
  "true" "false" "false" "squash"

# ===========================================================================
# GitLab forge tests — validate URL handling, token sanitization, and
# push auth patterns added by the multi-forge code agent work.
# ===========================================================================

# ---------------------------------------------------------------------------
# Test helper — wraps the shared _validate_gitlab_host to exercise the same
# code path as gitlab-code-ops.lib.sh forge_validate_issue_url.
# ---------------------------------------------------------------------------
source "${SCRIPT_DIR}/lib/gitlab-host-validation.lib.sh"

validate_gitlab_issue_url() {
  local url="$1"
  if [[ ! "${url}" =~ ^https://[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+/-/issues/[0-9]+$ ]]; then
    echo "invalid:pattern"
    return 0
  fi
  local host
  host=$(echo "${url}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  local err
  if err=$(_validate_gitlab_host "${host}" 2>&1); then
    echo "valid"
  else
    case "${err}" in
      *"CI_SERVER_HOST is not set"*) echo "invalid:no-trust-source" ;;
      *"CI_SERVER_HOST contains invalid"*) echo "invalid:ci-server-host-chars" ;;
      *"does not match CI_SERVER_HOST"*) echo "invalid:host:${host}" ;;
      *) echo "invalid:unknown" ;;
    esac
  fi
}

run_gitlab_url_test() {
  local test_name="$1"
  local url="$2"
  local expected_prefix="$3"

  local actual
  actual="$(validate_gitlab_issue_url "${url}")"

  if [[ "${actual}" != ${expected_prefix}* ]]; then
    echo "FAIL: ${test_name}"
    echo "  url:             '${url}'"
    echo "  expected prefix: '${expected_prefix}'"
    echo "  actual:          '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- GitLab URL validation test cases ---

CI_SERVER_HOST="gitlab.com" \
run_gitlab_url_test "gitlab-url-valid-gitlab-com" \
  "https://gitlab.com/group/project/-/issues/42" "valid"

CI_SERVER_HOST="gitlab.cee.redhat.com" \
run_gitlab_url_test "gitlab-url-valid-redhat" \
  "https://gitlab.cee.redhat.com/gallen/integration-service/-/issues/1" "valid"

CI_SERVER_HOST="gitlab.com" \
run_gitlab_url_test "gitlab-url-valid-nested-group" \
  "https://gitlab.com/org/sub-group/project/-/issues/99" "valid"

run_gitlab_url_test "gitlab-url-invalid-no-dash-segment" \
  "https://gitlab.com/group/project/issues/42" "invalid:pattern"

run_gitlab_url_test "gitlab-url-invalid-github-url" \
  "https://github.com/owner/repo/issues/42" "invalid:pattern"

CI_SERVER_HOST="gitlab.com" \
run_gitlab_url_test "gitlab-url-invalid-unknown-host" \
  "https://git.example.com/group/project/-/issues/42" "invalid:host"

run_gitlab_url_test "gitlab-url-invalid-http-scheme" \
  "http://gitlab.com/group/project/-/issues/42" "invalid:pattern"

run_gitlab_url_test "gitlab-url-invalid-non-numeric-issue" \
  "https://gitlab.com/group/project/-/issues/abc" "invalid:pattern"

run_gitlab_url_test "gitlab-url-invalid-mr-not-issue" \
  "https://gitlab.com/group/project/-/merge_requests/42" "invalid:pattern"

CI_SERVER_HOST="" \
run_gitlab_url_test "gitlab-url-no-trust-source" \
  "https://gitlab.com/group/project/-/issues/42" "invalid:no-trust-source"

CI_SERVER_HOST="evil host" \
run_gitlab_url_test "gitlab-url-ci-server-host-invalid-chars" \
  "https://gitlab.com/group/project/-/issues/42" "invalid:ci-server-host-chars"

# ---------------------------------------------------------------------------
# Test helper — reimplements the GitLab issue URL parsing from
# gitlab-code-ops.lib.sh forge_parse_issue_url.
# ---------------------------------------------------------------------------
parse_gitlab_issue_url() {
  local url="$1"
  local host repo_full issue_number repo_encoded
  host=$(echo "${url}" | sed -E 's|^https://([^/:]+)/.*|\1|')
  repo_full=$(echo "${url}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
  issue_number=$(basename "${url}")
  repo_encoded=$(printf '%s' "${repo_full}" | jq -sRr @uri)
  echo "host=${host} repo=${repo_full} encoded=${repo_encoded} issue=${issue_number}"
}

run_gitlab_parse_test() {
  local test_name="$1"
  local url="$2"
  local check_pattern="$3"

  local actual
  actual="$(parse_gitlab_issue_url "${url}")"

  if ! echo "${actual}" | grep -qF "${check_pattern}"; then
    echo "FAIL: ${test_name}"
    echo "  url:       '${url}'"
    echo "  expected:  '${check_pattern}'"
    echo "  actual:    '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- GitLab URL parsing test cases ---

run_gitlab_parse_test "gitlab-parse-host" \
  "https://gitlab.com/group/project/-/issues/42" \
  "host=gitlab.com"

run_gitlab_parse_test "gitlab-parse-repo" \
  "https://gitlab.com/group/project/-/issues/42" \
  "repo=group/project"

run_gitlab_parse_test "gitlab-parse-issue-number" \
  "https://gitlab.com/group/project/-/issues/42" \
  "issue=42"

run_gitlab_parse_test "gitlab-parse-encoded-path" \
  "https://gitlab.com/group/project/-/issues/42" \
  "encoded=group%2Fproject"

run_gitlab_parse_test "gitlab-parse-nested-group" \
  "https://gitlab.com/org/sub-group/project/-/issues/99" \
  "repo=org/sub-group/project"

run_gitlab_parse_test "gitlab-parse-nested-encoded" \
  "https://gitlab.com/org/sub-group/project/-/issues/99" \
  "encoded=org%2Fsub-group%2Fproject"

run_gitlab_parse_test "gitlab-parse-redhat-host" \
  "https://gitlab.cee.redhat.com/gallen/integration-service/-/issues/1" \
  "host=gitlab.cee.redhat.com"

# ---------------------------------------------------------------------------
# GitLab token sanitization — tests the sed patterns added to
# sanitize_failure_detail for GitLab tokens and auth headers.
#
# Reimplements the token-stripping regex to test patterns in isolation.
# ---------------------------------------------------------------------------
sanitize_gitlab_tokens() {
  local detail="$1"
  printf '%s\n' "${detail}" | sed -E \
    -e 's/glpat-[A-Za-z0-9_-]{20,}/[REDACTED]/g' \
    -e 's/oauth2:[^@[:space:]]+/oauth2:[REDACTED]/g' \
    -e 's/(Bearer|token|PRIVATE-TOKEN:)[[:space:]]*[A-Za-z0-9._-]+/\1 [REDACTED]/gi' \
    -e 's/x-access-token:[^@[:space:]]+/x-access-token:[REDACTED]/g'
}

run_gitlab_sanitize_test() {
  local test_name="$1"
  local input="$2"
  local check_pattern="$3"
  local expect_present="$4"  # "yes" or "no"

  local actual
  actual="$(sanitize_gitlab_tokens "${input}")"

  if [ "${expect_present}" = "yes" ]; then
    if ! echo "${actual}" | grep -qF "${check_pattern}"; then
      echo "FAIL: ${test_name}"
      echo "  expected to find: '${check_pattern}'"
      echo "  in output:        '${actual}'"
      FAILURES=$((FAILURES + 1))
      return
    fi
  else
    if echo "${actual}" | grep -qF "${check_pattern}"; then
      echo "FAIL: ${test_name}"
      echo "  expected NOT to find: '${check_pattern}'"
      echo "  in output:            '${actual}'"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

# --- GitLab token sanitization test cases ---

# glpat- personal access tokens should be redacted
run_gitlab_sanitize_test "sanitize-glpat-token" \
  "fatal: Authentication failed: glpat-xxxxxxxxxxxxxxxxxxxx" \
  "glpat-" "no"

run_gitlab_sanitize_test "sanitize-glpat-replaced" \
  "fatal: Authentication failed: glpat-xxxxxxxxxxxxxxxxxxxx" \
  "[REDACTED]" "yes"

# oauth2:TOKEN in push URLs should be redacted
# gitleaks:allow
run_gitlab_sanitize_test "sanitize-oauth2-push-url" \
  "https://oauth2:glpat-secret-token@gitlab.com/group/project.git" \
  "glpat-secret-token" "no"

# gitleaks:allow
run_gitlab_sanitize_test "sanitize-oauth2-replaced" \
  "https://oauth2:glpat-secret-token@gitlab.com/group/project.git" \
  "oauth2:[REDACTED]" "yes"

# PRIVATE-TOKEN header should be redacted (value constructed to avoid gitleaks)
_pt_val="glpat-secret"
_pt_val="${_pt_val}123456789abc"
run_gitlab_sanitize_test "sanitize-private-token-header" \
  "curl --header \"PRIVATE-TOKEN: ${_pt_val}\" https://api.example.com" \
  "${_pt_val}" "no"

# Bearer token should be redacted (value constructed to avoid gitleaks)
_bearer_val="eyJhbGciOiJSUzI1"
_bearer_val="${_bearer_val}NiJ9.payload"
run_gitlab_sanitize_test "sanitize-bearer-token" \
  "Authorization: Bearer ${_bearer_val}" \
  "${_bearer_val}" "no"

# x-access-token should still be redacted (existing GitHub pattern)
run_gitlab_sanitize_test "sanitize-x-access-token" \
  "https://x-access-token:ghs_abcdef123456@github.com/org/repo.git" \
  "ghs_abcdef123456" "no"

# Non-token text should be preserved
run_gitlab_sanitize_test "sanitize-preserves-normal-text" \
  "fatal: remote origin already exists" \
  "fatal: remote origin already exists" "yes"

# ---------------------------------------------------------------------------
# GitLab push remote URL construction — tests the oauth2 auth URL format
# used by forge_set_push_remote.
# ---------------------------------------------------------------------------
build_gitlab_push_url() {
  local token="$1"
  local host="$2"
  local repo="$3"
  printf 'https://oauth2:%s@%s/%s.git' "${token}" "${host}" "${repo}"
}

run_gitlab_push_url_test() {
  local test_name="$1"
  local token="$2"
  local host="$3"
  local repo="$4"
  local check_pattern="$5"

  local actual
  actual="$(build_gitlab_push_url "${token}" "${host}" "${repo}")"

  if ! echo "${actual}" | grep -qF "${check_pattern}"; then
    echo "FAIL: ${test_name}"
    echo "  expected to find: '${check_pattern}'"
    echo "  actual:           '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- GitLab push URL test cases ---

run_gitlab_push_url_test "gitlab-push-url-format" \
  "glpat-testtoken1234567890" "gitlab.com" "group/project" \
  "https://oauth2:glpat-testtoken1234567890@gitlab.com/group/project.git" # gitleaks:allow

run_gitlab_push_url_test "gitlab-push-url-nested-group" \
  "token123" "gitlab.cee.redhat.com" "org/sub/project" \
  "https://oauth2:token123@gitlab.cee.redhat.com/org/sub/project.git" # gitleaks:allow

# ---------------------------------------------------------------------------
# Forge dispatch pattern — tests that the declare -F dispatch pattern used
# in post-failure-report.lib.sh and pr-assignee.lib.sh works correctly.
# ---------------------------------------------------------------------------
run_forge_dispatch_test() {
  local test_name="$1"
  local define_fn="$2"  # "yes" or "no"
  local expected="$3"

  local actual
  if [ "${define_fn}" = "yes" ]; then
    actual="$(
      _test_forge_fn() { echo "forge"; }
      if declare -F _test_forge_fn >/dev/null 2>&1; then
        _test_forge_fn
      else
        echo "fallback"
      fi
    )"
  else
    actual="$(
      if declare -F _test_forge_fn >/dev/null 2>&1; then
        _test_forge_fn
      else
        echo "fallback"
      fi
    )"
  fi

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  define_fn: '${define_fn}'"
    echo "  expected:  '${expected}'"
    echo "  actual:    '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Forge dispatch test cases ---

run_forge_dispatch_test "dispatch-with-forge-fn" \
  "yes" "forge"

run_forge_dispatch_test "dispatch-without-forge-fn" \
  "no" "fallback"

# ---------------------------------------------------------------------------
# GitLab integration test — runs the REAL post-code.sh with FULLSEND_FORGE=gitlab
# against a minimal repo with mock binaries to verify the GitLab forge path
# executes end-to-end (namespace enforcement, push, MR creation).
# ---------------------------------------------------------------------------

GL_INT_TMPDIR="$(mktemp -d)"
GL_INT_MOCK_BIN="${GL_INT_TMPDIR}/bin"
mkdir -p "${GL_INT_MOCK_BIN}"

cat > "${GL_INT_MOCK_BIN}/sleep" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${GL_INT_MOCK_BIN}/sleep"

cat > "${GL_INT_MOCK_BIN}/gitleaks" <<'MOCKEOF'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then echo 8.30.1; exit 0; fi
exit 0
MOCKEOF
chmod +x "${GL_INT_MOCK_BIN}/gitleaks"

GL_REAL_GIT="$(which git)"
cat > "${GL_INT_MOCK_BIN}/git" <<MOCKEOF
#!/usr/bin/env bash
if [[ "\$1" == "remote" && "\$2" == "set-url" ]]; then
  exit 0
fi
exec ${GL_REAL_GIT} "\$@"
MOCKEOF
chmod +x "${GL_INT_MOCK_BIN}/git"

# Mock curl to simulate GitLab API responses for MR lifecycle
cat > "${GL_INT_MOCK_BIN}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
url=""
method="GET"
for arg in "$@"; do
  case "${arg}" in
    https://*) url="${arg}" ;;
  esac
done
prev=""
for arg in "$@"; do
  if [[ "${prev}" == "--request" || "${prev}" == "-X" ]]; then
    method="${arg}"
  fi
  prev="${arg}"
done
case "${method} ${url}" in
  *merge_requests\?state=opened*source_branch*)
    echo '[]'; exit 0 ;;
  *merge_requests\?state=opened*)
    echo '[]'; exit 0 ;;
  POST*merge_requests)
    echo '{"iid":1,"web_url":"https://gitlab.com/test-group/test-project/-/merge_requests/1"}'; exit 0 ;;
  PUT*merge_requests/*)
    echo '{}'; exit 0 ;;
  *projects/*)
    echo '{"id":1,"default_branch":"main","merge_method":"merge"}'; exit 0 ;;
  *users*)
    echo '[]'; exit 0 ;;
  *issues/*)
    echo '{}'; exit 0 ;;
  *)
    echo '{}'; exit 0 ;;
esac
MOCKEOF
chmod +x "${GL_INT_MOCK_BIN}/curl"

setup_gl_int_repo() {
  local run_dir="$1"
  local branch_name="${2:-evil-branch}"
  local bare_dir="${run_dir}/remote.git"
  local repo_dir="${run_dir}/repo"

  ${GL_REAL_GIT} init -q --bare -b main "${bare_dir}"
  ${GL_REAL_GIT} clone -q "${bare_dir}" "${repo_dir}"
  ${GL_REAL_GIT} -C "${repo_dir}" config user.email "test@example.com"
  ${GL_REAL_GIT} -C "${repo_dir}" config user.name "Test"
  echo "init" > "${repo_dir}/README.md"
  ${GL_REAL_GIT} -C "${repo_dir}" add README.md
  ${GL_REAL_GIT} -C "${repo_dir}" commit -q -m "init"
  ${GL_REAL_GIT} -C "${repo_dir}" push -q origin main

  ${GL_REAL_GIT} -C "${repo_dir}" checkout -q -b "${branch_name}"
  echo "changed content" > "${repo_dir}/file.txt"
  ${GL_REAL_GIT} -C "${repo_dir}" add -f file.txt
  ${GL_REAL_GIT} -C "${repo_dir}" commit -q -m "fix: test change"
}

# --- GitLab namespace enforcement: arbitrary branch renamed to agent/<issue>-* ---
_gl_ns_dir="${GL_INT_TMPDIR}/run-gl-namespace"
setup_gl_int_repo "${_gl_ns_dir}" "evil-branch"

_gl_ns_rc=0
# shellcheck disable=SC2030,SC2031
(
  cd "${_gl_ns_dir}"
  export HOME="${GL_INT_TMPDIR}"
  export PATH="${GL_INT_MOCK_BIN}:${PATH}"
  export PUSH_TOKEN="glpat-fake-token-for-test"
  export REPO_FULL_NAME="test-group/test-project"
  export ISSUE_NUMBER="99"
  export ISSUE_URL="https://gitlab.com/test-group/test-project/-/issues/99"
  export REPO_DIR="repo"
  export FULLSEND_FORGE="gitlab"
  export GITLAB_TOKEN="${PUSH_TOKEN}"
  export GITLAB_HOST="gitlab.com"
  export CI_SERVER_HOST="gitlab.com"
  bash "${POST_SCRIPT}"
) > "${GL_INT_TMPDIR}/stdout-gl-namespace.log" 2>&1 || _gl_ns_rc=$?

_gl_ns_safe="$(${GL_REAL_GIT} -C "${_gl_ns_dir}/remote.git" branch --list "agent/99-evil-branch" 2>/dev/null)"
_gl_ns_evil="$(${GL_REAL_GIT} -C "${_gl_ns_dir}/remote.git" branch --list "evil-branch" 2>/dev/null)"

if [ -n "${_gl_ns_safe}" ] && [ -z "${_gl_ns_evil}" ]; then
  echo "PASS: gitlab-integration-namespace-enforcement"
else
  echo "FAIL: gitlab-integration-namespace-enforcement"
  echo "  exit code:      ${_gl_ns_rc}"
  echo "  agent/99-*:     '${_gl_ns_safe}'"
  echo "  evil-branch:    '${_gl_ns_evil}'"
  echo "  remote refs:    $(${GL_REAL_GIT} -C "${_gl_ns_dir}/remote.git" branch --list)"
  cat "${GL_INT_TMPDIR}/stdout-gl-namespace.log"
  FAILURES=$((FAILURES + 1))
fi

rm -rf "${GL_INT_TMPDIR}"

# =============================================================================
# Jira-sourced code runs (#1841)
#
# The PR/MR is created on the code host (GitHub or GitLab) and the code-stage
# update with its URL is written to the Jira issue through
# `fullsend issues post-comment --tracker jira`. Covers both code hosts, the
# existing-PR (retry) path, write-failure visibility, bot identity, and that
# forge-originated runs never write to Jira.
# =============================================================================

JIRA_INT_TMPDIR="$(mktemp -d)"
JIRA_INT_MOCK_BIN="${JIRA_INT_TMPDIR}/bin"
JIRA_INT_FULLSEND_LOG="${JIRA_INT_TMPDIR}/fullsend.log"
JIRA_INT_FORGE_LOG="${JIRA_INT_TMPDIR}/forge.log"
JIRA_INT_PRECOMMIT_LOG="${JIRA_INT_TMPDIR}/precommit.log"
mkdir -p "${JIRA_INT_MOCK_BIN}"
JIRA_REAL_GIT="$(which git)"

for _tool in sleep gitleaks; do
  cat > "${JIRA_INT_MOCK_BIN}/${_tool}" <<'MOCKEOF'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then echo 8.30.1; fi
exit 0
MOCKEOF
  chmod +x "${JIRA_INT_MOCK_BIN}/${_tool}"
done

cat > "${JIRA_INT_MOCK_BIN}/git" <<MOCKEOF
#!/usr/bin/env bash
if [[ "\$1" == "remote" && "\$2" == "set-url" ]]; then
  exit 0
fi
exec ${JIRA_REAL_GIT} "\$@"
MOCKEOF
chmod +x "${JIRA_INT_MOCK_BIN}/git"

# GitHub code host. MOCK_EXISTING_PR=1 reports an open PR for the branch.
cat > "${JIRA_INT_MOCK_BIN}/gh" <<MOCKEOF
#!/usr/bin/env bash
echo "gh \$*" >> "${JIRA_INT_FORGE_LOG}"
case "\$1 \$2" in
  "api -X")      echo "unexpected Git Data API call: \$*" >&2; exit 99 ;;
  "api repos/"*) echo "main"; exit 0 ;;
  "pr list")     if [[ -n "\${MOCK_EXISTING_PR:-}" ]]; then echo "7"; fi; exit 0 ;;
  "pr view")     echo "https://github.com/test-org/test-repo/pull/7"; exit 0 ;;
  "pr create")   echo "https://github.com/test-org/test-repo/pull/1"; exit 0 ;;
  *)             exit 0 ;;
esac
MOCKEOF
chmod +x "${JIRA_INT_MOCK_BIN}/gh"

# GitLab code host.
cat > "${JIRA_INT_MOCK_BIN}/curl" <<MOCKEOF
#!/usr/bin/env bash
echo "curl \$*" >> "${JIRA_INT_FORGE_LOG}"
url=""
method="GET"
prev=""
for arg in "\$@"; do
  case "\${arg}" in
    https://*) url="\${arg}" ;;
  esac
  if [[ "\${prev}" == "--request" || "\${prev}" == "-X" ]]; then
    method="\${arg}"
  fi
  prev="\${arg}"
done
case "\${method} \${url}" in
  *merge_requests\?state=opened*) echo '[]' ;;
  POST*merge_requests) echo '{"iid":1,"web_url":"https://gitlab.com/test-group/test-project/-/merge_requests/1"}' ;;
  *projects/*) echo '{"id":1,"default_branch":"main","merge_method":"merge"}' ;;
  *users*) echo '[]' ;;
  *) echo '{}' ;;
esac
# Callers using --write-out read the HTTP status from the last line.
if [[ " \$* " == *" --write-out "* ]]; then
  printf '\n201'
fi
exit 0
MOCKEOF
chmod +x "${JIRA_INT_MOCK_BIN}/curl"

# Tracker CLI. Records args and the comment body; also records whether the
# token reached it through the environment. MOCK_FULLSEND_FAIL=1 fails it.
cat > "${JIRA_INT_MOCK_BIN}/fullsend" <<MOCKEOF
#!/usr/bin/env bash
BODY=""
PREV=""
for arg in "\$@"; do
  if [[ "\${arg}" == "-" && "\${PREV}" == "--result" ]]; then
    BODY=\$(cat)
  fi
  PREV="\${arg}"
done
echo "fullsend \$* env-token=\${JIRA_TOKEN:-unset} <<BODY:\${BODY}:BODY>>" >> "${JIRA_INT_FULLSEND_LOG}"
if [[ -n "\${MOCK_FULLSEND_FAIL:-}" ]]; then
  echo "Error: Jira API returned 401" >&2
  exit 1
fi
MOCKEOF
chmod +x "${JIRA_INT_MOCK_BIN}/fullsend"

# pre-commit stand-in. Records whether the Jira credentials are visible to
# hooks (it runs repo-controlled code in the real tool).
cat > "${JIRA_INT_MOCK_BIN}/pre-commit" <<MOCKEOF
#!/usr/bin/env bash
echo "pre-commit jira-token=\${JIRA_TOKEN:-unset} jira-email=\${JIRA_USER_EMAIL:-unset}" >> "${JIRA_INT_PRECOMMIT_LOG}"
exit 0
MOCKEOF
chmod +x "${JIRA_INT_MOCK_BIN}/pre-commit"

setup_jira_int_repo() {
  local run_dir="$1"
  local branch_name="$2"
  local repo_dir="${run_dir}/repo"
  ${JIRA_REAL_GIT} init -q --bare -b main "${run_dir}/remote.git"
  ${JIRA_REAL_GIT} clone -q "${run_dir}/remote.git" "${repo_dir}" 2>/dev/null
  ${JIRA_REAL_GIT} -C "${repo_dir}" config user.email "test@example.com"
  ${JIRA_REAL_GIT} -C "${repo_dir}" config user.name "Test"
  echo "init" > "${repo_dir}/README.md"
  ${JIRA_REAL_GIT} -C "${repo_dir}" add README.md
  ${JIRA_REAL_GIT} -C "${repo_dir}" commit -q -m "init"
  ${JIRA_REAL_GIT} -C "${repo_dir}" push -q origin main
  if [ -n "${JIRA_INT_WITH_PRECOMMIT:-}" ]; then
    printf 'repos: []\n' > "${repo_dir}/.pre-commit-config.yaml"
    ${JIRA_REAL_GIT} -C "${repo_dir}" add .pre-commit-config.yaml
    ${JIRA_REAL_GIT} -C "${repo_dir}" commit -q -m "chore: pre-commit config"
    ${JIRA_REAL_GIT} -C "${repo_dir}" push -q origin main
  fi
  ${JIRA_REAL_GIT} -C "${repo_dir}" checkout -q -b "${branch_name}"
  echo "changed content" > "${repo_dir}/file.txt"
  ${JIRA_REAL_GIT} -C "${repo_dir}" add -f file.txt
  ${JIRA_REAL_GIT} -C "${repo_dir}" commit -q -m "fix: test change"
  if [ -n "${JIRA_INT_PREPUSH_HOOK:-}" ]; then
    cat > "${repo_dir}/.git/hooks/pre-push" <<HOOKEOF
#!/usr/bin/env bash
echo "pre-push jira-token=\${JIRA_TOKEN:-unset} jira-email=\${JIRA_USER_EMAIL:-unset}" >> "${JIRA_INT_PREPUSH_HOOK}"
exit 0
HOOKEOF
    chmod +x "${repo_dir}/.git/hooks/pre-push"
  fi
}

# Run post-code for a Jira-sourced work item on the given code host. Extra
# NAME=VALUE arguments are exported last. Leaves the exit code in
# JIRA_INT_RC and the output in JIRA_INT_OUT.
run_jira_int() {
  local test_name="$1"
  local forge="$2"
  shift 2
  local run_dir="${JIRA_INT_TMPDIR}/run-${test_name}"
  setup_jira_int_repo "${run_dir}" "agent/TESTPROJ-42-fix"
  : > "${JIRA_INT_FULLSEND_LOG}"
  : > "${JIRA_INT_FORGE_LOG}"
  JIRA_INT_OUT="${JIRA_INT_TMPDIR}/stdout-${test_name}.log"
  JIRA_INT_RC=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    unset GITLAB_HOST CI_SERVER_URL GH_TOKEN GITLAB_TOKEN
    export HOME="${JIRA_INT_TMPDIR}"
    export PATH="${JIRA_INT_MOCK_BIN}:${PATH}"
    export PUSH_TOKEN="fake-token"
    export REPO_DIR="repo"
    export ISSUE_NUMBER=""
    export FULLSEND_FORGE="${forge}"
    export FULLSEND_TRACKER="jira"
    export FULLSEND_WORK_ITEM_SOURCE="jira"
    export FULLSEND_WORK_ITEM_KEY="TESTPROJ-42"
    export FULLSEND_WORK_ITEM_URL="https://test.atlassian.net/browse/TESTPROJ-42"
    export ISSUE_URL="${FULLSEND_WORK_ITEM_URL}"
    export JIRA_BASE_URL="https://test.atlassian.net/"
    export JIRA_USER_EMAIL="fullsend-bot@example.com"
    export JIRA_TOKEN="fake-jira-token"
    if [ "${forge}" = "gitlab" ]; then
      export REPO_FULL_NAME="test-group/test-project"
      export GITLAB_TOKEN="${PUSH_TOKEN}"
      export CI_SERVER_HOST="gitlab.com"
    else
      export REPO_FULL_NAME="test-org/test-repo"
      export GITHUB_SIGNED_COMMITS="false"
    fi
    local kv
    for kv in "$@"; do
      export "${kv?}"
    done
    bash "${POST_SCRIPT}"
  ) > "${JIRA_INT_OUT}" 2>&1 || JIRA_INT_RC=$?
}

jira_int_fail() {
  echo "FAIL: $1 — $2"
  echo "  exit code: ${JIRA_INT_RC}"
  cat "${JIRA_INT_OUT}"
  echo "  fullsend calls:"; cat "${JIRA_INT_FULLSEND_LOG}"
  FAILURES=$((FAILURES + 1))
}

JIRA_CODE_MARKER="--marker <!-- fullsend:code-agent -->"

# GitHub target: PR on GitHub, stage update with the PR URL on the Jira issue.
run_jira_int "jira-github-target" github
if [ "${JIRA_INT_RC}" -ne 0 ]; then
  jira_int_fail "jira-github-target-pr-url-to-jira" "post-code failed"
elif ! grep -q "^gh pr create" "${JIRA_INT_FORGE_LOG}"; then
  jira_int_fail "jira-github-target-pr-url-to-jira" "PR not created on GitHub"
elif ! grep -qF -- "--tracker jira --project TESTPROJ --number 42 --jira-url https://test.atlassian.net" "${JIRA_INT_FULLSEND_LOG}" \
     || ! grep -qF -- "${JIRA_CODE_MARKER}" "${JIRA_INT_FULLSEND_LOG}" \
     || ! grep -qF "opened pull request https://github.com/test-org/test-repo/pull/1 for TESTPROJ-42" "${JIRA_INT_FULLSEND_LOG}"; then
  jira_int_fail "jira-github-target-pr-url-to-jira" "Jira stage update missing or malformed"
elif grep -q "^gh issue comment" "${JIRA_INT_FORGE_LOG}"; then
  jira_int_fail "jira-github-target-pr-url-to-jira" "commented on a GitHub issue for a Jira work item"
else
  echo "PASS: jira-github-target-pr-url-to-jira"
fi

# Bot identity: the write uses the configured fullsend Jira account (the
# identity the Jira poller classifies as its own), and the token reaches the
# CLI through the environment rather than the command line.
if ! grep -qF -- "--jira-email fullsend-bot@example.com" "${JIRA_INT_FULLSEND_LOG}" \
   || ! grep -qF "env-token=fake-jira-token" "${JIRA_INT_FULLSEND_LOG}" \
   || grep -qF -- "--token" "${JIRA_INT_FULLSEND_LOG}"; then
  jira_int_fail "jira-stage-update-bot-identity" "write did not use the configured Jira account, or the token was passed on the command line"
else
  echo "PASS: jira-stage-update-bot-identity"
fi

# Jira credentials are withheld from pre-commit hooks (repo-controlled code)
# but still reach the Jira stage update afterwards.
: > "${JIRA_INT_PRECOMMIT_LOG}"
JIRA_INT_WITH_PRECOMMIT=1 run_jira_int "jira-precommit-hidden" github
if [ "${JIRA_INT_RC}" -ne 0 ]; then
  jira_int_fail "jira-token-hidden-from-precommit" "post-code failed"
elif ! grep -q "^pre-commit " "${JIRA_INT_PRECOMMIT_LOG}"; then
  jira_int_fail "jira-token-hidden-from-precommit" "pre-commit did not run"
elif ! grep -qF "pre-commit jira-token=unset jira-email=unset" "${JIRA_INT_PRECOMMIT_LOG}"; then
  jira_int_fail "jira-token-hidden-from-precommit" "Jira credentials visible to pre-commit hooks"
elif ! grep -qF "env-token=fake-jira-token" "${JIRA_INT_FULLSEND_LOG}"; then
  jira_int_fail "jira-token-hidden-from-precommit" "Jira credentials not restored for the stage update"
else
  echo "PASS: jira-token-hidden-from-precommit"
fi

# A pre-push hook (repo-controlled code that runs during the plain git push)
# does not see the Jira credentials either, and a `fullsend` binary dropped in
# ${HOME}/.local/bin (put first on PATH by the script) does not shadow the
# trusted CLI used for the Jira write.
JIRA_INT_PREPUSH_LOG="${JIRA_INT_TMPDIR}/prepush.log"
JIRA_INT_SHADOW_LOG="${JIRA_INT_TMPDIR}/shadow.log"
: > "${JIRA_INT_PREPUSH_LOG}"
: > "${JIRA_INT_SHADOW_LOG}"
mkdir -p "${JIRA_INT_TMPDIR}/.local/bin"
cat > "${JIRA_INT_TMPDIR}/.local/bin/fullsend" <<SHADOWEOF
#!/usr/bin/env bash
echo "shadow fullsend called token=\${JIRA_TOKEN:-unset}" >> "${JIRA_INT_SHADOW_LOG}"
exit 0
SHADOWEOF
chmod +x "${JIRA_INT_TMPDIR}/.local/bin/fullsend"
JIRA_INT_PREPUSH_HOOK="${JIRA_INT_PREPUSH_LOG}" run_jira_int "jira-prepush-hidden" github
rm -rf "${JIRA_INT_TMPDIR}/.local"
if [ "${JIRA_INT_RC}" -ne 0 ]; then
  jira_int_fail "jira-token-hidden-from-prepush-hook" "post-code failed"
elif ! grep -q "^pre-push " "${JIRA_INT_PREPUSH_LOG}"; then
  jira_int_fail "jira-token-hidden-from-prepush-hook" "pre-push hook did not run"
elif ! grep -qF "pre-push jira-token=unset jira-email=unset" "${JIRA_INT_PREPUSH_LOG}"; then
  jira_int_fail "jira-token-hidden-from-prepush-hook" "Jira credentials visible to a pre-push hook"
elif [ -s "${JIRA_INT_SHADOW_LOG}" ]; then
  jira_int_fail "jira-path-shadowed-fullsend-not-used" "a binary from the repo-controlled PATH entry received the Jira write"
elif ! grep -qF "env-token=fake-jira-token" "${JIRA_INT_FULLSEND_LOG}"; then
  jira_int_fail "jira-path-shadowed-fullsend-not-used" "trusted fullsend CLI was not used for the Jira write"
else
  echo "PASS: jira-token-hidden-from-prepush-hook"
  echo "PASS: jira-path-shadowed-fullsend-not-used"
fi

# GitLab target: MR on GitLab (host from CI_SERVER_HOST, since ISSUE_URL is the
# Jira URL), stage update with the MR URL on the Jira issue.
run_jira_int "jira-gitlab-target" gitlab
if [ "${JIRA_INT_RC}" -ne 0 ]; then
  jira_int_fail "jira-gitlab-target-mr-url-to-jira" "post-code failed"
elif ! grep -qE "^curl .*--request POST .*https://gitlab.com/api/v4/projects/test-group%2Ftest-project/merge_requests" "${JIRA_INT_FORGE_LOG}"; then
  jira_int_fail "jira-gitlab-target-mr-url-to-jira" "MR not created on GitLab"
elif grep -qF "atlassian.net/api/v4" "${JIRA_INT_FORGE_LOG}"; then
  jira_int_fail "jira-gitlab-target-mr-url-to-jira" "GitLab API call went to the Jira host"
elif ! grep -qF -- "${JIRA_CODE_MARKER}" "${JIRA_INT_FULLSEND_LOG}" \
     || ! grep -qF "opened merge request https://gitlab.com/test-group/test-project/-/merge_requests/1 for TESTPROJ-42" "${JIRA_INT_FULLSEND_LOG}"; then
  jira_int_fail "jira-gitlab-target-mr-url-to-jira" "Jira stage update missing or malformed"
else
  echo "PASS: jira-gitlab-target-mr-url-to-jira"
fi

# GitLab target without a trusted CI server host fails before any API call.
run_jira_int "jira-gitlab-target-no-ci-host" gitlab CI_SERVER_HOST=
if [ "${JIRA_INT_RC}" -eq 0 ]; then
  jira_int_fail "jira-gitlab-target-requires-ci-server-host" "expected failure but got success"
elif [ -s "${JIRA_INT_FORGE_LOG}" ] || [ -s "${JIRA_INT_FULLSEND_LOG}" ]; then
  jira_int_fail "jira-gitlab-target-requires-ci-server-host" "API calls made without a trusted GitLab host"
else
  echo "PASS: jira-gitlab-target-requires-ci-server-host (expected failure, got exit ${JIRA_INT_RC})"
fi

# Retry: the PR already exists, so the run updates it and rewrites the same
# sticky Jira comment (same marker) instead of adding a second one.
run_jira_int "jira-existing-pr" github MOCK_EXISTING_PR=1
if [ "${JIRA_INT_RC}" -ne 0 ]; then
  jira_int_fail "jira-retry-existing-pr-reuses-marker" "post-code failed"
elif grep -q "^gh pr create" "${JIRA_INT_FORGE_LOG}"; then
  jira_int_fail "jira-retry-existing-pr-reuses-marker" "created a second PR"
elif [ "$(grep -c "^fullsend issues post-comment" "${JIRA_INT_FULLSEND_LOG}")" -ne 1 ] \
     || ! grep -qF -- "${JIRA_CODE_MARKER}" "${JIRA_INT_FULLSEND_LOG}" \
     || ! grep -qF "pushed new commits to pull request https://github.com/test-org/test-repo/pull/7" "${JIRA_INT_FULLSEND_LOG}"; then
  jira_int_fail "jira-retry-existing-pr-reuses-marker" "expected one sticky Jira update for the existing PR"
else
  echo "PASS: jira-retry-existing-pr-reuses-marker"
fi

# Write-failure visibility: a failed Jira write fails the step on both paths.
for _jira_fail_case in "jira-write-failure-new-pr|" "jira-write-failure-existing-pr|MOCK_EXISTING_PR=1"; do
  _jira_fail_name="${_jira_fail_case%%|*}"
  _jira_fail_extra="${_jira_fail_case#*|}"
  run_jira_int "${_jira_fail_name}" github MOCK_FULLSEND_FAIL=1 ${_jira_fail_extra:+"${_jira_fail_extra}"}
  if [ "${JIRA_INT_RC}" -eq 0 ]; then
    jira_int_fail "${_jira_fail_name}-fails-step" "expected failure but got success"
  elif ! grep -qF "Failed to write the code-stage update to Jira issue TESTPROJ-42" "${JIRA_INT_OUT}"; then
    jira_int_fail "${_jira_fail_name}-fails-step" "missing Jira write-failure error"
  else
    echo "PASS: ${_jira_fail_name}-fails-step (expected failure, got exit ${JIRA_INT_RC})"
  fi
done

# Missing runner-side Jira credentials fail visibly instead of skipping.
run_jira_int "jira-missing-token" github JIRA_TOKEN=
if [ "${JIRA_INT_RC}" -eq 0 ]; then
  jira_int_fail "jira-missing-token-fails-step" "expected failure but got success"
elif ! grep -qF "JIRA_USER_EMAIL and JIRA_TOKEN are required" "${JIRA_INT_OUT}" || [ -s "${JIRA_INT_FULLSEND_LOG}" ]; then
  jira_int_fail "jira-missing-token-fails-step" "missing credential error, or a write was attempted"
else
  echo "PASS: jira-missing-token-fails-step (expected failure, got exit ${JIRA_INT_RC})"
fi

# A work-item key that disagrees with the URL is not written anywhere in Jira.
run_jira_int "jira-key-mismatch" github FULLSEND_WORK_ITEM_KEY=TESTPROJ-7
if [ "${JIRA_INT_RC}" -eq 0 ] || [ -s "${JIRA_INT_FULLSEND_LOG}" ]; then
  jira_int_fail "jira-key-mismatch-not-written" "expected failure with no Jira write"
else
  echo "PASS: jira-key-mismatch-not-written (expected failure, got exit ${JIRA_INT_RC})"
fi

# Forge-originated run (fullsend run still exports FULLSEND_WORK_ITEM_SOURCE):
# GitHub issue flow, no Jira write.
run_jira_int "forge-originated" github FULLSEND_TRACKER= FULLSEND_WORK_ITEM_SOURCE=github \
  FULLSEND_WORK_ITEM_KEY= FULLSEND_WORK_ITEM_URL= ISSUE_NUMBER=42 \
  ISSUE_URL=https://github.com/test-org/test-repo/issues/42 JIRA_TOKEN= JIRA_USER_EMAIL=
if [ "${JIRA_INT_RC}" -ne 0 ]; then
  jira_int_fail "forge-originated-run-no-jira-write" "post-code failed"
elif [ -s "${JIRA_INT_FULLSEND_LOG}" ]; then
  jira_int_fail "forge-originated-run-no-jira-write" "wrote to Jira for a GitHub issue"
elif ! grep -q "^gh pr create" "${JIRA_INT_FORGE_LOG}"; then
  jira_int_fail "forge-originated-run-no-jira-write" "PR not created"
else
  echo "PASS: forge-originated-run-no-jira-write"
fi

# An explicit tracker that disagrees with the exported work-item source stops
# the run before anything is pushed.
run_jira_int "jira-tracker-source-conflict" github FULLSEND_WORK_ITEM_SOURCE=github
if [ "${JIRA_INT_RC}" -eq 0 ] || [ -s "${JIRA_INT_FORGE_LOG}" ]; then
  jira_int_fail "jira-tracker-source-conflict-fails" "expected failure before any forge call"
else
  echo "PASS: jira-tracker-source-conflict-fails (expected failure, got exit ${JIRA_INT_RC})"
fi

rm -rf "${JIRA_INT_TMPDIR}"

# =============================================================================
# GitLab auto-merge unit tests
# =============================================================================

run_am_test() {
  local test_name="$1"
  local mock_body="$2"
  local expect_pattern="$3"  # grep -qE pattern expected in combined output
  local expect_absent="${4:-}"  # optional pattern that must NOT appear

  local am_output
  am_output=$(
    # Source the lib first, then override the API function
    unset GITLAB_CODE_OPS_SH_LOADED
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/gitlab-code-ops.lib.sh"

    # Override _gitlab_code_api with the test mock (AFTER source)
    eval "${mock_body}"

    # Stub gha_echo to write to stdout so we can capture it
    # shellcheck disable=SC2317
    gha_echo() { echo "::${1}::${2:-}"; }
    # Stub sleep to no-op
    # shellcheck disable=SC2317
    sleep() { :; }

    # shellcheck disable=SC2030
    export REPO_ENCODED="test-group%2Ftest-project"
    forge_enable_auto_merge "1" "--squash"
  ) 2>&1

  local pass=true
  if [ -n "${expect_pattern}" ]; then
    if ! echo "${am_output}" | grep -qE "${expect_pattern}"; then
      pass=false
    fi
  fi
  if [ -n "${expect_absent}" ]; then
    if echo "${am_output}" | grep -qE "${expect_absent}"; then
      pass=false
    fi
  fi

  if ${pass}; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name}"
    echo "  expected pattern: ${expect_pattern}"
    [ -n "${expect_absent}" ] && echo "  absent pattern:   ${expect_absent}"
    echo "  output: ${am_output}"
    FAILURES=$((FAILURES + 1))
  fi
}

# Test 1: pipeline running — should arm auto-merge
run_am_test "gitlab-auto-merge-pipeline-running" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"running\"},\"detailed_merge_status\":\"not_approved\"}" ;;
    */merge) return 0 ;;
  esac
}' "" "merge immediately"

# Test 2: pipeline pending — should arm auto-merge
run_am_test "gitlab-auto-merge-pipeline-pending" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"pending\"},\"detailed_merge_status\":\"not_approved\"}" ;;
    */merge) return 0 ;;
  esac
}' "" "merge immediately"

# Test 3: pipeline preparing (transitional) — should arm auto-merge
run_am_test "gitlab-auto-merge-pipeline-preparing" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"preparing\"},\"detailed_merge_status\":\"not_approved\"}" ;;
    */merge) return 0 ;;
  esac
}' "" "merge immediately"

# Test 4: no pipeline after 3 retries — should skip
run_am_test "gitlab-auto-merge-no-pipeline" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":null,\"detailed_merge_status\":\"unknown\"}" ;;
    */merge) return 0 ;;
  esac
}' "no pipeline after 3 attempts"

# Test 5: pipeline failed — should skip
run_am_test "gitlab-auto-merge-pipeline-failed" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"failed\"},\"detailed_merge_status\":\"ci_must_pass\"}" ;;
    */merge) return 0 ;;
  esac
}' "pipeline status .failed."

# Test 6: pipeline canceled — should skip
run_am_test "gitlab-auto-merge-pipeline-canceled" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"canceled\"},\"detailed_merge_status\":\"ci_must_pass\"}" ;;
    */merge) return 0 ;;
  esac
}' "pipeline status .canceled."

# Test 7: API failure — should skip gracefully
run_am_test "gitlab-auto-merge-api-failure" '
_gitlab_code_api() { return 1; }' \
  "could not query MR"

# Test 8: pipeline success + MR immediately mergeable — BLOCKED guard should skip
run_am_test "gitlab-auto-merge-blocked-guard-mergeable" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"success\"},\"detailed_merge_status\":\"mergeable\"}" ;;
    */merge) return 0 ;;
  esac
}' "immediately mergeable"

# Test 9: pipeline success + MR blocked (approvals needed) — should arm
run_am_test "gitlab-auto-merge-blocked-guard-not-approved" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"success\"},\"detailed_merge_status\":\"not_approved\"}" ;;
    */merge) return 0 ;;
  esac
}' "pipeline passed but MR is blocked" "immediately mergeable"

# Test 10: pipeline running + MR immediately mergeable — BLOCKED guard should skip
run_am_test "gitlab-auto-merge-running-but-mergeable" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"running\"},\"detailed_merge_status\":\"mergeable\"}" ;;
    */merge) return 0 ;;
  esac
}' "immediately mergeable"

# Test 11: legacy can_be_merged status — BLOCKED guard should skip
run_am_test "gitlab-auto-merge-can-be-merged" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"success\"},\"merge_status\":\"can_be_merged\"}" ;;
    */merge) return 0 ;;
  esac
}' "immediately mergeable"

# Test 12: checking status + pipeline running — should arm (pipeline provides safety)
run_am_test "gitlab-auto-merge-checking-running" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"running\"},\"detailed_merge_status\":\"checking\"}" ;;
    */merge) return 0 ;;
  esac
}' "" "skipping"

# Test 13: checking status + pipeline success — should skip (could merge immediately)
run_am_test "gitlab-auto-merge-checking-success" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"success\"},\"detailed_merge_status\":\"checking\"}" ;;
    */merge) return 0 ;;
  esac
}' "not settled but pipeline passed"

# Test 14: unknown merge status — should skip conservatively
run_am_test "gitlab-auto-merge-unknown-merge-status" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"running\"},\"detailed_merge_status\":\"some_future_status\"}" ;;
    */merge) return 0 ;;
  esac
}' "unrecognized merge status"

# Test 15: preparing status + pipeline running — should arm (new MR transitional state)
run_am_test "gitlab-auto-merge-preparing-running" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"running\"},\"detailed_merge_status\":\"preparing\"}" ;;
    */merge) return 0 ;;
  esac
}' "" "skipping"

# Test 16: preparing status + pipeline success — should skip (could merge immediately)
run_am_test "gitlab-auto-merge-preparing-success" '
_gitlab_code_api() {
  case "$2" in
    */merge_requests/1) echo "{\"head_pipeline\":{\"status\":\"success\"},\"detailed_merge_status\":\"preparing\"}" ;;
    */merge) return 0 ;;
  esac
}' "not settled but pipeline passed"

# =============================================================================
# GitLab workflow-run-url tests
# =============================================================================

run_workflow_url_test() {
  local test_name="$1"
  local env_setup="$2"
  local expected_url="$3"

  local actual_url
  actual_url=$(
    unset GITLAB_CODE_OPS_SH_LOADED
    unset GITHUB_RUN_ID GITHUB_REPOSITORY GITHUB_SERVER_URL
    unset CI_SERVER_URL CI_PROJECT_PATH CI_PIPELINE_ID CI_JOB_ID
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/gitlab-code-ops.lib.sh"
    eval "${env_setup}"
    # shellcheck disable=SC2030,SC2031
    export REPO_FULL_NAME="test-group/test-project"
    forge_get_workflow_run_url
  ) 2>&1

  if [ "${actual_url}" = "${expected_url}" ]; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name}"
    echo "  expected: ${expected_url}"
    echo "  actual:   ${actual_url}"
    FAILURES=$((FAILURES + 1))
  fi
}

# Test 1: GitLab CI with job ID
run_workflow_url_test "gitlab-workflow-url-job" \
  'export CI_SERVER_URL="https://gitlab.com"; export CI_PROJECT_PATH="grp/proj"; export CI_JOB_ID="12345"' \
  "https://gitlab.com/grp/proj/-/jobs/12345"

# Test 2: GitLab CI with pipeline ID only
run_workflow_url_test "gitlab-workflow-url-pipeline" \
  'export CI_SERVER_URL="https://gitlab.com"; export CI_PROJECT_PATH="grp/proj"; export CI_PIPELINE_ID="67890"' \
  "https://gitlab.com/grp/proj/-/pipelines/67890"

# Test 3: GHA fallback — GITHUB_RUN_ID present
run_workflow_url_test "gitlab-workflow-url-gha-fallback" \
  'export GITHUB_RUN_ID="111"; export GITHUB_REPOSITORY="org/repo"; export GITHUB_SERVER_URL="https://github.com"' \
  "https://github.com/org/repo/actions/runs/111"

# Test 4: GHA fallback takes precedence over GitLab CI vars
run_workflow_url_test "gitlab-workflow-url-gha-precedence" \
  'export GITHUB_RUN_ID="111"; export GITHUB_REPOSITORY="org/repo"; export CI_SERVER_URL="https://gitlab.com"; export CI_JOB_ID="999"' \
  "https://github.com/org/repo/actions/runs/111"

# =============================================================================
# forge_create_pr transient retry (issue #1361)
# =============================================================================

run_gh_create_pr_retry_test() {
  # shellcheck disable=SC2030,SC2031,SC2317
  local test_name="$1"
  local fail_times="$2"
  local error_msg="$3"
  local expect_attempts="$4"
  local expect_rc="$5"

  local tmp mock_bin call_log rc=0 output attempts
  tmp=$(mktemp -d)
  mock_bin="${tmp}/bin"
  call_log="${tmp}/calls"
  mkdir -p "${mock_bin}"
  : > "${call_log}"

  cat > "${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALL_LOG}"
n=$(grep -c 'pr create' "${CALL_LOG}" 2>/dev/null || true)
if printf '%s' " $*" | grep -q ' pr create '; then
  if [ "${n}" -le "${FAIL_TIMES}" ]; then
    echo "${ERROR_MSG}" >&2
    exit 1
  fi
  echo "https://github.com/org/repo/pull/1"
  exit 0
fi
exit 0
MOCK
  chmod +x "${mock_bin}/gh"

  output=$(
    # shellcheck disable=SC2030,SC2031,SC2317
    {
      unset GITHUB_CODE_OPS_SH_LOADED
      unset FORGE_TRANSIENT_RETRY_SH_LOADED
      # shellcheck disable=SC1091
      source "${SCRIPT_DIR}/lib/github-code-ops.lib.sh"
      sleep() { :; }
      export REPO_FULL_NAME="org/repo"
      export FORGE_TRANSIENT_RETRY_BASE_DELAY=0
      export CALL_LOG="${call_log}"
      export FAIL_TIMES="${fail_times}"
      export ERROR_MSG="${error_msg}"
      export PATH="${mock_bin}:${PATH}"
      forge_create_pr "main" "agent/1-x" "title" "body"
    } 2>&1
  ) || rc=$?

  attempts=$(grep -c 'pr create' "${call_log}" || true)

  if [ "${rc}" -ne "${expect_rc}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected rc ${expect_rc}, got ${rc}"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ "${attempts}" -ne "${expect_attempts}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected ${expect_attempts} gh pr create attempts, got ${attempts}"
    echo "  calls:"
    cat "${call_log}"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ "${expect_rc}" -eq 0 ]; then
    if ! echo "${output}" | grep -q 'https://github.com/org/repo/pull/1'; then
      echo "FAIL: ${test_name}"
      echo "  expected PR URL on success"
      echo "  output: ${output}"
      FAILURES=$((FAILURES + 1))
      rm -rf "${tmp}"
      return
    fi
  fi

  echo "PASS: ${test_name}"
  rm -rf "${tmp}"
}

run_gh_create_pr_retry_test "create-pr-retries-transient-503" \
  2 "HTTP 503: Internal Server Error" 3 0
run_gh_create_pr_retry_test "create-pr-gives-up-after-3" \
  99 "HTTP 503: Internal Server Error" 3 1
run_gh_create_pr_retry_test "create-pr-no-retry-on-422" \
  99 "HTTP 422: Validation Failed" 1 1
run_gh_create_pr_retry_test "create-pr-succeeds-first-try" \
  0 "HTTP 503: Internal Server Error" 1 0

run_gl_create_pr_retry_test() {
  # shellcheck disable=SC2030,SC2031,SC2317
  local test_name="$1"
  local fail_times="$2"
  local error_msg="$3"
  local expect_attempts="$4"
  local expect_rc="$5"

  local tmp call_log rc=0 output attempts
  tmp=$(mktemp -d)
  call_log="${tmp}/calls"
  : > "${call_log}"

  output=$(
    # shellcheck disable=SC2030,SC2031,SC2317
    {
      unset GITLAB_CODE_OPS_SH_LOADED
      unset GITLAB_HOST_VALIDATION_SH_LOADED
      unset FORGE_TRANSIENT_RETRY_SH_LOADED
      # shellcheck disable=SC1091
      source "${SCRIPT_DIR}/lib/gitlab-code-ops.lib.sh"
      sleep() { :; }
      export CALL_LOG="${call_log}"
      export FAIL_TIMES="${fail_times}"
      export ERROR_MSG="${error_msg}"
      export FORGE_TRANSIENT_RETRY_BASE_DELAY=0
      export REPO_ENCODED="group%2Fproject"
      _gitlab_code_api_with_status() {
        printf '%s\n' "called" >> "${CALL_LOG}"
        local n
        n=$(wc -l < "${CALL_LOG}" | tr -d ' ')
        if [ "${n}" -le "${FAIL_TIMES}" ]; then
          echo "${ERROR_MSG}" >&2
          return 1
        fi
        echo '{"web_url":"https://gitlab.com/group/project/-/merge_requests/1"}'
        return 0
      }
      forge_create_pr "main" "agent/1-x" "title" "body"
    } 2>&1
  ) || rc=$?

  attempts=$(wc -l < "${call_log}" | tr -d ' ')

  if [ "${rc}" -ne "${expect_rc}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected rc ${expect_rc}, got ${rc}"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ "${attempts}" -ne "${expect_attempts}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected ${expect_attempts} GitLab create attempts, got ${attempts}"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi

  echo "PASS: ${test_name}"
  rm -rf "${tmp}"
}

run_gl_create_pr_retry_test "gitlab-create-pr-retries-transient-503" \
  2 "GitLab API error (HTTP 503): no available server" 3 0
run_gl_create_pr_retry_test "gitlab-create-pr-gives-up-after-3" \
  99 "GitLab API error (HTTP 503): no available server" 3 1
run_gl_create_pr_retry_test "gitlab-create-pr-no-retry-on-400" \
  99 "GitLab API error (HTTP 400): invalid source branch" 1 1

# =============================================================================
# forge_create_pr already-exists recovery
# =============================================================================

run_already_exists_matcher_test() {
  local test_name="$1"
  local text="$2"
  local expect_rc="$3"
  local rc=0
  (
    unset FORGE_TRANSIENT_RETRY_SH_LOADED
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/forge-transient-retry.lib.sh"
    forge_is_already_exists_error "${text}"
  ) || rc=$?
  if [ "${rc}" -ne "${expect_rc}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected rc ${expect_rc}, got ${rc}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

run_already_exists_matcher_test "already-exists-matches-gh-cli" \
  'a pull request for branch "agent/1-x" into branch "main" already exists:
https://github.com/org/repo/pull/99' 0
run_already_exists_matcher_test "already-exists-matches-graphql" \
  "GraphQL: A pull request already exists for org:agent/1-x. (createPullRequest)" 0
run_already_exists_matcher_test "already-exists-matches-gitlab-409" \
  'GitLab API error (HTTP 409): Another open merge request already exists for this source branch: !1' 0
run_already_exists_matcher_test "already-exists-rejects-plain-422" \
  "HTTP 422: Validation Failed" 1
run_already_exists_matcher_test "already-exists-rejects-400" \
  "GitLab API error (HTTP 400): invalid source branch" 1

run_gh_create_pr_recover_test() {
  # shellcheck disable=SC2030,SC2031,SC2317
  local test_name="$1"
  local expect_rc="$2"
  local expect_url="$3"
  local expect_create_attempts="$4"
  local expect_list_attempts="$5"
  local list_json="$6"
  local create_errs="$7"

  local tmp mock_bin call_log rc=0 output create_attempts list_attempts
  tmp=$(mktemp -d)
  mock_bin="${tmp}/bin"
  call_log="${tmp}/calls"
  mkdir -p "${mock_bin}"
  : > "${call_log}"
  printf '%s\n' "${create_errs}" > "${tmp}/create_errs"

  cat > "${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALL_LOG}"
if printf '%s' " $*" | grep -q ' pr create '; then
  n=$(grep -c 'pr create' "${CALL_LOG}" 2>/dev/null || true)
  err=$(sed -n "${n}p" "${CREATE_ERRS_FILE}" 2>/dev/null || true)
  if [ -n "${err}" ]; then
    echo "${err}" >&2
    exit 1
  fi
  echo "https://github.com/org/repo/pull/1"
  exit 0
fi
if printf '%s' " $*" | grep -q ' pr list '; then
  printf '%s\n' "${LIST_JSON}"
  exit 0
fi
exit 0
MOCK
  chmod +x "${mock_bin}/gh"

  output=$(
    # shellcheck disable=SC2030,SC2031,SC2317
    {
      unset GITHUB_CODE_OPS_SH_LOADED
      unset FORGE_TRANSIENT_RETRY_SH_LOADED
      # shellcheck disable=SC1091
      source "${SCRIPT_DIR}/lib/github-code-ops.lib.sh"
      sleep() { :; }
      export REPO_FULL_NAME="org/repo"
      export FORGE_TRANSIENT_RETRY_BASE_DELAY=0
      export CALL_LOG="${call_log}"
      export CREATE_ERRS_FILE="${tmp}/create_errs"
      export LIST_JSON="${list_json}"
      export PATH="${mock_bin}:${PATH}"
      forge_create_pr "main" "agent/1-x" "title" "body"
    } 2>&1
  ) || rc=$?

  create_attempts=$(grep -c 'pr create' "${call_log}" || true)
  list_attempts=$(grep -c 'pr list' "${call_log}" || true)

  if [ "${rc}" -ne "${expect_rc}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected rc ${expect_rc}, got ${rc}"
    echo "  output: ${output}"
    echo "  calls:"
    cat "${call_log}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ "${create_attempts}" -ne "${expect_create_attempts}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected ${expect_create_attempts} gh pr create attempts, got ${create_attempts}"
    echo "  calls:"
    cat "${call_log}"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ "${list_attempts}" -ne "${expect_list_attempts}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected ${expect_list_attempts} gh pr list attempts, got ${list_attempts}"
    echo "  calls:"
    cat "${call_log}"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ -n "${expect_url}" ]; then
    if ! echo "${output}" | grep -qF "${expect_url}"; then
      echo "FAIL: ${test_name}"
      echo "  expected URL '${expect_url}'"
      echo "  output: ${output}"
      FAILURES=$((FAILURES + 1))
      rm -rf "${tmp}"
      return
    fi
  fi
  if [ "${expect_list_attempts}" -gt 0 ]; then
    if ! grep -q -- '--head agent/1-x' "${call_log}" || ! grep -q -- '--base main' "${call_log}"; then
      echo "FAIL: ${test_name}"
      echo "  expected gh pr list --head agent/1-x --base main"
      echo "  calls:"
      cat "${call_log}"
      FAILURES=$((FAILURES + 1))
      rm -rf "${tmp}"
      return
    fi
  fi

  echo "PASS: ${test_name}"
  rm -rf "${tmp}"
}

GH_MATCHING_PR='[{"number":99,"url":"https://github.com/org/repo/pull/99","headRepositoryOwner":{"login":"org"},"headRefName":"agent/1-x","baseRefName":"main"}]'
GH_WRONG_HEAD='[{"number":99,"url":"https://github.com/org/repo/pull/99","headRepositoryOwner":{"login":"org"},"headRefName":"agent/other","baseRefName":"main"}]'
GH_WRONG_BASE='[{"number":99,"url":"https://github.com/org/repo/pull/99","headRepositoryOwner":{"login":"org"},"headRefName":"agent/1-x","baseRefName":"develop"}]'
GH_FORK_PR='[{"number":99,"url":"https://github.com/org/repo/pull/99","headRepositoryOwner":{"login":"forker"},"headRefName":"agent/1-x","baseRefName":"main"}]'
GH_TWO_PRS='[{"number":98,"url":"https://github.com/org/repo/pull/98","headRepositoryOwner":{"login":"org"},"headRefName":"agent/1-x","baseRefName":"main"},{"number":99,"url":"https://github.com/org/repo/pull/99","headRepositoryOwner":{"login":"org"},"headRefName":"agent/1-x","baseRefName":"main"}]'

run_gh_create_pr_recover_test "create-pr-timeout-then-already-exists-recovers" \
  0 "https://github.com/org/repo/pull/99" 2 1 \
  "${GH_MATCHING_PR}" \
  $'operation timed out\na pull request already exists for org:agent/1-x'

run_gh_create_pr_recover_test "create-pr-already-exists-no-match-fails" \
  1 "could not be resolved" 1 1 \
  "[]" \
  'a pull request already exists for org:agent/1-x'

run_gh_create_pr_recover_test "create-pr-already-exists-wrong-head-not-adopted" \
  1 "could not be resolved" 1 1 \
  "${GH_WRONG_HEAD}" \
  'a pull request already exists for org:agent/1-x'

run_gh_create_pr_recover_test "create-pr-already-exists-wrong-base-not-adopted" \
  1 "could not be resolved" 1 1 \
  "${GH_WRONG_BASE}" \
  'a pull request already exists for org:agent/1-x'

run_gh_create_pr_recover_test "create-pr-already-exists-fork-not-adopted" \
  1 "could not be resolved" 1 1 \
  "${GH_FORK_PR}" \
  'a pull request already exists for org:agent/1-x'

run_gh_create_pr_recover_test "create-pr-already-exists-multiple-fails" \
  1 "could not be resolved" 1 1 \
  "${GH_TWO_PRS}" \
  'a pull request already exists for org:agent/1-x'

run_gh_create_pr_recover_test "create-pr-plain-422-does-not-list" \
  1 "" 1 0 \
  "${GH_MATCHING_PR}" \
  "HTTP 422: Validation Failed"

run_gl_create_pr_recover_test() {
  # shellcheck disable=SC2030,SC2031,SC2317
  local test_name="$1"
  local expect_rc="$2"
  local expect_url="$3"
  local expect_post_attempts="$4"
  local expect_get_attempts="$5"
  local list_json="$6"
  local error_msg="$7"

  local tmp call_log rc=0 output post_attempts get_attempts
  tmp=$(mktemp -d)
  call_log="${tmp}/calls"
  : > "${call_log}"

  output=$(
    # shellcheck disable=SC2030,SC2031,SC2317
    {
      unset GITLAB_CODE_OPS_SH_LOADED
      unset GITLAB_HOST_VALIDATION_SH_LOADED
      unset FORGE_TRANSIENT_RETRY_SH_LOADED
      # shellcheck disable=SC1091
      source "${SCRIPT_DIR}/lib/gitlab-code-ops.lib.sh"
      sleep() { :; }
      export CALL_LOG="${call_log}"
      export ERROR_MSG="${error_msg}"
      export LIST_JSON="${list_json}"
      export FORGE_TRANSIENT_RETRY_BASE_DELAY=0
      export REPO_ENCODED="group%2Fproject"
      _gitlab_code_api_with_status() {
        local method="$1"
        local endpoint="$2"
        printf '%s %s\n' "${method}" "${endpoint}" >> "${CALL_LOG}"
        if [ "${method}" = "POST" ]; then
          echo "${ERROR_MSG}" >&2
          return 1
        fi
        if [[ "${endpoint}" == *"/merge_requests?"* ]]; then
          printf '%s\n' "${LIST_JSON}"
          return 0
        fi
        if [ "${endpoint}" = "/projects/${REPO_ENCODED}" ]; then
          echo '{"id":42}'
          return 0
        fi
        echo "unexpected GitLab endpoint ${endpoint}" >&2
        return 1
      }
      forge_create_pr "main" "agent/1-x" "title" "body"
    } 2>&1
  ) || rc=$?

  post_attempts=$(grep -c '^POST ' "${call_log}" || true)
  get_attempts=$(grep -c '^GET ' "${call_log}" || true)

  if [ "${rc}" -ne "${expect_rc}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected rc ${expect_rc}, got ${rc}"
    echo "  output: ${output}"
    echo "  calls:"
    cat "${call_log}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ "${post_attempts}" -ne "${expect_post_attempts}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected ${expect_post_attempts} GitLab POSTs, got ${post_attempts}"
    echo "  calls:"
    cat "${call_log}"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ "${get_attempts}" -ne "${expect_get_attempts}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected ${expect_get_attempts} GitLab GETs, got ${get_attempts}"
    echo "  calls:"
    cat "${call_log}"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    rm -rf "${tmp}"
    return
  fi
  if [ -n "${expect_url}" ]; then
    if ! echo "${output}" | grep -qF "${expect_url}"; then
      echo "FAIL: ${test_name}"
      echo "  expected '${expect_url}'"
      echo "  output: ${output}"
      FAILURES=$((FAILURES + 1))
      rm -rf "${tmp}"
      return
    fi
  fi

  echo "PASS: ${test_name}"
  rm -rf "${tmp}"
}

GL_MATCHING_MR='[{"iid":1,"web_url":"https://gitlab.com/group/project/-/merge_requests/1","source_project_id":42,"source_branch":"agent/1-x","target_branch":"main"}]'
GL_WRONG_TARGET='[{"iid":1,"web_url":"https://gitlab.com/group/project/-/merge_requests/1","source_project_id":42,"source_branch":"agent/1-x","target_branch":"develop"}]'
GL_FORK_MR='[{"iid":1,"web_url":"https://gitlab.com/group/project/-/merge_requests/1","source_project_id":99,"source_branch":"agent/1-x","target_branch":"main"}]'
GL_409='GitLab API error (HTTP 409): Another open merge request already exists for this source branch: !1'

run_gl_create_pr_recover_test "gitlab-create-pr-409-recovers" \
  0 "https://gitlab.com/group/project/-/merge_requests/1" 1 2 \
  "${GL_MATCHING_MR}" \
  "${GL_409}"

run_gl_create_pr_recover_test "gitlab-create-pr-409-no-match-fails" \
  1 "could not be resolved" 1 2 \
  "[]" \
  "${GL_409}"

run_gl_create_pr_recover_test "gitlab-create-pr-409-wrong-target-not-adopted" \
  1 "could not be resolved" 1 2 \
  "${GL_WRONG_TARGET}" \
  "${GL_409}"

run_gl_create_pr_recover_test "gitlab-create-pr-409-fork-not-adopted" \
  1 "could not be resolved" 1 2 \
  "${GL_FORK_MR}" \
  "${GL_409}"

run_gl_create_pr_recover_test "gitlab-create-pr-400-does-not-list" \
  1 "" 1 0 \
  "${GL_MATCHING_MR}" \
  "GitLab API error (HTTP 400): invalid source branch"

# --- Summary ---

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
