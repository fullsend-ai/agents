#!/usr/bin/env bash
# post-prioritize-test.sh — Test post-prioritize.sh with fixture JSON and mock gh/fullsend.
#
# Run from the repo root: bash scripts/post-prioritize-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"
POST_SCRIPT="$(resolve_agent_script post-prioritize "${SCRIPT_DIR}")"
FAILURES=0

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

GH_LOG="${TEST_TMPDIR}/gh-calls.log"
GH_FAIL_COUNT="${TEST_TMPDIR}/gh-fail-count"
FS_ENV_LOG="${TEST_TMPDIR}/fullsend-env.log"
MOCK_BIN="${TEST_TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"

MOCK_PROJECT_ID="PVT_test_project"
MOCK_ITEM_ID="PVTI_test_item"
MOCK_ISSUE_NODE_ID="I_test_issue_node"

cat > "${MOCK_BIN}/gh" <<MOCKEOF
#!/usr/bin/env bash
GH_LOG_FILE="${GH_LOG}"
GH_FAIL_COUNT_FILE="${GH_FAIL_COUNT}"

echo "gh \$*" >> "\${GH_LOG_FILE}"

if [[ "\$1" == "api" && "\$2" == "rate_limit" ]]; then
  now=\$(date +%s)
  reset=\$(( now + 3600 ))
  printf '{"resources":{"core":{"limit":5000,"remaining":4999,"reset":%s},"graphql":{"limit":5000,"remaining":4999,"reset":%s}}}\n' "\${reset}" "\${reset}"
  exit 0
fi

fail_count=0
if [[ -f "\${GH_FAIL_COUNT_FILE}" ]]; then
  fail_count=\$(cat "\${GH_FAIL_COUNT_FILE}")
fi
fail_count=\$(( fail_count + 1 ))
echo "\${fail_count}" > "\${GH_FAIL_COUNT_FILE}"

if [[ "\${GH_CSMA_FAIL_MODE:-}" == "auth" ]] && [[ "\$1" != "api" || "\$2" != "rate_limit" ]]; then
  echo "ERROR: Resource not accessible by integration" >&2
  exit 1
fi

# Simulate gh exiting 0 but printing a rate limit error to stdout.
# This is how "gh project view" behaves on GraphQL rate limits.
if [[ "\${GH_CSMA_FAIL_MODE:-}" == "exit0-ratelimit" ]] && [[ "\$1" != "api" || "\$2" != "rate_limit" ]]; then
  if (( fail_count <= GH_CSMA_FAIL_UNTIL )); then
    echo "GraphQL: API rate limit exceeded for installation ID 131739396." >&2
    exit 0
  fi
fi

if [[ -n "\${GH_CSMA_FAIL_UNTIL:-}" ]] && (( fail_count <= GH_CSMA_FAIL_UNTIL )); then
  echo "You have exceeded a secondary rate limit. Please retry again later." >&2
  exit 1
fi

case "\$*" in
  *"project view"*)
    printf '{"id":"%s"}\n' "${MOCK_PROJECT_ID}"
    exit 0
    ;;
  *"repos/"*"/issues/"*)
    if [[ "\$*" == *"--jq"* ]]; then
      printf '%s\n' "${MOCK_ISSUE_NODE_ID}"
    else
      printf '{"node_id":"%s"}\n' "${MOCK_ISSUE_NODE_ID}"
    fi
    exit 0
    ;;
  *"project field-list"*)
    cat <<'FIELDS'
{"fields":[
  {"id":"PVTF_reach","name":"RICE Reach"},
  {"id":"PVTF_impact","name":"RICE Impact"},
  {"id":"PVTF_confidence","name":"RICE Confidence"},
  {"id":"PVTF_effort","name":"RICE Effort"},
  {"id":"PVTF_score","name":"RICE Score"}
]}
FIELDS
    exit 0
    ;;
esac

if [[ "\$1" == "api" && "\$2" == "graphql" ]]; then
  if [[ "\$*" == *"--input"* ]]; then
    input=\$(cat)
    if echo "\${input}" | grep -q 'updateProjectV2ItemFieldValue'; then
      echo '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_test_item"}}}}'
      exit 0
    fi
  fi
  printf '{"data":{"node":{"projectItems":{"nodes":[{"id":"%s","project":{"id":"%s"}}]}}}}\n' \
    "${MOCK_ITEM_ID}" "${MOCK_PROJECT_ID}"
  exit 0
fi

echo "unexpected gh invocation: \$*" >&2
exit 99
MOCKEOF
chmod +x "${MOCK_BIN}/gh"

cat > "${MOCK_BIN}/fullsend" <<MOCKEOF
#!/usr/bin/env bash
BODY=""
PREV=""
echo "email=\${FULLSEND_JIRA_EMAIL-<unset>} token=\${FULLSEND_JIRA_TOKEN-<unset>}" >> "${FS_ENV_LOG}"
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
export GH_LOG="${GH_LOG}"
export GH_FAIL_COUNT="${GH_FAIL_COUNT}"
export MOCK_PROJECT_ID="${MOCK_PROJECT_ID}"
export MOCK_ITEM_ID="${MOCK_ITEM_ID}"
export MOCK_ISSUE_NODE_ID="${MOCK_ISSUE_NODE_ID}"
export ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
export GH_TOKEN="fake-token"
export ORG="test-org"
export PROJECT_NUMBER="1"
export FULLSEND_FORGE="github"
export GITHUB_CSMA_SLOT_MAX_MS=0
export GITHUB_CSMA_BACKOFF_CAP_SEC=1
export GITHUB_CSMA_SPREAD_MAX_SEC=0

FIXTURE_JSON='{
  "reach": 3,
  "impact": 2,
  "confidence": 0.8,
  "effort": 2,
  "reasoning": {
    "reach": "Many users affected.",
    "impact": "Moderate workflow improvement.",
    "confidence": "Some customer signal.",
    "effort": "Small scoped change."
  }
}'

