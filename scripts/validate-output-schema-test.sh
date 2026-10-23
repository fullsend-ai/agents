#!/usr/bin/env bash
# validate-output-schema-test.sh — Test validate-output-schema.sh with fixtures.
#
# Run from the repo root:
#   bash scripts/validate-output-schema-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-output-schema.sh"
SCHEMA="${SCRIPT_DIR}/../schemas/triage-result.schema.json"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

run_test() {
  local test_name="$1"
  local json_content="$2"
  local expect_pass="$3"  # "true" or "false"
  local expect_output="${4:-}"  # optional: substring that must appear in stdout

  local test_dir="${TMPDIR}/${test_name}"
  mkdir -p "${test_dir}/output"
  echo "${json_content}" > "${test_dir}/output/agent-result.json"

  local exit_code=0
  FULLSEND_OUTPUT_SCHEMA="${SCHEMA}" \
    bash -c "cd '${test_dir}' && bash '${VALIDATOR}'" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  local passed=true
  if [[ "${expect_pass}" == "true" && ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected PASS but got exit ${exit_code}"
    head -10 "${TMPDIR}/stdout.log"
    passed=false
  elif [[ "${expect_pass}" == "false" && ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected FAIL but got PASS"
    passed=false
  fi

  if [[ -n "${expect_output}" ]] && ! grep -qF "${expect_output}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected output to contain: ${expect_output}"
    echo "  actual output:"
    head -10 "${TMPDIR}/stdout.log"
    passed=false
  fi

  if [[ "${passed}" == "true" ]]; then
    echo "PASS: ${test_name}"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

# --- Valid inputs ---

run_test "valid-insufficient" \
  '{"action":"insufficient","reasoning":"missing repro","clarity_scores":{"symptom":0.6,"cause":0.3,"reproduction":0.1,"impact":0.5,"overall":0.39},"comment":"Can you share repro steps?"}' \
  "true"

run_test "valid-sufficient" \
  '{"action":"sufficient","reasoning":"clear","clarity_scores":{"symptom":0.9,"cause":0.8,"reproduction":0.9,"impact":0.7,"overall":0.85},"triage_summary":{"title":"Bug","severity":"high","category":"bug","problem":"crash","root_cause_hypothesis":"null ptr","reproduction_steps":["step 1"],"impact":"all users","recommended_fix":"fix ptr","proposed_test_case":"test_fix"},"comment":"Triage complete."}' \
  "true"

run_test "valid-sufficient-promote-true" \
  '{"action":"sufficient","reasoning":"clear","clarity_scores":{"symptom":0.9,"cause":0.8,"reproduction":0.9,"impact":0.7,"overall":0.85},"triage_summary":{"title":"Bug","severity":"high","category":"bug","problem":"crash","root_cause_hypothesis":"null ptr","reproduction_steps":["step 1"],"impact":"all users","recommended_fix":"fix ptr","proposed_test_case":"test_fix","promote_to_ready_to_code":true},"comment":"Triage complete."}' \
  "true"

run_test "valid-sufficient-promote-false" \
  '{"action":"sufficient","reasoning":"clear","clarity_scores":{"symptom":0.9,"cause":0.8,"reproduction":0.9,"impact":0.7,"overall":0.85},"triage_summary":{"title":"Bug","severity":"high","category":"bug","problem":"crash","root_cause_hypothesis":"null ptr","reproduction_steps":["step 1"],"impact":"all users","recommended_fix":"fix ptr","proposed_test_case":"test_fix","promote_to_ready_to_code":false},"comment":"Triage complete."}' \
  "true"

run_test "invalid-promote-not-boolean" \
  '{"action":"sufficient","reasoning":"clear","clarity_scores":{"symptom":0.9,"cause":0.8,"reproduction":0.9,"impact":0.7,"overall":0.85},"triage_summary":{"title":"Bug","severity":"high","category":"bug","problem":"crash","root_cause_hypothesis":"null ptr","reproduction_steps":["step 1"],"impact":"all users","recommended_fix":"fix ptr","proposed_test_case":"test_fix","promote_to_ready_to_code":"yes"},"comment":"Triage complete."}' \
  "false"

run_test "valid-duplicate" \
  '{"action":"duplicate","reasoning":"same as #10","duplicate_of":10,"comment":"Duplicate of #10."}' \
  "true"

run_test "valid-question" \
  '{"action":"question","reasoning":"this is a support question","comment":"Based on the docs, Python 4 is not supported. Would you like to open a feature request?"}' \
  "true"

run_test "valid-not-planned" \
  '{"action":"not-planned","reasoning":"out of scope","comment":"This is out of scope."}' \
  "true"

run_test "valid-completed" \
  '{"action":"completed","reasoning":"all child issues are closed","comment":"All tracked work is done. Closing as completed."}' \
  "true"

run_test "valid-prerequisites-existing" \
  '{"action":"prerequisites","reasoning":"upstream dependency","prerequisites":{"existing":[{"url":"https://github.com/org/repo/issues/99"}],"create":[]},"comment":"Blocked on upstream."}' \
  "true"

run_test "valid-prerequisites-create" \
  '{"action":"prerequisites","reasoning":"needs upstream issue","prerequisites":{"existing":[],"create":[{"repo":"org/upstream","title":"Add X","body":"Need X."}]},"comment":"Blocked on upstream."}' \
  "true"

run_test "valid-in-progress" \
  '{"action":"in-progress","reasoning":"PR #123 fixes this issue","pull_requests":[{"url":"https://github.com/org/repo/pull/123"}],"comment":"An open PR already addresses this issue."}' \
  "true"

run_test "valid-split" \
  '{"action":"split","reasoning":"issue bundles independent concerns","sub_issues":[{"title":"Fix crash on save","body":"The save handler crashes when input is empty."},{"title":"Update error messages","body":"Error messages are outdated."}],"comment":"Splitting into independent sub-issues."}' \
  "true"

run_test "valid-move-without-evidence" \
  '{"action":"move","reasoning":"the affected code is maintained elsewhere","move_to":{"target":"org/other-repo"},"comment":"Moving this issue to the repository that owns the affected code."}' \
  "true"

run_test "valid-move-with-evidence" \
  '{"action":"move","reasoning":"the affected code is maintained elsewhere","move_to":{"target":"org/other-repo","evidence":["The affected package lives in org/other-repo."]},"comment":"Moving this issue to the repository that owns the affected code."}' \
  "true"

run_test "valid-move-jira-project-key" \
  '{"action":"move","reasoning":"the issue belongs to another Jira project","move_to":{"target":"OTHERPROJ"},"comment":"Moving this issue to the owning Jira project."}' \
  "true"

# --- Jira tracker shapes ---
# duplicate_of is an integer on GitHub/GitLab but a full issue key on Jira.
run_test "valid-jira-duplicate-key" \
  '{"action":"duplicate","reasoning":"same as PROJ-45","duplicate_of":"PROJ-45","comment":"Duplicate of PROJ-45."}' \
  "true"

# Jira prerequisite targets are bare project keys, not owner/name paths.
run_test "valid-jira-prerequisites-create-project-key" \
  '{"action":"prerequisites","reasoning":"needs upstream issue","prerequisites":{"existing":[{"url":"https://test.atlassian.net/browse/OTHERPROJ-7"}],"create":[{"repo":"OTHERPROJ","title":"Add X","body":"Need X."}]},"comment":"Blocked on upstream."}' \
  "true"

# Cross-project Jira sub-issues also use a bare project key in repo.
run_test "valid-jira-split-project-key" \
  '{"action":"split","reasoning":"issue bundles independent concerns","sub_issues":[{"title":"Fix crash on save","body":"The save handler crashes when input is empty."},{"repo":"OTHERPROJ","title":"Update error messages","body":"Error messages are outdated."}],"comment":"Splitting into independent sub-issues."}' \
  "true"

# --- Conditional requirement failures ---

run_test "insufficient-missing-clarity-scores" \
  '{"action":"insufficient","reasoning":"missing info","comment":"Need more info."}' \
  "false"

run_test "duplicate-missing-duplicate-of" \
  '{"action":"duplicate","reasoning":"dupe","comment":"Duplicate."}' \
  "false"

run_test "sufficient-missing-triage-summary" \
  '{"action":"sufficient","reasoning":"ok","clarity_scores":{"symptom":0.9,"cause":0.8,"reproduction":0.9,"impact":0.7,"overall":0.85},"comment":"Done."}' \
  "false"

run_test "move-missing-move-to" \
  '{"action":"move","reasoning":"owned elsewhere","comment":"Moving this issue."}' \
  "false"

run_test "move-missing-target" \
  '{"action":"move","reasoning":"owned elsewhere","move_to":{},"comment":"Moving this issue."}' \
  "false"

run_test "move-empty-target" \
  '{"action":"move","reasoning":"owned elsewhere","move_to":{"target":""},"comment":"Moving this issue."}' \
  "false"

run_test "move-url-target" \
  '{"action":"move","reasoning":"owned elsewhere","move_to":{"target":"https://github.com/org/other-repo"},"comment":"Moving this issue."}' \
  "false"

run_test "move-whitespace-target" \
  '{"action":"move","reasoning":"owned elsewhere","move_to":{"target":"   "},"comment":"Moving this issue."}' \
  "false"

run_test "move-newline-target" \
  '{"action":"move","reasoning":"owned elsewhere","move_to":{"target":"org/other-repo\n::set-output name=target::malicious"},"comment":"Moving this issue."}' \
  "false"

run_test "move-trailing-newline-target" \
  '{"action":"move","reasoning":"owned elsewhere","move_to":{"target":"org/other-repo\n"},"comment":"Moving this issue."}' \
  "false"

run_test "move-dot-segment-target" \
  '{"action":"move","reasoning":"owned elsewhere","move_to":{"target":"org/.."},"comment":"Moving this issue."}' \
  "false"

run_test "move-parent-path-target" \
  '{"action":"move","reasoning":"owned elsewhere","move_to":{"target":"../.."},"comment":"Moving this issue."}' \
  "false"

run_test "move-malformed-evidence" \
  '{"action":"move","reasoning":"owned elsewhere","move_to":{"target":"org/other-repo","evidence":["valid evidence",42]},"comment":"Moving this issue."}' \
  "false"

run_test "move-with-triage-summary-rejected" \
  '{"action":"move","reasoning":"owned elsewhere","move_to":{"target":"org/other-repo"},"triage_summary":{"title":"Bug","severity":"high","category":"bug","problem":"crash","root_cause_hypothesis":"null ptr","reproduction_steps":["step 1"],"impact":"all users","recommended_fix":"fix ptr","proposed_test_case":"test_fix","promote_to_ready_to_code":true},"comment":"Moving this issue."}' \
  "false"

run_test "prerequisites-missing-prerequisites-field" \
  '{"action":"prerequisites","reasoning":"upstream dependency","comment":"Blocked."}' \
  "false"

run_test "prerequisites-both-arrays-empty" \
  '{"action":"prerequisites","reasoning":"upstream dependency","prerequisites":{"existing":[],"create":[]},"comment":"Blocked."}' \
  "false"

run_test "prerequisites-malformed-url-in-existing" \
  '{"action":"prerequisites","reasoning":"upstream dependency","prerequisites":{"existing":[{"url":"not-a-url"}],"create":[]},"comment":"Blocked."}' \
  "false"

run_test "split-missing-sub-issues" \
  '{"action":"split","reasoning":"issue bundles independent concerns","comment":"Splitting."}' \
  "false"

run_test "in-progress-missing-pull-requests" \
  '{"action":"in-progress","reasoning":"PR #123 fixes this issue","comment":"An open PR already addresses this issue."}' \
  "false"

run_test "in-progress-empty-pull-requests" \
  '{"action":"in-progress","reasoning":"PR #123 fixes this issue","pull_requests":[],"comment":"An open PR already addresses this issue."}' \
  "false"

run_test "in-progress-malformed-pr-url" \
  '{"action":"in-progress","reasoning":"PR #123 fixes this issue","pull_requests":[{"url":"https://github.com/org/repo/issues/123"}],"comment":"An open PR already addresses this issue."}' \
  "false"

# --- Fallback removal (issue #376) ---
# Verify that "result.json" is NOT accepted as a fallback for agent-result.json.
# The fallback was removed to enforce a single output filename.

run_test_fallback_removed() {
  local test_name="$1"
  local json_content="$2"
  local expect_output="${3:-}"

  local test_dir="${TMPDIR}/${test_name}"
  mkdir -p "${test_dir}/output"
  # Write only result.json (the old fallback name), not agent-result.json
  echo "${json_content}" > "${test_dir}/output/result.json"

  local exit_code=0
  FULLSEND_OUTPUT_SCHEMA="${SCHEMA}" \
    bash -c "cd '${test_dir}' && bash '${VALIDATOR}'" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  local passed=true
  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected FAIL but got PASS (fallback should be removed)"
    passed=false
  fi

  if [[ -n "${expect_output}" ]] && ! grep -qF "${expect_output}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected output to contain: ${expect_output}"
    echo "  actual output:"
    head -10 "${TMPDIR}/stdout.log"
    passed=false
  fi

  if [[ "${passed}" == "true" ]]; then
    echo "PASS: ${test_name}"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

run_test_fallback_removed "fallback-result-json-rejected" \
  '{"action":"insufficient","reasoning":"missing repro","clarity_scores":{"symptom":0.6,"cause":0.3,"reproduction":0.1,"impact":0.5,"overall":0.39},"comment":"Can you share repro steps?"}' \
  "agent-result.json not found"

# Verify that default filename (agent-result.json) works without FULLSEND_OUTPUT_FILE set
# (this is the standard path after harness configs no longer set FULLSEND_OUTPUT_FILE)
run_test "default-filename-without-env-override" \
  '{"action":"insufficient","reasoning":"missing repro","clarity_scores":{"symptom":0.6,"cause":0.3,"reproduction":0.1,"impact":0.5,"overall":0.39},"comment":"Can you share repro steps?"}' \
  "true"

# --- FULLSEND_OUTPUT_FILE override ---

run_test_custom_filename() {
  local test_name="$1"
  local json_content="$2"
  local output_file="$3"
  local schema="$4"
  local expect_pass="$5"
  local expect_output="${6:-}"  # optional: substring that must appear in stdout

  local test_dir="${TMPDIR}/${test_name}"
  mkdir -p "${test_dir}/output"
  echo "${json_content}" > "${test_dir}/output/$(basename "${output_file}")"

  local exit_code=0
  FULLSEND_OUTPUT_SCHEMA="${schema}" FULLSEND_OUTPUT_FILE="${output_file}" \
    bash -c "cd '${test_dir}' && bash '${VALIDATOR}'" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  local passed=true
  if [[ "${expect_pass}" == "true" && ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected PASS but got exit ${exit_code}"
    head -10 "${TMPDIR}/stdout.log"
    passed=false
  elif [[ "${expect_pass}" == "false" && ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected FAIL but got PASS"
    passed=false
  fi

  if [[ -n "${expect_output}" ]] && ! grep -qF "${expect_output}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected output to contain: ${expect_output}"
    echo "  actual output:"
    head -10 "${TMPDIR}/stdout.log"
    passed=false
  fi

  if [[ "${passed}" == "true" ]]; then
    echo "PASS: ${test_name}"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

FIX_SCHEMA="${SCRIPT_DIR}/../schemas/fix-result.schema.json"
REVIEW_SCHEMA="${SCRIPT_DIR}/../schemas/review-result.schema.json"

run_test_custom_filename "custom-output-file-valid" \
  '{"pr_number":42,"summary":"Fixed 1 issue.","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"nil check","description":"Added nil check","path":"pkg/handler.go"}],"files_changed":["pkg/handler.go"]}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "true"

run_test_custom_filename "custom-output-file-invalid" \
  '{"summary":"Bad."}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "false"

run_test_custom_filename "review-approve-actionable-finding-valid" \
  '{"action":"approve","pr_number":42,"repo":"owner/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Approved with follow-ups.","findings":[{"severity":"low","category":"missing-doc","file":"README.md","line":3,"description":"Document the flag.","remediation":"Add a short usage note.","actionable":true}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

run_test_custom_filename "review-finding-additional-property-rejected" \
  '{"action":"approve","pr_number":42,"repo":"owner/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Approved.","findings":[{"severity":"low","category":"missing-doc","file":"README.md","description":"Document the flag.","unexpected":true}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false"

# Helper for custom-filename tests that also assert output content.
run_test_custom_filename_output() {
  local test_name="$1"
  local json_content="$2"
  local output_file="$3"
  local schema="$4"
  local expect_pass="$5"
  local expect_output="$6"

  local test_dir="${TMPDIR}/${test_name}"
  mkdir -p "${test_dir}/output"
  echo "${json_content}" > "${test_dir}/output/$(basename "${output_file}")"

  local exit_code=0
  FULLSEND_OUTPUT_SCHEMA="${schema}" FULLSEND_OUTPUT_FILE="${output_file}" \
    bash -c "cd '${test_dir}' && bash '${VALIDATOR}'" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  local passed=true
  if [[ "${expect_pass}" == "true" && ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected PASS but got exit ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    passed=false
  elif [[ "${expect_pass}" == "false" && ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected FAIL but got PASS"
    passed=false
  fi

  if [[ -n "${expect_output}" ]] && ! grep -qF "${expect_output}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected output to contain: ${expect_output}"
    echo "  actual output:"
    head -10 "${TMPDIR}/stdout.log"
    passed=false
  fi

  if [[ "${passed}" == "true" ]]; then
    echo "PASS: ${test_name}"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

run_test_custom_filename_output "nested-additional-property-shows-allowed" \
  '{"action":"approve","pr_number":42,"repo":"owner/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Approved.","findings":[{"severity":"low","category":"missing-doc","file":"README.md","description":"Document the flag.","unexpected":true}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "allowed properties: actionable, category, description, file, id, line, remediation, severity"

# --- Structural failures ---

run_test "missing-action" \
  '{"reasoning":"test","comment":"test"}' \
  "false"

run_test "missing-comment" \
  '{"action":"sufficient","reasoning":"test"}' \
  "false"

run_test "invalid-action-value" \
  '{"action":"not_a_bug","reasoning":"test","comment":"test"}' \
  "false"

run_test "invalid-json" \
  'not json at all' \
  "false"

run_test "additional-properties-rejected" \
  '{"action":"sufficient","reasoning":"ok","clarity_scores":{"symptom":0.9,"cause":0.8,"reproduction":0.9,"impact":0.7,"overall":0.85},"triage_summary":{"title":"Bug","severity":"high","category":"bug","problem":"crash","root_cause_hypothesis":"null ptr","reproduction_steps":["step 1"],"impact":"all users","recommended_fix":"fix","proposed_test_case":"test"},"comment":"Done.","injected_field":"malicious"}' \
  "false"

# --- Allowed-properties output tests ---

# Helper that asserts both exit code and that stdout contains a required string.
run_test_output() {
  local test_name="$1"
  local json_content="$2"
  local expect_pass="$3"  # "true" or "false"
  local expect_output="$4"  # substring that must appear in stdout

  local test_dir="${TMPDIR}/${test_name}"
  mkdir -p "${test_dir}/output"
  echo "${json_content}" > "${test_dir}/output/agent-result.json"

  local exit_code=0
  FULLSEND_OUTPUT_SCHEMA="${SCHEMA}" \
    bash -c "cd '${test_dir}' && bash '${VALIDATOR}'" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  local passed=true
  if [[ "${expect_pass}" == "true" && ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected PASS but got exit ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    passed=false
  elif [[ "${expect_pass}" == "false" && ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected FAIL but got PASS"
    passed=false
  fi

  if [[ -n "${expect_output}" ]] && ! grep -qF "${expect_output}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected output to contain: ${expect_output}"
    echo "  actual output:"
    head -10 "${TMPDIR}/stdout.log"
    passed=false
  fi

  if [[ "${passed}" == "true" ]]; then
    echo "PASS: ${test_name}"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

run_test_output "additional-properties-shows-allowed" \
  '{"action":"sufficient","reasoning":"ok","clarity_scores":{"symptom":0.9,"cause":0.8,"reproduction":0.9,"impact":0.7,"overall":0.85},"triage_summary":{"title":"Bug","severity":"high","category":"bug","problem":"crash","root_cause_hypothesis":"null ptr","reproduction_steps":["step 1"],"impact":"all users","recommended_fix":"fix","proposed_test_case":"test"},"comment":"Done.","injected_field":"malicious"}' \
  "false" \
  "allowed properties:"

run_test_output "additional-properties-lists-known-keys" \
  '{"action":"sufficient","reasoning":"ok","clarity_scores":{"symptom":0.9,"cause":0.8,"reproduction":0.9,"impact":0.7,"overall":0.85},"triage_summary":{"title":"Bug","severity":"high","category":"bug","problem":"crash","root_cause_hypothesis":"null ptr","reproduction_steps":["step 1"],"impact":"all users","recommended_fix":"fix","proposed_test_case":"test"},"comment":"Done.","injected_field":"malicious"}' \
  "false" \
  "action, clarity_scores, comment, component_actions, duplicate_of, label_actions, move_to, prerequisites, pull_requests, reasoning, sub_issues, triage_summary"

run_test_output "valid-output-no-allowed-line" \
  '{"action":"insufficient","reasoning":"missing repro","clarity_scores":{"symptom":0.6,"cause":0.3,"reproduction":0.1,"impact":0.5,"overall":0.39},"comment":"Can you share repro steps?"}' \
  "true" \
  ""

run_test "invalid-category-rejected" \
  '{"action":"sufficient","reasoning":"ok","clarity_scores":{"symptom":0.9,"cause":0.8,"reproduction":0.9,"impact":0.7,"overall":0.85},"triage_summary":{"title":"Bug","severity":"high","category":"invented-category","problem":"crash","root_cause_hypothesis":"null ptr","reproduction_steps":["step 1"],"impact":"all users","recommended_fix":"fix","proposed_test_case":"test"},"comment":"Done."}' \
  "false"

# --- fix-result.schema.json conditional allOf/if/then rules ---

run_test_custom_filename "fix-missing-description" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"nil check"}],"files_changed":["f.go"]}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "false"

run_test_custom_filename "disagree-missing-reason" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"disagree","finding":"nil check"}],"files_changed":["f.go"]}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "false"

run_test_custom_filename "fix-with-description-valid" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"nil check","description":"Added nil check"}],"files_changed":["f.go"]}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "true"

run_test_custom_filename "disagree-with-reason-valid" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"disagree","finding":"nil check","reason":"Already guarded upstream"}],"files_changed":["f.go"]}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "true"

run_test_custom_filename "empty-actions-rejected" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[],"files_changed":["f.go"]}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "false"

run_test_custom_filename "fix-history-rewritten-valid" \
  '{"pr_number":42,"summary":"s","trigger_source":"human","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"squash","description":"Squashed 3 commits"}],"files_changed":["f.go"],"history_rewritten":true}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "true"

run_test_custom_filename "fix-merged-target-valid" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"forge conflict","description":"Merged origin/main"}],"files_changed":["f.go"],"merged_target":true,"conflict_update":{"forge_state":"CONFLICTING","target_branch":"main","strategy":"merge","outcome":"merged"}}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "true"

run_test_custom_filename "fix-conflict-update-invalid-strategy" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"forge conflict","description":"Merged origin/main"}],"files_changed":["f.go"],"conflict_update":{"strategy":"squash","outcome":"merged"}}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "false"

run_test_custom_filename "fix-ci-inspections-valid" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"nil check","description":"Added nil check"}],"files_changed":["f.go"],"ci_inspections":[{"job":"lint","status":"success","classification":"passing","diagnosis":"Lint passed."},{"job":"unit-tests","status":"failure","classification":"pr-related","diagnosis":"Failing test matches the diff.","remediation":"Fixed the test."}]}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "true"

