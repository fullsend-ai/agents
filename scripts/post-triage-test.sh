#!/usr/bin/env bash
# post-triage-test.sh — Test post-triage.sh with fixture JSON inputs.
#
# Uses a mock gh command to capture calls without hitting GitHub.
# Run from the repo root: bash scripts/post-triage-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST_SCRIPT="${SCRIPT_DIR}/post-triage.sh"
FAILURES=0

# Create a temp directory for test fixtures and mock state.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# Mock gh: record all calls to a log file.
GH_LOG="${TMPDIR}/gh-calls.log"
MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/gh" <<MOCKEOF
#!/usr/bin/env bash
# When querying the repo labels list, return a set of known test labels so that
# the label-existence guard in post-triage.sh allows them through.
if [[ "\$1" == "api" ]] && [[ "\$2" == *"/labels" ]] && [[ "\$*" == *"--paginate"* ]] && [[ "\$*" != *"-f "* ]] && [[ "\$*" != *"-X "* ]]; then
  # Return labels used by the test fixtures, one per line (--jq '.[].name').
  printf '%s\n' "area/api" "area/cli" "priority/high" "component/parser" "enhancement" "bug" "documentation" "pr-open"
  exit 0
fi
# For issue create, return a fake URL on stdout so callers can capture it.
if [[ "\$1" == "issue" ]] && [[ "\$2" == "create" ]]; then
  echo "gh \$*" >> "${GH_LOG}"
  echo "https://github.com/mock-org/mock-repo/issues/999"
  exit 0
fi
# Capture stdin when --body-file - is used (e.g., gh issue comment).
if echo "\$*" | grep -q -- "--body-file -"; then
  BODY=\$(cat)
  echo "gh \$* <<BODY:\${BODY}:BODY>>" >> "${GH_LOG}"
else
  echo "gh \$*" >> "${GH_LOG}"
fi
MOCKEOF
chmod +x "${MOCK_BIN}/gh"

cat > "${MOCK_BIN}/fullsend" <<MOCKEOF
#!/usr/bin/env bash
BODY=""
PREV=""
for arg in "\$@"; do
  if [[ "\${arg}" == "-" ]] && [[ "\${PREV}" == "--result" ]]; then
    BODY=\$(cat)
  fi
  PREV="\${arg}"
done
if [[ -n "\${BODY}" ]]; then
  echo "fullsend \$* <<BODY:\${BODY}:BODY>>" >> "${GH_LOG}"
else
  echo "fullsend \$*" >> "${GH_LOG}"
fi
MOCKEOF
chmod +x "${MOCK_BIN}/fullsend"

export PATH="${MOCK_BIN}:${PATH}"
export GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
export GH_TOKEN="fake-token"
# Harness defaults — post-triage.sh expects these from the harness env.
export TRIAGE_AUTO_CODE="on"
export TRIAGE_AUTO_CODE_CATEGORIES="bug,documentation,performance"

# prerequisites handler reads config.yaml from GITHUB_WORKSPACE.
# Create a minimal workspace with an allowlist so the test can exercise
# both the allowed and disallowed paths.
WORKSPACE="${TMPDIR}/workspace"
mkdir -p "${WORKSPACE}"
cat > "${WORKSPACE}/config.yaml" <<CFGEOF
version: "1"
create_issues:
  allow_targets:
    orgs:
      - test-org
    repos:
      - allowed-org/allowed-repo
CFGEOF
export GITHUB_WORKSPACE="${WORKSPACE}"

run_test() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"
  local expect_failure="${4:-false}"

  # Create iteration output structure.
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"

  # Clear gh call log.
  : > "${GH_LOG}"

  # Run the post-script.
  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure, got exit code ${exit_code})"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — expected gh call pattern '${expected_pattern}' not found"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_stdout() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Test cases ---

run_test "insufficient-uses-plain-comment" \
  '{"action":"insufficient","reasoning":"missing repro","clarity_scores":{"symptom":0.6,"cause":0.3,"reproduction":0.1,"impact":0.5,"overall":0.39},"comment":"Could you share the exact steps to reproduce this?"}' \
  "gh issue comment 42 --repo test-org/test-repo --body-file -"

run_test "insufficient-posts-comment-and-labels" \
  '{"action":"insufficient","reasoning":"missing repro","clarity_scores":{"symptom":0.6,"cause":0.3,"reproduction":0.1,"impact":0.5,"overall":0.39},"comment":"Could you share the exact steps to reproduce this?"}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=needs-info --silent"

run_test "insufficient-removes-blocked-label" \
  '{"action":"insufficient","reasoning":"missing repro","clarity_scores":{"symptom":0.6,"cause":0.3,"reproduction":0.1,"impact":0.5,"overall":0.39},"comment":"Could you share the exact steps to reproduce this?"}' \
  "gh api repos/test-org/test-repo/issues/42/labels/blocked -X DELETE --silent"

run_test "insufficient-removes-pr-open-label" \
  '{"action":"insufficient","reasoning":"missing repro","clarity_scores":{"symptom":0.6,"cause":0.3,"reproduction":0.1,"impact":0.5,"overall":0.39},"comment":"Could you share the exact steps to reproduce this?"}' \
  "gh api repos/test-org/test-repo/issues/42/labels/pr-open -X DELETE --silent"