run_test() {
  local test_name="$1"
  local fail_until="${2:-}"
  local min_gh_calls="${3:-1}"
  local expect_failure="${4:-false}"
  local fail_mode="${5:-}"

  local run_dir="${TEST_TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${FIXTURE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"

  : > "${GH_LOG}"
  rm -f "${GH_FAIL_COUNT}"
  unset GH_CSMA_FAIL_UNTIL GH_CSMA_FAIL_MODE
  if [[ -n "${fail_until}" ]]; then
    export GH_CSMA_FAIL_UNTIL="${fail_until}"
  fi
  if [[ -n "${fail_mode}" ]]; then
    export GH_CSMA_FAIL_MODE="${fail_mode}"
  fi

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TEST_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

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
    cat "${TEST_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local gh_calls
  gh_calls=$(wc -l < "${GH_LOG}")
  if (( gh_calls < min_gh_calls )); then
    echo "FAIL: ${test_name} — expected at least ${min_gh_calls} gh calls, got ${gh_calls}"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF 'project view' "${GH_LOG}"; then
    echo "FAIL: ${test_name} — missing project view call"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF 'fullsend post-comment' "${GH_LOG}"; then
    echo "FAIL: ${test_name} — missing fullsend post-comment call"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF 'fullsend:prioritize-agent' "${GH_LOG}"; then
    echo "FAIL: ${test_name} — comment marker not posted"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_failure_stderr() {
  local test_name="$1"
  local fail_until="$2"
  local expected_stderr="$3"
  local fail_mode="${4:-}"

  local run_dir="${TEST_TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${FIXTURE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"

  : > "${GH_LOG}"
  rm -f "${GH_FAIL_COUNT}"
  unset GH_CSMA_FAIL_UNTIL GH_CSMA_FAIL_MODE
  export GITHUB_CSMA_MAX_ATTEMPTS="${GITHUB_CSMA_MAX_ATTEMPTS:-8}"
  if [[ -n "${fail_until}" ]]; then
    export GH_CSMA_FAIL_UNTIL="${fail_until}"
  fi
  if [[ -n "${fail_mode}" ]]; then
    export GH_CSMA_FAIL_MODE="${fail_mode}"
  fi

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TEST_TMPDIR}/stdout-${test_name}.log" 2> "${TEST_TMPDIR}/stderr-${test_name}.log" || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected failure but got success"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stderr}" "${TEST_TMPDIR}/stderr-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected stderr containing '${expected_stderr}'"
    cat "${TEST_TMPDIR}/stderr-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Unit tests for shared CSMA helpers.
# --- Inlined from lib/github-api-csma.sh ---
# CSMA/CD-style resilience for GitHub API calls via gh/fullsend.
# Carrier sense: check rate_limit before transmitting.
# Slot time: random jitter between calls to desynchronize parallel runners.
# Collision detection: retry on 429 / secondary rate limit errors with exponential backoff.
#
# Environment (all optional):
#   GITHUB_CSMA_MAX_ATTEMPTS          — default 8
#   GITHUB_CSMA_MIN_REMAINING_CORE    — default 100
#   GITHUB_CSMA_MIN_REMAINING_GRAPHQL — default 100
#   GITHUB_CSMA_SLOT_MIN_MS           — default 250
#   GITHUB_CSMA_SLOT_MAX_MS           — default 750 (0 disables jitter)
#   GITHUB_CSMA_SPREAD_MAX_SEC        — default 60 (post-reset desync spread)
#   GITHUB_CSMA_BACKOFF_CAP_SEC       — default 120

# shellcheck shell=bash

[[ -n "${GITHUB_API_CSMA_SH_LOADED:-}" ]] && return 0
GITHUB_API_CSMA_SH_LOADED=1

_github_csma_max_attempts() {
  echo "${GITHUB_CSMA_MAX_ATTEMPTS:-8}"
}

_github_csma_min_remaining() {
  local resource="$1"
  case "${resource}" in
    graphql) echo "${GITHUB_CSMA_MIN_REMAINING_GRAPHQL:-100}" ;;
    *) echo "${GITHUB_CSMA_MIN_REMAINING_CORE:-100}" ;;
  esac
}

_github_csma_slot_min_ms() {
  echo "${GITHUB_CSMA_SLOT_MIN_MS:-250}"
}

_github_csma_slot_max_ms() {
  echo "${GITHUB_CSMA_SLOT_MAX_MS:-750}"
}

_github_csma_spread_max_sec() {
  echo "${GITHUB_CSMA_SPREAD_MAX_SEC:-60}"
}

_github_csma_backoff_cap_sec() {
  echo "${GITHUB_CSMA_BACKOFF_CAP_SEC:-120}"
}

# Add a random spread delay after a rate-limit sleep to desynchronize runners.
# Called from both github_csma_sense and _github_csma_sleep_after_rate_limit.
_github_csma_post_reset_spread() {
  local spread_max
  spread_max=$(_github_csma_spread_max_sec)
  if (( spread_max > 0 )); then
    local spread_secs=$(( RANDOM % spread_max ))
    echo "Rate limit reset — spreading ${spread_secs}s to desync from other runners..." >&2
    sleep "${spread_secs}"
  fi
}

_github_csma_emit_failure() {
  printf '%s\n' "$1" >&2
}

# Wait until the named rate_limit resource has enough quota (carrier sense).
# Usage: github_csma_sense [core|graphql] [min_remaining]
github_csma_sense() {
  local resource="${1:-core}"
  local min_remaining="${2:-$(_github_csma_min_remaining "${resource}")}"

  local info remaining reset now wait_secs
  if ! info=$(gh api rate_limit 2>/dev/null); then
    echo "WARNING: github_csma_sense: could not read rate_limit; proceeding" >&2
    return 0
  fi

  remaining=$(echo "${info}" | jq -r --arg r "${resource}" '.resources[$r].remaining // empty')
  reset=$(echo "${info}" | jq -r --arg r "${resource}" '.resources[$r].reset // empty')

  if [[ -z "${remaining}" || "${remaining}" == "null" ]]; then
    echo "WARNING: github_csma_sense: no .resources.${resource} in rate_limit; proceeding" >&2
    return 0
  fi

  if (( remaining >= min_remaining )); then
    return 0
  fi

  now=$(date +%s)
  wait_secs=$(( reset - now + 1 ))
  if (( wait_secs < 1 )); then
    wait_secs=1
  fi
  cap=$(_github_csma_backoff_cap_sec)
  if (( wait_secs > cap )); then
    wait_secs="${cap}"
  fi

  echo "Rate limit sense: ${resource} remaining=${remaining} (min=${min_remaining}); waiting ${wait_secs}s until reset..." >&2
  sleep "${wait_secs}"

  # After a rate-limit sleep, all runners wake at the same reset timestamp.
  # Spread them over a wide window to avoid a thundering herd.
  _github_csma_post_reset_spread
}

# Random inter-call delay (slot time) to reduce synchronized collisions.
github_csma_slot() {
  local max_ms min_ms span_ms delay_ms
  max_ms=$(_github_csma_slot_max_ms)
  if (( max_ms <= 0 )); then
    return 0
  fi
  min_ms=$(_github_csma_slot_min_ms)
  if (( min_ms > max_ms )); then
    min_ms="${max_ms}"
  fi
  span_ms=$(( max_ms - min_ms + 1 ))
  delay_ms=$(( min_ms + RANDOM % span_ms ))
  sleep "$(awk -v ms="${delay_ms}" 'BEGIN { printf "%.3f", ms / 1000 }')"
}

# Return 0 if combined output looks like a retryable GitHub rate limit error.
github_csma_is_rate_limit() {
  local text="$1"
  local lower
  lower=$(echo "${text}" | tr '[:upper:]' '[:lower:]')

  if echo "${lower}" | grep -qE 'http 429|status: 429'; then
    return 0
  fi
  if echo "${lower}" | grep -qE 'secondary rate limit|rate limit exceeded|api rate limit'; then
    return 0
  fi
  if echo "${lower}" | grep -qE 'http 403|status: 403'; then
    if echo "${lower}" | grep -qE 'secondary|rate limit|abuse|retry.after'; then
      return 0
    fi
  fi
  return 1
}