run_test_custom_filename "fix-ci-inspections-invalid-classification" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"nil check","description":"Added nil check"}],"files_changed":["f.go"],"ci_inspections":[{"job":"lint","classification":"excluded"}]}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "false"

run_test_custom_filename "fix-ci-inspections-missing-job" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"nil check","description":"Added nil check"}],"files_changed":["f.go"],"ci_inspections":[{"classification":"passing"}]}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "false"

run_test_custom_filename "fix-ci-inspections-additional-property-rejected" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"nil check","description":"Added nil check"}],"files_changed":["f.go"],"ci_inspections":[{"job":"lint","classification":"passing","unexpected":true}]}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "false"

run_test_custom_filename "fix-ci-inspections-empty-array-valid" \
  '{"pr_number":42,"summary":"s","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"nil check","description":"Added nil check"}],"files_changed":["f.go"],"ci_inspections":[]}' \
  "fix-result.json" \
  "${FIX_SCHEMA}" \
  "true"

# --- FULLSEND_OUTPUT_FILE path traversal guard ---
run_test_custom_filename "path-traversal-stripped" \
  '{"pr_number":42,"summary":"Fixed 1 issue.","trigger_source":"bot","iteration":1,"tests_passed":true,"actions":[{"type":"fix","finding":"nil check","description":"Added nil check","path":"pkg/handler.go"}],"files_changed":["pkg/handler.go"]}' \
  "../../etc/fix-result.json" \
  "${FIX_SCHEMA}" \
  "true"