run_test "sufficient-posts-summary-and-labels" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash on save","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_save_crash"},"comment":"## Triage Summary\n\nThis is ready."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent"

run_test "sufficient-bug-gets-ready-to-code" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash on save","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_save_crash"},"comment":"## Triage Summary\n\nThis is ready."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent"

run_test "sufficient-bug-gets-bug-label" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash on save","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_save_crash"},"comment":"## Triage Summary\n\nThis is ready."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=bug --silent"

run_test "sufficient-feature-gets-triaged" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Add dark mode","severity":"medium","category":"feature","problem":"No dark mode","root_cause_hypothesis":"Not implemented","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Add theme toggle","proposed_test_case":"test_dark_mode"},"comment":"## Triage Summary\n\nThis is a feature."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent"

run_test "sufficient-feature-gets-feature-label" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Add dark mode","severity":"medium","category":"feature","problem":"No dark mode","root_cause_hypothesis":"Not implemented","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Add theme toggle","proposed_test_case":"test_dark_mode"},"comment":"## Triage Summary\n\nThis is a feature."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=feature --silent"

run_test "sufficient-other-gets-triaged" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Misc","severity":"low","category":"other","problem":"Misc","root_cause_hypothesis":"Unclear","reproduction_steps":["step 1"],"environment":"Linux","impact":"Some","recommended_fix":"Investigate","proposed_test_case":"test_misc"},"comment":"## Triage Summary\n\nMisc."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent"

run_test "sufficient-performance-gets-ready-to-code" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Slow query","severity":"medium","category":"performance","problem":"Slow","root_cause_hypothesis":"Missing index","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Add index","proposed_test_case":"test_query_speed"},"comment":"## Triage Summary\n\nThis is a performance issue."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent"

run_test "sufficient-documentation-gets-ready-to-code" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Update docs","severity":"low","category":"documentation","problem":"Outdated docs","root_cause_hypothesis":"Not updated","reproduction_steps":["step 1"],"environment":"Linux","impact":"Contributors","recommended_fix":"Update README","proposed_test_case":"test_docs"},"comment":"## Triage Summary\n\nThis is a documentation issue."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent"

run_test "sufficient-documentation-gets-documentation-label" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Update docs","severity":"low","category":"documentation","problem":"Outdated docs","root_cause_hypothesis":"Not updated","reproduction_steps":["step 1"],"environment":"Linux","impact":"Contributors","recommended_fix":"Update README","proposed_test_case":"test_docs"},"comment":"## Triage Summary\n\nThis is a documentation issue."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=documentation --silent"

run_test "sufficient-with-empty-info-gaps-passes" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash on save","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_save_crash","information_gaps":[]},"comment":"## Triage Summary\n\nThis is ready."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent"

run_test "sufficient-with-info-gaps-fails" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash on save","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_save_crash","information_gaps":["What label naming convention to use?"]},"comment":"## Triage Summary\n\nThis is ready."}' \
  "" \
  "true"

run_test "sufficient-appends-action-hints-footer" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash on save","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_save_crash"},"comment":"## Triage Summary\n\nThis is ready."}' \
  "/fs-code"

run_test "sufficient-removes-blocked-label" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash on save","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_save_crash","information_gaps":[]},"comment":"## Triage Summary\n\nThis is ready."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/blocked -X DELETE --silent"

run_test "sufficient-removes-needs-info-label" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash on save","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_save_crash","information_gaps":[]},"comment":"## Triage Summary\n\nThis is ready."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/needs-info -X DELETE --silent"

run_test "sufficient-removes-pr-open-label" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash on save","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_save_crash","information_gaps":[]},"comment":"## Triage Summary\n\nThis is ready."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/pr-open -X DELETE --silent"

run_test "duplicate-labels" \
  '{"action":"duplicate","reasoning":"same as #10","duplicate_of":10,"comment":"This appears to be a duplicate of #10."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=duplicate --silent"

run_test "duplicate-removes-blocked-label" \
  '{"action":"duplicate","reasoning":"same as #10","duplicate_of":10,"comment":"This appears to be a duplicate of #10."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/blocked -X DELETE --silent"

run_test "duplicate-removes-pr-open-label" \
  '{"action":"duplicate","reasoning":"same as #10","duplicate_of":10,"comment":"This appears to be a duplicate of #10."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/pr-open -X DELETE --silent"

run_test "duplicate-closes-issue" \
  '{"action":"duplicate","reasoning":"same as #10","duplicate_of":10,"comment":"This appears to be a duplicate of #10."}' \
  "gh issue close 42 --repo test-org/test-repo --reason duplicate"

run_test "duplicate-self-reference-fails" \
  '{"action":"duplicate","reasoning":"same issue","duplicate_of":42,"comment":"Duplicate of itself."}' \
  "" \
  "true"

run_test "prerequisites-posts-comment-and-labels" \
  '{"action":"prerequisites","reasoning":"needs upstream fix","prerequisites":{"existing":[{"url":"https://github.com/other-org/other-repo/issues/99"}],"create":[]},"comment":"This issue is blocked on an upstream dependency."}' \
  "gh issue comment 42 --repo test-org/test-repo --body-file -"

