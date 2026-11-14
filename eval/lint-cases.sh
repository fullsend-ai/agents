#!/usr/bin/env bash
# Lint eval case definitions — verifies every case has required fields.
#
# Usage:
#   ./eval/lint-cases.sh <agent-name>
#   ./eval/lint-cases.sh triage
#
# Checks:
#   - Every case directory has annotations.yaml
#   - eval.yaml declares a max_cost judge, and every annotations.yaml
#     declares max_cost_usd
#   - If eval.yaml declares a max_turns judge, every annotations.yaml
#     declares max_turns (review has none: its num_turns does not track work)
set -euo pipefail

AGENT="${1:?agent name required}"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
CASES_DIR="${EVAL_DIR}/${AGENT}/cases"
EVAL_YAML="${EVAL_DIR}/${AGENT}/eval.yaml"

if [[ ! -d "$CASES_DIR" ]]; then
  echo "ERROR: cases directory not found: $CASES_DIR" >&2
  exit 1
fi

ERRORS=0

# Check that eval.yaml has the required behavioral judges
if [[ ! -f "$EVAL_YAML" ]]; then
  echo "FAIL: eval.yaml not found: $EVAL_YAML"
  ERRORS=$((ERRORS + 1))
else
  if ! yq -e '.judges[] | select(.name == "max_cost")' "$EVAL_YAML" >/dev/null 2>&1; then
    echo "FAIL: eval.yaml missing required judge: max_cost"
    ERRORS=$((ERRORS + 1))
  fi
fi
has_max_turns=false
if [[ -f "$EVAL_YAML" ]] && yq -e '.judges[] | select(.name == "max_turns")' "$EVAL_YAML" >/dev/null 2>&1; then
  has_max_turns=true
fi

# Check that every case has annotations with thresholds
for case_dir in "$CASES_DIR"/*/; do
  case_name=$(basename "$case_dir")
  annotations="$case_dir/annotations.yaml"
  if [[ ! -f "$annotations" ]]; then
    echo "FAIL: ${case_name}: annotations.yaml not found"
    ERRORS=$((ERRORS + 1))
    continue
  fi
  max_turns=$(yq -r '.max_turns // ""' "$annotations")
  max_cost=$(yq -r '.max_cost_usd // ""' "$annotations")
  if [[ -z "$max_cost" ]]; then
    echo "FAIL: ${case_name}: annotations.yaml missing max_cost_usd"
    ERRORS=$((ERRORS + 1))
  fi
  if [[ "$has_max_turns" == true && -z "$max_turns" ]]; then
    echo "FAIL: ${case_name}: annotations.yaml missing max_turns (eval.yaml has a max_turns judge)"
    ERRORS=$((ERRORS + 1))
  fi
done

if [[ $ERRORS -gt 0 ]]; then
  echo "ERROR: $ERRORS case lint failures" >&2
  exit 1
fi

echo "OK: all cases pass lint checks"