# --- review-result.schema.json tests ---

REVIEW_SCHEMA="${SCRIPT_DIR}/../schemas/review-result.schema.json"

run_test_custom_filename "review-reject-valid" \
  '{"action":"reject","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Wrong approach.","findings":[{"severity":"high","category":"design-direction","file":"main.go","description":"Wrong design."}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

run_test_custom_filename "review-reject-missing-findings" \
  '{"action":"reject","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Wrong approach."}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'findings' is a required property"

run_test_custom_filename "review-reject-missing-body" \
  '{"action":"reject","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","findings":[{"severity":"high","category":"design-direction","file":"main.go","description":"Wrong design."}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'body' is a required property"

run_test_custom_filename "review-failure-time-budget-valid" \
  '{"action":"failure","pr_number":1,"repo":"org/repo","reason":"time-budget"}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

run_test_custom_filename "review-failure-unknown-reason-rejected" \
  '{"action":"failure","pr_number":1,"repo":"org/repo","reason":"ran-out-of-time"}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "is not one of"

# --- review-result.schema.json per-action required fields ---

run_test_custom_filename "review-request-changes-missing-findings" \
  '{"action":"request-changes","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Please change."}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'findings' is a required property"

run_test_custom_filename "review-request-changes-missing-body" \
  '{"action":"request-changes","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","findings":[{"severity":"high","category":"bug","file":"main.go","description":"Bug."}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'body' is a required property"