run_test "prerequisites-applies-blocked-label" \
  '{"action":"prerequisites","reasoning":"needs upstream fix","prerequisites":{"existing":[{"url":"https://github.com/other-org/other-repo/issues/99"}],"create":[]},"comment":"This issue is blocked on an upstream dependency."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=blocked --silent"

run_test "prerequisites-removes-pr-open-label" \
  '{"action":"prerequisites","reasoning":"needs upstream fix","prerequisites":{"existing":[{"url":"https://github.com/other-org/other-repo/issues/99"}],"create":[]},"comment":"This issue is blocked on an upstream dependency."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/pr-open -X DELETE --silent"

run_test "prerequisites-missing-comment-fails" \
  '{"action":"prerequisites","reasoning":"needs upstream fix","prerequisites":{"existing":[{"url":"https://github.com/other-org/other-repo/issues/99"}],"create":[]}}' \
  "" \
  "true"

run_test "prerequisites-creates-allowed-issue" \
  '{"action":"prerequisites","reasoning":"needs upstream fix","prerequisites":{"existing":[],"create":[{"repo":"allowed-org/allowed-repo","title":"Need X","body":"We need X for downstream."}]},"comment":"Blocked on upstream work."}' \
  "gh issue create --repo allowed-org/allowed-repo --title Need X --body We need X for downstream."

run_test_stdout "prerequisites-skips-disallowed-target" \
  '{"action":"prerequisites","reasoning":"needs upstream fix","prerequisites":{"existing":[],"create":[{"repo":"disallowed-org/other-repo","title":"Need Y","body":"We need Y."}]},"comment":"Blocked on upstream work."}' \
  "::warning::Skipping issue creation in 'disallowed-org/other-repo'"

# Verify prerequisites handler works without GITHUB_WORKSPACE set (local execution).
# Temporarily unset GITHUB_WORKSPACE to exercise the :-/tmp fallback guard (#2458).
# The script must not crash with an unbound variable error under set -u.
unset GITHUB_WORKSPACE
run_test "prerequisites-no-github-workspace-fallback" \
  '{"action":"prerequisites","reasoning":"needs upstream fix","prerequisites":{"existing":[{"url":"https://github.com/other-org/other-repo/issues/99"}],"create":[]},"comment":"This issue is blocked on an upstream dependency."}' \
  "gh issue comment 42 --repo test-org/test-repo --body-file -"
export GITHUB_WORKSPACE="${WORKSPACE}"

run_test "in-progress-posts-sticky-comment" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"}],"comment":"An open PR is already addressing this issue."}' \
  "fullsend post-comment --repo test-org/test-repo --number 42 --marker <!-- fullsend:triage-in-progress -->"

run_test "in-progress-applies-pr-open-label" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"}],"comment":"An open PR is already addressing this issue."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=pr-open --silent"

run_test "in-progress-removes-blocked-label" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"}],"comment":"An open PR is already addressing this issue."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/blocked -X DELETE --silent"

run_test "in-progress-removes-ready-to-code-label" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"}],"comment":"An open PR is already addressing this issue."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/ready-to-code -X DELETE --silent"

run_test "in-progress-removes-needs-info-label" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"}],"comment":"An open PR is already addressing this issue."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/needs-info -X DELETE --silent"

run_test "in-progress-appends-pr-links" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"}],"comment":"An open PR is already addressing this issue."}' \
  "Addressed by:"

run_test "in-progress-multiple-prs-both-linked" \
  '{"action":"in-progress","reasoning":"PR #50 and #51 together fix the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"},{"url":"https://github.com/test-org/test-repo/pull/51"}],"comment":"Open PRs are already addressing this issue."}' \
  "- https://github.com/test-org/test-repo/pull/50"

run_test "in-progress-multiple-prs-second-linked" \
  '{"action":"in-progress","reasoning":"PR #50 and #51 together fix the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"},{"url":"https://github.com/test-org/test-repo/pull/51"}],"comment":"Open PRs are already addressing this issue."}' \
  "- https://github.com/test-org/test-repo/pull/51"

run_test "in-progress-creates-pr-open-label" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"}],"comment":"An open PR is already addressing this issue."}' \
  "gh label create pr-open --repo test-org/test-repo --description An open PR already addresses this issue --color D4C5F9 --force"

run_test "in-progress-missing-comment-fails" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"}]}' \
  "" \
  "true"

run_test "in-progress-empty-pull-requests-fails" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[],"comment":"An open PR is already addressing this issue."}' \
  "" \
  "true"

run_test "in-progress-missing-pull-requests-fails" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","comment":"An open PR is already addressing this issue."}' \
  "" \
  "true"

run_test "in-progress-malformed-pull-requests-fails" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":["https://github.com/test-org/test-repo/pull/50"],"comment":"An open PR is already addressing this issue."}' \
  "" \
  "true"

run_test "in-progress-null-url-fails" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[{"url":null}],"comment":"An open PR is already addressing this issue."}' \
  "" \
  "true"

