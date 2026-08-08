#!/usr/bin/env bash
# pre-code-test.sh — Test pre-code.sh with mock gh to verify existing-PR check
# and the pre-script output protocol skip signal
# (fullsend docs/normative/prescript-output/v1, fullsend-ai/fullsend#4718).
#
# Uses a mock gh command to capture calls without hitting GitHub.
# Run from the repo root: bash scripts/pre-code-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"

PRE_SCRIPT="$(resolve_agent_script pre-code "${SCRIPT_DIR}")"
FAILURES=0

# Create a temp directory for mock state.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# --- Helpers ---

# build_mock creates a mock gh binary that returns preconfigured responses.
# Arguments:
#   $1 — JSON array to return for "gh pr list" calls. When the caller
#        passes --jq, the mock pipes this JSON through jq so the real
#        filter expression is exercised.  Pass an empty string for no PRs.
build_mock() {
  local pr_list_output="$1"
  local mock_bin="${TMPDIR}/bin"
  local gh_log="${TMPDIR}/gh-calls.log"

  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"
  : > "${gh_log}"

  # Write the pr list output to a file so the mock can read it.
  printf '%s' "${pr_list_output}" > "${TMPDIR}/pr-list-output.txt"

  cat > "${mock_bin}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
CALL_LOG="LOGFILE_PLACEHOLDER"
PR_OUTPUT="OUTPUT_PLACEHOLDER"

echo "gh $*" >> "${CALL_LOG}"

# Route by subcommand
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  # Parse --jq flag from arguments, just like the real gh CLI.
  JQ_EXPR=""
  shift 2
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--jq" ]]; then
      JQ_EXPR="$2"
      break
    fi
    shift
  done
  if [[ -n "${JQ_EXPR}" ]] && [[ -s "${PR_OUTPUT}" ]]; then
    jq -r "${JQ_EXPR}" "${PR_OUTPUT}"
  else
    cat "${PR_OUTPUT}"
  fi
elif [[ "$1" == "label" ]]; then
  exit 0
elif [[ "$1" == "api" ]]; then
  exit 0
elif [[ "$1" == "issue" && "$2" == "comment" ]]; then
  # Consume stdin (body-file reads from stdin)
  cat > /dev/null
  exit 0
fi
MOCKEOF

  # Patch placeholders with actual paths (avoid sed on source files,
  # but this is a generated mock — not repo source code).
  local escaped_log="${gh_log//\//\\/}"
  local escaped_out="${TMPDIR//\//\\/}\/pr-list-output.txt"
  perl -pi -e "s/LOGFILE_PLACEHOLDER/${escaped_log}/g" "${mock_bin}/gh"
  perl -pi -e "s/OUTPUT_PLACEHOLDER/${escaped_out}/g" "${mock_bin}/gh"

  chmod +x "${mock_bin}/gh"

  echo "${mock_bin}"
}