run_test_custom_filename "review-request-changes-missing-head-sha" \
  '{"action":"request-changes","pr_number":1,"repo":"org/repo","body":"Please change.","findings":[{"severity":"high","category":"bug","file":"main.go","description":"Bug."}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'head_sha' is a required property"

run_test_custom_filename "review-request-changes-empty-findings" \
  '{"action":"request-changes","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Please change.","findings":[]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "should be non-empty"

run_test_custom_filename "review-comment-missing-body" \
  '{"action":"comment","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01"}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'body' is a required property"

run_test_custom_filename "review-comment-missing-head-sha" \
  '{"action":"comment","pr_number":1,"repo":"org/repo","body":"FYI only."}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'head_sha' is a required property"

run_test_custom_filename "review-failure-missing-reason" \
  '{"action":"failure","pr_number":1,"repo":"org/repo"}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'reason' is a required property"

run_test_custom_filename "review-approve-missing-body" \
  '{"action":"approve","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01"}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'body' is a required property"

run_test_custom_filename "review-approve-missing-head-sha" \
  '{"action":"approve","pr_number":1,"repo":"org/repo","body":"LGTM."}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'head_sha' is a required property"

run_test_custom_filename "review-reject-missing-head-sha" \
  '{"action":"reject","pr_number":1,"repo":"org/repo","body":"Wrong approach.","findings":[{"severity":"high","category":"design-direction","file":"main.go","description":"Wrong design."}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'head_sha' is a required property"