run_test_stdout "in-progress-warns-on-dropped-prerequisites" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"}],"prerequisites":{"existing":[{"url":"https://github.com/other-org/other-repo/issues/99"}],"create":[]},"comment":"An open PR is already addressing this issue."}' \
  "::warning::Ignoring 'prerequisites' on an 'in-progress' result"

run_test_stdout "in-progress-control-label-refused" \
  '{"action":"in-progress","reasoning":"PR #50 fixes the reported bug","pull_requests":[{"url":"https://github.com/test-org/test-repo/pull/50"}],"comment":"An open PR is already addressing this issue.","label_actions":{"reason":"Tried to set pr-open label.","actions":[{"action":"add","label":"pr-open"}]}}' \
  "::warning::Refused to add control label 'pr-open' -- control labels are managed by the triage pipeline"

run_test "question-posts-comment" \
  '{"action":"question","reasoning":"issue is asking a question","comment":"Based on the repository docs, Python 4 is not currently supported.\n\nDid this answer your question, or would you like to open a feature request for Python 4 support?"}' \
  "gh issue comment 42 --repo test-org/test-repo --body-file -"

run_test "question-applies-question-label" \
  '{"action":"question","reasoning":"issue is asking a question","comment":"Based on the repository docs, Python 4 is not currently supported.\n\nDid this answer your question, or would you like to open a feature request for Python 4 support?"}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=question --silent"

run_test "question-removes-blocked-label" \
  '{"action":"question","reasoning":"issue is asking a question","comment":"Based on the repository docs, Python 4 is not currently supported."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/blocked -X DELETE --silent"

run_test "question-removes-needs-info-label" \
  '{"action":"question","reasoning":"issue is asking a question","comment":"Based on the repository docs, Python 4 is not currently supported."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/needs-info -X DELETE --silent"

run_test "question-removes-pr-open-label" \
  '{"action":"question","reasoning":"issue is asking a question","comment":"Based on the repository docs, Python 4 is not currently supported."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/pr-open -X DELETE --silent"

run_test "question-missing-comment-fails" \
  '{"action":"question","reasoning":"issue is asking a question"}' \
  "" \
  "true"

run_test "not-planned-posts-comment" \
  '{"action":"not-planned","reasoning":"out of scope","comment":"This request is out of scope for the project goals. See docs/scope.md for more details."}' \
  "gh issue comment 42 --repo test-org/test-repo --body-file -"

run_test "not-planned-applies-label" \
  '{"action":"not-planned","reasoning":"out of scope","comment":"This request is out of scope for the project goals."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=not-planned --silent"

run_test "not-planned-removes-blocked-label" \
  '{"action":"not-planned","reasoning":"out of scope","comment":"This request is out of scope."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/blocked -X DELETE --silent"

run_test "not-planned-removes-needs-info-label" \
  '{"action":"not-planned","reasoning":"out of scope","comment":"This request is out of scope."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/needs-info -X DELETE --silent"

run_test "not-planned-removes-pr-open-label" \
  '{"action":"not-planned","reasoning":"out of scope","comment":"This request is out of scope."}' \
  "gh api repos/test-org/test-repo/issues/42/labels/pr-open -X DELETE --silent"

run_test "not-planned-closes-issue" \
  '{"action":"not-planned","reasoning":"out of scope","comment":"This request is out of scope for the project goals."}' \
  "gh issue close 42 --repo test-org/test-repo --reason not planned"

run_test "not-planned-missing-comment-fails" \
  '{"action":"not-planned","reasoning":"out of scope"}' \
  "" \
  "true"

run_test_stdout "question-control-label-refused" \
  '{"action":"question","reasoning":"issue is asking a question","comment":"Answer here.","label_actions":{"reason":"Tried to set question label.","actions":[{"action":"add","label":"question"}]}}' \
  "::warning::Refused to add control label 'question' -- control labels are managed by the triage pipeline"

run_test "unknown-action-fails" \
  '{"action":"not_a_bug","reasoning":"working as intended","comment":"This is working as intended."}' \
  "" \
  "true"

run_test "missing-json-fails" \
  "" \
  "" \
  "true"

run_test "invalid-json-fails" \
  "this is not json" \
  "" \
  "true"

run_test "label-actions-applied" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"API crash matches area/api label.","actions":[{"action":"add","label":"area/api"}]}}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=area/api --silent"

run_test_stdout "label-actions-control-label-refused" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"Tried to set control label.","actions":[{"action":"add","label":"ready-to-code"}]}}' \
  "::warning::Refused to add control label 'ready-to-code' -- control labels are managed by the triage pipeline"

run_test_stdout "label-actions-feature-control-label-refused" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"Tried to set feature label.","actions":[{"action":"add","label":"feature"}]}}' \
  "::warning::Refused to add control label 'feature' -- control labels are managed by the triage pipeline"

run_test_stdout "label-actions-not-planned-control-label-refused" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"Tried to set not-planned label.","actions":[{"action":"add","label":"not-planned"}]}}' \
  "::warning::Refused to add control label 'not-planned' -- control labels are managed by the triage pipeline"

run_test "label-actions-absent-still-posts-comment" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady."}' \
  "fullsend post-comment --repo test-org/test-repo --number 42 --marker <!-- fullsend:triage-agent -->"

