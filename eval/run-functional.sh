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
cleanup_runtime_config() {
  # Trailing `true` is load-bearing: an EXIT trap's own exit status
  # replaces an already-issued `exit N` when the trap's last command is
  # false, and the `[[ -n ... ]] &&` guards below are false whenever that
  # path was never created — without `true` a successful run would be
  # reported to the caller as exit 1.
  [[ -n "$EVAL_YAML" ]] && rm -f "$EVAL_YAML"
  [[ -n "$RELEASE_STAGE_DIR" ]] && rm -rf "$RELEASE_STAGE_DIR"
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
EVAL_YAML="$(mktemp "${EVAL_DIR}/${AGENT}/eval-runtime-XXXXXX.yaml")"

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
# Phase 1: Create workspaces
# ---------------------------------------------------------------------------
echo "=== Creating workspaces ==="
python3 "$WORKSPACE_PY" \
  --config "$EVAL_YAML" \
  --run-id "$RUN_ID"

# ---------------------------------------------------------------------------
# Phase 2: Execute — harness drives case iteration with hooks
# ---------------------------------------------------------------------------
echo ""
echo "=== Executing ==="
exec_exit=0
AGENT_EVAL_RUNS_DIR="$RUNS_BASE" \
  python3 "$EXECUTE_PY" \
    --workspace "/tmp/agent-eval/${RUN_ID}" \
    --skill "$AGENT" \
    --config "$EVAL_YAML" \
    --output "$RUN_DIR" \
    --run-id "$RUN_ID" \
  || exec_exit=$?

if [[ $exec_exit -ne 0 ]]; then
  echo "WARNING: execute.py exited $exec_exit" >&2
  # If no case produced output, this is an infrastructure failure — not an agent failure.
  if [[ ! -d "$RUN_DIR/cases" ]] || [[ -z "$(ls "$RUN_DIR/cases/" 2>/dev/null)" ]]; then
    echo "ERROR: no case output produced — infrastructure failure" >&2
    exit 1
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
if [[ ${#case_failures[@]} -gt 0 ]]; then
  echo "ERROR: ${#case_failures[@]} case(s) failed to run cleanly:" >&2
  printf '  %s\n' "${case_failures[@]}" >&2
fi

# Copy output artifacts from harness workspace to runs directory.
# execute.py copies stdout/stderr/input but not the output/ subdirectory
# that after_each hooks populate (e.g., fixture-state.json).
WORKSPACE_CASES="/tmp/agent-eval/${RUN_ID}/cases"
if [[ -d "$WORKSPACE_CASES" ]]; then
  for ws_case in "$WORKSPACE_CASES"/*/; do
    case_name=$(basename "$ws_case")
    ws_output="$ws_case/output"
    run_output="$RUN_DIR/cases/${case_name}/output"
    if [[ -d "$ws_output" ]]; then
      mkdir -p "$run_output"
      cp -a "$ws_output/." "$run_output/"
    fi
  done
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
score_exit=0
AGENT_EVAL_RUNS_DIR="$RUNS_BASE" \
  python3 "$SCORE_PY" judges \
    --run-id "$RUN_ID" \
    --config "$EVAL_YAML" \
  || score_exit=$?

echo ""
if [[ ${#case_failures[@]} -gt 0 ]]; then
  echo "=== RESULT: ${#case_failures[@]} case(s) failed ===" >&2
  exit 1
fi
if [[ $exec_exit -ne 0 ]]; then
  echo "=== RESULT: execute.py exited ${exec_exit} ===" >&2
  exit 1
fi
if [[ $score_exit -ne 0 ]]; then
  echo "=== RESULT: score.py exited ${score_exit} ===" >&2
  exit 1
fi
echo "=== RESULT: All phases complete ==="