run_test_custom_filename "review-approve-valid" \
  '{"action":"approve","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Looks good, only minor nits."}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

# --- review-result.schema.json: repo path segments ---
# GitLab project paths may nest groups arbitrarily (group/subgroup/project).

for repo_case in "owner/repo" "group/subgroup/project" "a/b/c/d"; do
  run_test_custom_filename "review-repo-valid-${repo_case//\//_}" \
    "{\"action\":\"failure\",\"pr_number\":1,\"repo\":\"${repo_case}\",\"reason\":\"time-budget\"}" \
    "agent-result.json" \
    "${REVIEW_SCHEMA}" \
    "true"
done

for repo_case in "repo" "" "/a/b" "a/b/" "a//b"; do
  run_test_custom_filename "review-repo-invalid-${repo_case//\//_}" \
    "{\"action\":\"failure\",\"pr_number\":1,\"repo\":\"${repo_case}\",\"reason\":\"time-budget\"}" \
    "agent-result.json" \
    "${REVIEW_SCHEMA}" \
    "false"
done

# --- review-result.schema.json: short / non-hex SHA rejected ---

run_test_custom_filename "review-reject-short-sha-rejected" \
  '{"action":"reject","pr_number":1,"repo":"org/repo","head_sha":"abc1234","body":"Wrong.","findings":[{"severity":"high","category":"logic-error","file":"main.go","description":"Bug."}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'abc1234' does not match"