run_test "label-actions-with-insufficient" \
  '{"action":"insufficient","reasoning":"missing repro","clarity_scores":{"symptom":0.6,"cause":0.3,"reproduction":0.1,"impact":0.5,"overall":0.39},"comment":"Could you share the exact steps to reproduce this?","label_actions":{"reason":"Component label applies regardless of triage outcome.","actions":[{"action":"add","label":"component/parser"}]}}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=component/parser --silent"

run_test "label-actions-reason-appended-to-comment" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"API crash matches area/api label.","actions":[{"action":"add","label":"area/api"}]}}' \
  "API crash matches area/api label."

run_test "label-actions-remove" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"Stale area label removed.","actions":[{"action":"remove","label":"area/cli"}]}}' \
  "gh api repos/test-org/test-repo/issues/42/labels/area%2Fcli -X DELETE --silent"

run_test "label-actions-multiple-add" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"Multiple labels apply.","actions":[{"action":"add","label":"area/api"},{"action":"add","label":"priority/high"}]}}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=area/api --silent"

run_test "label-actions-multiple-second-label" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"Multiple labels apply.","actions":[{"action":"add","label":"area/api"},{"action":"add","label":"priority/high"}]}}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=priority/high --silent"

run_test_stdout "label-actions-nonexistent-label-skipped" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"Agent recommended a label that does not exist.","actions":[{"action":"add","label":"nonexistent-label"}]}}' \
  "::warning::Skipping label 'nonexistent-label' -- does not exist in repo (will not auto-create)"

run_test_stdout "label-actions-invalid-characters-refused" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"Injection attempt.","actions":[{"action":"add","label":"label;injection"}]}}' \
  "::warning::Refused label 'label;injection' -- contains invalid characters"

# Verify that when all label actions are refused, the reason is NOT appended to the comment.
# We check that the fullsend call does NOT contain "Labels:" in the body.
run_test_no_pattern() {
  local test_name="$1"
  local json_content="$2"
  local forbidden_pattern="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF -- "${forbidden_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — forbidden pattern '${forbidden_pattern}' was found"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_no_pattern "label-actions-all-refused-no-reason" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"Should not appear.","actions":[{"action":"add","label":"ready-to-code"}]}}' \
  "Should not appear."

# run_test_label_order verifies that a pattern appears AFTER another pattern
# in the gh call log (i.e., ordering of API calls).
run_test_label_order() {
  local test_name="$1"
  local json_content="$2"
  local before_pattern="$3"
  local after_pattern="$4"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local before_line after_line
  before_line=$(grep -nF -- "${before_pattern}" "${GH_LOG}" | head -1 | cut -d: -f1)
  after_line=$(grep -nF -- "${after_pattern}" "${GH_LOG}" | head -1 | cut -d: -f1)

  if [[ -z "${before_line}" ]]; then
    echo "FAIL: ${test_name} — before pattern '${before_pattern}' not found"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -z "${after_line}" ]]; then
    echo "FAIL: ${test_name} — after pattern '${after_pattern}' not found"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ "${before_line}" -ge "${after_line}" ]]; then
    echo "FAIL: ${test_name} — '${before_pattern}' (line ${before_line}) should appear before '${after_pattern}' (line ${after_line})"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Verify ready-to-code is applied AFTER informational labels from label_actions
# to prevent the ready-to-code webhook event from being superseded (#1752).
run_test_label_order "ready-to-code-applied-after-label-actions" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"Component label.","actions":[{"action":"add","label":"area/api"},{"action":"add","label":"priority/high"}]}}' \
  "labels[]=priority/high" \
  "labels[]=ready-to-code"

# Verify ready-to-code is still applied when there are no label_actions.
run_test "ready-to-code-applied-without-label-actions" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent"

# Verify label-category consistency guard strips contradicting labels (#39).
run_test_stdout "label-category-contradiction-stripped" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Update docs","severity":"low","category":"documentation","problem":"Outdated docs","root_cause_hypothesis":"Not updated","reproduction_steps":["step 1"],"environment":"Linux","impact":"Contributors","recommended_fix":"Update README","proposed_test_case":"test_docs"},"comment":"## Triage Summary\n\nDocs issue.","label_actions":{"reason":"Reclassifying to enhancement.","actions":[{"action":"add","label":"enhancement"}]}}' \
  "::warning::Stripping label 'enhancement' from label_actions — contradicts triage_summary.category 'documentation'"

# Verify non-contradicting labels pass through the consistency guard.
run_test "label-category-consistent-passes" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady.","label_actions":{"reason":"Area label applies.","actions":[{"action":"add","label":"area/api"}]}}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=area/api --silent"

# ---------------------------------------------------------------------------
# FULLSEND_VALIDATED_ITERATION_DIR tests
# Verify that when FULLSEND_VALIDATED_ITERATION_DIR is set, the script reads
# from that directory instead of scanning iteration-*/output.
# ---------------------------------------------------------------------------

# Minimal sufficient fixture for validated-dir tests.
VALIDATED_DIR_FIXTURE='{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady."}'