# Compute backoff seconds for attempt (0-based). Writes to stdout.
github_csma_backoff() {
  local attempt="$1"
  local cap base delay
  cap=$(_github_csma_backoff_cap_sec)
  base=$(( 1 << attempt ))
  if (( base > cap )); then
    base="${cap}"
  fi
  delay=$(( RANDOM % (base + 1) ))
  if (( delay < 1 )); then
    delay=1
  fi
  echo "${delay}"
}

_github_csma_sleep_after_rate_limit() {
  local attempt="$1"
  local resource="${2:-core}"
  local delay wait_secs now reset info cap

  delay=$(github_csma_backoff "${attempt}")
  if info=$(gh api rate_limit 2>/dev/null); then
    now=$(date +%s)
    reset=$(echo "${info}" | jq -r --arg r "${resource}" '.resources[$r].reset // empty')
    if [[ -n "${reset}" && "${reset}" != "null" ]]; then
      wait_secs=$(( reset - now + 1 ))
      cap=$(_github_csma_backoff_cap_sec)
      if (( wait_secs > cap )); then
        wait_secs="${cap}"
      fi
      if (( wait_secs > delay && wait_secs > 0 )); then
        delay="${wait_secs}"
      fi
    fi
  fi
  echo "GitHub API rate limit (attempt $(( attempt + 1 ))); backing off ${delay}s..." >&2
  sleep "${delay}"

  # After backing off, spread runners to avoid thundering herd on wake.
  _github_csma_post_reset_spread
}

# Run gh with CSMA/CD. First argument: rate_limit resource (core|graphql).
# Remaining arguments are passed to gh. Prints gh stdout on success.
github_csma_run() {
  local resource="${1:-core}"
  shift

  local max_attempts attempt outfile errfile combined
  max_attempts=$(_github_csma_max_attempts)
  outfile=$(mktemp)
  errfile=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '${outfile}' '${errfile}'" RETURN

  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    github_csma_sense "${resource}"
    github_csma_slot

    : >"${outfile}"
    : >"${errfile}"
    local rc=0
    gh "$@" >"${outfile}" 2>"${errfile}" || rc=$?

    combined=$(cat "${outfile}" "${errfile}")
    if github_csma_is_rate_limit "${combined}"; then
      if (( attempt < max_attempts - 1 )); then
        _github_csma_sleep_after_rate_limit "${attempt}" "${resource}"
        continue
      fi
      _github_csma_emit_failure "${combined}"
      return 1
    fi

    if (( rc != 0 )); then
      _github_csma_emit_failure "${combined}"
      return 1
    fi
    cat "${outfile}"
    return 0
  done

  return 1
}

# Run producer | gh with CSMA/CD. First argument: resource; rest are gh args.
# Reads producer output from stdin (save once for retries).
github_csma_run_pipe() {
  local resource="${1:-graphql}"
  shift

  local max_attempts attempt infile outfile errfile combined
  max_attempts=$(_github_csma_max_attempts)
  infile=$(mktemp)
  outfile=$(mktemp)
  errfile=$(mktemp)
  cat >"${infile}"
  # shellcheck disable=SC2064
  trap "rm -f '${infile}' '${outfile}' '${errfile}'" RETURN

  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    github_csma_sense "${resource}"
    github_csma_slot

    : >"${outfile}"
    : >"${errfile}"
    local rc=0
    gh "$@" <"${infile}" >"${outfile}" 2>"${errfile}" || rc=$?

    combined=$(cat "${outfile}" "${errfile}")
    if github_csma_is_rate_limit "${combined}"; then
      if (( attempt < max_attempts - 1 )); then
        _github_csma_sleep_after_rate_limit "${attempt}" "${resource}"
        continue
      fi
      _github_csma_emit_failure "${combined}"
      return 1
    fi

    if (( rc != 0 )); then
      _github_csma_emit_failure "${combined}"
      return 1
    fi
    cat "${outfile}"
    return 0
  done

  return 1
}

# Run an arbitrary command with stdin from caller; retries on rate-limit errors in output.
# First argument: rate_limit resource (core|graphql); remaining args are the command.
github_csma_run_cmd() {
  local resource="${1:-core}"
  shift

  local max_attempts attempt infile outfile errfile combined
  max_attempts=$(_github_csma_max_attempts)
  infile=$(mktemp)
  outfile=$(mktemp)
  errfile=$(mktemp)
  cat >"${infile}"
  # shellcheck disable=SC2064
  trap "rm -f '${infile}' '${outfile}' '${errfile}'" RETURN

  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    github_csma_sense "${resource}"
    github_csma_slot

    : >"${outfile}"
    : >"${errfile}"
    local rc=0
    "$@" <"${infile}" >"${outfile}" 2>"${errfile}" || rc=$?

    combined=$(cat "${outfile}" "${errfile}")
    if github_csma_is_rate_limit "${combined}"; then
      if (( attempt < max_attempts - 1 )); then
        _github_csma_sleep_after_rate_limit "${attempt}" "${resource}"
        continue
      fi
      _github_csma_emit_failure "${combined}"
      return 1
    fi

    if (( rc != 0 )); then
      _github_csma_emit_failure "${combined}"
      return 1
    fi
    cat "${outfile}"
    return 0
  done

  return 1
}
# --- End inlined CSMA ---
if github_csma_is_rate_limit "HTTP 429: Too Many Requests"; then
  :
else
  echo "FAIL: github_csma_is_rate_limit — expected HTTP 429 match"
  FAILURES=$((FAILURES + 1))
fi
if github_csma_is_rate_limit "You have exceeded a secondary rate limit"; then
  :
else
  echo "FAIL: github_csma_is_rate_limit — expected secondary limit match"
  FAILURES=$((FAILURES + 1))
fi
if ! github_csma_is_rate_limit '{"totalCount":429}'; then
  :
else
  echo "FAIL: github_csma_is_rate_limit — bare 429 must not match"
  FAILURES=$((FAILURES + 1))
fi
delay=$(github_csma_backoff 0)
if (( delay >= 1 && delay <= 120 )); then
  echo "PASS: github_csma_backoff"
else
  echo "FAIL: github_csma_backoff — delay out of range: ${delay}"
  FAILURES=$((FAILURES + 1))
fi

# Happy path: no injected failures.
run_test "happy-path" "" 8

# Retry path: first two non-rate-limit gh calls fail with secondary limit, then succeed.
run_test "rate-limit-retry" "2" 10

# Non-retryable errors must surface to stderr without retry loops.
run_test_failure_stderr "auth-error" "" "Resource not accessible by integration" "auth"

# Exhausted retries on persistent rate limits.
export GITHUB_CSMA_MAX_ATTEMPTS=3
run_test_failure_stderr "exhausted-retries" "100" "secondary rate limit"
unset GITHUB_CSMA_MAX_ATTEMPTS

# gh exits 0 but output contains rate limit error (gh project view behavior).
# First 2 calls fail with exit-0 rate limit, then succeed.
run_test "exit0-rate-limit-retry" "2" 10 "false" "exit0-ratelimit"

# Exhausted retries when gh keeps exiting 0 with rate limit errors.
export GITHUB_CSMA_MAX_ATTEMPTS=3
run_test_failure_stderr "exit0-rate-limit-exhausted" "100" "rate limit exceeded" "exit0-ratelimit"
unset GITHUB_CSMA_MAX_ATTEMPTS

