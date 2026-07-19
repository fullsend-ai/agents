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

# The harness has inconsistent path resolution for dataset.path between
# workspace.py (config-dir-relative) and execute.py (cwd-relative). Work
# around this by rewriting dataset.path to an absolute path at runtime.
EVAL_YAML="$(mktemp "${EVAL_DIR}/${AGENT}/eval-runtime-XXXXXX.yaml")"
trap 'rm -f "$EVAL_YAML"' EXIT
yq ".dataset.path = \"${CASES_DIR}\"" "$EVAL_YAML_SRC" > "$EVAL_YAML"
HARNESS_DIR="${AGENT_EVAL_HARNESS_DIR:-${EVAL_DIR}/.agent-eval-harness}"

if [[ ! -f "$EVAL_YAML_SRC" ]]; then
  echo "ERROR: eval config not found: $EVAL_YAML_SRC" >&2
  exit 1
fi

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
FULLSEND_DIR="$(cd "$FULLSEND_DIR" && pwd)"
export FULLSEND_DIR

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUNS_BASE="${EVAL_DIR}/runs"
RUNS_DIR="${RUNS_BASE}/${AGENT}"
RUN_DIR="${RUNS_DIR}/${RUN_ID}"
mkdir -p "$RUN_DIR"

echo "=== Functional Tests: ${AGENT} ==="
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
AGENT_EVAL_RUNS_DIR="$RUNS_BASE" \
  python3 "$SCORE_PY" judges \
    --run-id "$RUN_ID" \
    --config "$EVAL_YAML"

echo ""
echo "=== RESULT: All phases complete ==="