run_validated_dir_test() {
  local test_name="$1"
  local validated_dir_file="$2"   # "agent-result.json", "result.json", or "none"
  local expected_pattern="$3"
  local expect_failure="${4:-false}"

  local run_dir="${TMPDIR}/run-${test_name}"
  local validated_dir="${run_dir}/validated-output"
  mkdir -p "${validated_dir}"

  # Place the fixture in the validated dir under the specified filename.
  if [[ "${validated_dir_file}" != "none" ]]; then
    echo "${VALIDATED_DIR_FIXTURE}" > "${validated_dir}/${validated_dir_file}"
  fi

  # Also place a DIFFERENT result in iteration-2 to verify it's NOT used
  # when the validated dir is set.
  mkdir -p "${run_dir}/iteration-2/output"
  echo '{"action":"not_a_bug","reasoning":"wrong","comment":"Should not be used."}' \
    > "${run_dir}/iteration-2/output/agent-result.json"

  : > "${GH_LOG}"

  local exit_code=0
  (
    cd "${run_dir}"
    export FULLSEND_VALIDATED_ITERATION_DIR="${validated_dir}"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure)"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_pattern}" ]] && ! grep -qF -- "${expected_pattern}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout '${expected_pattern}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Validated dir has agent-result.json → used
run_validated_dir_test "validated-dir-expected-filename" \
  "agent-result.json" \
  "Reading triage result from: ${TMPDIR}/run-validated-dir-expected-filename/validated-output/agent-result.json"

# Validated dir has only result.json → used as fallback
run_validated_dir_test "validated-dir-fallback-filename" \
  "result.json" \
  "Reading triage result from: ${TMPDIR}/run-validated-dir-fallback-filename/validated-output/result.json"

# Validated dir has neither filename → fails closed
run_validated_dir_test "validated-dir-neither-filename" \
  "none" \
  "" \
  "true"

# --- Workflow change detection tests (#325) ---

# Bug with requires_workflow_changes=true should get triaged instead of ready-to-code.
run_test "workflow-changes-bug-gets-triaged" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix CI caching step","severity":"high","category":"bug","problem":"CI cache miss","root_cause_hypothesis":"Missing cache key","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Update workflow","proposed_test_case":"test_cache","requires_workflow_changes":true},"comment":"## Triage Summary\n\nThis requires workflow changes."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent"

# Bug with requires_workflow_changes=true should NOT get ready-to-code.
run_test_no_pattern "workflow-changes-bug-no-ready-to-code" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix CI caching step","severity":"high","category":"bug","problem":"CI cache miss","root_cause_hypothesis":"Missing cache key","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Update workflow","proposed_test_case":"test_cache","requires_workflow_changes":true},"comment":"## Triage Summary\n\nThis requires workflow changes."}' \
  "labels[]=ready-to-code"

# Documentation with requires_workflow_changes=true should get triaged instead of ready-to-code.
run_test "workflow-changes-documentation-gets-triaged" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Update CI docs","severity":"low","category":"documentation","problem":"Outdated CI docs","root_cause_hypothesis":"Not updated","reproduction_steps":["step 1"],"environment":"Linux","impact":"Contributors","recommended_fix":"Update workflow and docs","proposed_test_case":"test_docs","requires_workflow_changes":true},"comment":"## Triage Summary\n\nThis requires workflow changes."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent"

# Performance with requires_workflow_changes=true should get triaged instead of ready-to-code.
run_test "workflow-changes-performance-gets-triaged" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Speed up CI","severity":"medium","category":"performance","problem":"Slow CI","root_cause_hypothesis":"No parallelism","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Add parallel steps","proposed_test_case":"test_speed","requires_workflow_changes":true},"comment":"## Triage Summary\n\nThis requires workflow changes."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent"

# Bug without requires_workflow_changes still gets ready-to-code (regression guard).
run_test "no-workflow-flag-bug-still-gets-ready-to-code" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent"

# Bug with requires_workflow_changes=false still gets ready-to-code.
run_test "workflow-false-bug-gets-ready-to-code" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash","requires_workflow_changes":false},"comment":"## Triage Summary\n\nReady."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent"

# Workflow changes warning appears in stdout.
run_test_stdout "workflow-changes-warning-emitted" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix CI caching","severity":"high","category":"bug","problem":"CI cache miss","root_cause_hypothesis":"Missing cache key","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Update workflow","proposed_test_case":"test_cache","requires_workflow_changes":true},"comment":"## Triage Summary\n\nThis requires workflow changes."}' \
  "::warning::Triage detected workflow file changes required (#325)"

# --- TRIAGE_AUTO_CODE configuration tests (#1754) ---