# ---------------------------------------------------------------------------
# FULLSEND_VALIDATED_ITERATION_DIR tests
# Verify that when FULLSEND_VALIDATED_ITERATION_DIR is set, the script reads
# from that directory instead of scanning iteration-*/output.
# ---------------------------------------------------------------------------

run_validated_dir_test() {
  local test_name="$1"
  local validated_dir_file="$2"   # "agent-result.json", "result.json", or "none"
  local expected_stdout="$3"
  local expect_failure="${4:-false}"

  local run_dir="${TEST_TMPDIR}/run-${test_name}"
  local validated_dir="${run_dir}/validated-output"
  mkdir -p "${validated_dir}"

  # Place the fixture in the validated dir under the specified filename.
  if [[ "${validated_dir_file}" != "none" ]]; then
    echo "${FIXTURE_JSON}" > "${validated_dir}/${validated_dir_file}"
  fi

  # Also place a DIFFERENT result in iteration-2 to ensure the script does
  # NOT fall back to scanning when the validated dir is set.
  mkdir -p "${run_dir}/iteration-2/output"
  echo '{"reach":0,"impact":0,"confidence":0,"effort":1,"reasoning":{"reach":"wrong","impact":"wrong","confidence":"wrong","effort":"wrong"}}' \
    > "${run_dir}/iteration-2/output/agent-result.json"

  : > "${GH_LOG}"
  rm -f "${GH_FAIL_COUNT}"
  unset GH_CSMA_FAIL_UNTIL GH_CSMA_FAIL_MODE 2>/dev/null || true

  local exit_code=0
  (
    cd "${run_dir}"
    export FULLSEND_VALIDATED_ITERATION_DIR="${validated_dir}"
    bash "${POST_SCRIPT}"
  ) > "${TEST_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

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
    cat "${TEST_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_stdout}" ]] && ! grep -qF -- "${expected_stdout}" "${TEST_TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TEST_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Validated dir has agent-result.json → used
run_validated_dir_test "validated-dir-expected-filename" \
  "agent-result.json" \
  "Reading RICE result from: ${TEST_TMPDIR}/run-validated-dir-expected-filename/validated-output/agent-result.json"

# Validated dir has only result.json → used as fallback
run_validated_dir_test "validated-dir-fallback-filename" \
  "result.json" \
  "Reading RICE result from: ${TEST_TMPDIR}/run-validated-dir-fallback-filename/validated-output/result.json"

# Validated dir has neither filename → fails closed
run_validated_dir_test "validated-dir-neither-filename" \
  "none" \
  "" \
  "true"

# ---------------------------------------------------------------------------
# GitLab forge tests
# Verify that post-prioritize.sh works correctly with FULLSEND_FORGE=gitlab.
# ---------------------------------------------------------------------------

# Switch to GitLab forge.
export FULLSEND_FORGE="gitlab"
export ISSUE_URL="https://gitlab.com/test-group/test-project/-/issues/42"
export GITLAB_TOKEN="fake-gitlab-token"
export CI_SERVER_HOST="gitlab.com"
unset GH_TOKEN
unset GITLAB_HOST
unset ORG
unset PROJECT_NUMBER

CURL_LOG="${TEST_TMPDIR}/curl-calls.log"
MOCK_NOTES_FILE="${TEST_TMPDIR}/mock-notes-override.json"
printf '#!/usr/bin/env bash\necho "curl $*" >> %s\nMOCK_NOTES_FILE=%s\n' "${CURL_LOG}" "${MOCK_NOTES_FILE}" > "${MOCK_BIN}/curl"
cat >> "${MOCK_BIN}/curl" <<'CURLMOCK'

