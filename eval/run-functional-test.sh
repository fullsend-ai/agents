#!/usr/bin/env bash
# Tests for run-functional.sh's tier selection, release-tier case
# filtering/gating, the non-zero-case-exit ("false green") fix, the
# judge-error classification (infrastructure vs quality regression), the
# per-case attribution of failed checks and judge errors, and the
# preservation of a retried case's first attempt.
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
# git with no user config, hooks or signing, for the fixture repositories.
FIXTURE_GIT="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null"
# pin_harness <root> <version>: a new harness commit at <version>, checked out
# in the submodule and recorded by the superproject (a pin bump).
pin_harness() {
  echo "version = \"$2\"" > "$1/harness-src/pyproject.toml"
  $FIXTURE_GIT -C "$1/harness-src" add -A && $FIXTURE_GIT -C "$1/harness-src" commit -qm "pin $2"
  $FIXTURE_GIT -C "$1/eval/.agent-eval-harness" -c protocol.file.allow=always pull -q origin HEAD
  $FIXTURE_GIT -C "$1" add eval/.agent-eval-harness && $FIXTURE_GIT -C "$1" commit -qm "bump to $2"
}

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
  finding_expectations:
    min_pass_rate: 1.0
  required_labels:
    min_pass_rate: 1.0
  forbidden_labels:
    min_pass_rate: 1.0
  risk_label_present:
    min_pass_rate: 1.0
  expected_files:
    min_pass_rate: 1.0
  pr_created:
    min_pass_rate: 1.0
  new_commit:
    min_pass_rate: 1.0
  sandbox_started:
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
  # (${EVAL_DIR}/.agent-eval-harness): it only checks these paths exist and
  # reads the version. run-functional.sh takes the pinned version from the
  # submodule commit the superproject records, so the fixture is a git
  # checkout: a harness repo with a 1.37.4 commit then a 1.56.3 commit,
  # recorded as the submodule at 1.56.3 (the minimum run-functional.sh
  # enforces). The fixture's own files stay untracked.
  mkdir -p "${root}/harness-src/skills/eval-run/scripts"
  : > "${root}/harness-src/skills/eval-run/scripts/workspace.py"
  : > "${root}/harness-src/skills/eval-run/scripts/execute.py"
  : > "${root}/harness-src/skills/eval-run/scripts/score.py"
  $FIXTURE_GIT -C "${root}/harness-src" init -q
  echo 'version = "1.37.4"' > "${root}/harness-src/pyproject.toml"
  $FIXTURE_GIT -C "${root}/harness-src" add -A && $FIXTURE_GIT -C "${root}/harness-src" commit -qm old
  echo 'version = "1.56.3"' > "${root}/harness-src/pyproject.toml"
  $FIXTURE_GIT -C "${root}/harness-src" add -A && $FIXTURE_GIT -C "${root}/harness-src" commit -qm pin
  $FIXTURE_GIT -C "$root" init -q
  $FIXTURE_GIT -C "$root" -c protocol.file.allow=always submodule add -q "${root}/harness-src" eval/.agent-eval-harness
  $FIXTURE_GIT -C "$root" add .gitmodules eval/.agent-eval-harness && $FIXTURE_GIT -C "$root" commit -qm super

  mkdir -p "${root}/bin" "${root}/capture"

  cat > "${root}/bin/python3" <<'STUBEOF'
#!/usr/bin/env bash
# Stub python3: fakes workspace.py/execute.py/score.py, recording what it
# was asked to do so the test can inspect it afterward.
set -euo pipefail
echo "$*" >> "${CAPTURE_DIR}/python3-calls.log"

config_arg=""
output_arg=""
run_id_arg=""
prev=""
for a in "$@"; do
  [[ "$prev" == "--config" ]] && config_arg="$a"
  [[ "$prev" == "--output" ]] && output_arg="$a"
  [[ "$prev" == "--run-id" ]] && run_id_arg="$a"
  prev="$a"
done
[[ -n "$config_arg" ]] && cp "$config_arg" "${CAPTURE_DIR}/last-config.yaml"

# `python3 -P -c "import agent_eval"` probe: installed unless
# STUB_AGENT_EVAL_MISSING is set. A probe without -P is refused, so the flag
# cannot silently go away.
if [[ "${1:-}" == "-P" && "${2:-}" == "-c" ]]; then
  [[ -n "${STUB_AGENT_EVAL_MISSING:-}" ]] && exit 1
  exit 0
fi
[[ "${1:-}" == "-c" ]] && exit 1

