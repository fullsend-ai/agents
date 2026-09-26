#!/usr/bin/env bash
# Run functional agent tests using agent-eval-harness.
#
# Usage:
#   ./eval/run-functional.sh <agent-name>
#
# Example:
#   EVAL_ORG=halfsend ./eval/run-functional.sh triage
#
# Required environment:
#   EVAL_ORG      — GitHub org for ephemeral repos
#   GH_TOKEN      — GitHub token (defaults to gh auth token)
#
# Required:
#   agent-eval-harness — pip install from the submodule or repo
#   fullsend           — must be on PATH
#
# Optional environment:
#   FULLSEND_DIR  — path to fullsend scaffold directory (default: repo root)
#   EVAL_RUNTIME  — run every case under this runtime (claude|pi) instead of
#                   the workspace config.yaml's runtime (fullsend run --runtime)
#   EVAL_MODEL    — model override for every case: alias, id or provider/id
#                   (fullsend run --model), e.g. google-vertex/gemini-2.5-flash
#   EVAL_EFFORT   — effort override (fullsend run --effort)
#   EVAL_TIER     — "full" (default) or "release".
#                     full    — run every case, as today.
#                     release — run only this agent's release:true case(s),
#                               and fail only on a non-zero case exit or a
#                               deterministic judge (not on LLM-quality
#                               judges or the max_turns/max_cost budget
#                               judges, which still run and report).
#                   If unset, defaults to "release" when running as a
#                   cross-repo workflow_call under GitHub Actions
#                   (GITHUB_ACTIONS=true and GITHUB_REPOSITORY set to
#                   something other than fullsend-ai/agents — i.e. the
#                   fullsend release gate, which checks out agents `main`
#                   rather than a pinned commit). Otherwise defaults to
#                   "full". Any other value is an error.
#   GOOGLE_APPLICATION_CREDENTIALS, ANTHROPIC_VERTEX_PROJECT_ID, etc.
#   AGENT_EVAL_HARNESS_DIR — path to agent-eval-harness
#
# Exit status:
#   0 — every phase passed
#   1 — a case failed after the agent ran, a judge threshold failed on
#       scored cases (a quality regression), or score.py failed without a
#       regression list (a crash or a config error)
#   3 — infrastructure, not an agent or quality result: every failed case
#       failed before the agent ran (non-zero exit other than a timeout,
#       no turns, cost or tokens) on its first run and on one retry, or
#       every failing threshold is explained by LLM judge calls that errored
#       (an error_rate gate, or a judge left with no score), after one
#       scoring retry
set -euo pipefail

AGENT="${1:?agent name required}"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${EVAL_DIR}/.." && pwd)"
export REPO_ROOT
export PATH="${EVAL_DIR}/scripts:${PATH}"
EVAL_YAML_SRC="${EVAL_DIR}/${AGENT}/eval.yaml"
CASES_DIR="${EVAL_DIR}/${AGENT}/cases"

if [[ ! -f "$EVAL_YAML_SRC" ]]; then
  echo "ERROR: eval config not found: $EVAL_YAML_SRC" >&2
  exit 1
fi

notice() {
  # ::notice:: is GitHub Actions annotation syntax; plain text elsewhere.
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::notice::$1"
  else
    echo "$1"
  fi
}

# ---------------------------------------------------------------------------
# Tier selection
# ---------------------------------------------------------------------------
if [[ -n "${EVAL_TIER:-}" ]]; then
  case "$EVAL_TIER" in
    full|release)
      TIER_REASON="explicit EVAL_TIER=${EVAL_TIER}"
      ;;
    *)
      echo "ERROR: invalid EVAL_TIER '${EVAL_TIER}' (must be 'full' or 'release')" >&2
      exit 1
      ;;
  esac
