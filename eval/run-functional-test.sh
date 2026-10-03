#!/usr/bin/env bash
# Tests for run-functional.sh's tier selection, release-tier case
# filtering/gating, the non-zero-case-exit ("false green") fix, and the
# score.py-exit-under-set-e ("missing RESULT line") fix.
#
# Every invocation of the script under test runs with `env -i` and a
# minimal stub PATH: a per-test bin/ directory stubs python3 (standing in
# for the agent-eval-harness workspace.py/execute.py/score.py scripts),
# fullsend, openshell and gh so no live suite, sandbox or GitHub call ever
# runs, plus the real yq/jq/coreutils needed by the script's own logic.
#
# Run from the repo root:
#   bash eval/run-functional-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_FUNCTIONAL_SRC="${SCRIPT_DIR}/run-functional.sh"
FAILURES=0
TESTS=0

fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }
run_test() { TESTS=$((TESTS + 1)); }

for tool in yq jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool is required to run these tests (not on PATH)" >&2
    exit 1
  fi
done
REAL_YQ_DIR="$(dirname "$(command -v yq)")"
REAL_JQ_DIR="$(dirname "$(command -v jq)")"
REAL_COREUTILS_DIR="/usr/bin"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# ---------------------------------------------------------------------------
# Fixture: an isolated eval/ tree with one "testagent" that has two cases
# (one release:true, one not) and a stub harness, so run-functional.sh's
# own file-existence checks pass without a real agent-eval-harness.
# ---------------------------------------------------------------------------
setup_fixture() {
  local root="$1"
  mkdir -p "${root}/eval/testagent/cases/001-release-case"
  mkdir -p "${root}/eval/testagent/cases/002-full-only-case"
  cp "${RUN_FUNCTIONAL_SRC}" "${root}/eval/run-functional.sh"
  chmod +x "${root}/eval/run-functional.sh"

  cat > "${root}/eval/testagent/eval.yaml" <<'YAML'
name: testagent-eval
dataset:
  path: cases
thresholds:
  deterministic_check:
    min_pass_rate: 1.0
  agent_quality:
    min_mean: 3.0
  max_turns:
    min_pass_rate: 1.0
  max_cost:
    min_pass_rate: 1.0
YAML

  cat > "${root}/eval/testagent/cases/001-release-case/annotations.yaml" <<'YAML'
release: true
max_turns: 10
YAML
  echo "fixture: {}" > "${root}/eval/testagent/cases/001-release-case/input.yaml"

  cat > "${root}/eval/testagent/cases/002-full-only-case/annotations.yaml" <<'YAML'
max_turns: 10
YAML
  echo "fixture: {}" > "${root}/eval/testagent/cases/002-full-only-case/input.yaml"

  # Stub harness at run-functional.sh's default AGENT_EVAL_HARNESS_DIR
  # (${EVAL_DIR}/.agent-eval-harness) — it only checks these paths exist.
  mkdir -p "${root}/eval/.agent-eval-harness/skills/eval-run/scripts"
  : > "${root}/eval/.agent-eval-harness/skills/eval-run/scripts/workspace.py"
  : > "${root}/eval/.agent-eval-harness/skills/eval-run/scripts/execute.py"
  : > "${root}/eval/.agent-eval-harness/skills/eval-run/scripts/score.py"

  mkdir -p "${root}/bin" "${root}/capture"

  cat > "${root}/bin/python3" <<'STUBEOF'
#!/usr/bin/env bash
# Stub python3: fakes workspace.py/execute.py/score.py, recording what it
# was asked to do so the test can inspect it afterward.
set -euo pipefail
echo "$*" >> "${CAPTURE_DIR}/python3-calls.log"

config_arg=""
output_arg=""
prev=""
for a in "$@"; do
  [[ "$prev" == "--config" ]] && config_arg="$a"
  [[ "$prev" == "--output" ]] && output_arg="$a"
  prev="$a"
done
[[ -n "$config_arg" ]] && cp "$config_arg" "${CAPTURE_DIR}/last-config.yaml"

if [[ "${1:-}" == "-c" ]]; then
  # `python3 -c "import agent_eval"` probe — pretend it is installed.
  exit 0
fi

case "${1:-}" in
  *execute.py)
    if [[ -n "$config_arg" ]]; then
      dataset_path="$(yq '.dataset.path' "$config_arg" 2>/dev/null || true)"
      if [[ -n "$dataset_path" && -d "$dataset_path" ]]; then
        ls "$dataset_path" > "${CAPTURE_DIR}/staged-cases.txt"
      fi
    fi
    if [[ -n "${STUB_CASE_RESULTS:-}" && -n "$output_arg" ]]; then
      IFS=',' read -ra pairs <<< "${STUB_CASE_RESULTS}"
      for pair in "${pairs[@]}"; do
        name="${pair%%:*}"
        code="${pair##*:}"
        mkdir -p "${output_arg}/cases/${name}"
        printf '{"exit_code": %s}\n' "$code" > "${output_arg}/cases/${name}/run_result.json"
      done
    fi
    exit "${STUB_EXECUTE_EXIT:-0}"
    ;;
  *score.py)
    exit "${STUB_SCORE_EXIT:-0}"
    ;;
  *)
    exit 0
    ;;