run_test() {
  local test_name="$1"
  local pr_list_output="$2"
  local expected_pattern="$3"
  local expect_exit="$4"         # 0 = success, 1 = failure
  local extra_env="${5:-}"       # additional env vars (KEY=VAL KEY2=VAL2)

  local mock_bin
  mock_bin="$(build_mock "${pr_list_output}")"
  local gh_log="${TMPDIR}/gh-calls.log"
  local gh_output="${TMPDIR}/github-output.txt"
  : > "${gh_output}"

  # Set base env vars for the script.
  local env_cmd=(
    env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE -u COMMENT_BODY
    PATH="${mock_bin}:${PATH}"
    ISSUE_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    GH_TOKEN="fake-token"
    GITHUB_OUTPUT="${gh_output}"
  )

  # Add extra env vars if provided (read line-by-line to support values with spaces).
  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  # Check exit code.
  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # The script must never write to GITHUB_OUTPUT — the legacy skipped= writes
  # were removed in favor of the pre-script output protocol, and fullsend run's
  # own relay writes to this file (last-write-wins collision otherwise).
  if [[ -s "${gh_output}" ]]; then
    echo "FAIL: ${test_name} — unexpected GITHUB_OUTPUT writes:"
    cat "${gh_output}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # Check expected pattern in gh calls (if provided).
  if [[ -n "${expected_pattern}" ]]; then
    if ! grep -qF "${expected_pattern}" "${gh_log}" 2>/dev/null; then
      echo "FAIL: ${test_name} — expected gh call pattern '${expected_pattern}' not found"
      echo "Actual calls:"
      cat "${gh_log}" 2>/dev/null || echo "(no calls)"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

# Check stdout contains a specific string.
run_test_stdout() {
  local test_name="$1"
  local pr_list_output="$2"
  local expected_stdout="$3"
  local expect_exit="$4"
  local extra_env="${5:-}"

  local mock_bin
  mock_bin="$(build_mock "${pr_list_output}")"
  local gh_output="${TMPDIR}/github-output.txt"
  : > "${gh_output}"

  local env_cmd=(
    env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE -u COMMENT_BODY
    PATH="${mock_bin}:${PATH}"
    ISSUE_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    GH_TOKEN="fake-token"
    GITHUB_OUTPUT="${gh_output}"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # The script must never write to GITHUB_OUTPUT — the legacy skipped= writes
  # were removed in favor of the pre-script output protocol, and fullsend run's
  # own relay writes to this file (last-write-wins collision otherwise).
  if [[ -s "${gh_output}" ]]; then
    echo "FAIL: ${test_name} — unexpected GITHUB_OUTPUT writes:"
    cat "${gh_output}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log" 2>/dev/null; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Check stdout contains one string and does NOT contain another.
run_test_stdout_excludes() {
  local test_name="$1"
  local pr_list_output="$2"
  local expected_stdout="$3"
  local excluded_stdout="$4"
  local expect_exit="$5"
  local extra_env="${6:-}"

  local mock_bin
  mock_bin="$(build_mock "${pr_list_output}")"
  local gh_output="${TMPDIR}/github-output.txt"
  : > "${gh_output}"

  local env_cmd=(
    env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE -u COMMENT_BODY
    PATH="${mock_bin}:${PATH}"
    ISSUE_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    GH_TOKEN="fake-token"
    GITHUB_OUTPUT="${gh_output}"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # The script must never write to GITHUB_OUTPUT — the legacy skipped= writes
  # were removed in favor of the pre-script output protocol, and fullsend run's
  # own relay writes to this file (last-write-wins collision otherwise).
  if [[ -s "${gh_output}" ]]; then
    echo "FAIL: ${test_name} — unexpected GITHUB_OUTPUT writes:"
    cat "${gh_output}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log" 2>/dev/null; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF "${excluded_stdout}" "${TMPDIR}/stdout.log" 2>/dev/null; then
    echo "FAIL: ${test_name} — excluded stdout '${excluded_stdout}' was found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Test cases ---

# JSON helpers — build unfiltered PR JSON that the mock returns to the
# script.  The mock pipes this through jq using the real --jq expression
# from pre-code.sh, so the filter is exercised end-to-end.

# Single human PR.
HUMAN_PR_JSON='[{"number":99,"author":{"login":"human-dev"},"url":"https://github.com/test-org/test-repo/pull/99"}]'

# Single fullsend-ai[bot] PR.
BOT_PR_JSON='[{"number":10,"author":{"login":"fullsend-ai[bot]"},"url":"https://github.com/test-org/test-repo/pull/10"}]'

# Single fullsend-ai-coder[bot] PR.
CODER_BOT_PR_JSON='[{"number":11,"author":{"login":"fullsend-ai-coder[bot]"},"url":"https://github.com/test-org/test-repo/pull/11"}]'

# Both bot PRs plus a human PR.
MIXED_PR_JSON='[{"number":10,"author":{"login":"fullsend-ai[bot]"},"url":"https://github.com/test-org/test-repo/pull/10"},{"number":11,"author":{"login":"fullsend-ai-coder[bot]"},"url":"https://github.com/test-org/test-repo/pull/11"},{"number":99,"author":{"login":"human-dev"},"url":"https://github.com/test-org/test-repo/pull/99"}]'

# Multiple human PRs.
MULTI_HUMAN_PR_JSON='[{"number":50,"author":{"login":"dev-a"},"url":"https://github.com/test-org/test-repo/pull/50"},{"number":51,"author":{"login":"dev-b"},"url":"https://github.com/test-org/test-repo/pull/51"}]'

# No existing PRs → agent proceeds (exit 0, no label/comment).
run_test_stdout "no-existing-prs-proceeds" \
  "" \
  "No existing human PRs found" \
  0

# Human PR exists → should apply label and comment, then exit 0.
run_test "human-pr-applies-label" \
  "${HUMAN_PR_JSON}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=pr-open --silent" \
  0

run_test "human-pr-posts-comment" \
  "${HUMAN_PR_JSON}" \
  "gh issue comment 42 --repo test-org/test-repo --body-file -" \
  0

run_test_stdout "human-pr-skips-agent" \
  "${HUMAN_PR_JSON}" \
  "Skipping code agent" \
  0

# Bot PR only → jq filter removes it → script sees empty output → proceeds.
run_test_stdout "bot-pr-does-not-block" \
  "${BOT_PR_JSON}" \
  "No existing human PRs found" \
  0

# CODE_FORCE=true → should skip check even with human PR.
run_test_stdout "force-override-code-force" \
  "${HUMAN_PR_JSON}" \
  "Force override" \
  0 \
  "CODE_FORCE=true"

# COMMENT_BODY contains --force → should also skip check.
run_test_stdout "force-override-comment-body" \
  "${HUMAN_PR_JSON}" \
  "Force override" \
  0 \
  "COMMENT_BODY=/fs-code --force"

# No GH_TOKEN → skips check entirely, exits 0.
run_test_stdout "no-gh-token-skips-check" \
  "" \
  "GH_TOKEN not set" \
  0 \
  "GH_TOKEN="

# Coder bot PR only → jq filter removes it → script proceeds.
run_test_stdout "coder-bot-pr-does-not-block" \
  "${CODER_BOT_PR_JSON}" \
  "No existing human PRs found" \
  0

# Both bots + human PR → jq filter removes bots, human PR blocks.
run_test_stdout "coder-bot-pr-plus-human-pr-blocks" \
  "${MIXED_PR_JSON}" \
  "Skipping code agent" \
  0

# Both bots only → jq filter removes all → script proceeds.
run_test_stdout "both-bots-do-not-block" \
  '[{"number":10,"author":{"login":"fullsend-ai[bot]"},"url":"https://github.com/test-org/test-repo/pull/10"},{"number":11,"author":{"login":"fullsend-ai-coder[bot]"},"url":"https://github.com/test-org/test-repo/pull/11"}]' \
  "No existing human PRs found" \
  0

# Multiple human PRs → should block and apply label.
run_test "multiple-human-prs-block" \
  "${MULTI_HUMAN_PR_JSON}" \
  "gh api repos/test-org/test-repo/issues/42/labels -f labels[]=pr-open --silent" \
  0

run_test_stdout "multiple-human-prs-notice" \
  "${MULTI_HUMAN_PR_JSON}" \
  "Found existing human PR #50 by @dev-a" \
  0

# PR label gets created.
run_test "pr-label-created" \
  "${HUMAN_PR_JSON}" \
  "gh label create pr-open --repo test-org/test-repo" \
  0

# --- Regression tests: workflow-command injection hardening (PR #576) ---

# The GITHUB_ISSUE_URL ::notice:: moved to after validation — it must not
# appear when validation fails, otherwise an unvalidated value could still
# reach GHA's workflow-command parser via the notice line.
run_test_stdout_excludes "notice-not-emitted-before-validation" \
  "" \
  "::error::ISSUE_NUMBER must be a positive integer" \
  "::notice::" \
  1 \
  "ISSUE_NUMBER=not-a-number"

# The reordering must not have dropped the notice entirely — it still fires
# on the validation-success path, with the validated GITHUB_ISSUE_URL.
run_test_stdout "notice-emitted-after-successful-validation" \
  "" \
  "::notice::🔗 Code target: https://github.com/test-org/test-repo/issues/42" \
  0

# COMMENT_BODY content itself must never reach stdout — only its length is
# logged, so a hostile trigger comment can't inject GHA workflow commands
# or terminal escape sequences via debug logging.
run_test_stdout_excludes "comment-body-not-echoed-raw" \
  "" \
  "COMMENT_BODY_LENGTH=" \
  "TOTALLY-SECRET-MARKER" \
  0 \
  "COMMENT_BODY=/fs-code TOTALLY-SECRET-MARKER"

# Validation-failure ::error:: lines strip embedded "::" from untrusted
# input before interpolating it — GHA's workflow-command parser triggers on
# any line starting with "::", so raw interpolation of a malformed value
# (which failed validation specifically because it's not well-formed)
# could inject a second workflow command.
run_test_stdout_excludes "error-line-strips-workflow-cmd-chars" \
  "" \
  "got: '1234'" \
  "got: '12::34'" \
  1 \
  "ISSUE_NUMBER=12::34"

# CODE_FORCE is interpolated in the force-override debug log — sanitize it
# so a value containing "::" can't inject a GHA workflow command.
run_test_stdout_excludes "code-force-sanitized-in-log" \
  "" \
  "CODE_FORCE='hasinjection'" \
  "has::injection" \
  0 \
  "CODE_FORCE=has::injection"

# --- Regression tests: --force bypasses PR search (issue #1697) ---
TAB=$'\t'

# COMMENT_BODY with --force must exit before PR search is reached.
run_test_stdout_excludes "force-comment-body-no-pr-search" \
  "99${TAB}human-dev${TAB}https://github.com/test-org/test-repo/pull/99" \
  "Force override" \
  "Checking for existing open PRs" \
  0 \
  "COMMENT_BODY=/fs-code --force"

# CODE_FORCE=true must exit before PR search is reached.
run_test_stdout_excludes "force-code-force-no-pr-search" \
  "99${TAB}human-dev${TAB}https://github.com/test-org/test-repo/pull/99" \
  "Force override" \
  "Checking for existing open PRs" \
  0 \
  "CODE_FORCE=true"

# Force check logs COMMENT_BODY value for debuggability.
run_test_stdout "force-check-logs-comment-body" \
  "" \
  "Evaluating force override:" \
  0 \
  "COMMENT_BODY=/fs-code --force"

# Without --force, PR search IS reached (no false bypass).
run_test_stdout "no-force-reaches-pr-search" \
  "" \
  "Checking for existing open PRs" \
  0 \
  "COMMENT_BODY=/fs-code"

# --- Anchoring: --force counts only as the command's flag token ---
# Mirrors the dispatch router's first-line tokenization. A comment that
# merely mentions --force must not bypass the existing-PR check.

# A longer flag sharing the prefix does not bypass; the check still blocks.
run_test_stdout "forceful-prefix-does-not-bypass" \
  "${HUMAN_PR_JSON}" \
  "Skipping code agent" \
  0 \
  "COMMENT_BODY=/fs-code --forceful"

# A mid-sentence mention of --force does not bypass.
run_test_stdout "force-mid-sentence-does-not-bypass" \
  "${HUMAN_PR_JSON}" \
  "Skipping code agent" \
  0 \
  "COMMENT_BODY=please don't use --force on this issue"

# --force anywhere but the flag position does not bypass.
run_test_stdout "force-third-token-does-not-bypass" \
  "${HUMAN_PR_JSON}" \
  "Skipping code agent" \
  0 \
  "COMMENT_BODY=/fs-code now --force"

# --- Pre-script output protocol tests (fullsend-ai/fullsend#4718) ---
# Contract: fullsend docs/normative/prescript-output/v1. The script writes
# skipped=true (plus reason=...) to FULLSEND_PRESCRIPT_OUTPUT only when an
# open human PR blocks the run; every proceed path leaves the file empty
# (absent skipped means proceed).

# Helper: run pre-code.sh with FULLSEND_PRESCRIPT_OUTPUT set and assert the
# protocol file's exact content ("" = must stay empty).
run_test_prescript_output() {
  local test_name="$1"
  local pr_list_output="$2"
  local expected_content="$3"
  local expect_exit="$4"
  local extra_env="${5:-}"

  local mock_bin
  mock_bin="$(build_mock "${pr_list_output}")"
  local proto_out="${TMPDIR}/prescript-output.txt"
  local gh_output="${TMPDIR}/github-output.txt"
  : > "${proto_out}"
  : > "${gh_output}"

  local env_cmd=(
    env -u FULLSEND_PRESCRIPT_OUTPUT -u CODE_FORCE -u COMMENT_BODY
    PATH="${mock_bin}:${PATH}"
    ISSUE_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    GITHUB_ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
    GH_TOKEN="fake-token"
    GITHUB_OUTPUT="${gh_output}"
    FULLSEND_PRESCRIPT_OUTPUT="${proto_out}"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # The script must never write to GITHUB_OUTPUT — the legacy skipped= writes
  # were removed in favor of the pre-script output protocol, and fullsend run's
  # own relay writes to this file (last-write-wins collision otherwise).
  if [[ -s "${gh_output}" ]]; then
    echo "FAIL: ${test_name} — unexpected GITHUB_OUTPUT writes:"
    cat "${gh_output}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! diff <(printf '%s' "${expected_content}") "${proto_out}" > "${TMPDIR}/proto-diff.log" 2>&1; then
    echo "FAIL: ${test_name} — protocol output mismatch"
    cat "${TMPDIR}/proto-diff.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

NL=$'\n'

# Existing human PR → skipped=true with a single-line reason naming the PR.
run_test_prescript_output "protocol-skip-on-existing-pr" \
  "${HUMAN_PR_JSON}" \
  "skipped=true${NL}reason=open PR #99 by @human-dev already addresses issue #42${NL}" \
  0

# No existing PRs → file stays empty (absent skipped = proceed).
run_test_prescript_output "protocol-empty-on-no-prs" \
  "" \
  "" \
  0

# Force override exits before the PR check → file stays empty.
run_test_prescript_output "protocol-empty-on-force" \
  "${HUMAN_PR_JSON}" \
  "" \
  0 \
  "CODE_FORCE=true"

# No GH_TOKEN → check skipped, run proceeds → file stays empty.
run_test_prescript_output "protocol-empty-on-no-token" \
  "" \
  "" \
  0 \
  "GH_TOKEN="

# Bot-only PRs are filtered out → proceed → file stays empty.
run_test_prescript_output "protocol-empty-on-bot-prs" \
  "${BOT_PR_JSON}" \
  "" \
  0

# Old-CLI guard (fails open by design, see the protocol's Version skew
# section): FULLSEND_PRESCRIPT_OUTPUT unset + existing human PR → the
# script must not crash under set -u; it comments/labels and exits 0.
# All earlier tests in this file also run with the variable unset; this
# one documents the skip path explicitly.
run_test_stdout "protocol-unset-env-old-cli-fails-open" \
  "${HUMAN_PR_JSON}" \
  "Skipping code agent" \
  0

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
