#!/usr/bin/env bash
# validate-code-output-test.sh — Tests for validate-code-output.sh.
#
# Parts 1-2 cover schema validation and the sweep-path soft-pass; Part 3
# drives the pre-commit gate against a real git fixture with a stub
# `pre-commit` on PATH.
#
# Run from the repo root:
#   bash scripts/validate-code-output-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The test target is configurable: "source" runs the .src.sh directly,
# "bundled" runs the bundled .sh artifact.  Default: "source" (consistent
# with other test scripts in this repo).
SCRIPT_TEST_TARGET="${SCRIPT_TEST_TARGET:-source}"
if [ "${SCRIPT_TEST_TARGET}" = "bundled" ]; then
  VALIDATOR="${SCRIPT_DIR}/validate-code-output.sh"
else
  VALIDATOR="${SCRIPT_DIR}/validate-code-output.src.sh"
fi

SCHEMA="${SCRIPT_DIR}/../schemas/code-result.schema.json"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# ---------------------------------------------------------------------------
# Part 1: Schema validation (same behavior as validate-output-schema.sh)
# ---------------------------------------------------------------------------

run_test() {
  local test_name="$1"
  local json_content="$2"
  local expect_pass="$3"
  local expect_output="${4:-}"

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

# Schema pass cases
run_test "schema-valid-target-branch-only" \
  '{"target_branch":"main"}' \
  "true" \
  "PASS: output validated against schema"

run_test "schema-valid-with-pr-body" \
  '{"target_branch":"main","pr_body":"## Summary\nFixed a bug."}' \
  "true"

run_test "schema-valid-with-closes-issue-false" \
  '{"target_branch":"develop","pr_body":"Partial.","closes_issue":false}' \
  "true"

# Schema fail cases
run_test "schema-missing-target-branch" \
  '{"pr_body":"No target branch."}' \
  "false"

run_test "schema-additional-property" \
  '{"target_branch":"main","unexpected_field":"bad"}' \
  "false"

run_test "schema-invalid-json" \
  'not json' \
  "false"

# The run_test helper always creates output/agent-result.json, so testing a
# missing output directory requires a separate helper.
run_test_no_output_dir() {
  local test_name="$1"
  local expect_output="$2"

  local test_dir="${TMPDIR}/${test_name}"
  mkdir -p "${test_dir}"
  # Intentionally do NOT create output/ directory

  local exit_code=0
  FULLSEND_OUTPUT_SCHEMA="${SCHEMA}" \
    bash -c "cd '${test_dir}' && bash '${VALIDATOR}'" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  local passed=true
  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected FAIL but got PASS"
    passed=false
  fi
  if [[ -n "${expect_output}" ]] && ! grep -qF "${expect_output}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected output to contain: ${expect_output}"
    passed=false
  fi
  if [[ "${passed}" == "true" ]]; then
    echo "PASS: ${test_name}"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

run_test_no_output_dir "missing-output-dir" "output directory not found"

# ---------------------------------------------------------------------------
# Part 2: Pre-commit gate — empty TARGET_REPO_DIR soft-passes
# ---------------------------------------------------------------------------

run_test_precommit_gate() {
  local test_name="$1"
  local json_content="$2"
  local target_repo_dir="$3"
  local expect_pass="$4"
  local expect_output="${5:-}"

  local test_dir="${TMPDIR}/${test_name}"
  mkdir -p "${test_dir}/output"
  echo "${json_content}" > "${test_dir}/output/agent-result.json"

  local exit_code=0
  FULLSEND_OUTPUT_SCHEMA="${SCHEMA}" TARGET_REPO_DIR="${target_repo_dir}" \
    bash -c "cd '${test_dir}' && bash '${VALIDATOR}'" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  local passed=true
  if [[ "${expect_pass}" == "true" && ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected PASS but got exit ${exit_code}"
    head -20 "${TMPDIR}/stdout.log"
    passed=false
  elif [[ "${expect_pass}" == "false" && ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected FAIL but got PASS"
    passed=false
  fi

  if [[ -n "${expect_output}" ]] && ! grep -qF "${expect_output}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected output to contain: ${expect_output}"
    echo "  actual output:"
    head -20 "${TMPDIR}/stdout.log"
    passed=false
  fi

  if [[ "${passed}" == "true" ]]; then
    echo "PASS: ${test_name}"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

# Empty TARGET_REPO_DIR -> soft-pass (schema still validates)
run_test_precommit_gate "empty-target-repo-dir-softpass" \
  '{"target_branch":"main"}' \
  "" \
  "true" \
  "skipping pre-commit gate (sweep path)"

# Non-existent TARGET_REPO_DIR -> soft-pass
run_test_precommit_gate "nonexistent-target-repo-dir-softpass" \
  '{"target_branch":"main"}' \
  "/nonexistent/path/to/repo" \
  "true" \
  "skipping pre-commit gate (sweep path)"

# Schema fail with TARGET_REPO_DIR set -> still fails on schema
run_test_precommit_gate "schema-fail-even-with-target-repo-dir" \
  '{"pr_body":"missing target_branch"}' \
  "" \
  "false" \
  "schema validation error"

# ---------------------------------------------------------------------------
# Part 3: Pre-commit gate against a real repo fixture
#
# These cases exercise the path the validation loop exists for: a lint
# failure on the agent's changed files must exit non-zero with the hook
# diagnostics in stdout (that text becomes the next iteration's prompt),
# and the check-only contract must hold — the extracted repo is never
# amended.  `pre-commit` itself is a stub on PATH so the cases are hermetic
# and drive the gate's branches deterministically, the same way
# check-rollup-result-test.sh stubs `gh`.
# ---------------------------------------------------------------------------

# make_repo_fixture <dir> <with_config> <agent_commit> <signoff>
#   Builds a git repo with a base commit on main, an origin/main ref at that
#   base, and optionally one "agent" commit on top (optionally carrying a
#   Signed-off-by trailer).
make_repo_fixture() {
  local dir="$1" with_config="$2" agent_commit="$3" signoff="$4"
  mkdir -p "${dir}"
  (
    cd "${dir}"
    git init -q -b main .
    git config user.email test@example.com
    git config user.name test
    echo "base" > src.py
    if [ "${with_config}" = "true" ]; then
      printf 'repos: []\n' > .pre-commit-config.yaml
    fi
    git add -A
    git commit -q -m "base"
    git update-ref refs/remotes/origin/main HEAD
    if [ "${agent_commit}" = "true" ]; then
      echo "agent change" >> src.py
      git add -A
      if [ "${signoff}" = "true" ]; then
        git commit -q -m "agent" -m "Signed-off-by: agent <a@b>"
      else
        git commit -q -m "agent"
      fi
    fi
  )
}

# make_precommit_stub <bindir> <mode>
#   mode: pass | fail | fail-modify (fails AND rewrites a tracked file, the
#   way a formatter hook would)
make_precommit_stub() {
  local bindir="$1" mode="$2"
  mkdir -p "${bindir}"
  cat > "${bindir}/pre-commit" <<STUB
#!/bin/sh
case "${mode}" in
  pass)
    echo "ruff.....................................................................Passed"
    exit 0 ;;
  fail-modify)
    echo "formatted" >> src.py ;;
  secret-only)
    echo "gitleaks.................................................................Failed"
    echo "- hook id: gitleaks"
    echo "  Finding: generic-api-key in src.py"
    exit 1 ;;
  infra)
    echo "An unexpected error has occurred: CalledProcessError"
    echo "Check the log at /home/runner/.cache/pre-commit/pre-commit.log"
    exit 1 ;;
  mixed)
    echo "gitleaks.................................................................Failed"
    echo "- hook id: gitleaks"
    echo "ruff.....................................................................Failed"
    echo "- hook id: ruff"
    echo "  src.py:2:1: E501 line too long"
    exit 1 ;;
esac
echo "ruff.....................................................................Failed"
echo "- hook id: ruff"
echo "  src.py:2:1: E501 line too long"
exit 1
STUB
  chmod +x "${bindir}/pre-commit"
}

# run_test_precommit_repo <name> <stub_mode> <with_config> <agent_commit> <signoff> <expect_pass> <expect_output> [expect_head_unchanged]
run_test_precommit_repo() {
  local test_name="$1" stub_mode="$2" with_config="$3" agent_commit="$4"
  local signoff="$5" expect_pass="$6" expect_output="${7:-}"
  local expect_head_unchanged="${8:-false}"

  local test_dir="${TMPDIR}/${test_name}"
  local repo_dir="${test_dir}/repo"
  local bin_dir="${test_dir}/bin"
  mkdir -p "${test_dir}/output"
  echo "${PRECOMMIT_TEST_RESULT_JSON:-{\"target_branch\":\"main\"\}}" > "${test_dir}/output/agent-result.json"
  make_repo_fixture "${repo_dir}" "${with_config}" "${agent_commit}" "${signoff}"
  make_precommit_stub "${bin_dir}" "${stub_mode}"

  local head_before
  head_before="$(git -C "${repo_dir}" rev-parse HEAD)"

  # The validator prepends ${HOME}/.local/bin to PATH after the dependency
  # install step, which is where a pip --user pre-commit lives on most
  # runners.  Point HOME at an empty dir so the stub is the only
  # pre-commit in sight; otherwise a real one shadows it and these cases
  # pass vacuously against the fixture's empty hook list.
  local fake_home="${test_dir}/home"
  mkdir -p "${fake_home}"

  local exit_code=0
  HOME="${fake_home}" PATH="${bin_dir}:${PATH}" \
  FULLSEND_OUTPUT_SCHEMA="${SCHEMA}" TARGET_REPO_DIR="${repo_dir}" TARGET_BRANCH="main" \
    bash -c "cd '${test_dir}' && bash '${VALIDATOR}'" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  local passed=true
  if [[ "${expect_pass}" == "true" && ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected PASS but got exit ${exit_code}"
    head -20 "${TMPDIR}/stdout.log"
    passed=false
  elif [[ "${expect_pass}" == "false" && ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected FAIL but got PASS"
    head -20 "${TMPDIR}/stdout.log"
    passed=false
  fi

  if [[ -n "${expect_output}" ]] && ! grep -qF "${expect_output}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected output to contain: ${expect_output}"
    echo "  actual output:"
    head -20 "${TMPDIR}/stdout.log"
    passed=false
  fi

  if [[ "${expect_head_unchanged}" == "true" ]]; then
    local head_after
    head_after="$(git -C "${repo_dir}" rev-parse HEAD)"
    if [[ "${head_after}" != "${head_before}" ]]; then
      echo "FAIL: ${test_name} — HEAD moved (${head_before:0:8} -> ${head_after:0:8}); check-only mode must never amend the extracted repo"
      passed=false
    fi
  fi

  if [[ "${passed}" == "true" ]]; then
    echo "PASS: ${test_name}"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

# A lint failure on the agent's files consumes an iteration: exit 1, and the
# hook diagnostics are in stdout — that text is what the next iteration's
# prompt carries, so the agent must be able to read the actual error.
run_test_precommit_repo "precommit-fail-consumes-iteration" \
  "fail" "true" "true" "false" \
  "false" "E501 line too long"
run_test_precommit_repo "precommit-fail-reports-category" \
  "fail" "true" "true" "false" \
  "false" "FAIL: pre-commit-blocked"

# Clean hooks pass through.
run_test_precommit_repo "precommit-pass" \
  "pass" "true" "true" "false" \
  "true" "Pre-commit passed"

# A Signed-off-by trailer is agent-fixable and consumes an iteration; it is
# caught before pre-commit even runs.
run_test_precommit_repo "signoff-consumes-iteration" \
  "pass" "true" "true" "true" \
  "false" "FAIL: signed-off-by"

# The Signed-off-by check must inspect only commits introduced or modified by
# the current fix run. Human-authored PR commits may legitimately carry DCO
# trailers, including after the agent rebases them onto an updated target.
run_test_signoff_attribution() {
  local test_name="$1" rebase="$2" agent_signoff="$3" expect_pass="$4"
  local agent_merge="${5:-false}"
  local human_merge="${6:-false}"
  local agent_amend="${7:-none}"
  local test_dir="${TMPDIR}/${test_name}"
  local repo_dir="${test_dir}/repo"
  local bin_dir="${test_dir}/bin"
  mkdir -p "${test_dir}/output"
  echo '{"target_branch":"main"}' > "${test_dir}/output/agent-result.json"

  git init -q -b main "${repo_dir}"
  git -C "${repo_dir}" config user.email human@example.com
  git -C "${repo_dir}" config user.name Human
  echo "base" > "${repo_dir}/src.py"
  printf 'repos: []\n' > "${repo_dir}/.pre-commit-config.yaml"
  git -C "${repo_dir}" add -A
  git -C "${repo_dir}" commit -q -m "base"
  git -C "${repo_dir}" update-ref refs/remotes/origin/main HEAD

  git -C "${repo_dir}" checkout -q -b feature
  if [ "${human_merge}" = "true" ]; then
    git -C "${repo_dir}" checkout -q -b human-side
    echo "human change" > "${repo_dir}/human.txt"
    git -C "${repo_dir}" add human.txt
    git -C "${repo_dir}" commit -q -m "human change"
    git -C "${repo_dir}" checkout -q feature
    git -C "${repo_dir}" merge -q --no-ff --signoff -m "human merge" human-side
  else
    if [ "${agent_amend}" = "whitespace" ]; then
      printf 'def value():\n    return 1\n' > "${repo_dir}/behavior.py"
      git -C "${repo_dir}" add behavior.py
    else
      echo "human change" >> "${repo_dir}/src.py"
      git -C "${repo_dir}" add src.py
    fi
    if [ "${agent_amend}" = "unsigned" ]; then
      git -C "${repo_dir}" commit -q -m "human change"
    elif [ "${agent_amend}" = "reorder" ]; then
      git -C "${repo_dir}" commit -q -m "human change" \
        -m $'Signed-off-by: Human <human@example.com>\nSigned-off-by: Reviewer <reviewer@example.com>'
    else
      git -C "${repo_dir}" commit -q -s -m "human change"
    fi
  fi
  local pre_agent_head
  pre_agent_head="$(git -C "${repo_dir}" rev-parse HEAD)"

  git -C "${repo_dir}" config user.email agent@example.com
  git -C "${repo_dir}" config user.name Agent
  if [ "${rebase}" = "true" ]; then
    git -C "${repo_dir}" checkout -q main
    echo "upstream change" > "${repo_dir}/upstream.txt"
    git -C "${repo_dir}" add upstream.txt
    git -C "${repo_dir}" commit -q -m "upstream change"
    git -C "${repo_dir}" update-ref refs/remotes/origin/main HEAD
    git -C "${repo_dir}" checkout -q feature
    if [ "${human_merge}" = "true" ]; then
      git -C "${repo_dir}" rebase -q --rebase-merges main
    else
      git -C "${repo_dir}" rebase -q main
    fi
  fi

  if [ "${agent_amend}" = "whitespace" ]; then
    printf 'def value():\nreturn 1\n' > "${repo_dir}/behavior.py"
    git -C "${repo_dir}" add behavior.py
    git -C "${repo_dir}" commit -q --amend --no-edit
  elif [ "${agent_amend}" = "duplicate" ]; then
    git -C "${repo_dir}" show -s --format='%B' > "${test_dir}/commit-message"
    printf 'Signed-off-by: Human <human@example.com>\n' >> "${test_dir}/commit-message"
    git -C "${repo_dir}" commit -q --amend -F "${test_dir}/commit-message"
  elif [ "${agent_amend}" = "reorder" ]; then
    git -C "${repo_dir}" commit -q --amend -m "human change" \
      -m $'Signed-off-by: Reviewer <reviewer@example.com>\nSigned-off-by: Human <human@example.com>'
  elif [ "${agent_amend}" != "none" ]; then
    git -C "${repo_dir}" commit -q --amend --no-edit --signoff
  elif [ "${agent_merge}" = "true" ]; then
    git -C "${repo_dir}" checkout -q -b agent-side
    echo "agent change" > "${repo_dir}/agent.txt"
    git -C "${repo_dir}" add agent.txt
    git -C "${repo_dir}" commit -q -m "agent change"
    git -C "${repo_dir}" checkout -q feature
    git -C "${repo_dir}" merge -q --no-ff --signoff -m "agent merge" agent-side
  else
    echo "agent change" > "${repo_dir}/agent.txt"
    git -C "${repo_dir}" add agent.txt
    if [ "${agent_signoff}" = "true" ]; then
      git -C "${repo_dir}" commit -q -s -m "agent change"
    else
      git -C "${repo_dir}" commit -q -m "agent change"
    fi
  fi
  make_precommit_stub "${bin_dir}" "pass"

  local fake_home="${test_dir}/home"
  mkdir -p "${fake_home}"
  local exit_code=0
  HOME="${fake_home}" PATH="${bin_dir}:${PATH}" \
  FULLSEND_OUTPUT_SCHEMA="${SCHEMA}" TARGET_REPO_DIR="${repo_dir}" \
  TARGET_BRANCH="main" PRE_AGENT_HEAD="${pre_agent_head}" \
    bash -c "cd '${test_dir}' && bash '${VALIDATOR}'" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [ "${expect_pass}" = "true" ] && [ "${exit_code}" -eq 0 ]; then
    echo "PASS: ${test_name}"
  elif [ "${expect_pass}" = "false" ] && [ "${exit_code}" -ne 0 ] \
    && grep -qF "FAIL: signed-off-by" "${TMPDIR}/stdout.log"; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — unexpected exit ${exit_code}"
    head -20 "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
  fi
}

run_test_signoff_attribution "human-signoff-ignored" "false" "false" "true"
run_test_signoff_attribution "human-signoff-ignored-after-rebase" "true" "false" "true"
run_test_signoff_attribution "human-merge-signoff-ignored-after-rebase" "true" "false" "true" "false" "true"
run_test_signoff_attribution "agent-signoff-rejected" "false" "true" "false"
run_test_signoff_attribution "agent-amended-signoff-rejected" "false" "false" "false" "false" "false" "unsigned"
run_test_signoff_attribution "agent-added-signoff-rejected" "false" "false" "false" "false" "false" "signed"
run_test_signoff_attribution "agent-whitespace-amend-rejected" "false" "false" "false" "false" "false" "whitespace"
run_test_signoff_attribution "agent-duplicate-signoff-rejected" "false" "false" "false" "false" "false" "duplicate"
run_test_signoff_attribution "agent-reordered-signoffs-rejected" "false" "false" "false" "false" "false" "reorder"
# git cherry omits merges, so cover an agent-created signed merge explicitly.
run_test_signoff_attribution "signed-agent-merge-rejected" "false" "true" "false" "true"

# No agent commit (HEAD == origin/main) -> nothing to gate.
run_test_precommit_repo "no-changed-files-softpass" \
  "fail" "true" "false" "false" \
  "true" "No changed files"

# Repo without a pre-commit config -> gate skips (schema still validated).
run_test_precommit_repo "no-precommit-config-skip" \
  "fail" "false" "true" "false" \
  "true" "No .pre-commit-config.yaml"

# Check-only classification (the lib can only say pre-commit-blocked here, so
# the validator derives the category from the hook output):
#   every failed hook is a secret scanner -> soft-pass, post-script owns it
run_test_precommit_repo "secret-hook-only-softpass" \
  "secret-only" "true" "true" "false" \
  "true" "deferring to post-script"
#   pre-commit itself died before any hook ran -> infra soft-pass
run_test_precommit_repo "infra-failure-softpass" \
  "infra" "true" "true" "false" \
  "true" "infra/transient"
#   a secret hook alongside a fixable hook -> still consumes the iteration,
#   the agent can act on the fixable one
run_test_precommit_repo "mixed-secret-and-lint-consumes-iteration" \
  "mixed" "true" "true" "false" \
  "false" "FAIL: pre-commit-blocked"

# Diagnostics must appear exactly once in the captured stream — the runner
# truncates it to 10 KiB before it becomes the agent's prompt.
run_test_precommit_repo "diagnostics-printed-once" \
  "fail" "true" "true" "false" \
  "false" "E501 line too long"
if [ "$(grep -c "E501 line too long" "${TMPDIR}/stdout.log")" != "1" ]; then
  echo "FAIL: diagnostics-printed-once — hook output appears $(grep -c "E501 line too long" "${TMPDIR}/stdout.log") times, expected 1"
  FAILURES=$((FAILURES + 1))
fi

# The check-only contract: a formatter-style hook that rewrites files must
# NOT trigger the auto-fix + amend path.  TARGET_REPO_DIR is an extracted
# copy; an amend there would be invisible to the sandbox agent and would
# make the post-script's later authoritative run diverge from what the
# agent sees.  Expect a plain failure and an unmoved HEAD.
run_test_precommit_repo "check-only-never-amends" \
  "fail-modify" "true" "true" "false" \
  "false" "FAIL: pre-commit-blocked" "true"

# The diff base comes from the agent's declared target_branch, not the
# workflow's hard-coded TARGET_BRANCH (which is "main" for the code harness).
# Fixture: origin/develop at the agent's own commit, so diffing against
# develop yields no changed files and the gate is skipped; diffing against
# main would have found src.py and run the failing stub.
run_test_target_branch_resolution() {
  local test_name="agent-target-branch-wins-over-env"
  local test_dir="${TMPDIR}/${test_name}" repo_dir="${TMPDIR}/${test_name}/repo" bin_dir="${TMPDIR}/${test_name}/bin"
  mkdir -p "${test_dir}/output"
  echo '{"target_branch":"develop"}' > "${test_dir}/output/agent-result.json"
  make_repo_fixture "${repo_dir}" "true" "true" "false"
  git -C "${repo_dir}" update-ref refs/remotes/origin/develop HEAD
  make_precommit_stub "${bin_dir}" "fail"
  local fake_home="${test_dir}/home"; mkdir -p "${fake_home}"
  local exit_code=0
  HOME="${fake_home}" PATH="${bin_dir}:${PATH}" \
  FULLSEND_OUTPUT_SCHEMA="${SCHEMA}" TARGET_REPO_DIR="${repo_dir}" TARGET_BRANCH="main" \
    bash -c "cd '${test_dir}' && bash '${VALIDATOR}'" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?
  if [[ ${exit_code} -eq 0 ]] && grep -qF "No changed files" "${TMPDIR}/stdout.log"; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — expected diff against origin/develop (no changes, exit 0); got exit ${exit_code}"
    head -20 "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
  fi
}
run_test_target_branch_resolution

# ---------------------------------------------------------------------------
# Part 4: precommit_run_gate auto-fix path, against the real library
#
# post-code-test.sh and post-fix-test.sh never exercise the gate, so the
# auto-fix branch — nameref rebuild of the caller's array, amend, gitleaks
# re-scan, Signed-off-by re-check — had no coverage before or after the
# extraction. Drive the real function with stubs for pre-commit and gitleaks.
# ---------------------------------------------------------------------------

LIB_DIR="${SCRIPT_DIR}/lib"

# make_autofix_stubs <bindir> <gitleaks_rc>
#   pre-commit: first call rewrites src.py (formatter) and fails; second call
#   passes. gitleaks: exits with the given code.
make_autofix_stubs() {
  local bindir="$1" gitleaks_rc="$2"
  mkdir -p "${bindir}"
  cat > "${bindir}/pre-commit" <<STUB
#!/bin/sh
if [ ! -f "${bindir}/.ran-once" ]; then
  touch "${bindir}/.ran-once"
  echo "formatted" >> src.py
  echo "ruff-format..............................................................Failed"
  echo "- hook id: ruff-format"
  echo "- files were modified by this hook"
  exit 1
fi
echo "ruff-format..............................................................Passed"
exit 0
STUB
  cat > "${bindir}/gitleaks" <<STUB
#!/bin/sh
exit ${gitleaks_rc}
STUB
  chmod +x "${bindir}/pre-commit" "${bindir}/gitleaks"
}

# run_test_autofix <name> <gitleaks_rc> <expect_result> <expect_category> <expect_head_moved> <expect_secret_fail>
run_test_autofix() {
  local test_name="$1" gitleaks_rc="$2" expect_result="$3" expect_category="$4"
  local expect_head_moved="$5" expect_secret_fail="$6"
  local test_dir="${TMPDIR}/${test_name}" repo_dir="${TMPDIR}/${test_name}/repo" bin_dir="${TMPDIR}/${test_name}/bin"
  make_repo_fixture "${repo_dir}" "true" "true" "false"
  make_autofix_stubs "${bin_dir}" "${gitleaks_rc}"
  local base head_before
  base="$(git -C "${repo_dir}" rev-parse refs/remotes/origin/main)"
  head_before="$(git -C "${repo_dir}" rev-parse HEAD)"

  local out
  out="$(cd "${repo_dir}" && PATH="${bin_dir}:${PATH}" bash -c '
    set -euo pipefail
    source "'"${LIB_DIR}"'/post-failure-report.lib.sh"
    source "'"${LIB_DIR}"'/precommit-gate.lib.sh"
    files=(src.py)
    precommit_run_gate files "'"${base}"'..HEAD" main "'"${base}"'" >/dev/null 2>&1
    printf "result=%s category=%s secret=%s signoff=%s nfiles=%s
"       "${PRECOMMIT_GATE_RESULT}" "${PRECOMMIT_GATE_CATEGORY}"       "${PRECOMMIT_GATE_SECRET_FAIL}" "${PRECOMMIT_GATE_SIGNOFF_FAIL}" "${#files[@]}"
  ' 2>&1)"
  local head_after
  head_after="$(git -C "${repo_dir}" rev-parse HEAD)"

  local passed=true
  case "${out}" in *"result=${expect_result} category=${expect_category} "*) ;; *)
    echo "FAIL: ${test_name} — expected result=${expect_result} category=${expect_category}; got: ${out}"; passed=false;; esac
  case "${out}" in *"secret=${expect_secret_fail} "*) ;; *)
    echo "FAIL: ${test_name} — expected secret=${expect_secret_fail}; got: ${out}"; passed=false;; esac
  if [ "${expect_head_moved}" = "true" ] && [ "${head_after}" = "${head_before}" ]; then
    echo "FAIL: ${test_name} — expected HEAD to move (amend), it did not"; passed=false
  fi
  if [ "${expect_head_moved}" = "false" ] && [ "${head_after}" != "${head_before}" ]; then
    echo "FAIL: ${test_name} — expected HEAD unmoved, it moved"; passed=false
  fi
  # The amended commit must contain the hook's rewrite, staged only from the
  # files the gate was scoped to.
  if [ "${expect_head_moved}" = "true" ] && ! git -C "${repo_dir}" show HEAD:src.py | grep -q "^formatted$"; then
    echo "FAIL: ${test_name} — amended commit does not contain the hook's rewrite"; passed=false
  fi
  if [ "${passed}" = "true" ]; then echo "PASS: ${test_name}"; else FAILURES=$((FAILURES + 1)); fi
}

# Formatter rewrites a file -> re-stage, amend, gitleaks clean, retry passes.
# The caller's array survives the nameref rebuild (nfiles=1).
run_test_autofix "autofix-amends-and-retries" 0 "pass" "" "true" "false"
# Same, but the re-scan finds a secret -> secret-scan, amend already happened.
run_test_autofix "autofix-secret-rescan-fails" 1 "fail" "secret-scan" "true" "true"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