esac
STUBEOF
  chmod +x "${root}/bin/python3"

  cat > "${root}/bin/fullsend" <<'STUBEOF'
#!/usr/bin/env bash
exit 0
STUBEOF
  chmod +x "${root}/bin/fullsend"

  cat > "${root}/bin/openshell" <<'STUBEOF'
#!/usr/bin/env bash
exit 0
STUBEOF
  chmod +x "${root}/bin/openshell"

  cat > "${root}/bin/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "stub-gh-token"
exit 0
STUBEOF
  chmod +x "${root}/bin/gh"
}

# setup_empty_release_fixture: a second agent with no release:true case,
# to exercise "no release case → notice + exit 0".
add_no_release_agent() {
  local root="$1"
  mkdir -p "${root}/eval/noreleaseagent/cases/001-only-case"
  cat > "${root}/eval/noreleaseagent/eval.yaml" <<'YAML'
name: noreleaseagent-eval
dataset:
  path: cases
thresholds:
  deterministic_check:
    min_pass_rate: 1.0
YAML
  cat > "${root}/eval/noreleaseagent/cases/001-only-case/annotations.yaml" <<'YAML'
max_turns: 10
YAML
  echo "fixture: {}" > "${root}/eval/noreleaseagent/cases/001-only-case/input.yaml"
}

# run_rf <agent> [extra env assignments...] -- invokes run-functional.sh
# under env -i with a minimal stub PATH. Env assignments are NAME=value
# strings applied on top of the fixed baseline (PATH/HOME/GH_TOKEN/CAPTURE_DIR).
run_rf() {
  local root="$1" agent="$2"
  shift 2
  local stub_path="${root}/bin:${REAL_YQ_DIR}:${REAL_JQ_DIR}:${REAL_COREUTILS_DIR}:/bin"
  env -i \
    PATH="$stub_path" \
    HOME="$root" \
    GH_TOKEN="test-token" \
    CAPTURE_DIR="${root}/capture" \
    "$@" \
    bash "${root}/eval/run-functional.sh" "$agent"
}

# ---------------------------------------------------------------------------
# Tier selection: defaults
# ---------------------------------------------------------------------------

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
OUT=$(run_rf "$ROOT" testagent GITHUB_ACTIONS=true GITHUB_REPOSITORY=fullsend-ai/fullsend 2>&1) || true
if echo "$OUT" | grep -q "EVAL_TIER=release (cross-repo workflow_call"; then
  pass "default tier: cross-repo Actions call selects release"
else
  fail "default tier: cross-repo Actions call selects release (output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
OUT=$(run_rf "$ROOT" testagent GITHUB_ACTIONS=true GITHUB_REPOSITORY=fullsend-ai/agents 2>&1) || true
if echo "$OUT" | grep -q "EVAL_TIER=full (default"; then
  pass "default tier: same-repo (fullsend-ai/agents) Actions call selects full"