case "${1:-}" in
  *execute.py)
    if [[ -n "$config_arg" ]]; then
      dataset_path="$(yq '.dataset.path' "$config_arg" 2>/dev/null || true)"
      if [[ -n "$dataset_path" && -d "$dataset_path" ]]; then
        ls "$dataset_path" > "${CAPTURE_DIR}/staged-cases.txt"
      fi
    fi
    # Call N (1-based) uses STUB_CASE_RESULTS_<N> when set, else
    # STUB_CASE_RESULTS: comma-separated name:exit[:turns[:tokens]]. With
    # tokens, the record carries token_usage.input, the given turns (default
    # 0) and cost_usd 0 (an agent cut off before its totals). With turns
    # only, it carries num_turns and a cost (the agent ran). With neither,
    # both are null (the case failed before the agent ran). Each case also
    # gets attempt.txt: "retry" when the run id ends in -retry, else "first".
    # With STUB_COPY_FAIL_<N> set, call N's output/ copy into the runs dir
    # fails (run-functional.sh's execute_run returns 2). With
    # STUB_PRESERVED_EXISTS_<N> set, call N (a retry) pre-creates the first
    # run's first-attempt/cases/<case> dir.
    en=$(( $(cat "${CAPTURE_DIR}/execute-calls" 2>/dev/null || echo 0) + 1 ))
    echo "$en" > "${CAPTURE_DIR}/execute-calls"
    results_var="STUB_CASE_RESULTS_${en}"
    results="${!results_var:-${STUB_CASE_RESULTS:-}}"
    if [[ -n "$results" && -n "$output_arg" ]]; then
      IFS=',' read -ra pairs <<< "${results}"
      for pair in "${pairs[@]}"; do
        IFS=':' read -r name code turns tokens <<< "$pair"
        mkdir -p "${output_arg}/cases/${name}"
        if [[ -n "${tokens:-}" ]]; then
          printf '{"exit_code": %s, "num_turns": %s, "cost_usd": 0, "token_usage": {"input": %s, "output": 0}}\n' \
            "$code" "${turns:-0}" "$tokens" > "${output_arg}/cases/${name}/run_result.json"
        elif [[ -n "${turns:-}" ]]; then
          printf '{"exit_code": %s, "num_turns": %s, "cost_usd": 0.05}\n' "$code" "$turns" \
            > "${output_arg}/cases/${name}/run_result.json"
        else
          printf '{"exit_code": %s, "num_turns": null, "cost_usd": null}\n' "$code" \
            > "${output_arg}/cases/${name}/run_result.json"
        fi
        if [[ "$run_id_arg" == *-retry ]]; then
          echo retry > "${output_arg}/cases/${name}/attempt.txt"
        else
          echo first > "${output_arg}/cases/${name}/attempt.txt"
        fi
        copy_fail_var="STUB_COPY_FAIL_${en}"
        if [[ -n "${!copy_fail_var:-}" ]]; then
          # A workspace output/ dir to copy, and a regular file where the
          # copy's destination directory should be.
          ws_out="/tmp/agent-eval/${run_id_arg}/cases/${name}/output"
          mkdir -p "$ws_out"
          echo state > "${ws_out}/fixture-state.json"
          echo "/tmp/agent-eval/${run_id_arg}" >> "${CAPTURE_DIR}/ws-dirs"
          : > "${output_arg}/cases/${name}/output"
        fi
        preserved_var="STUB_PRESERVED_EXISTS_${en}"
        if [[ -n "${!preserved_var:-}" ]]; then
          # Occupy the first run's first-attempt/cases/<case> slot.
          occupied="${output_arg%-retry}/first-attempt/cases/${name}"
          mkdir -p "$occupied"
          echo earlier > "${occupied}/occupant.txt"
        fi
      done
      # Run-level record, as execute.py writes it: per_case mirrors each
      # case's run_result.json.
      jq -n '{per_case: {}}' > "${output_arg}/run_result.json"
      for rr in "${output_arg}"/cases/*/run_result.json; do
        cname="$(basename "$(dirname "$rr")")"
        jq --arg c "$cname" --slurpfile r "$rr" '.per_case[$c] = $r[0]' \
          "${output_arg}/run_result.json" > "${output_arg}/run_result.json.tmp"
        mv "${output_arg}/run_result.json.tmp" "${output_arg}/run_result.json"
      done
    fi
    exit "${STUB_EXECUTE_EXIT:-0}"
    ;;
  *workspace.py)
    wn=$(( $(cat "${CAPTURE_DIR}/workspace-calls" 2>/dev/null || echo 0) + 1 ))
    echo "$wn" > "${CAPTURE_DIR}/workspace-calls"
    if [[ -n "${STUB_WORKSPACE_EXITS:-}" ]]; then
      IFS=',' read -ra wcodes <<< "${STUB_WORKSPACE_EXITS}"
      exit "${wcodes[$((wn - 1))]:-0}"
    fi
    exit 0
    ;;
  *score.py)
    # Per-call behaviour for the judge-error tests: call N (1-based) uses
    # STUB_SCORE_EXITS' Nth comma-separated exit code, prints
    # STUB_SCORE_OUT_<N> and writes STUB_SUMMARY_<N> as the run's
    # summary.yaml. Without them, exit STUB_SCORE_EXIT.
    n=$(( $(cat "${CAPTURE_DIR}/score-calls" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "${CAPTURE_DIR}/score-calls"
    run_id=""
    prev=""
    for a in "$@"; do
      [[ "$prev" == "--run-id" ]] && run_id="$a"
      prev="$a"
    done
    summary_var="STUB_SUMMARY_${n}"
    out_var="STUB_SCORE_OUT_${n}"
    if [[ -n "${!summary_var:-}" ]]; then
      for d in "${AGENT_EVAL_RUNS_DIR}"/*/"${run_id}"; do
        printf '%b' "${!summary_var}" > "${d}/summary.yaml"
      done
    fi
    [[ -n "${!out_var:-}" ]] && printf '%b' "${!out_var}"
    if [[ -n "${STUB_SCORE_EXITS:-}" ]]; then
      IFS=',' read -ra codes <<< "${STUB_SCORE_EXITS}"
      exit "${codes[$((n - 1))]:-0}"
    fi
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
# Both tiers: deterministic contract judges gate; LLM-quality, live-model
# behaviour and budget judges are report-only (thresholds dropped at runtime)
# ---------------------------------------------------------------------------

for tier in full release; do
  run_test
  ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
  run_rf "$ROOT" testagent EVAL_TIER="$tier" >/dev/null 2>&1 || true
  THRESHOLD_KEYS="$(yq -r '.thresholds | keys | sort | join(",")' "${ROOT}/capture/last-config.yaml")"
  if [[ "$THRESHOLD_KEYS" == "deterministic_check,new_commit,pr_created,sandbox_started" ]]; then
    pass "${tier} tier drops quality/behaviour/budget judges from thresholds, keeps deterministic judges"
  else
    fail "${tier} tier drops quality/behaviour/budget judges from thresholds (got: '$THRESHOLD_KEYS')"
  fi
  run_test
  SRC_KEYS="$(yq -r '.thresholds | keys | length' "${ROOT}/eval/testagent/eval.yaml")"
  if [[ "$SRC_KEYS" == "12" ]]; then
    pass "${tier} tier leaves the checked-in eval.yaml thresholds untouched"
  else
    fail "${tier} tier leaves the checked-in eval.yaml thresholds untouched (got ${SRC_KEYS} keys)"
  fi
  rm -rf "$ROOT"
done

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

# ---------------------------------------------------------------------------
# Harness version gate: the checkout in use must be a plain release version
# at or above the submodule pin, for every eval. AGENT_EVAL_HARNESS_DIR may
# point at another checkout. The pin is the submodule commit the superproject
# records, not the directory's contents.
# ---------------------------------------------------------------------------
RUN="STUB_CASE_RESULTS=001-release-case:0:3,002-full-only-case:0:3"
other_harness() { # root version: a second checkout for AGENT_EVAL_HARNESS_DIR
  mkdir -p "$1/other-harness/skills/eval-run/scripts"
  : > "$1/other-harness/skills/eval-run/scripts/workspace.py"
  : > "$1/other-harness/skills/eval-run/scripts/execute.py"
  : > "$1/other-harness/skills/eval-run/scripts/score.py"
  [[ -z "$2" ]] || echo "version = \"$2\"" > "$1/other-harness/pyproject.toml"
}
no_execute() { [[ "$(cat "$1/capture/execute-calls" 2>/dev/null || echo 0)" == "0" ]]; }

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
rm -rf "${ROOT}/.git"   # an exported tree: nothing records the pin
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "cannot read the pinned agent-eval-harness version: ${ROOT} is not a git checkout that records eval/.agent-eval-harness" \
  && echo "$OUT" | grep -q "Run the evals from a git clone of this repository. Run: git submodule sync" \
  && no_execute "$ROOT"; then
  pass "a tree that is not a git checkout is refused before anything runs: the pin cannot be read"