run_test_custom_filename "review-approve-nonhex-sha-rejected" \
  '{"action":"approve","pr_number":1,"repo":"org/repo","head_sha":"ghijkl0123456789ghijkl0123456789ghijkl01","body":"LGTM."}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false"

# --- review-result.schema.json protected-path constraint ---

run_test_custom_filename "review-approve-with-protected-path-rejected" \
  '{"action":"approve","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Approved.","findings":[{"severity":"high","category":"protected-path","file":".github/workflows/ci.yml","description":"PR modifies protected path."}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false"

run_test_custom_filename "review-comment-with-protected-path-valid" \
  '{"action":"comment","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Protected paths detected.","findings":[{"severity":"medium","category":"protected-path","file":"CODEOWNERS","description":"PR modifies protected path."}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

run_test_custom_filename "review-request-changes-with-protected-path-valid" \
  '{"action":"request-changes","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Protected paths.","findings":[{"severity":"high","category":"protected-path","file":"scripts/deploy.sh","description":"PR modifies protected path."}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

run_test_custom_filename "review-approve-no-protected-path-valid" \
  '{"action":"approve","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM.","findings":[{"severity":"low","category":"naming-convention","file":"main.go","description":"Minor style nit."}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

# --- review-result.schema.json risk_assessment score↔level allOf ---