else
  fail "default tier: same-repo Actions call selects full (output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
OUT=$(run_rf "$ROOT" testagent 2>&1) || true
if echo "$OUT" | grep -q "EVAL_TIER=full (default"; then
  pass "default tier: local run (no GITHUB_ACTIONS) selects full"
else
  fail "default tier: local run selects full (output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
OUT=$(run_rf "$ROOT" testagent GITHUB_ACTIONS=true 2>&1) || true
if echo "$OUT" | grep -q "EVAL_TIER=full (default"; then
  pass "default tier: GITHUB_REPOSITORY unset selects full"
else
  fail "default tier: GITHUB_REPOSITORY unset selects full (output: $OUT)"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Tier selection: explicit EVAL_TIER overrides the default in both directions
# ---------------------------------------------------------------------------

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
OUT=$(run_rf "$ROOT" testagent GITHUB_ACTIONS=true GITHUB_REPOSITORY=some-org/some-repo EVAL_TIER=full 2>&1) || true
if echo "$OUT" | grep -q "EVAL_TIER=full (explicit EVAL_TIER=full)"; then
  pass "explicit EVAL_TIER=full overrides cross-repo default"
else
  fail "explicit EVAL_TIER=full overrides cross-repo default (output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
OUT=$(run_rf "$ROOT" testagent GITHUB_ACTIONS=true GITHUB_REPOSITORY=fullsend-ai/agents EVAL_TIER=release 2>&1) || true
if echo "$OUT" | grep -q "EVAL_TIER=release (explicit EVAL_TIER=release)"; then
  pass "explicit EVAL_TIER=release overrides same-repo default"
else
  fail "explicit EVAL_TIER=release overrides same-repo default (output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=bogus 2>&1) || RC=$?
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -q "invalid EVAL_TIER"; then
  pass "invalid EVAL_TIER value is rejected"
else
  fail "invalid EVAL_TIER value is rejected (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Release tier: case filtering — only the release:true case is staged, and
# the checked-in cases/ tree is left untouched.
# ---------------------------------------------------------------------------

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
run_rf "$ROOT" testagent EVAL_TIER=release >"${ROOT}/capture/stdout.log" 2>&1 || true
STAGED="$(cat "${ROOT}/capture/staged-cases.txt" 2>/dev/null || true)"
if [[ "$STAGED" == "001-release-case" ]]; then
  pass "release tier stages only the release:true case"
else
  fail "release tier stages only the release:true case (staged: '$STAGED')"
fi
if [[ -d "${ROOT}/eval/testagent/cases/001-release-case" && -d "${ROOT}/eval/testagent/cases/002-full-only-case" ]]; then
  pass "release tier leaves the checked-in cases/ tree untouched"
else
  fail "release tier leaves the checked-in cases/ tree untouched"
fi
run_test
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
run_rf "$ROOT" testagent EVAL_TIER=full >"${ROOT}/capture/stdout.log" 2>&1 || true
STAGED="$(sort "${ROOT}/capture/staged-cases.txt" 2>/dev/null | tr '\n' ',' || true)"
if [[ "$STAGED" == "001-release-case,002-full-only-case," ]]; then
  pass "full tier runs every case"
else
  fail "full tier runs every case (staged: '$STAGED')"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; add_no_release_agent "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" noreleaseagent EVAL_TIER=release 2>&1) || RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "No release:true case for agent 'noreleaseagent'"; then
  pass "agent with no release:true case prints a notice and exits 0"
else
  fail "agent with no release:true case prints a notice and exits 0 (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Release tier: deterministic judges block, LLM-quality/budget judges don't
# ---------------------------------------------------------------------------

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
run_rf "$ROOT" testagent EVAL_TIER=release >/dev/null 2>&1 || true
THRESHOLD_KEYS="$(yq -r '.thresholds | keys | sort | join(",")' "${ROOT}/capture/last-config.yaml")"
if [[ "$THRESHOLD_KEYS" == "deterministic_check" ]]; then
  pass "release tier drops quality/max_turns/max_cost from thresholds, keeps deterministic judges"