else
  fail "a tree that is not a git checkout is refused before anything runs: the pin cannot be read (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# git also finds a repository in the parent directories: an exported tree
# inside a checkout must not borrow the enclosing checkout's pin.
run_test
OUTER="$(mktemp -d)"; setup_fixture "$OUTER"
ROOT="${OUTER}/exported"; setup_fixture "$ROOT"; rm -rf "${ROOT}/.git"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "cannot read the pinned agent-eval-harness version: ${ROOT} is not a git checkout that records eval/.agent-eval-harness" \
  && no_execute "$ROOT"; then
  pass "an exported tree inside another checkout is refused as not a git checkout"
else
  fail "an exported tree inside another checkout is refused as not a git checkout (rc=$RC, output: $OUT)"
fi
rm -rf "$OUTER"

# A directory of plain files committed where the submodule was is not a pin.
run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
$FIXTURE_GIT -C "$ROOT" rm -q --cached eval/.agent-eval-harness
rm -f "${ROOT}/.gitmodules" "${ROOT}/eval/.agent-eval-harness/.git"
$FIXTURE_GIT -C "$ROOT" add eval/.agent-eval-harness && $FIXTURE_GIT -C "$ROOT" commit -qm "plain files"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "cannot read the pinned agent-eval-harness version: ${ROOT} is not a git checkout that records eval/.agent-eval-harness as a submodule" \
  && no_execute "$ROOT"; then
  pass "a harness directory committed as plain files is refused: not a submodule pin"
else
  fail "a harness directory committed as plain files is refused: not a submodule pin (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" STUB_AGENT_EVAL_MISSING=1 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "agent-eval-harness library is not installed" \
  && echo "$OUT" | grep -q "pip install -e eval/.agent-eval-harness" \
  && no_execute "$ROOT"; then
  pass "a missing agent_eval install is refused before anything runs"
else
  fail "a missing agent_eval install is refused before anything runs (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
$FIXTURE_GIT -C "$ROOT" submodule deinit -q -f eval/.agent-eval-harness   # recorded, never initialised
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" 2>&1) || RC=$?
# With the submodule as the checkout in use, the missing-script check comes
# first; the hint is the same.
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "harness script not found: ${ROOT}/eval/.agent-eval-harness/skills/eval-run/scripts/workspace.py" \
  && echo "$OUT" | grep -q "Run: git submodule sync eval/.agent-eval-harness && git submodule update --init eval/.agent-eval-harness" \
  && no_execute "$ROOT"; then
  pass "an uninitialised submodule is refused before anything runs"
else
  fail "an uninitialised submodule is refused before anything runs (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; other_harness "$ROOT" 1.57.0
$FIXTURE_GIT -C "$ROOT" submodule deinit -q -f eval/.agent-eval-harness   # never initialised, another checkout in use
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" AGENT_EVAL_HARNESS_DIR="${ROOT}/other-harness" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "but that commit is not in the submodule directory" \
  && no_execute "$ROOT"; then
  pass "an uninitialised submodule with another checkout in use is still refused: the pin is read from the submodule"
else
  fail "an uninitialised submodule with another checkout in use is still refused: the pin is read from the submodule (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
$FIXTURE_GIT -C "${ROOT}/eval/.agent-eval-harness" checkout -q HEAD~1   # directory behind the pin
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "checkout at ${ROOT}/eval/.agent-eval-harness is version 1.37.4, older than the agent-eval-harness 1.56.3 this repo pins" \
  && no_execute "$ROOT"; then
  pass "a submodule directory behind the recorded pin is refused (the pin is read from the gitlink)"
else
  fail "a submodule directory behind the recorded pin is refused (the pin is read from the gitlink) (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" 2>&1) || RC=$?
if [[ $RC -eq 0 ]] && ! echo "$OUT" | grep -q "this repo pins"; then
  pass "a submodule directory at the recorded pin runs normally"
else
  fail "a submodule directory at the recorded pin runs normally (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; other_harness "$ROOT" 1.49.1
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" AGENT_EVAL_HARNESS_DIR="${ROOT}/other-harness" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "checkout at ${ROOT}/other-harness is version 1.49.1, older than the agent-eval-harness 1.56.3 this repo pins" \
  && echo "$OUT" | grep -q "point AGENT_EVAL_HARNESS_DIR at a checkout of 1.56.3 or later" \
  && no_execute "$ROOT"; then
  pass "a checkout older than the pin is refused before anything runs"
else
  fail "a checkout older than the pin is refused before anything runs (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# The minimum is the pin itself, not a number written into the script.
run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; other_harness "$ROOT" 1.57.0
pin_harness "$ROOT" 1.60.0
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" AGENT_EVAL_HARNESS_DIR="${ROOT}/other-harness" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "is version 1.57.0, older than the agent-eval-harness 1.60.0 this repo pins" && no_execute "$ROOT"; then
  pass "the minimum follows the submodule pin"
else
  fail "the minimum follows the submodule pin (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

for ver in 1.56.3 1.56.10 2.0.0; do
  run_test
  ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; other_harness "$ROOT" "$ver"
  RC=0
  OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" AGENT_EVAL_HARNESS_DIR="${ROOT}/other-harness" 2>&1) || RC=$?
  if [[ $RC -eq 0 ]] && ! echo "$OUT" | grep -q "this repo pins"; then
    pass "a checkout at ${ver} (at or above the pin) runs normally"
  else
    fail "a checkout at ${ver} (at or above the pin) runs normally (rc=$RC, output: $OUT)"
  fi
  rm -rf "$ROOT"
done

for ver in unknown 1.56.3rc1 2.0; do
  run_test
  ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; other_harness "$ROOT" "$ver"
  RC=0
  OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" AGENT_EVAL_HARNESS_DIR="${ROOT}/other-harness" 2>&1) || RC=$?
  if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "is version '${ver}', not a release version" && no_execute "$ROOT"; then
    pass "a checkout at '${ver}' is refused as not a release version"
  else
    fail "a checkout at '${ver}' is refused as not a release version (rc=$RC, output: $OUT)"
  fi
  rm -rf "$ROOT"
done

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; other_harness "$ROOT" ""
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full "$RUN" AGENT_EVAL_HARNESS_DIR="${ROOT}/other-harness" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "cannot read the agent-eval-harness version from ${ROOT}/other-harness/pyproject.toml" \
  && echo "$OUT" | grep -q "point AGENT_EVAL_HARNESS_DIR at a checkout of 1.56.3 or later" \
  && no_execute "$ROOT"; then
  pass "a checkout with no readable version is refused"
else
  fail "a checkout with no readable version is refused (rc=$RC, output: $OUT)"
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
# Cases that fail before the agent runs (no turns, no cost) are retried once;
# if they fail again, the run is an infrastructure failure (exit 3).
# ---------------------------------------------------------------------------

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS_1="001-release-case:1,002-full-only-case:0:5" \
  STUB_CASE_RESULTS_2="001-release-case:0:4" 2>&1) || RC=$?