# Helper: run_test with extra env vars. Accepts a 5th arg: newline-separated
# KEY=VALUE pairs exported into the post-script subshell (values may contain
# spaces).
run_test_with_env() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"
  local expect_failure="${4:-false}"
  local extra_env="$5"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  (
    cd "${run_dir}"
    # shellcheck disable=SC2163  # exporting KEY=VALUE, not the var "kv"
    while IFS= read -r kv; do [[ -n "$kv" ]] && export "$kv"; done <<< "$extra_env"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure, got exit code ${exit_code})"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — expected gh call pattern '${expected_pattern}' not found"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_unset_env() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"
  local vars_to_unset="$4"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  (
    cd "${run_dir}"
    for var in ${vars_to_unset}; do unset "${var}"; done
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — expected gh call pattern '${expected_pattern}' not found"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_stdout_with_env() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"
  local extra_env="$4"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  (
    cd "${run_dir}"
    # shellcheck disable=SC2163  # exporting KEY=VALUE, not the var "kv"
    while IFS= read -r kv; do [[ -n "$kv" ]] && export "$kv"; done <<< "$extra_env"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_no_pattern_with_env() {
  local test_name="$1"
  local json_content="$2"
  local forbidden_pattern="$3"
  local extra_env="$4"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  (
    cd "${run_dir}"
    # shellcheck disable=SC2163  # exporting KEY=VALUE, not the var "kv"
    while IFS= read -r kv; do [[ -n "$kv" ]] && export "$kv"; done <<< "$extra_env"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF -- "${forbidden_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — forbidden pattern '${forbidden_pattern}' was found"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Shared fixture: sufficient bug.
AUTO_CODE_BUG_FIXTURE='{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix crash","severity":"high","category":"bug","problem":"Crash","root_cause_hypothesis":"Buffer overflow","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Fix buffer","proposed_test_case":"test_crash"},"comment":"## Triage Summary\n\nReady."}'

# Shared fixture: sufficient documentation.
AUTO_CODE_DOCS_FIXTURE='{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Update docs","severity":"low","category":"documentation","problem":"Outdated docs","root_cause_hypothesis":"Not updated","reproduction_steps":["step 1"],"environment":"Linux","impact":"Contributors","recommended_fix":"Update README","proposed_test_case":"test_docs"},"comment":"## Triage Summary\n\nDocs issue."}'

# Shared fixture: sufficient performance.
AUTO_CODE_PERF_FIXTURE='{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Slow query","severity":"medium","category":"performance","problem":"Slow","root_cause_hypothesis":"Missing index","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Add index","proposed_test_case":"test_speed"},"comment":"## Triage Summary\n\nPerformance issue."}'

# Shared fixture: sufficient feature.
AUTO_CODE_FEATURE_FIXTURE='{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Add dark mode","severity":"medium","category":"feature","problem":"No dark mode","root_cause_hypothesis":"Not implemented","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Add theme toggle","proposed_test_case":"test_dark_mode"},"comment":"## Triage Summary\n\nFeature request."}'

# Default (unset): bug gets ready-to-code, genuinely exercising the
# ${TRIAGE_AUTO_CODE:-on} fallback (both vars unset in a subshell).
run_test_unset_env "auto-code-default-bug-gets-ready-to-code" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent" \
  "TRIAGE_AUTO_CODE TRIAGE_AUTO_CODE_CATEGORIES"

# TRIAGE_AUTO_CODE=on: bug gets ready-to-code (explicit on).
run_test_with_env "auto-code-on-bug-gets-ready-to-code" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent" \
  "false" \
  "TRIAGE_AUTO_CODE=on"

# TRIAGE_AUTO_CODE=off: bug gets triaged instead of ready-to-code.
run_test_with_env "auto-code-off-bug-gets-triaged" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent" \
  "false" \
  "TRIAGE_AUTO_CODE=off"

# TRIAGE_AUTO_CODE=off: bug does NOT get ready-to-code.
run_test_no_pattern_with_env "auto-code-off-bug-no-ready-to-code" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "labels[]=ready-to-code" \
  "TRIAGE_AUTO_CODE=off"

# TRIAGE_AUTO_CODE=off: documentation gets triaged instead of ready-to-code.
run_test_with_env "auto-code-off-docs-gets-triaged" \
  "${AUTO_CODE_DOCS_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent" \
  "false" \
  "TRIAGE_AUTO_CODE=off"

# TRIAGE_AUTO_CODE=off: performance gets triaged instead of ready-to-code.
run_test_with_env "auto-code-off-perf-gets-triaged" \
  "${AUTO_CODE_PERF_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent" \
  "false" \
  "TRIAGE_AUTO_CODE=off"

# TRIAGE_AUTO_CODE=off: feature still gets triaged (unchanged behavior).
run_test_with_env "auto-code-off-feature-gets-triaged" \
  "${AUTO_CODE_FEATURE_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent" \
  "false" \
  "TRIAGE_AUTO_CODE=off"

# TRIAGE_AUTO_CODE=off: bug still gets the bug category label.
run_test_with_env "auto-code-off-bug-still-gets-bug-label" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=bug --silent" \
  "false" \
  "TRIAGE_AUTO_CODE=off"

# TRIAGE_AUTO_CODE=off: documentation still gets the documentation label.
run_test_with_env "auto-code-off-docs-still-gets-docs-label" \
  "${AUTO_CODE_DOCS_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=documentation --silent" \
  "false" \
  "TRIAGE_AUTO_CODE=off"

# TRIAGE_AUTO_CODE=category with default categories: bug gets ready-to-code.
run_test_with_env "auto-code-category-default-bug-gets-ready-to-code" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent" \
  "false" \
  "TRIAGE_AUTO_CODE=category"

# TRIAGE_AUTO_CODE=category with only bug: bug gets ready-to-code.
run_test_with_env "auto-code-category-bug-only-bug-gets-ready-to-code" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent" \
  "false" \
  $'TRIAGE_AUTO_CODE=category\nTRIAGE_AUTO_CODE_CATEGORIES=bug'

# TRIAGE_AUTO_CODE=category with only bug: documentation gets triaged.
run_test_with_env "auto-code-category-bug-only-docs-gets-triaged" \
  "${AUTO_CODE_DOCS_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent" \
  "false" \
  $'TRIAGE_AUTO_CODE=category\nTRIAGE_AUTO_CODE_CATEGORIES=bug'

# TRIAGE_AUTO_CODE=category with only bug: docs does NOT get ready-to-code.
run_test_no_pattern_with_env "auto-code-category-bug-only-docs-no-ready-to-code" \
  "${AUTO_CODE_DOCS_FIXTURE}" \
  "labels[]=ready-to-code" \
  $'TRIAGE_AUTO_CODE=category\nTRIAGE_AUTO_CODE_CATEGORIES=bug'

# TRIAGE_AUTO_CODE=category with only documentation: performance gets triaged.
run_test_with_env "auto-code-category-docs-only-perf-gets-triaged" \
  "${AUTO_CODE_PERF_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent" \
  "false" \
  $'TRIAGE_AUTO_CODE=category\nTRIAGE_AUTO_CODE_CATEGORIES=documentation'

# TRIAGE_AUTO_CODE=category with bug,documentation: both get ready-to-code.
run_test_with_env "auto-code-category-bug-docs-bug-gets-ready-to-code" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent" \
  "false" \
  $'TRIAGE_AUTO_CODE=category\nTRIAGE_AUTO_CODE_CATEGORIES=bug,documentation'

run_test_with_env "auto-code-category-bug-docs-docs-gets-ready-to-code" \
  "${AUTO_CODE_DOCS_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent" \
  "false" \
  $'TRIAGE_AUTO_CODE=category\nTRIAGE_AUTO_CODE_CATEGORIES=bug,documentation'

# TRIAGE_AUTO_CODE=garbage: unrecognized value falls back to "on" but warns.
run_test_stdout_with_env "auto-code-unrecognized-value-warns" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "::warning::Unrecognized TRIAGE_AUTO_CODE value 'garbage' — falling back to 'on'" \
  "TRIAGE_AUTO_CODE=garbage"

# TRIAGE_AUTO_CODE=garbage: unrecognized value still gets ready-to-code (fallback behavior).
run_test_with_env "auto-code-unrecognized-value-still-ready-to-code" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent" \
  "false" \
  "TRIAGE_AUTO_CODE=garbage"

# TRIAGE_AUTO_CODE=category with uppercase category name: still matches (case-insensitive).
run_test_with_env "auto-code-category-uppercase-still-matches" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent" \
  "false" \
  $'TRIAGE_AUTO_CODE=category\nTRIAGE_AUTO_CODE_CATEGORIES=Bug,Documentation'

# TRIAGE_AUTO_CODE=off with workflow-changes: still triaged (both guards agree).
run_test_with_env "auto-code-off-with-workflow-changes-gets-triaged" \
  '{"action":"sufficient","reasoning":"all clear","clarity_scores":{"symptom":0.9,"cause":0.85,"reproduction":0.9,"impact":0.8,"overall":0.87},"triage_summary":{"title":"Fix CI","severity":"high","category":"bug","problem":"CI broken","root_cause_hypothesis":"Missing step","reproduction_steps":["step 1"],"environment":"Linux","impact":"All users","recommended_fix":"Update workflow","proposed_test_case":"test_ci","requires_workflow_changes":true},"comment":"## Triage Summary\n\nNeeds workflow changes."}' \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent" \
  "false" \
  "TRIAGE_AUTO_CODE=off"

# TRIAGE_AUTO_CODE=category: feature still gets feature+triaged (unchanged).
run_test_with_env "auto-code-category-feature-gets-feature-label" \
  "${AUTO_CODE_FEATURE_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=feature --silent" \
  "false" \
  $'TRIAGE_AUTO_CODE=category\nTRIAGE_AUTO_CODE_CATEGORIES=bug'

# TRIAGE_AUTO_CODE=category with explicit empty categories: promotes nothing.
run_test_with_env "auto-code-category-empty-string-gets-triaged" \
  "${AUTO_CODE_BUG_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=triaged --silent" \
  "false" \
  $'TRIAGE_AUTO_CODE=category\nTRIAGE_AUTO_CODE_CATEGORIES='

# TRIAGE_AUTO_CODE=category with whitespace in categories: still matches.
# Uses documentation fixture (not bug) to verify multi-item matching actually
# works — bug would match even a truncated list.
run_test_with_env "auto-code-category-whitespace-tolerant" \
  "${AUTO_CODE_DOCS_FIXTURE}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=ready-to-code --silent" \
  "false" \
  $'TRIAGE_AUTO_CODE=category\nTRIAGE_AUTO_CODE_CATEGORIES=bug, documentation, performance'

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