else
  fail "release tier drops quality/max_turns/max_cost from thresholds (got: '$THRESHOLD_KEYS')"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
run_rf "$ROOT" testagent EVAL_TIER=full >/dev/null 2>&1 || true
THRESHOLD_KEYS="$(yq -r '.thresholds | keys | sort | join(",")' "${ROOT}/capture/last-config.yaml")"
if [[ "$THRESHOLD_KEYS" == "agent_quality,deterministic_check,max_cost,max_turns" ]]; then
  pass "full tier keeps every threshold entry"
else
  fail "full tier keeps every threshold entry (got: '$THRESHOLD_KEYS')"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# False-green fix: a non-zero case exit must fail the script even when the
# aggregate execute.py exit code is 0 and other cases produced output.
# ---------------------------------------------------------------------------

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_EXECUTE_EXIT=0 \
  STUB_CASE_RESULTS="001-release-case:1,002-full-only-case:0" 2>&1) || RC=$?
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -q "001-release-case"; then
  pass "a failing case fails the script even when execute.py's own exit code is 0"
else
  fail "a failing case fails the script even when execute.py's own exit code is 0 (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_EXECUTE_EXIT=0 \
  STUB_CASE_RESULTS="001-release-case:0,002-full-only-case:0" 2>&1) || RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "RESULT: All phases complete"; then
  pass "all cases passing still succeeds"
else
  fail "all cases passing still succeeds (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_EXECUTE_EXIT=1 \
  STUB_CASE_RESULTS="001-release-case:0" 2>&1) || RC=$?
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -q "002-full-only-case (no run_result.json)"; then
  pass "a case with no run_result.json fails the script"
else
  fail "a case with no run_result.json fails the script (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_EXECUTE_EXIT=0 \
  STUB_CASE_RESULTS="001-release-case:0,002-full-only-case:-1" 2>&1) || RC=$?
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -q "002-full-only-case (exit -1)"; then
  pass "a timed-out case (exit -1) fails the script"
else
  fail "a timed-out case (exit -1) fails the script (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_EXECUTE_EXIT=1 \
  STUB_CASE_RESULTS="001-release-case:0,002-full-only-case:0" 2>&1) || RC=$?
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -q "execute.py exited 1"; then
  pass "a non-zero execute.py exit fails the script even when every case record is 0"
else
  fail "a non-zero execute.py exit fails the script even when every case record is 0 (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_EXECUTE_EXIT=0 \
  STUB_CASE_RESULTS="001-release-case:0,002-full-only-case:null" 2>&1) || RC=$?
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -q "002-full-only-case (exit missing)"; then
  pass "a case record with no exit_code fails the script"
else
  fail "a case record with no exit_code fails the script (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_EXECUTE_EXIT=0 \
  STUB_CASE_RESULTS="001-release-case:0,002-full-only-case:0" \
  STUB_SCORE_EXIT=1 2>&1) || RC=$?
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -q "RESULT: score.py exited 1"; then
  pass "a non-zero score.py exit under set -e still prints a RESULT line and fails the script"
else
  fail "a non-zero score.py exit under set -e still prints a RESULT line and fails the script (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=release \
  STUB_EXECUTE_EXIT=0 \
  STUB_CASE_RESULTS="001-release-case:0" 2>&1) || RC=$?
shopt -s nullglob
LEFTOVER=("${ROOT}"/eval/testagent/release-cases-*)
shopt -u nullglob
if [[ $RC -eq 0 && ${#LEFTOVER[@]} -eq 0 ]]; then
  pass "release tier succeeds and removes its staged release-cases dir"
else
  fail "release tier succeeds and removes its staged release-cases dir (rc=$RC, leftover: ${LEFTOVER[*]:-none}, output: $OUT)"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== $TESTS tests, $FAILURES failures ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