CALLS="$(cat "${ROOT}/capture/execute-calls" 2>/dev/null || echo 0)"
STAGED="$(cat "${ROOT}/capture/staged-cases.txt" 2>/dev/null || true)"
LEFTOVER=( "${ROOT}"/eval/testagent/retry-cases-* "${ROOT}"/eval/testagent/eval-retry-*.yaml )
if [[ $RC -eq 0 && "$CALLS" == "2" && "$STAGED" == "001-release-case" && ! -e "${LEFTOVER[0]}" && ! -e "${LEFTOVER[1]}" ]] \
  && echo "$OUT" | grep -q "Retrying 1 case(s) that failed before the agent ran: 001-release-case" \
  && echo "$OUT" | grep -q "RESULT: All phases complete"; then
  pass "a case that failed before the agent ran is retried alone, and passes when the retry does"
else
  fail "a case that failed before the agent ran is retried alone, and passes when the retry does (rc=$RC, calls=$CALLS, staged='$STAGED', output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS_1="001-release-case:1,002-full-only-case:0:5" \
  STUB_CASE_RESULTS_2="001-release-case:1" 2>&1) || RC=$?
if [[ $RC -eq 3 ]] && echo "$OUT" | grep -q "RESULT: 1 case(s) failed before the agent ran (setup or infrastructure, not an agent result)"; then
  pass "a case that fails before the agent ran twice exits 3 as infrastructure"
else
  fail "a case that fails before the agent ran twice exits 3 as infrastructure (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS="001-release-case:1:7,002-full-only-case:0:5" 2>&1) || RC=$?
CALLS="$(cat "${ROOT}/capture/execute-calls" 2>/dev/null || echo 0)"
if [[ $RC -eq 1 && "$CALLS" == "1" ]] && echo "$OUT" | grep -q "RESULT: 1 case(s) failed ===" \
  && ! echo "$OUT" | grep -q "Retrying"; then
  pass "a case that failed after the agent ran is not retried and exits 1"
else
  fail "a case that failed after the agent ran is not retried and exits 1 (rc=$RC, calls=$CALLS, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS_1="001-release-case:1,002-full-only-case:1:7" \
  STUB_CASE_RESULTS_2="001-release-case:1" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "RESULT: 2 case(s) failed ===" \
  && echo "$OUT" | grep -q "of which failed before the agent ran (setup or infrastructure, after one retry): 001-release-case"; then
  pass "an agent failure alongside a setup failure exits 1 and names the setup failure"
else
  fail "an agent failure alongside a setup failure exits 1 and names the setup failure (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS="001-release-case:-1,002-full-only-case:0:5" 2>&1) || RC=$?
CALLS="$(cat "${ROOT}/capture/execute-calls" 2>/dev/null || echo 0)"
if [[ $RC -eq 1 && "$CALLS" == "1" ]] && ! echo "$OUT" | grep -q "Retrying"; then
  pass "a harness timeout (exit -1, no turns) is not retried as a setup failure and exits 1"
else
  fail "a harness timeout (exit -1, no turns) is not retried as a setup failure and exits 1 (rc=$RC, calls=$CALLS, output: $OUT)"
fi
rm -rf "$ROOT"

for tcode in 124 137; do
  run_test
  ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
  RC=0
  OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
    STUB_CASE_RESULTS="001-release-case:${tcode},002-full-only-case:0:5" 2>&1) || RC=$?
  CALLS="$(cat "${ROOT}/capture/execute-calls" 2>/dev/null || echo 0)"
  if [[ $RC -eq 1 && "$CALLS" == "1" ]] && ! echo "$OUT" | grep -q "Retrying"; then
    pass "a script timeout (exit ${tcode}) is not retried as a setup failure and exits 1"
  else
    fail "a script timeout (exit ${tcode}) is not retried as a setup failure and exits 1 (rc=$RC, calls=$CALLS, output: $OUT)"
  fi
  rm -rf "$ROOT"
done

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS="001-release-case:1:0:1200,002-full-only-case:0:5" 2>&1) || RC=$?
CALLS="$(cat "${ROOT}/capture/execute-calls" 2>/dev/null || echo 0)"
if [[ $RC -eq 1 && "$CALLS" == "1" ]] && ! echo "$OUT" | grep -q "Retrying"; then
  pass "a failure with recorded tokens but no final turn count is an agent failure, not retried"
else
  fail "a failure with recorded tokens but no final turn count is an agent failure, not retried (rc=$RC, calls=$CALLS, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS_1="001-release-case:1,002-full-only-case:0:5" \
  STUB_WORKSPACE_EXITS="0,1" 2>&1) || RC=$?
if [[ $RC -eq 3 ]] && echo "$OUT" | grep -q "the retry could not start; keeping the first attempt's results" \
  && echo "$OUT" | grep -q "RESULT: 1 case(s) failed before the agent ran"; then
  pass "a retry that cannot start keeps the first attempt and still reports a result"
else
  fail "a retry that cannot start keeps the first attempt and still reports a result (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS_1="001-release-case:1,002-full-only-case:0:5" \
  STUB_CASE_RESULTS_2="001-release-case:0:4" 2>&1) || RC=$?
RUNREC=""
for f in "${ROOT}"/eval/runs/testagent/*/run_result.json; do
  [[ "$f" == *-retry/run_result.json ]] && continue
  RUNREC="$f"
  break
done
MERGED="$(jq -c '{case: (.per_case["001-release-case"] | {exit_code, num_turns}), exit_code, num_turns}' "$RUNREC" 2>/dev/null || true)"
if [[ $RC -eq 0 && "$MERGED" == '{"case":{"exit_code":0,"num_turns":4},"exit_code":0,"num_turns":9}' ]]; then
  pass "a retried case's record replaces the first attempt in the run-level run_result.json, totals recomputed"
else
  fail "a retried case's record replaces the first attempt in the run-level run_result.json, totals recomputed (rc=$RC, merged='$MERGED', output: $OUT)"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# A retried case's first attempt is preserved under
# <run-dir>/first-attempt/cases/<case>, outside cases/ so it is never scored,
# and only when the retry replaced it.
# ---------------------------------------------------------------------------

# main_run_dir <root>: the testagent run dir that is not the -retry one.
main_run_dir() {
  local d
  for d in "$1"/eval/runs/testagent/*/; do
    [[ "$d" == *-retry/ ]] && continue
    echo "${d%/}"
    return
  done
}