RISK_BASE='{"action":"comment","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Risk assessed."'

run_test_custom_filename "risk-score-1-level-low-valid" \
  "${RISK_BASE},\"risk_assessment\":{\"score\":1,\"level\":\"low\",\"rationale\":\"Small change.\"}}" \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

run_test_custom_filename "risk-score-2-level-moderate-valid" \
  "${RISK_BASE},\"risk_assessment\":{\"score\":2,\"level\":\"moderate\",\"rationale\":\"Some complexity.\"}}" \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

run_test_custom_filename "risk-score-3-level-elevated-valid" \
  "${RISK_BASE},\"risk_assessment\":{\"score\":3,\"level\":\"elevated\",\"rationale\":\"Sensitive area.\"}}" \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

run_test_custom_filename "risk-score-4-level-high-valid" \
  "${RISK_BASE},\"risk_assessment\":{\"score\":4,\"level\":\"high\",\"rationale\":\"Security-sensitive.\"}}" \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

run_test_custom_filename "risk-score-5-level-critical-valid" \
  "${RISK_BASE},\"risk_assessment\":{\"score\":5,\"level\":\"critical\",\"rationale\":\"Auth change.\"}}" \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

run_test_custom_filename "risk-score-level-mismatch-rejected" \
  "${RISK_BASE},\"risk_assessment\":{\"score\":1,\"level\":\"critical\",\"rationale\":\"Mismatched.\"}}" \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false"

run_test_custom_filename "risk-score-2-level-high-mismatch-rejected" \
  "${RISK_BASE},\"risk_assessment\":{\"score\":2,\"level\":\"high\",\"rationale\":\"Wrong level.\"}}" \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false"

run_test_custom_filename "risk-missing-rationale-rejected" \
  "${RISK_BASE},\"risk_assessment\":{\"score\":3,\"level\":\"elevated\"}}" \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false"

run_test_custom_filename "risk-score-out-of-range-rejected" \
  "${RISK_BASE},\"risk_assessment\":{\"score\":6,\"level\":\"critical\",\"rationale\":\"Too high.\"}}" \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false"

run_test_custom_filename "risk-additional-property-rejected" \
  "${RISK_BASE},\"risk_assessment\":{\"score\":1,\"level\":\"low\",\"rationale\":\"Small.\",\"extra\":true}}" \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false"

# --- review-result.schema.json finding category taxonomy ---
# A category outside the projection allowlist makes post-review drop the
# prior-findings projection, so the next review loses its ledger. The schema
# must reject such a category before the review is posted.

run_test_custom_filename "review-non-canonical-category-rejected" \
  '{"action":"comment","pr_number":1,"repo":"org/repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Review.","findings":[{"severity":"medium","category":"race-condition","file":"main.go","description":"Unsynchronized access."}]}' \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "false" \
  "'race-condition' is not one of"

ALL_CATEGORIES_RESULT="$(jq -c '
  ."$defs".finding.properties.category.enum
  | {action: "comment", pr_number: 1, repo: "org/repo",
     head_sha: "abcdef0123456789abcdef0123456789abcdef01", body: "Review.",
     findings: map({severity: "low", category: ., file: "main.go", description: "Finding."})}
' "${REVIEW_SCHEMA}")"
run_test_custom_filename "review-every-listed-category-valid" \
  "${ALL_CATEGORIES_RESULT}" \
  "agent-result.json" \
  "${REVIEW_SCHEMA}" \
  "true"

# The category taxonomy is duplicated in the schema, the pre-review and
# post-review projection allowlists, and the re-review dimension table. All
# copies must agree, otherwise a schema-valid finding can still break the
# projection.

# Print the quoted strings inside a jq `def <name>:` block, one per line,
# ignoring `type == "string"` guards.
jq_def_strings() {
  local file="$1" name="$2"
  awk -v def="def ${name}:" '
    index($0, def) { found = 1 }
    found { gsub(/type == "string"/, ""); print }
    found && /\);/ { exit }
  ' "${file}" | grep -oE '"[a-z-]+"' | tr -d '"' | sort
}

assert_same_set() {
  local test_name="$1" expected="$2" actual="$3"
  if [[ -z "${expected}" || -z "${actual}" ]]; then
    echo "FAIL: ${test_name} — could not extract a category list"
    FAILURES=$((FAILURES + 1))
  elif [[ "${expected}" == "${actual}" ]]; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — category sets differ"
    diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") || true
    FAILURES=$((FAILURES + 1))
  fi
}