elif [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${GITHUB_REPOSITORY:-}" && "${GITHUB_REPOSITORY}" != "fullsend-ai/agents" ]]; then
  # Cross-repo workflow_call (the fullsend release gate) runs this script
  # from agents `main`, not a pinned commit, so this is the one place the
  # release-tier default can take effect without a fullsend pin bump.
  EVAL_TIER="release"
  TIER_REASON="cross-repo workflow_call (GITHUB_REPOSITORY=${GITHUB_REPOSITORY} != fullsend-ai/agents)"
else
  EVAL_TIER="full"
  TIER_REASON="default (not a cross-repo Actions call)"
fi

notice "EVAL_TIER=${EVAL_TIER} (${TIER_REASON})"

# ---------------------------------------------------------------------------
# Release-tier case selection — stage only this agent's release:true
# case(s) into a temp dataset dir so the checked-in cases/ tree is never
# modified. The staging dir is created as a sibling of cases/ (i.e. at the
# same depth under eval/<agent>/) so a case's relative symlinks (e.g.
# repo/ -> ../../repos/foo) still resolve correctly from the copy.
# ---------------------------------------------------------------------------
EVAL_YAML=""
RELEASE_STAGE_DIR=""
RETRY_STAGE_DIR=""
RETRY_YAML=""
cleanup_runtime_config() {
  # Trailing `true` is load-bearing: an EXIT trap's own exit status
  # replaces an already-issued `exit N` when the trap's last command is
  # false, and the `[[ -n ... ]] &&` guards below are false whenever that
  # path was never created — without `true` a successful run would be
  # reported to the caller as exit 1.
  [[ -n "$EVAL_YAML" ]] && rm -f "$EVAL_YAML"
  [[ -n "$RELEASE_STAGE_DIR" ]] && rm -rf "$RELEASE_STAGE_DIR"
  [[ -n "$RETRY_STAGE_DIR" ]] && rm -rf "$RETRY_STAGE_DIR"
  [[ -n "$RETRY_YAML" ]] && rm -f "$RETRY_YAML"
  true
}
# Armed before either temp path is created, so a failure while staging
# release cases cannot leave eval/<agent>/release-cases-* behind.
trap cleanup_runtime_config EXIT

if [[ "$EVAL_TIER" == "release" ]]; then
  RELEASE_STAGE_DIR="$(mktemp -d "${EVAL_DIR}/${AGENT}/release-cases-XXXXXX")"
  release_case_count=0
  shopt -s nullglob
  for case_dir in "${CASES_DIR}"/*/; do
    case_name="$(basename "$case_dir")"
    annotations="${case_dir}annotations.yaml"
    if [[ -f "$annotations" ]] && [[ "$(yq '.release // false' "$annotations")" == "true" ]]; then
      cp -a "$case_dir" "${RELEASE_STAGE_DIR}/${case_name}"
      release_case_count=$((release_case_count + 1))
    fi
  done
  shopt -u nullglob
  if [[ "$release_case_count" -eq 0 ]]; then
    notice "No release:true case for agent '${AGENT}' — skipping functional tests"
    rm -rf "$RELEASE_STAGE_DIR"
    exit 0
  fi
  CASES_DIR="$RELEASE_STAGE_DIR"
fi

# The harness has inconsistent path resolution for dataset.path between
# workspace.py (config-dir-relative) and execute.py (cwd-relative). Work
# around this by rewriting dataset.path to an absolute path at runtime.
# BSD mktemp (macOS) only substitutes trailing X's, so a template with a
# .yaml suffix produces the literal name eval-runtime-XXXXXX.yaml and a second
# run fails with "File exists". Create the temp name first, then add the suffix.
EVAL_YAML_TMP="$(mktemp "${EVAL_DIR}/${AGENT}/eval-runtime-XXXXXX")"
EVAL_YAML="${EVAL_YAML_TMP}.yaml"
mv "$EVAL_YAML_TMP" "$EVAL_YAML"

yq_expr=".dataset.path = \"${CASES_DIR}\""
if [[ "$EVAL_TIER" == "release" ]]; then
  # Report-only judges in the release tier: LLM-quality judges (name ends
  # in "_quality", e.g. review_quality/triage_quality) and the max_turns/
  # max_cost budget judges. score.py's detect_regressions() only gates on
  # judges with a thresholds: entry, so dropping these leaves them running
  # and reported but out of the tier's pass/fail decision.
  yq_expr+=' | .thresholds |= with_entries(select(.key as $k | ($k == "max_turns" or $k == "max_cost" or ($k | test("_quality$"))) | not))'
fi
yq "$yq_expr" "$EVAL_YAML_SRC" > "$EVAL_YAML"
HARNESS_DIR="${AGENT_EVAL_HARNESS_DIR:-${EVAL_DIR}/.agent-eval-harness}"

# Fail fast if agent_eval library is not installed
if ! python3 -c "import agent_eval" 2>/dev/null; then
  echo "ERROR: agent-eval-harness library is not installed." >&2
  echo "       pip install -e eval/.agent-eval-harness" >&2
  exit 1
fi

# Fail fast if fullsend is not on PATH
if ! command -v fullsend >/dev/null 2>&1; then
  echo "ERROR: fullsend is not installed or not on PATH" >&2
  exit 1
fi

# Fail fast if openshell is not on PATH
if ! command -v openshell >/dev/null 2>&1; then
  echo "ERROR: openshell is not installed" >&2
  exit 1
fi

WORKSPACE_PY="${HARNESS_DIR}/skills/eval-run/scripts/workspace.py"
EXECUTE_PY="${HARNESS_DIR}/skills/eval-run/scripts/execute.py"
SCORE_PY="${HARNESS_DIR}/skills/eval-run/scripts/score.py"

for script in "$WORKSPACE_PY" "$EXECUTE_PY" "$SCORE_PY"; do
  if [[ ! -f "$script" ]]; then
    echo "ERROR: harness script not found: $script" >&2
    echo "       Run: git submodule sync eval/.agent-eval-harness && git submodule update --init eval/.agent-eval-harness" >&2
    exit 1
  fi
done

export GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"

# Default FULLSEND_DIR to the repo root (the agents repo IS the scaffold).
export FULLSEND_DIR="${FULLSEND_DIR:-${REPO_ROOT}}"
# Per-run overrides forwarded to run-fullsend.sh (empty = not set).
export EVAL_RUNTIME="${EVAL_RUNTIME:-}" EVAL_MODEL="${EVAL_MODEL:-}" EVAL_EFFORT="${EVAL_EFFORT:-}"
FULLSEND_DIR="$(cd "$FULLSEND_DIR" && pwd)"
export FULLSEND_DIR

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUNS_BASE="${EVAL_DIR}/runs"
RUNS_DIR="${RUNS_BASE}/${AGENT}"
RUN_DIR="${RUNS_DIR}/${RUN_ID}"
mkdir -p "$RUN_DIR"

echo "=== Functional Tests: ${AGENT} ==="
echo "Tier:    ${EVAL_TIER}"
echo "Config:  ${EVAL_YAML}"
echo "Cases:   ${CASES_DIR}"
echo "Run ID:  ${RUN_ID}"
echo "Output:  ${RUN_DIR}"
echo ""

# If no case directories exist, warn and exit successfully.
shopt -s nullglob
case_dirs=("${CASES_DIR}"/*/)
shopt -u nullglob
if [[ ${#case_dirs[@]} -eq 0 ]]; then
  echo "WARNING: no cases found in ${CASES_DIR} — skipping functional tests for ${AGENT}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Phases 1-2: create workspaces and execute — the harness drives case
# iteration with hooks. execute_run is called once, plus once more for any
# case that failed before the agent ran (see below).
# ---------------------------------------------------------------------------
# execute_run <config> <run-id> <run-dir>: sets exec_exit.
execute_run() {
  local config="$1" run_id="$2" run_dir="$3" first_run="${4:-}"
  mkdir -p "$run_dir"
  echo "=== Creating workspaces ==="
  # EVAL_CASES="001-foo 002-bar" limits the first run to those case
  # directories (workspace.py --cases). A retry run is already staged with
  # only the cases it should repeat, so it gets no --cases.
  local case_args=()
  if [[ "$first_run" == "first" && -n "${EVAL_CASES:-}" ]]; then
    # shellcheck disable=SC2206 # intentional word splitting on whitespace
    case_args=(--cases ${EVAL_CASES})
  fi
  if ! python3 "$WORKSPACE_PY" \
    --config "$config" \
    --run-id "$run_id" \
    "${case_args[@]+"${case_args[@]}"}"; then
    echo "ERROR: workspace.py failed for run ${run_id}" >&2
    return 1
  fi

  echo ""
  echo "=== Executing ==="
  exec_exit=0
  # Forward EVAL_MODEL/EVAL_EFFORT to the harness too, so an eval whose
  # runner.command carries the {model}/{effort} placeholders (eval/code-rhai)
  # resolves them from the override instead of models.skill. Evals without
  # the placeholders (eval/code) still get the override from run-fullsend.sh's env.
  local model_args=()
  [[ -n "${EVAL_MODEL:-}" ]] && model_args+=(--model "$EVAL_MODEL")
  [[ -n "${EVAL_EFFORT:-}" ]] && model_args+=(--effort "$EVAL_EFFORT")
  AGENT_EVAL_RUNS_DIR="$RUNS_BASE" \
    python3 "$EXECUTE_PY" \
      --workspace "/tmp/agent-eval/${run_id}" \
      --skill "$AGENT" \
      --config "$config" \
      --output "$run_dir" \
      --run-id "$run_id" \
      "${model_args[@]+"${model_args[@]}"}" \
    || exec_exit=$?

  # Copy output artifacts from harness workspace to runs directory.
  # execute.py copies stdout/stderr/input but not the output/ subdirectory
  # that after_each hooks populate (e.g., fixture-state.json).
  # execute.py copies stdout/stderr/input but not the outputs[*].path
  # subdirectories that after_each hooks populate (output/fixture-state.json,
  # and eval/code-rhai's judge/ tree). Copy every declared outputs path.
  local ws_cases="/tmp/agent-eval/${run_id}/cases" ws_case case_name out_path
  local output_paths=()
  mapfile -t output_paths < <(yq -r '.outputs[] | .path // ""' "$config" | grep -v '^$')
  [[ ${#output_paths[@]} -eq 0 ]] && output_paths=(output)
  if [[ -d "$ws_cases" ]]; then
    for ws_case in "$ws_cases"/*/; do
      case_name=$(basename "$ws_case")
      for out_path in "${output_paths[@]}"; do
        if [[ -d "$ws_case/$out_path" ]]; then
          mkdir -p "$run_dir/cases/${case_name}/$out_path"
          if ! cp -a "$ws_case/$out_path/." "$run_dir/cases/${case_name}/$out_path/"; then
            echo "ERROR: copying ${case_name} ${out_path} into ${run_dir} failed" >&2
            return 2
          fi
        fi
      done
    done
  fi
}

# A case that exited non-zero with no agent turns, no cost and no tokens
# never reached the agent: a fixture, sandbox, provider or profile setup
# failure (e.g. a provider profile reported missing right after import), or
# a runner that could not start. A timed-out agent is left out: the
# script's own `timeout` (exit 124, or 137 after SIGKILL) and the harness
# timeout (exit -1) cut the run before its final turn and cost totals, so
# those can read 0, but the agent ran (tokens are recorded as it goes).
# Prints one case name per line.
pre_agent_failures() {
  local case_dir case_name run_result
  for case_dir in "${case_dirs[@]}"; do
    case_name="$(basename "$case_dir")"
    run_result="$RUN_DIR/cases/${case_name}/run_result.json"
    [[ -f "$run_result" ]] || continue
    if jq -e '(.exit_code // 0) as $e
              | $e != 0 and ([-1, 124, 137] | index($e) | not)
              and ((.num_turns // 0) == 0)
              and ((.cost_usd // 0) == 0)
              and (([(.token_usage // {})[]?] | add // 0) == 0)' "$run_result" >/dev/null 2>&1; then
      echo "$case_name"
    fi
  done
}

execute_run "$EVAL_YAML" "$RUN_ID" "$RUN_DIR" first || exit 1

if [[ $exec_exit -ne 0 ]]; then
  echo "WARNING: execute.py exited $exec_exit" >&2
  # If no case produced output, this is an infrastructure failure — not an agent failure.
  if [[ ! -d "$RUN_DIR/cases" ]] || [[ -z "$(ls "$RUN_DIR/cases/" 2>/dev/null)" ]]; then
    echo "ERROR: no case output produced — infrastructure failure" >&2
    exit 1
  fi
fi

# Retry, once, the cases that failed before the agent ran. They are staged
# like release-tier cases (a sibling of cases/, so relative symlinks still
# resolve), run under their own run id, and each retried case's results
# replace its first attempt in RUN_DIR.
mapfile -t retry_cases < <(pre_agent_failures)
if [[ ${#retry_cases[@]} -gt 0 ]]; then
  echo ""
  echo "Retrying ${#retry_cases[@]} case(s) that failed before the agent ran: ${retry_cases[*]}" >&2
  RETRY_STAGE_DIR="$(mktemp -d "${EVAL_DIR}/${AGENT}/retry-cases-XXXXXX")"
  for case_name in "${retry_cases[@]}"; do
    cp -a "${CASES_DIR}/${case_name}" "${RETRY_STAGE_DIR}/${case_name}"
  done
  RETRY_YAML_TMP="$(mktemp "${EVAL_DIR}/${AGENT}/eval-retry-XXXXXX")"
  RETRY_YAML="${RETRY_YAML_TMP}.yaml"
  mv "$RETRY_YAML_TMP" "$RETRY_YAML"
  yq ".dataset.path = \"${RETRY_STAGE_DIR}\"" "$EVAL_YAML" > "$RETRY_YAML"
  RETRY_RUN_ID="${RUN_ID}-retry"
  RETRY_RUN_DIR="${RUNS_DIR}/${RETRY_RUN_ID}"
  first_exec_exit=$exec_exit
  retry_rc=0
  execute_run "$RETRY_YAML" "$RETRY_RUN_ID" "$RETRY_RUN_DIR" || retry_rc=$?
  if [[ $retry_rc -eq 0 ]]; then
    for case_name in "${retry_cases[@]}"; do
      retried="${RETRY_RUN_DIR}/cases/${case_name}"
      [[ -d "$retried" ]] || continue
      rm -rf "${RUN_DIR}/cases/${case_name}"
      cp -a "$retried" "${RUN_DIR}/cases/${case_name}"
      # score.py also reads each case's record from the run-level
      # run_result.json; point it at the retry's.
      if [[ -f "${RUN_DIR}/run_result.json" && -f "${retried}/run_result.json" ]]; then
        # Replace the case's record, then recompute the run-level totals
        # from per_case so they describe the attempts that count: exit_code
        # as execute.py derives it (the max), and summed cost, turns and
        # tokens. The first attempt's spend stays in its own case dirs.
        if ! { jq --arg c "$case_name" --slurpfile r "${retried}/run_result.json" '
                 .per_case[$c] = $r[0]
                 | [.per_case[]] as $cs
                 | .exit_code = ([$cs[] | .exit_code // 0] | max)
                 | .cost_usd = ([$cs[] | .cost_usd // 0] | add)
                 | .num_turns = ([$cs[] | .num_turns // 0] | add)
                 | .token_usage = (reduce ($cs[] | .token_usage // {} | to_entries[]) as $t
                                     ({}; .[$t.key] = ((.[$t.key] // 0) + ($t.value // 0))))
               ' "${RUN_DIR}/run_result.json" > "${RUN_DIR}/run_result.json.tmp" \
               && mv "${RUN_DIR}/run_result.json.tmp" "${RUN_DIR}/run_result.json"; }; then
          echo "WARNING: could not update run_result.json for ${case_name}" >&2
        fi
      fi
    done
  elif [[ $retry_rc -eq 2 ]]; then
    echo "WARNING: the retry ran but its output could not be copied; keeping the first attempt's results" >&2
    exec_exit=$first_exec_exit
  else
    echo "WARNING: the retry could not start; keeping the first attempt's results" >&2
    exec_exit=$first_exec_exit
  fi
  # The retry's own exit replaces the first attempt's only when every
  # first-attempt failure was one of the retried cases.
  if [[ $first_exec_exit -ne 0 && $exec_exit -eq 0 ]]; then
    other_failure=false
    for case_dir in "${case_dirs[@]}"; do
      case_name="$(basename "$case_dir")"
      [[ " ${retry_cases[*]} " == *" ${case_name} "* ]] && continue
      jq -e '(.exit_code // 1) == 0' "$RUN_DIR/cases/${case_name}/run_result.json" >/dev/null 2>&1 \
        || other_failure=true
    done
    [[ "$other_failure" == true ]] && exec_exit=$first_exec_exit
  elif [[ $first_exec_exit -ne 0 ]]; then
    exec_exit=$first_exec_exit
  fi
fi

# A non-zero exit from any individual case must fail the script, even when
# other cases produced output — the aggregate execute.py exit code above is
# not reliable enough to gate on by itself (a -1 timeout is hidden by its
# max()). Check every expected case's own run_result.json exit record; a
# case with no record (skipped, or execute.py died first) is a failure too.
case_failures=()
for case_dir in "${case_dirs[@]}"; do
  case_name="$(basename "$case_dir")"
  run_result="$RUN_DIR/cases/${case_name}/run_result.json"
  if [[ ! -f "$run_result" ]]; then
    case_failures+=("${case_name} (no run_result.json)")
    continue
  fi
  case_exit="$(jq -r '.exit_code // "missing"' "$run_result")"
  if [[ "$case_exit" != "0" ]]; then
    case_failures+=("${case_name} (exit ${case_exit})")
  fi
done
mapfile -t setup_failures < <(pre_agent_failures)
if [[ ${#case_failures[@]} -gt 0 ]]; then
  echo "ERROR: ${#case_failures[@]} case(s) failed to run cleanly:" >&2
  printf '  %s\n' "${case_failures[@]}" >&2
  if [[ ${#setup_failures[@]} -gt 0 ]]; then
    echo "  of which failed before the agent ran (setup or infrastructure, after one retry): ${setup_failures[*]}" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Phase 3: Score — use agent-eval-harness score.py for judging
# ---------------------------------------------------------------------------
echo ""
echo "=== Scoring ==="
# Scoring runs on the host and needs the original GCP credentials, not the
# sandbox-rewritten ones (which reference paths inside the container).
if [[ -n "${EVALS_HOST_CREDENTIALS:-}" ]]; then
  export GOOGLE_APPLICATION_CREDENTIALS="$EVALS_HOST_CREDENTIALS"
fi
SCORE_LOG="${RUN_DIR}/score.log"
SUMMARY_YAML="${RUN_DIR}/summary.yaml"

# score.py exits 1 for any threshold miss, including one caused only by
# judge calls that errored (a 400 from the model API, an unparseable
# reply): those cases carry an `error:` entry and a null score. Capture
# its output instead of letting set -e end the script, so a judge error is
# reported as infrastructure, not as a quality regression.
run_score() {
  local rc=0
  AGENT_EVAL_RUNS_DIR="$RUNS_BASE" \
    python3 "$SCORE_PY" judges \
      --run-id "$RUN_ID" \
      --config "$EVAL_YAML" 2>&1 | tee "$SCORE_LOG" || rc=$?
  return "$rc"
}

# Model-backed judges (judge_type llm or agent) whose call errored on at
# least one case, sorted, one per line. A check judge that raises, or a
# judge's own `if:` condition raising, is a bug in the eval (possibly in the
# change under test), not a failed call, so other judge types and
# "Condition error" entries are left out.
errored_judges() {
  [[ -f "$SUMMARY_YAML" ]] || return 0
  yq -r '[.per_case[] | to_entries[]
          | select((.value.judge_type == "llm" or .value.judge_type == "agent") and .value.error != null
                   and (.value.error | test("^Condition error") | not))
          | .key] | .[]' "$SUMMARY_YAML" 2>/dev/null | sort -u || true
}

# score.py's regression lines ("    [judge] metric: baseline -> current")
# that a judge error does NOT explain, one per line. A line is explained
# when its metric is error_rate (the max_error_rate gate), or its current
# value is n/a and the judge errored. Anything else (including a low mean
# on a judge that also errored on some cases) is a quality regression.
unexplained_regressions() {
  # Through the environment: BSD awk rejects a newline in a -v value.
  ERRORED_JUDGES="$1" awk '
    BEGIN { n = split(ENVIRON["ERRORED_JUDGES"], e, "\n"); for (i = 1; i <= n; i++) if (e[i] != "") err[e[i]] = 1 }
    /REGRESSIONS: [0-9]+ detected/ { in_list = 1; next }
    in_list && match($0, /^ +\[[A-Za-z0-9_.-]+\] /) {
      judge = substr($0, RSTART, RLENGTH); gsub(/[][ ]/, "", judge)
      rest = substr($0, RSTART + RLENGTH)
      metric = rest; sub(/:.*/, "", metric)
      current = rest; sub(/.*-> */, "", current)
      if (metric == "error_rate" || (current == "n/a" && (judge in err))) next
      print; next
    }
    in_list { in_list = 0 }' "$SCORE_LOG"
}

# One line of untrusted text that Actions cannot read as a workflow
# command: CR/LF become spaces and every "::" is broken up. Judge error
# text comes from model API responses and eval config.
log_safe() {
  printf '%s' "$1" | tr '\r\n' '  ' | sed 's/::/: :/g'
}

print_judge_errors() {
  local judge count first_error
  while IFS= read -r judge; do
    [[ -n "$judge" ]] || continue
    count="$(yq -r "[.per_case[] | select(.[\"${judge}\"].error != null)] | length" "$SUMMARY_YAML" 2>/dev/null || echo "?")"
    # Read the whole value, then cut it in bash: piping into `head -c`
    # can SIGPIPE yq on a long error and, under pipefail, end the script
    # before it reports a result.
    first_error="$(yq -r "[.per_case[] | .[\"${judge}\"].error | select(. != null)] | .[0]" "$SUMMARY_YAML" 2>/dev/null || true)"
    first_error="${first_error:0:300}"
    echo "JUDGE ERROR: $(log_safe "$judge") errored on ${count} case(s); first error: $(log_safe "$first_error")" >&2
  done <<< "$1"
}

score_exit=0
run_score || score_exit=$?
# One retry when a judge errored and nothing else has already decided the
# result: a transient API failure that outlived the SDK's own retries often
# clears on a second pass; a deterministic error (such as a prompt over the
# model's input limit) fails the same way twice.
if [[ $score_exit -ne 0 && ${#case_failures[@]} -eq 0 && -n "$(errored_judges)" ]]; then
  echo "Judge call(s) errored ($(errored_judges | paste -sd, -)); retrying scoring once" >&2
  score_exit=0
  run_score || score_exit=$?
fi

errored="$(errored_judges)"
# Report judge errors even when no threshold failed (e.g. the release tier,
# which drops the *_quality thresholds), so an unscored judge is never silent.
print_judge_errors "$errored"

score_verdict="pass"
if [[ $score_exit -ne 0 ]]; then
  if ! grep -qE 'REGRESSIONS: [0-9]+ detected' "$SCORE_LOG"; then
    # score.py failed without a regression list: a crash or a config error,
    # e.g. a broken eval.yaml in the change under test.
    score_verdict="crash"
  elif [[ -n "$errored" && -z "$(unexplained_regressions "$errored")" ]]; then
    score_verdict="judge-infra"
  else
    score_verdict="regression"
  fi
fi

# RESULT lines also go out as an Actions error annotation, so the class of
# failure shows on the check without opening the log.
result() {
  local msg
  msg="$(log_safe "$1")"
  echo "=== RESULT: ${msg} ===" >&2
  [[ "${GITHUB_ACTIONS:-}" == "true" ]] && echo "::error::${msg}"
  return 0
}

echo ""
if [[ ${#case_failures[@]} -gt 0 && ${#case_failures[@]} -eq ${#setup_failures[@]} ]]; then
  result "${#case_failures[@]} case(s) failed before the agent ran (setup or infrastructure, not an agent result)"
  exit 3
fi
if [[ ${#case_failures[@]} -gt 0 ]]; then
  result "${#case_failures[@]} case(s) failed"
  exit 1
fi
if [[ $exec_exit -ne 0 ]]; then
  result "execute.py exited ${exec_exit}"
  exit 1
fi
case "$score_verdict" in
  judge-infra)
    result "judge infrastructure error (not a quality regression)"
    exit 3
    ;;
  crash)
    result "score.py failed (exit ${score_exit}) without a regression list"
    exit 1
    ;;
  regression)
    result "quality regression (score.py exited ${score_exit})"
    exit 1
    ;;
esac
echo "=== RESULT: All phases complete ==="