# entries <dir>: the names in <dir>, each followed by a comma ("" if none).
entries() {
  local e out=""
  shopt -s nullglob dotglob
  for e in "$1"/*; do out+="$(basename "$e"),"; done
  shopt -u nullglob dotglob
  echo "$out"
}

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS_1="001-release-case:1,002-full-only-case:0:5" \
  STUB_CASE_RESULTS_2="001-release-case:0:4" 2>&1) || RC=$?
RD="$(main_run_dir "$ROOT")"
SCORED="$(cat "${RD}/cases/001-release-case/attempt.txt" 2>/dev/null || true)"
KEPT="$(cat "${RD}/first-attempt/cases/001-release-case/attempt.txt" 2>/dev/null || true)"
KEPT_EXIT="$(jq -r '.exit_code' "${RD}/first-attempt/cases/001-release-case/run_result.json" 2>/dev/null || true)"
TOP="$(entries "${RD}/first-attempt")"
KEPT_CASES="$(entries "${RD}/first-attempt/cases")"
if [[ $RC -eq 0 && "$SCORED" == "retry" && "$KEPT" == "first" && "$KEPT_EXIT" == "1" \
      && "$TOP" == "cases," && "$KEPT_CASES" == "001-release-case," ]] \
  && echo "$OUT" | grep -q "RESULT: All phases complete"; then
  pass "a retry that succeeds is scored from cases/, and the first attempt is kept in first-attempt/cases/"
else
  fail "a retry that succeeds is scored from cases/, and the first attempt is kept in first-attempt/cases/ (rc=$RC, scored='$SCORED', kept='$KEPT', kept_exit='$KEPT_EXIT', top='$TOP', kept_cases='$KEPT_CASES', output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS_1="001-release-case:1,002-full-only-case:0:5" \
  STUB_CASE_RESULTS_2="001-release-case:1" 2>&1) || RC=$?
RD="$(main_run_dir "$ROOT")"
SCORED="$(cat "${RD}/cases/001-release-case/attempt.txt" 2>/dev/null || true)"
KEPT="$(cat "${RD}/first-attempt/cases/001-release-case/attempt.txt" 2>/dev/null || true)"
if [[ $RC -eq 3 && "$SCORED" == "retry" && "$KEPT" == "first" ]] \
  && echo "$OUT" | grep -q "RESULT: 1 case(s) failed before the agent ran (setup or infrastructure, not an agent result)"; then
  pass "a retry that fails again keeps both attempts and still exits 3"
else
  fail "a retry that fails again keeps both attempts and still exits 3 (rc=$RC, scored='$SCORED', kept='$KEPT', output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS_1="001-release-case:1,002-full-only-case:0:5" \
  STUB_CASE_RESULTS_2="001-release-case:0:4" \
  STUB_WORKSPACE_EXITS="0,1" 2>&1) || RC=$?
RD="$(main_run_dir "$ROOT")"
SCORED="$(cat "${RD}/cases/001-release-case/attempt.txt" 2>/dev/null || true)"
if [[ $RC -eq 3 && "$SCORED" == "first" && ! -e "${RD}/first-attempt" ]] \
  && echo "$OUT" | grep -q "the retry could not start; keeping the first attempt's results"; then
  pass "a retry that cannot start leaves the first attempt in cases/ and creates no first-attempt/"
else
  fail "a retry that cannot start leaves the first attempt in cases/ and creates no first-attempt/ (rc=$RC, scored='$SCORED', output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS_1="001-release-case:1,002-full-only-case:0:5" \
  STUB_CASE_RESULTS_2="001-release-case:0:4" \
  STUB_COPY_FAIL_2=1 2>&1) || RC=$?
RD="$(main_run_dir "$ROOT")"
SCORED="$(cat "${RD}/cases/001-release-case/attempt.txt" 2>/dev/null || true)"
if [[ $RC -eq 3 && "$SCORED" == "first" && ! -e "${RD}/first-attempt" ]] \
  && echo "$OUT" | grep -q "the retry ran but its output could not be copied; keeping the first attempt's results"; then
  pass "a retry whose output copy fails leaves the first attempt in cases/ and creates no first-attempt/"
else
  fail "a retry whose output copy fails leaves the first attempt in cases/ and creates no first-attempt/ (rc=$RC, scored='$SCORED', output: $OUT)"
fi
while IFS= read -r ws; do
  [[ "$ws" == /tmp/agent-eval/*-retry ]] && rm -rf "$ws"
done < <(cat "${ROOT}/capture/ws-dirs" 2>/dev/null || true)
rmdir /tmp/agent-eval 2>/dev/null || true
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS_1="001-release-case:1,002-full-only-case:0:5" \
  STUB_CASE_RESULTS_2="001-release-case:0:4" \
  STUB_PRESERVED_EXISTS_2=1 2>&1) || RC=$?
RD="$(main_run_dir "$ROOT")"
SCORED="$(cat "${RD}/cases/001-release-case/attempt.txt" 2>/dev/null || true)"
OCCUPANT="$(cat "${RD}/first-attempt/cases/001-release-case/occupant.txt" 2>/dev/null || true)"
if [[ $RC -eq 3 && "$SCORED" == "first" && "$OCCUPANT" == "earlier" ]] \
  && echo "$OUT" | grep -q "first-attempt/cases/001-release-case already exists; keeping the first attempt of 001-release-case in cases/"; then
  pass "an occupied first-attempt/cases/<case> keeps the first attempt in cases/ and skips the retry"
else
  fail "an occupied first-attempt/cases/<case> keeps the first attempt in cases/ and skips the retry (rc=$RC, scored='$SCORED', occupant='$OCCUPANT', output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS="001-release-case:0:5,002-full-only-case:0:5" 2>&1) || RC=$?
RD="$(main_run_dir "$ROOT")"
RUN_DIRS="$(entries "${ROOT}/eval/runs/testagent")"
CASE_DIRS="$(entries "${RD}/cases")"
if [[ $RC -eq 0 && "$RUN_DIRS" == "$(basename "$RD")," && "$CASE_DIRS" == "001-release-case,002-full-only-case," && ! -e "${RD}/first-attempt" ]]; then
  pass "a run with no retries creates no first-attempt/ dir"
else
  fail "a run with no retries creates no first-attempt/ dir (rc=$RC, run_dirs=$RUN_DIRS, cases='$CASE_DIRS', output: $OUT)"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Judge errors: a threshold miss caused only by judge calls that errored is
# a judge infrastructure error (exit 3, one scoring retry), not a quality
# regression (exit 1).
# ---------------------------------------------------------------------------

ERRORED_SUMMARY='per_case:\n  001-release-case:\n    agent_quality:\n      judge_type: llm\n      error: "Error code: 400 - prompt is too long"\n      value: null\n  002-full-only-case:\n    agent_quality:\n      judge_type: llm\n      error: "Error code: 400 - prompt is too long"\n      value: null\n    deterministic_check:\n      value: true\n'
MIXED_SUMMARY='per_case:\n  001-release-case:\n    agent_quality:\n      judge_type: llm\n      error: "Error code: 400 - prompt is too long"\n      value: null\n    deterministic_check:\n      value: false\n'
CLEAN_SUMMARY='per_case:\n  001-release-case:\n    agent_quality:\n      value: 4\n  002-full-only-case:\n    agent_quality:\n      value: 4\n'
QUALITY_REGRESSION_OUT='\n  REGRESSIONS: 1 detected\n    [agent_quality] mean: >= 3.0 -> n/a\n'
MIXED_REGRESSION_OUT='\n  REGRESSIONS: 2 detected\n    [agent_quality] mean: >= 3.0 -> n/a\n    [deterministic_check] pass_rate: >= 1.0 -> 0.0\n'
CASES_OK="001-release-case:0:5,002-full-only-case:0:5"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="1,1" \
  STUB_SUMMARY_1="$ERRORED_SUMMARY" STUB_SCORE_OUT_1="$QUALITY_REGRESSION_OUT" \
  STUB_SUMMARY_2="$ERRORED_SUMMARY" STUB_SCORE_OUT_2="$QUALITY_REGRESSION_OUT" 2>&1) || RC=$?
CALLS="$(cat "${ROOT}/capture/score-calls" 2>/dev/null || echo 0)"
if [[ $RC -eq 3 && "$CALLS" == "2" ]] \
  && echo "$OUT" | grep -q "RESULT: judge infrastructure error (not a quality regression)" \
  && echo "$OUT" | grep -q "JUDGE ERROR: agent_quality errored on 2 case(s); first error: Error code: 400 - prompt is too long"; then
  pass "a threshold miss caused only by judge errors exits 3 after one retry, with the error text"
else
  fail "a threshold miss caused only by judge errors exits 3 after one retry, with the error text (rc=$RC, calls=$CALLS, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="1,0" \
  STUB_SUMMARY_1="$ERRORED_SUMMARY" STUB_SCORE_OUT_1="$QUALITY_REGRESSION_OUT" \
  STUB_SUMMARY_2="$CLEAN_SUMMARY" STUB_SCORE_OUT_2='\n  REGRESSIONS: 0\n' 2>&1) || RC=$?
CALLS="$(cat "${ROOT}/capture/score-calls" 2>/dev/null || echo 0)"
if [[ $RC -eq 0 && "$CALLS" == "2" ]] && echo "$OUT" | grep -q "RESULT: All phases complete"; then
  pass "a judge error that clears on the scoring retry passes"
else
  fail "a judge error that clears on the scoring retry passes (rc=$RC, calls=$CALLS, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="1,1" \
  STUB_SUMMARY_1="$MIXED_SUMMARY" STUB_SCORE_OUT_1="$MIXED_REGRESSION_OUT" \
  STUB_SUMMARY_2="$MIXED_SUMMARY" STUB_SCORE_OUT_2="$MIXED_REGRESSION_OUT" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "RESULT: quality regression" \
  && echo "$OUT" | grep -q "JUDGE ERROR: agent_quality errored on 1 case(s)"; then
  pass "a regression on a scored judge stays a quality regression (exit 1) and still reports the judge error"
else
  fail "a regression on a scored judge stays a quality regression (exit 1) and still reports the judge error (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="1" \
  STUB_SUMMARY_1="$CLEAN_SUMMARY" STUB_SCORE_OUT_1="$QUALITY_REGRESSION_OUT" 2>&1) || RC=$?
CALLS="$(cat "${ROOT}/capture/score-calls" 2>/dev/null || echo 0)"
if [[ $RC -eq 1 && "$CALLS" == "1" ]] && echo "$OUT" | grep -q "RESULT: quality regression (score.py exited 1)"; then
  pass "a regression with no judge errors exits 1 without a scoring retry"
else
  fail "a regression with no judge errors exits 1 without a scoring retry (rc=$RC, calls=$CALLS, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
PARTIAL_SUMMARY='per_case:\n  001-release-case:\n    agent_quality:\n      judge_type: llm\n      error: "Error code: 529 - overloaded"\n      value: null\n  002-full-only-case:\n    agent_quality:\n      value: 1\n'
PARTIAL_OUT='\n  REGRESSIONS: 1 detected\n    [agent_quality] mean: >= 3.0 -> 1.0\n'
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="1,1" \
  STUB_SUMMARY_1="$PARTIAL_SUMMARY" STUB_SCORE_OUT_1="$PARTIAL_OUT" \
  STUB_SUMMARY_2="$PARTIAL_SUMMARY" STUB_SCORE_OUT_2="$PARTIAL_OUT" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "RESULT: quality regression"; then
  pass "a low mean on a judge that also errored on some cases is a quality regression"
else
  fail "a low mean on a judge that also errored on some cases is a quality regression (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="1" STUB_SCORE_OUT_1='Traceback (most recent call last):\n  ValueError: bad judge config\n' 2>&1) || RC=$?
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "RESULT: score.py failed (exit 1) without a regression list"; then
  pass "a score.py crash with no regression list exits 1, not as infrastructure"
else
  fail "a score.py crash with no regression list exits 1, not as infrastructure (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
TWO_SUMMARY='per_case:\n  001-release-case:\n    z_quality:\n      judge_type: llm\n      error: "Error code: 400 - x"\n      value: null\n    agent_quality:\n      judge_type: llm\n      error: "Error code: 400 - x"\n      value: null\n'
TWO_OUT='\n  REGRESSIONS: 2 detected\n    [agent_quality] mean: >= 3.0 -> n/a\n    [z_quality] error_rate: <= 0.2 -> 1.000\n'
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="1,1" \
  STUB_SUMMARY_1="$TWO_SUMMARY" STUB_SCORE_OUT_1="$TWO_OUT" \
  STUB_SUMMARY_2="$TWO_SUMMARY" STUB_SCORE_OUT_2="$TWO_OUT" 2>&1) || RC=$?
if [[ $RC -eq 3 ]] && echo "$OUT" | grep -q "JUDGE ERROR: z_quality errored on 1 case(s)"; then
  pass "two errored judges (unsorted in the summary) still classify as infrastructure"
else
  fail "two errored judges (unsorted in the summary) still classify as infrastructure (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="0" STUB_SUMMARY_1="$ERRORED_SUMMARY" STUB_SCORE_OUT_1='\n  REGRESSIONS: 0\n' 2>&1) || RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "JUDGE ERROR: agent_quality errored on 2 case(s)"; then
  pass "judge errors are reported even when no threshold failed"
else
  fail "judge errors are reported even when no threshold failed (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full \
  STUB_CASE_RESULTS="001-release-case:1:7,002-full-only-case:0:5" \
  STUB_SCORE_EXITS="1,1" \
  STUB_SUMMARY_1="$ERRORED_SUMMARY" STUB_SCORE_OUT_1="$QUALITY_REGRESSION_OUT" 2>&1) || RC=$?
CALLS="$(cat "${ROOT}/capture/score-calls" 2>/dev/null || echo 0)"
if [[ $RC -eq 1 && "$CALLS" == "1" ]]; then
  pass "scoring is not retried when a case already failed"
else
  fail "scoring is not retried when a case already failed (rc=$RC, calls=$CALLS, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
CHECK_SUMMARY='per_case:\n  001-release-case:\n    deterministic_check:\n      judge_type: check\n      error: "KeyError: labels"\n      value: null\n'
CHECK_OUT='\n  REGRESSIONS: 1 detected\n    [deterministic_check] pass_rate: >= 1.0 -> n/a\n'
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="1" STUB_SUMMARY_1="$CHECK_SUMMARY" STUB_SCORE_OUT_1="$CHECK_OUT" 2>&1) || RC=$?
CALLS="$(cat "${ROOT}/capture/score-calls" 2>/dev/null || echo 0)"
if [[ $RC -eq 1 && "$CALLS" == "1" ]] && echo "$OUT" | grep -q "RESULT: quality regression"; then
  pass "a check judge that raises is an eval bug (exit 1), not a judge infrastructure error"
else
  fail "a check judge that raises is an eval bug (exit 1), not a judge infrastructure error (rc=$RC, calls=$CALLS, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
INJ_SUMMARY='per_case:\n  001-release-case:\n    agent_quality:\n      judge_type: llm\n      error: "bad\\n::add-mask::secret\\r\\n::set-env name=X::y"\n      value: null\n'
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" GITHUB_ACTIONS=true \
  STUB_SCORE_EXITS="0" STUB_SUMMARY_1="$INJ_SUMMARY" STUB_SCORE_OUT_1='\n  REGRESSIONS: 0\n' 2>&1) || RC=$?
if echo "$OUT" | grep -q "JUDGE ERROR: agent_quality errored on 1 case(s)" \
  && ! echo "$OUT" | grep -qE '^::(add-mask|set-env)'; then
  pass "judge error text cannot start a workflow command line"
else
  fail "judge error text cannot start a workflow command line (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
# 100,000 characters: past the 64 KiB pipe buffer, under Linux's 128 KiB
# limit on a single environment string.
BIG_ERR="$(head -c 100000 /dev/zero | tr '\0' 'x')"
BIG_SUMMARY="per_case:\n  001-release-case:\n    agent_quality:\n      judge_type: llm\n      error: \"${BIG_ERR}\"\n      value: null\n"
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="0" STUB_SUMMARY_1="$BIG_SUMMARY" STUB_SCORE_OUT_1='\n  REGRESSIONS: 0\n' 2>&1) || RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "JUDGE ERROR: agent_quality errored on 1 case(s)" \
  && echo "$OUT" | grep -q "RESULT: All phases complete"; then
  pass "a very long judge error is truncated without ending the run"
else
  fail "a very long judge error is truncated without ending the run (rc=$RC, output tail: $(echo "$OUT" | tail -3))"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# Per-case attribution: each failed check and each judge error is named by
# case and judge from summary.yaml (score.py prints only aggregates), with
# the judge's rationale or error, without changing the exit code. The saved
# summary below has score.py's shape: aggregates under judges:, and one
# value/rationale/judge_type (or error) per case and judge under per_case:.
# ---------------------------------------------------------------------------

SAVED_SUMMARY='judges:
  max_turns:
    pass_rate: 0.5
    mean: 0.5
    errored_cases: 0
    scored_cases: 2
  pr_created:
    pass_rate: 0.5
    mean: 0.5
    errored_cases: 0
    scored_cases: 2
  agent_quality:
    pass_rate: null
    mean: 4.0
    errored_cases: 1
    scored_cases: 1
per_case:
  002-full-only-case:
    max_turns:
      value: false
      rationale: "Exceeded max_turns: 12 > 10"
      judge_type: check
    pr_created:
      value: true
      rationale: "PR #7 created"
      judge_type: check
    agent_quality:
      value: 4
      rationale: "Solid triage"
      judge_type: llm
    expected_files:
      value: null
      rationale: "Skipped: condition false"
      judge_type: check
  001-release-case:
    max_turns:
      value: true
      rationale: "Turns OK: 8 <= 10"
      judge_type: check
    pr_created:
      value: false
      rationale: "No PR was created"
      judge_type: check
    agent_quality:
      value: null
      error: "Error code: 400 - prompt is too long"
      judge_type: llm
'
SAVED_REGRESSION_OUT='\n  REGRESSIONS: 1 detected\n    [pr_created] pass_rate: >= 1.0 -> 0.5\n'

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="1,1" \
  STUB_SUMMARY_1="$SAVED_SUMMARY" STUB_SCORE_OUT_1="$SAVED_REGRESSION_OUT" \
  STUB_SUMMARY_2="$SAVED_SUMMARY" STUB_SCORE_OUT_2="$SAVED_REGRESSION_OUT" 2>&1) || RC=$?
CASE_LINES="$(echo "$OUT" | grep '^CASE ' || true)"
EXPECTED_LINES='CASE JUDGE ERROR: [agent_quality] 001-release-case: Error code: 400 - prompt is too long
CASE CHECK FAILED: [pr_created] 001-release-case: No PR was created
CASE CHECK FAILED: [max_turns] 002-full-only-case: Exceeded max_turns: 12 > 10'
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "RESULT: quality regression (score.py exited 1)" \
  && [[ "$CASE_LINES" == "$EXPECTED_LINES" ]]; then
  pass "a regression names each failed check and judge error by case and judge, with its reason, sorted, and still exits 1"
else
  fail "a regression names each failed check and judge error by case and judge, with its reason, sorted, and still exits 1 (rc=$RC, case lines: '$CASE_LINES', output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="1,1" \
  STUB_SUMMARY_1="$ERRORED_SUMMARY" STUB_SCORE_OUT_1="$QUALITY_REGRESSION_OUT" \
  STUB_SUMMARY_2="$ERRORED_SUMMARY" STUB_SCORE_OUT_2="$QUALITY_REGRESSION_OUT" 2>&1) || RC=$?
if [[ $RC -eq 3 ]] && echo "$OUT" | grep -q "RESULT: judge infrastructure error (not a quality regression)" \
  && echo "$OUT" | grep -qF "CASE JUDGE ERROR: [agent_quality] 001-release-case: Error code: 400" \
  && echo "$OUT" | grep -qF "CASE JUDGE ERROR: [agent_quality] 002-full-only-case: Error code: 400" \
  && ! echo "$OUT" | grep -q "CASE CHECK FAILED"; then
  pass "an errored judge is named per case as a judge error, not a failed check, and still exits 3"
else
  fail "an errored judge is named per case as a judge error, not a failed check, and still exits 3 (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="0" STUB_SUMMARY_1="$CLEAN_SUMMARY" STUB_SCORE_OUT_1='\n  REGRESSIONS: 0\n' 2>&1) || RC=$?
if [[ $RC -eq 0 ]] && ! echo "$OUT" | grep -q "^CASE "; then
  pass "passing, numeric and skipped judge results print no per-case lines"
else
  fail "passing, numeric and skipped judge results print no per-case lines (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
NO_REASON_SUMMARY='per_case:\n  001-release-case:\n    max_turns:\n      value: false\n      judge_type: check\n'
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SCORE_EXITS="0" STUB_SUMMARY_1="$NO_REASON_SUMMARY" STUB_SCORE_OUT_1='\n  REGRESSIONS: 0\n' 2>&1) || RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -qF "CASE CHECK FAILED: [max_turns] 001-release-case: (no reason recorded)"; then
  pass "a failed check with no rationale says so"
else
  fail "a failed check with no rationale says so (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
INJ_CHECK_SUMMARY='per_case:\n  001-release-case:\n    max_turns:\n      value: false\n      rationale: "over\\n::add-mask::secret\\r\\n::set-env name=X::y\\tend"\n      judge_type: check\n'
OUT=$(run_rf "$ROOT" testagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" GITHUB_ACTIONS=true \
  STUB_SCORE_EXITS="0" STUB_SUMMARY_1="$INJ_CHECK_SUMMARY" STUB_SCORE_OUT_1='\n  REGRESSIONS: 0\n' 2>&1) || RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "CASE CHECK FAILED: \[max_turns\] 001-release-case: over" \
  && ! echo "$OUT" | grep -qE '^::(add-mask|set-env)'; then
  pass "a failed check's rationale stays on one line and cannot start a workflow command"
else
  fail "a failed check's rationale stays on one line and cannot start a workflow command (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
# An agent whose every threshold is report-only (as triage and review are)
# runs with an empty runtime thresholds map: it still passes when every case
# passes, still fails on a case exit, and a judge error is reported without
# failing the run or retrying scoring.
# ---------------------------------------------------------------------------

add_report_only_agent() {
  local root="$1"
  mkdir -p "${root}/eval/reportonlyagent/cases/001-release-case" \
    "${root}/eval/reportonlyagent/cases/002-full-only-case"
  cat > "${root}/eval/reportonlyagent/eval.yaml" <<'YAML'
name: reportonlyagent-eval
dataset:
  path: cases
thresholds:
  agent_quality:
    min_mean: 3.0
    max_error_rate: 0.2
  required_labels:
    min_pass_rate: 1.0
  finding_expectations:
    min_pass_rate: 1.0
YAML
  printf 'release: true\nmax_turns: 10\n' > "${root}/eval/reportonlyagent/cases/001-release-case/annotations.yaml"
  printf 'max_turns: 10\n' > "${root}/eval/reportonlyagent/cases/002-full-only-case/annotations.yaml"
  echo "fixture: {}" > "${root}/eval/reportonlyagent/cases/001-release-case/input.yaml"
  echo "fixture: {}" > "${root}/eval/reportonlyagent/cases/002-full-only-case/input.yaml"
}

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; add_report_only_agent "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" reportonlyagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SUMMARY_1="$CLEAN_SUMMARY" 2>&1) || RC=$?
RUNTIME_THRESHOLDS="$(yq -r '.thresholds | length' "${ROOT}/capture/last-config.yaml" 2>/dev/null || echo missing)"
if [[ $RC -eq 0 && "$RUNTIME_THRESHOLDS" == "0" ]] && echo "$OUT" | grep -q "RESULT: All phases complete"; then
  pass "an agent with only report-only thresholds passes with an empty runtime thresholds map"
else
  fail "an agent with only report-only thresholds passes with an empty runtime thresholds map (rc=$RC, thresholds=$RUNTIME_THRESHOLDS, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; add_report_only_agent "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" reportonlyagent EVAL_TIER=full \
  STUB_CASE_RESULTS="001-release-case:1:7,002-full-only-case:0:5" 2>&1) || RC=$?
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "RESULT: 1 case(s) failed ==="; then
  pass "an agent with only report-only thresholds still fails on a case exit (exit 1)"
else
  fail "an agent with only report-only thresholds still fails on a case exit (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; add_report_only_agent "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" reportonlyagent EVAL_TIER=full \
  STUB_CASE_RESULTS_1="001-release-case:1,002-full-only-case:0:5" \
  STUB_CASE_RESULTS_2="001-release-case:1" 2>&1) || RC=$?
if [[ $RC -eq 3 ]] && echo "$OUT" | grep -q "failed before the agent ran (setup or infrastructure, not an agent result)"; then
  pass "an agent with only report-only thresholds still exits 3 on a repeated pre-agent failure"
else
  fail "an agent with only report-only thresholds still exits 3 on a repeated pre-agent failure (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; add_report_only_agent "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" reportonlyagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SUMMARY_1="$ERRORED_SUMMARY" 2>&1) || RC=$?
CALLS="$(cat "${ROOT}/capture/score-calls" 2>/dev/null || echo 0)"
if [[ $RC -eq 0 && "$CALLS" == "1" ]] \
  && echo "$OUT" | grep -q "JUDGE ERROR: agent_quality errored on 2 case(s)"; then
  pass "a judge error on a report-only judge is reported, without a scoring retry or a failed run"
else
  fail "a judge error on a report-only judge is reported, without a scoring retry or a failed run (rc=$RC, calls=$CALLS, output: $OUT)"
fi
rm -rf "$ROOT"

run_test
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"; add_report_only_agent "$ROOT"
RC=0
OUT=$(run_rf "$ROOT" reportonlyagent EVAL_TIER=full STUB_CASE_RESULTS="$CASES_OK" \
  STUB_SUMMARY_1="$SAVED_SUMMARY" STUB_SCORE_OUT_1='\n  REGRESSIONS: 0\n' 2>&1) || RC=$?
CALLS="$(cat "${ROOT}/capture/score-calls" 2>/dev/null || echo 0)"
if [[ $RC -eq 0 && "$CALLS" == "1" ]] && echo "$OUT" | grep -q "RESULT: All phases complete" \
  && echo "$OUT" | grep -qF "CASE CHECK FAILED: [max_turns] 002-full-only-case: Exceeded max_turns: 12 > 10" \
  && echo "$OUT" | grep -qF "CASE JUDGE ERROR: [agent_quality] 001-release-case: Error code: 400 - prompt is too long"; then
  pass "a failed report-only check is named by case without failing the run"
else
  fail "a failed report-only check is named by case without failing the run (rc=$RC, calls=$CALLS, output: $OUT)"
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