SCHEMA_CATEGORIES="$(jq -r '."$defs".finding.properties.category.enum[]' "${REVIEW_SCHEMA}" | sort)"
PRE_REVIEW_ALLOWED="$(jq_def_strings "${SCRIPT_DIR}/pre-review.src.sh" allowed_category)"
POST_REVIEW_ALLOWED="$(jq_def_strings "${SCRIPT_DIR}/post-review.src.sh" allowed_category)"
# post-review treats these as non-dimensional; sub-agent-failure is matched
# separately in non_dimensional_finding.
POST_REVIEW_NON_DIMENSIONAL="$( (jq_def_strings "${SCRIPT_DIR}/post-review.src.sh" non_dimensional_category; echo "sub-agent-failure") | sort)"
RE_REVIEW_TABLE="$(awk '
  /^\| Dimension / { found = 1; next }
  found && !/^\|/ { exit }
  found { print }
' "${SCRIPT_DIR}/../skills/pr-review/references/re-review.md" | grep -oE '`[a-z-]+`' | tr -d '`' | sort)"

assert_same_set "category-allowlist-pre-matches-post" \
  "${PRE_REVIEW_ALLOWED}" "${POST_REVIEW_ALLOWED}"
assert_same_set "category-allowlist-matches-re-review-table" \
  "${PRE_REVIEW_ALLOWED}" "${RE_REVIEW_TABLE}"
assert_same_set "category-schema-enum-matches-allowlist-plus-non-dimensional" \
  "${SCHEMA_CATEGORIES}" "$(printf '%s\n%s\n' "${PRE_REVIEW_ALLOWED}" "${POST_REVIEW_NON_DIMENSIONAL}" | sort)"

# --- Retro result schema (schemas/retro-result.schema.json) ---
# related_issues is OPTIONAL in the schema: a missing or quantity-deficient
# receipt must skip only its own proposal in post-retro, not fail whole-result
# validation and drop valid siblings and the summary (the retro validation loop
# is all-or-nothing with no feedback). Receipt quantity/uniqueness is enforced
# by the post-retro gate (see post-retro-test.sh), not here. The schema still
# rejects a structurally wrong receipt (non-array searched, non-string items).
SCHEMA="${SCRIPT_DIR}/../schemas/retro-result.schema.json"

run_test "retro-valid-proposal-with-receipt" \
  '{"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v","related_issues":{"searched":["fix keywords","root cause keywords"],"found":[123],"note":"n"}}]}' \
  "true"

run_test "retro-valid-receipt-empty-found" \
  '{"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v","related_issues":{"searched":["fix keywords","root cause keywords"],"found":[]}}]}' \
  "true"

# found may mix a bare integer (target_repo) with a qualified owner/repo#N
# string (cross-repo canonical).
run_test "retro-valid-found-qualified-cross-repo-ref" \
  '{"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v","related_issues":{"searched":["fix keywords","root cause keywords"],"found":[1234,"fullsend-ai/fullsend#1887"]}}]}' \
  "true"

# A malformed found entry (bare #N string, not owner/repo#N) is rejected.
run_test "retro-found-bare-hash-string-rejected" \
  '{"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v","related_issues":{"searched":["a","b"],"found":["#1887"]}}]}' \
  "false"

# found accepts a nested GitLab group/subgroup/project#N reference.
run_test "retro-found-nested-gitlab-group-ref" \
  '{"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v","related_issues":{"searched":["a","b"],"found":["group/subgroup/project#12"]}}]}' \
  "true"

# A large receipt must NOT fail whole-result validation (no maxItems): the
# non-poisoning design requires a big found/searched to pass the schema and be
# handled by the post-retro gate, not reject the whole result.
run_test "retro-large-receipt-passes-schema" \
  "$(python3 -c '
import json
found=list(range(1,31))
searched=["phrase %d" % i for i in range(1,21)]
print(json.dumps({"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v","related_issues":{"searched":searched,"found":found}}]}))')" \
  "true"

# Missing receipt passes the schema (optional) — the post-retro gate skips it.
run_test "retro-missing-related-issues-passes-schema" \
  '{"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v"}]}' \
  "true"

# Quantity-deficient receipts pass the schema (gate enforces quantity) so that a
# weak receipt skips only its own proposal rather than failing the whole result.
run_test "retro-single-search-phrase-passes-schema" \
  '{"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v","related_issues":{"searched":["only one phrase"]}}]}' \
  "true"

run_test "retro-duplicate-search-phrases-pass-schema" \
  '{"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v","related_issues":{"searched":["same phrase","same phrase"]}}]}' \
  "true"

# A structurally wrong receipt still fails the schema: searched must be an array.
run_test "retro-searched-not-array-rejected" \
  '{"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v","related_issues":{"searched":"a single string"}}]}' \
  "false"

# searched items must be strings.
run_test "retro-searched-non-string-items-rejected" \
  '{"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v","related_issues":{"searched":[1,2]}}]}' \
  "false"

# An unknown key in related_issues is rejected (additionalProperties:false).
run_test "retro-related-issues-unknown-key-rejected" \
  '{"summary":"s","proposals":[{"target_repo":"org/repo","title":"T","what_happened":"w","what_could_go_better":"b","proposed_change":"p","validation_criteria":"v","related_issues":{"searched":["a","b"],"bogus":1}}]}' \
  "false"

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