# Parse the URL from args.
URL=""
METHOD="GET"
WRITE_OUT=""
HAS_FAIL=""
for arg in "$@"; do
  case "${arg}" in
    --request) shift_next=method ;;
    --fail) HAS_FAIL=1 ;;
    --silent|--show-error) ;;
    --header|--connect-timeout|--max-time|--data|--data-urlencode) shift_next=skip ;;
    --write-out) shift_next=writeout ;;
    *)
      if [[ "${shift_next:-}" == "method" ]]; then
        METHOD="${arg}"
        shift_next=""
      elif [[ "${shift_next:-}" == "skip" ]]; then
        shift_next=""
      elif [[ "${shift_next:-}" == "writeout" ]]; then
        WRITE_OUT="${arg}"
        shift_next=""
      elif [[ "${arg}" =~ ^https:// ]]; then
        URL="${arg}"
      fi
      ;;
  esac
done

# Return bot user identity.
if [[ "${URL}" =~ /user$ ]] && [[ "${METHOD}" == "GET" ]]; then
  echo '{"username":"fullsend-bot","id":12345,"name":"Fullsend Bot"}'
  exit 0
fi

# Return notes list — check for test-specific override file (page 1 only).
if [[ "${URL}" =~ /notes\? ]] && [[ "${METHOD}" == "GET" ]]; then
  if [[ "${URL}" =~ page=1 ]] || [[ ! "${URL}" =~ page=[0-9] ]]; then
    if [[ -f "${MOCK_NOTES_FILE}" ]]; then
      cat "${MOCK_NOTES_FILE}"
    else
      echo '[]'
    fi
  else
    echo '[]'
  fi
  exit 0
fi

# PUT to notes — sticky comment update.
if [[ "${URL}" =~ /notes/[0-9]+$ ]] && [[ "${METHOD}" == "PUT" ]]; then
  echo '{"id":1}'
  exit 0
fi

# POST to notes — comment posting.
if [[ "${URL}" =~ /notes$ ]] && [[ "${METHOD}" == "POST" ]]; then
  echo '{"id":1}'
  exit 0
fi

echo '{"ok":true}'
exit 0
CURLMOCK
chmod +x "${MOCK_BIN}/curl"

run_gitlab_test() {
  local test_name="$1"
  local expect_failure="${2:-false}"
  local custom_fixture="${3:-}"

  local run_dir="${TEST_TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  if [[ -n "${custom_fixture}" ]]; then
    echo "${custom_fixture}" > "${run_dir}/iteration-1/output/agent-result.json"
  else
    echo "${FIXTURE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"
  fi

  : > "${CURL_LOG}"
  : > "${GH_LOG}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TEST_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

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
    cat "${TEST_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_gitlab_test_no_gh() {
  local test_name="$1"

  local run_dir="${TEST_TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${FIXTURE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${CURL_LOG}"
  : > "${GH_LOG}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TEST_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TEST_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -s "${GH_LOG}" ]]; then
    echo "FAIL: ${test_name} — gh was called but should not be on gitlab forge"
    echo "gh calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_gitlab_test_curl_pattern() {
  local test_name="$1"
  local expected_pattern="$2"

  local run_dir="${TEST_TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${FIXTURE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"

  : > "${CURL_LOG}"
  : > "${GH_LOG}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TEST_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TEST_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_pattern}" "${CURL_LOG}"; then
    echo "FAIL: ${test_name} — expected curl call pattern '${expected_pattern}' not found"
    echo "Actual curl calls:"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_gitlab_test_stdout() {
  local test_name="$1"
  local expected_stdout="$2"

  local run_dir="${TEST_TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${FIXTURE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"

  : > "${CURL_LOG}"
  : > "${GH_LOG}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TEST_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TEST_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_stdout}" "${TEST_TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TEST_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Core test: GitLab forge uses curl, not gh.
run_gitlab_test_no_gh "gitlab-no-gh-calls"

# GitLab happy path: scores posted and comment posted.
run_gitlab_test "gitlab-happy-path"

# GitLab posts comment via curl POST to notes API.
run_gitlab_test_curl_pattern "gitlab-posts-comment" \
  "--request POST https://gitlab.com/api/v4/projects/test-group%2Ftest-project/issues/42/notes"

# GitLab curl calls use timeout flags.
run_gitlab_test_curl_pattern "gitlab-curl-has-timeout-flags" \
  "--connect-timeout 10 --max-time 30"

# GitLab custom fields: stub logs notice that feature is not yet implemented.
run_gitlab_test_stdout "gitlab-custom-fields-stub" \
  "custom fields not yet implemented"

# GitLab URL validation: reject non-allowlisted host.
SAVED_ISSUE_URL="${ISSUE_URL}"
export ISSUE_URL="https://evil.example/group/project/-/issues/1"
run_gitlab_test "gitlab-rejects-non-allowlisted-host" "true"
export ISSUE_URL="${SAVED_ISSUE_URL}"

# --- GitLab sticky-comment author filtering ---

# Test: sticky comment ignores notes from other users (spoofing protection).
printf '%s' '[{"id":100,"body":"<!-- fullsend:prioritize-agent -->\nSpoofed content","author":{"username":"attacker"}}]' > "${MOCK_NOTES_FILE}"
run_gitlab_test_curl_pattern "gitlab-sticky-comment-ignores-spoofed-notes" \
  "--request POST"
if grep -qF "notes/100" "${CURL_LOG}"; then
  echo "FAIL: gitlab-sticky-comment-ignores-spoofed-notes — attacker note 100 was updated (PUT)"
  FAILURES=$((FAILURES + 1))
fi
rm -f "${MOCK_NOTES_FILE}"

# Test: sticky comment updates own note when bot-authored note exists.
printf '%s' '[{"id":200,"body":"<!-- fullsend:prioritize-agent -->\nOld RICE scores","author":{"username":"fullsend-bot"}}]' > "${MOCK_NOTES_FILE}"
run_gitlab_test_curl_pattern "gitlab-sticky-comment-updates-own-note" \
  "notes/200"
rm -f "${MOCK_NOTES_FILE}"

# Test: sticky comment preserves history in <details> block.
printf '%s' '[{"id":300,"body":"<!-- fullsend:prioritize-agent -->\nPrevious RICE summary here","author":{"username":"fullsend-bot"}}]' > "${MOCK_NOTES_FILE}"
run_gitlab_test_curl_pattern "gitlab-sticky-comment-preserves-history" \
  "Previous run"
rm -f "${MOCK_NOTES_FILE}"

# --- GitLab subgroup URL parsing ---

# Test: forge_parse_issue_url handles subgroup URLs correctly.
SAVED_ISSUE_URL="${ISSUE_URL}"
export ISSUE_URL="https://gitlab.com/top/sub/deep/project/-/issues/99"
run_gitlab_test_curl_pattern "gitlab-subgroup-url-parsing" \
  "projects/top%2Fsub%2Fdeep%2Fproject/issues/99/notes"
export ISSUE_URL="${SAVED_ISSUE_URL}"

# Test: unset GITLAB_TOKEN triggers guard error.
SAVED_GITLAB_TOKEN="${GITLAB_TOKEN}"
unset GITLAB_TOKEN
run_gitlab_test "gitlab-unset-token-fails" "true"
export GITLAB_TOKEN="${SAVED_GITLAB_TOKEN}"

# Restore GitHub forge for any subsequent tests.
export FULLSEND_FORGE="github"
export ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
export GH_TOKEN="fake-token"
export ORG="test-org"
export PROJECT_NUMBER="1"
unset GITLAB_TOKEN CI_SERVER_HOST

# Smoke test: GitHub forge still works after GitLab section (catches state leakage).
run_test "github-after-gitlab-smoke" "" 8

# ---------------------------------------------------------------------------
# Jira forge tests
# Verify FULLSEND_FORGE=jira routes REST through the upstream gateway
# (<api_url>/ex/jira/<cloudId>/rest/api/3), writes only the single
# RICE PRIORITY SCORE custom field, posts the full breakdown in the sticky
# comment, and never calls gh or writes Rank/Priority.
# ---------------------------------------------------------------------------

export FULLSEND_FORGE="jira"
export ISSUE_URL="https://redhat.atlassian.net/browse/AISDLC-8"
export JIRA_TOKEN="fake-jira-token"
export JIRA_USER_EMAIL="bot@example.com"
export FULLSEND_DIR="${TEST_TMPDIR}/fullsend-dir"
mkdir -p "${FULLSEND_DIR}"
unset GH_TOKEN ORG PROJECT_NUMBER GITLAB_TOKEN CI_SERVER_HOST JIRA_API_URL
unset JIRA_BASE_URL

CURL_LOG="${TEST_TMPDIR}/jira-curl-calls.log"
CURL_DATA_FILE="${TEST_TMPDIR}/jira-curl-data.json"
MOCK_FIELDS_FILE="${TEST_TMPDIR}/jira-fields.json"
MOCK_TENANT_FILE="${TEST_TMPDIR}/jira-tenant-info.json"

JIRA_CLOUD_ID_VALUE="11111111-2222-3333-4444-555555555555"
JIRA_DEFAULT_GATEWAY="https://api.atlassian.com"
JIRA_DEFAULT_REST="${JIRA_DEFAULT_GATEWAY}/ex/jira/${JIRA_CLOUD_ID_VALUE}/rest/api/3"

DEFAULT_JIRA_FIELDS='[
  {"id":"customfield_10105","name":"RICE PRIORITY SCORE","schema":{"type":"number"}},
  {"id":"customfield_10101","name":"RICE Reach","schema":{"type":"number"}},
  {"id":"priority","name":"Priority","schema":{"type":"priority"}},
  {"id":"customfield_10019","name":"Rank","schema":{"type":"any"}},
  {"id":"assignee","name":"Assignee","schema":{"type":"user"}},
  {"id":"status","name":"Status","schema":{"type":"status"}}
]'
echo "${DEFAULT_JIRA_FIELDS}" > "${MOCK_FIELDS_FILE}"
echo "{\"cloudId\":\"${JIRA_CLOUD_ID_VALUE}\"}" > "${MOCK_TENANT_FILE}"

cat > "${MOCK_BIN}/curl" <<CURLMOCK
#!/usr/bin/env bash
echo "curl \$*" >> "${CURL_LOG}"

URL=""
METHOD="GET"
shift_next=""
for arg in "\$@"; do
  case "\${arg}" in
    --request) shift_next=method ;;
    --data) shift_next=data ;;
    --user|--header|--connect-timeout|--max-time|--write-out|--oauth2-bearer)
      shift_next=skip
      ;;
    --fail|--silent|--show-error) ;;
    *)
      if [[ "\${shift_next:-}" == "method" ]]; then
        METHOD="\${arg}"
        shift_next=""
      elif [[ "\${shift_next:-}" == "data" ]]; then
        printf '%s' "\${arg}" > "${CURL_DATA_FILE}"
        shift_next=""
      elif [[ "\${shift_next:-}" == "skip" ]]; then
        shift_next=""
      elif [[ "\${arg}" =~ ^https:// ]]; then
        URL="\${arg}"
      fi
      ;;
  esac
done

if [[ "\${URL}" == */_edge/tenant_info ]]; then
  cat "${MOCK_TENANT_FILE}"
  exit 0
fi

if [[ "\${URL}" == */rest/api/3/field ]]; then
  cat "${MOCK_FIELDS_FILE}"
  exit 0
fi

if [[ "\${URL}" == */rest/api/3/issue/* ]] && [[ "\${METHOD}" == "PUT" ]]; then
  echo '{}'
  exit 0
fi

echo '{"ok":true}'
exit 0
CURLMOCK
chmod +x "${MOCK_BIN}/curl"

run_jira_test() {
  local test_name="$1"
  local expect_failure="${2:-false}"

  local run_dir="${TEST_TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${FIXTURE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"

  : > "${CURL_LOG}"
  : > "${GH_LOG}"
  : > "${FS_ENV_LOG}"
  rm -f "${CURL_DATA_FILE}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TEST_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      cat "${TEST_TMPDIR}/stdout-${test_name}.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure)"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TEST_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_jira_test_stdout() {
  local test_name="$1"
  local expected_stdout="$2"
  local expect_failure="${3:-false}"

  local run_dir="${TEST_TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${FIXTURE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"

  : > "${CURL_LOG}"
  : > "${GH_LOG}"
  : > "${FS_ENV_LOG}"
  rm -f "${CURL_DATA_FILE}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TEST_TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
  elif [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TEST_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_stdout}" "${TEST_TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected output containing '${expected_stdout}'"
    cat "${TEST_TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Assert no REST write happened and nothing was sent to a gateway.
assert_jira_no_writes() {
  local test_name="$1"
  if [[ -f "${CURL_DATA_FILE}" ]] || grep -qF -- '--request PUT' "${CURL_LOG}"; then
    echo "FAIL: ${test_name} — a Jira write was sent"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${test_name}-no-writes"
  fi
}

# Assert a log has no /rest/api/3 call outside <rest_root>.
assert_jira_only_rest_root() {
  local test_name="$1"
  local rest_root="$2"
  if grep -F '/rest/api/3' "${CURL_LOG}" | grep -vqF "${rest_root}/"; then
    echo "FAIL: ${test_name} — REST call outside ${rest_root}"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${test_name}"
  fi
}

run_jira_test "jira-happy-path"

run_jira_test "jira-no-gh-calls"
if grep -qE '^gh ' "${GH_LOG}"; then
  echo "FAIL: jira-no-gh-calls — gh was called but should not be on jira forge"
  cat "${GH_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-no-gh-calls-log-empty"
fi

# --- Gateway URL format and cloud-ID routing ---

# Default gateway: the cloud ID comes from the site's tenant_info and REST
# goes to https://api.atlassian.com/ex/jira/<cloudId>/rest/api/3, never to
# the site or to <gateway>/rest/api/3 directly.
run_jira_test "jira-default-gateway-url-format"
if grep -qF "curl --fail --silent --show-error --connect-timeout 10 --max-time 30 https://redhat.atlassian.net/_edge/tenant_info" "${CURL_LOG}"; then
  echo "PASS: jira-cloud-id-discovered-from-site-tenant-info"
else
  echo "FAIL: jira-cloud-id-discovered-from-site-tenant-info"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
fi
if grep -qF "${JIRA_DEFAULT_REST}/field" "${CURL_LOG}" \
  && grep -qF "${JIRA_DEFAULT_REST}/issue/AISDLC-8" "${CURL_LOG}"; then
  echo "PASS: jira-default-gateway-routes-field-list-and-update"
else
  echo "FAIL: jira-default-gateway-routes-field-list-and-update — expected calls at ${JIRA_DEFAULT_REST}"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
fi
assert_jira_only_rest_root "jira-default-gateway-only-ex-jira-rest" "${JIRA_DEFAULT_REST}"
if grep -qF "atlassian.net/rest/api/3" "${CURL_LOG}" \
  || grep -qF "${JIRA_DEFAULT_GATEWAY}/rest/api/3" "${CURL_LOG}"; then
  echo "FAIL: jira-no-direct-rest-api — /rest/api/3 appended directly to a base"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-no-direct-rest-api"
fi
# The cloud ID is looked up once per run.
if [[ "$(grep -cF '/_edge/tenant_info' "${CURL_LOG}")" -eq 1 ]]; then
  echo "PASS: jira-cloud-id-resolved-once"
else
  echo "FAIL: jira-cloud-id-resolved-once"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
fi

write_jira_config() {
  # $1 = api_url (optional), $2 = base_url (optional)
  rm -f "${FULLSEND_DIR}/config.yaml"
  [[ -n "${1:-}${2:-}" ]] || return 0
  {
    echo "tracker:"
    echo "  jira:"
    [[ -n "${1:-}" ]] && echo "    api_url: \"${1}\""
    [[ -n "${2:-}" ]] && echo "    base_url: \"${2}\""
  } > "${FULLSEND_DIR}/config.yaml"
  return 0
}

if ! command -v yq &>/dev/null; then
  echo "SKIP: jira-config-* — yq not found"
else
  # tracker.jira.api_url is the gateway base; /ex/jira/<cloudId> is appended.
  write_jira_config "https://gateway.example.test/" "https://redhat.atlassian.net/"
  GATEWAY_REST="https://gateway.example.test/ex/jira/${JIRA_CLOUD_ID_VALUE}/rest/api/3"
  run_jira_test "jira-config-api-url-is-gateway-base"
  if grep -qF "${GATEWAY_REST}/field" "${CURL_LOG}" \
    && grep -qF "${GATEWAY_REST}/issue/AISDLC-8" "${CURL_LOG}"; then
    echo "PASS: jira-config-api-url-routes-through-ex-jira"
  else
    echo "FAIL: jira-config-api-url-routes-through-ex-jira — expected calls at ${GATEWAY_REST}"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
  fi
  assert_jira_only_rest_root "jira-config-api-url-no-other-rest-base" "${GATEWAY_REST}"
  # Cloud ID still comes from the site, not from the gateway.
  if grep -F '_edge/tenant_info' "${CURL_LOG}" | grep -qvF "https://redhat.atlassian.net/_edge/tenant_info"; then
    echo "FAIL: jira-config-tenant-info-from-site-only"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: jira-config-tenant-info-from-site-only"
  fi

  # A JIRA_API_URL environment variable (which fullsend run sets to a full
  # gateway URL for the sandbox) must not redirect host-side calls.
  export JIRA_API_URL="https://env-gateway.example.test/ex/jira/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  run_jira_test "jira-env-api-url-ignored"
  if grep -qF "env-gateway.example.test" "${CURL_LOG}"; then
    echo "FAIL: jira-env-api-url-ignored — REST call used JIRA_API_URL"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: jira-env-api-url-ignored-log"
  fi
  unset JIRA_API_URL

  # Scalar `tracker: jira` carries no connection settings: default gateway.
  printf 'tracker: jira\n' > "${FULLSEND_DIR}/config.yaml"
  run_jira_test "jira-scalar-tracker-uses-default-gateway"
  assert_jira_only_rest_root "jira-scalar-tracker-uses-default-gateway-log" "${JIRA_DEFAULT_REST}"

  # --- Invalid or mismatched destinations ---

  write_jira_config "http://evil.example"
  run_jira_test_stdout "jira-config-api-url-requires-https" "Jira REST base must be https" "true"
  assert_jira_no_writes "jira-config-api-url-requires-https"

  write_jira_config "https://user:pw@evil.example"
  run_jira_test_stdout "jira-config-api-url-rejects-userinfo" "is not a plain https URL" "true"
  assert_jira_no_writes "jira-config-api-url-rejects-userinfo"

  write_jira_config "https://evil.example/path?x=1"
  run_jira_test_stdout "jira-config-api-url-rejects-query" "is not a plain https URL" "true"
  assert_jira_no_writes "jira-config-api-url-rejects-query"

  write_jira_config "" "https://other.atlassian.net"
  run_jira_test_stdout "jira-config-base-url-tenant-mismatch" "does not match ISSUE_URL host" "true"
  assert_jira_no_writes "jira-config-base-url-tenant-mismatch"
  if grep -qF '_edge/tenant_info' "${CURL_LOG}"; then
    echo "FAIL: jira-config-base-url-tenant-mismatch — tenant lookup ran for a mismatched site"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: jira-config-base-url-tenant-mismatch-no-lookup"
  fi

  write_jira_config "" "http://redhat.atlassian.net"
  run_jira_test_stdout "jira-config-base-url-requires-https" "Jira tracker.jira.base_url must be https" "true"

  write_jira_config
fi

# Cloud-ID discovery failures fail closed and send no credentials or writes.
echo '{"cloudId":"../../evil"}' > "${MOCK_TENANT_FILE}"
run_jira_test_stdout "jira-invalid-cloud-id-fails" "returned no valid cloudId" "true"
assert_jira_no_writes "jira-invalid-cloud-id"
if grep -qF '/rest/api/3' "${CURL_LOG}"; then
  echo "FAIL: jira-invalid-cloud-id — REST call made with an invalid cloud ID"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-invalid-cloud-id-no-rest-calls"
fi
echo '{}' > "${MOCK_TENANT_FILE}"
run_jira_test_stdout "jira-missing-cloud-id-fails" "returned no valid cloudId" "true"
assert_jira_no_writes "jira-missing-cloud-id"
echo "{\"cloudId\":\"${JIRA_CLOUD_ID_VALUE}\"}" > "${MOCK_TENANT_FILE}"

# The tenant_info lookup is unauthenticated: no credentials go to the site.
run_jira_test "jira-tenant-info-lookup-unauthenticated"
if grep -F '_edge/tenant_info' "${CURL_LOG}" | grep -qE -- '--user|--oauth2-bearer|fake-jira-token'; then
  echo "FAIL: jira-tenant-info-lookup-unauthenticated — credentials sent to tenant_info"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-tenant-info-lookup-sends-no-credentials"
fi

SAVED_ISSUE_URL="${ISSUE_URL}"
export ISSUE_URL="https://evil.example/browse/AISDLC-8"
run_jira_test "jira-rejects-non-allowlisted-host" "true"
assert_jira_no_writes "jira-rejects-non-allowlisted-host"
export ISSUE_URL="${SAVED_ISSUE_URL}"

export JIRA_BASE_URL="https://other.atlassian.net"
run_jira_test_stdout "jira-base-url-mismatch-fails" "does not match ISSUE_URL host" "true"
assert_jira_no_writes "jira-base-url-mismatch"
unset JIRA_BASE_URL

# --- Authentication: bot user (Basic) and service account (Bearer) ---

# Bot user: JIRA_USER_EMAIL set -> Basic auth for the REST calls, and the
# sticky-comment CLI gets both FULLSEND_JIRA_TOKEN and FULLSEND_JIRA_EMAIL.
run_jira_test "jira-bot-user-auth"
if grep -F "${JIRA_DEFAULT_REST}/" "${CURL_LOG}" | grep -vqF -- "--user bot@example.com:fake-jira-token"; then
  echo "FAIL: jira-bot-user-auth — a REST call lacked Basic auth"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
elif grep -qF -- '--oauth2-bearer' "${CURL_LOG}"; then
  echo "FAIL: jira-bot-user-auth — Bearer auth used with an email set"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-bot-user-auth-rest-basic"
fi
if grep -qF "email=bot@example.com token=fake-jira-token" "${FS_ENV_LOG}"; then
  echo "PASS: jira-bot-user-auth-cli-env"
else
  echo "FAIL: jira-bot-user-auth-cli-env"
  cat "${FS_ENV_LOG}"
  FAILURES=$((FAILURES + 1))
fi

# Service account: no email (or whitespace only) -> Bearer auth, and the CLI
# must not see an inherited FULLSEND_JIRA_EMAIL.
for sa_email in "" "   "; do
  export JIRA_USER_EMAIL="${sa_email}"
  export FULLSEND_JIRA_EMAIL="stale@example.com"
  run_jira_test "jira-service-account-auth"
  if grep -F "${JIRA_DEFAULT_REST}/" "${CURL_LOG}" | grep -vqF -- "--oauth2-bearer fake-jira-token"; then
    echo "FAIL: jira-service-account-auth — a REST call lacked Bearer auth (email='${sa_email}')"
    cat "${CURL_LOG}"
    FAILURES=$((FAILURES + 1))
  elif grep -qF -- '--user' "${CURL_LOG}"; then
    echo "FAIL: jira-service-account-auth — Basic auth used without an email"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: jira-service-account-auth-rest-bearer"
  fi
  if grep -qF "email=<unset> token=fake-jira-token" "${FS_ENV_LOG}"; then
    echo "PASS: jira-service-account-auth-cli-env"
  else
    echo "FAIL: jira-service-account-auth-cli-env (email='${sa_email}')"
    cat "${FS_ENV_LOG}"
    FAILURES=$((FAILURES + 1))
  fi
done
unset FULLSEND_JIRA_EMAIL
export JIRA_USER_EMAIL="bot@example.com"

# --- Single-field update payload ---

# The PUT body is exactly one field: RICE PRIORITY SCORE, set to the score
# (3 * 2 * 0.8 / 2 = 2.4). No Reach/Impact/Confidence/Effort fields.
run_jira_test "jira-writes-single-rice-priority-score-field"
if [[ ! -f "${CURL_DATA_FILE}" ]]; then
  echo "FAIL: jira-writes-single-rice-priority-score-field — no PUT body captured"
  FAILURES=$((FAILURES + 1))
else
  if [[ "$(jq -c '.' "${CURL_DATA_FILE}")" == '{"fields":{"customfield_10105":2.4}}' ]]; then
    echo "PASS: jira-writes-single-rice-priority-score-field-payload"
  else
    echo "FAIL: jira-writes-single-rice-priority-score-field — unexpected payload"
    cat "${CURL_DATA_FILE}"
    FAILURES=$((FAILURES + 1))
  fi
  if jq -e '.fields | has("priority") or has("rank") or has("assignee") or has("status")' "${CURL_DATA_FILE}" >/dev/null; then
    echo "FAIL: jira-writes-single-rice-priority-score-field — payload includes Rank/Priority/status/assignee"
    FAILURES=$((FAILURES + 1))
  fi
fi
if [[ "$(grep -cF -- '--request PUT' "${CURL_LOG}")" -eq 1 ]]; then
  echo "PASS: jira-single-put-request"
else
  echo "FAIL: jira-single-put-request"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
fi

# Rank (customfield_10019) and Priority must never appear in the PUT body
# or the request URL.
run_jira_test "jira-does-not-write-rank-or-priority"
if grep -Eiq 'customfield_10019|"priority"|"Rank"|/rank' "${CURL_LOG}" "${CURL_DATA_FILE}"; then
  echo "FAIL: jira-does-not-write-rank-or-priority — Rank/Priority mentioned in curl"
  cat "${CURL_LOG}"
  cat "${CURL_DATA_FILE}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-does-not-write-rank-or-priority-log"
fi

# --- Sticky comment carries the complete breakdown ---

run_jira_test "jira-posts-sticky-comment"
if ! grep -qF 'fullsend issues post-comment --tracker jira' "${GH_LOG}"; then
  echo "FAIL: jira-posts-sticky-comment — missing fullsend issues post-comment --tracker jira"
  cat "${GH_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-posts-sticky-comment-cli"
fi
if ! grep -qF 'fullsend:prioritize-agent' "${GH_LOG}"; then
  echo "FAIL: jira-posts-sticky-comment — comment marker not posted"
  cat "${GH_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-posts-sticky-comment-marker"
fi
for expected in \
  'RICE PRIORITY SCORE: 2.4' \
  'Reach: 3** — Many users affected.' \
  'Impact: 2** — Moderate workflow improvement.' \
  'Confidence: 0.8** — Some customer signal.' \
  'Effort: 2** — Small scoped change.' \
  'Formula:** (Reach 3 x Impact 2 x Confidence 0.8) / Effort 2 = **2.4**'; do
  if grep -qF -- "${expected}" "${GH_LOG}"; then
    echo "PASS: jira-sticky-comment-contains: ${expected}"
  else
    echo "FAIL: jira-sticky-comment-contains: ${expected}"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
  fi
done
# Jira renders markdown, so the GitHub <details> table is not used.
if grep -qF '<details>' "${GH_LOG}"; then
  echo "FAIL: jira-sticky-comment-no-details-block"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira-sticky-comment-no-details-block"
fi

# Reasoning from the agent has HTML stripped and newlines collapsed.
HTML_FIXTURE_JSON='{"reach":3,"impact":2,"confidence":0.8,"effort":2,"reasoning":{"reach":"Many <b>users</b>\nare affected.","impact":"i","confidence":"c","effort":"e"}}'
SAVED_FIXTURE_JSON="${FIXTURE_JSON}"
FIXTURE_JSON="${HTML_FIXTURE_JSON}"
run_jira_test "jira-sticky-comment-sanitizes-reasoning"
FIXTURE_JSON="${SAVED_FIXTURE_JSON}"
if grep -qF 'Reach: 3** — Many users are affected.' "${GH_LOG}"; then
  echo "PASS: jira-sticky-comment-sanitizes-reasoning-body"
else
  echo "FAIL: jira-sticky-comment-sanitizes-reasoning-body"
  cat "${GH_LOG}"
  FAILURES=$((FAILURES + 1))
fi

# --- Field resolution fails closed ---

# Missing RICE PRIORITY SCORE field: nothing is written.
echo '[{"id":"priority","name":"Priority","schema":{"type":"priority"}},{"id":"customfield_10019","name":"Rank","schema":{"type":"any"}}]' > "${MOCK_FIELDS_FILE}"
run_jira_test_stdout "jira-missing-field-fails" "Jira field 'RICE PRIORITY SCORE' not found" "true"
assert_jira_no_writes "jira-missing-field"
if grep -qF 'post-comment' "${GH_LOG}"; then
  echo "FAIL: jira-missing-field — comment posted after a failed field write"
  FAILURES=$((FAILURES + 1))
fi

# The old five-field names are not enough.
echo '[{"id":"customfield_10101","name":"RICE Reach","schema":{"type":"number"}},{"id":"customfield_10105","name":"RICE Score","schema":{"type":"number"}}]' > "${MOCK_FIELDS_FILE}"
run_jira_test_stdout "jira-legacy-five-fields-not-accepted" "Jira field 'RICE PRIORITY SCORE' not found" "true"
assert_jira_no_writes "jira-legacy-five-fields"

# Duplicate field name: ambiguous, so fail closed.
echo '[{"id":"customfield_10105","name":"RICE PRIORITY SCORE","schema":{"type":"number"}},{"id":"customfield_10106","name":"RICE PRIORITY SCORE","schema":{"type":"number"}}]' > "${MOCK_FIELDS_FILE}"
run_jira_test_stdout "jira-duplicate-field-fails" "not found or not unique (matches=2)" "true"
assert_jira_no_writes "jira-duplicate-field"

# A system field that happens to be named "RICE PRIORITY SCORE" must not be written.
echo '[{"id":"priority","name":"RICE PRIORITY SCORE","schema":{"type":"priority"}}]' > "${MOCK_FIELDS_FILE}"
run_jira_test_stdout "jira-rejects-system-field-named-rice" "not a custom number field" "true"
assert_jira_no_writes "jira-rejects-system-field-named-rice"

# A custom field of the wrong type must not be written.
echo '[{"id":"customfield_10105","name":"RICE PRIORITY SCORE","schema":{"type":"string"}}]' > "${MOCK_FIELDS_FILE}"
run_jira_test_stdout "jira-rejects-non-number-custom-field" "expected number" "true"
assert_jira_no_writes "jira-rejects-non-number-custom-field"
echo "${DEFAULT_JIRA_FIELDS}" > "${MOCK_FIELDS_FILE}"

SAVED_JIRA_TOKEN="${JIRA_TOKEN}"
unset JIRA_TOKEN
run_jira_test "jira-unset-token-fails" "true"
export JIRA_TOKEN="${SAVED_JIRA_TOKEN}"

# Restore GitHub forge and prove no Jira state leaked into it.
export FULLSEND_FORGE="github"
export ISSUE_URL="https://github.com/test-org/test-repo/issues/42"
export GH_TOKEN="fake-token"
export ORG="test-org"
export PROJECT_NUMBER="1"
unset JIRA_TOKEN JIRA_USER_EMAIL FULLSEND_DIR JIRA_BASE_URL JIRA_API_URL

run_test "github-after-jira-smoke" "" 8

# --- Summary ---

if [[ ${FAILURES} -gt 0 ]]; then
  echo ""
  echo "${FAILURES} test(s) failed."
  exit 1
fi

echo ""
echo "All post-prioritize tests passed."
