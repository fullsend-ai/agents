#!/usr/bin/env bash
# select-eval-agents.sh — Given changed files on stdin, output agent names
# whose functional tests should run.
#
# Usage:
#   echo "env/triage.env" | ./select-eval-agents.sh [--repo-root <path>]
#
# Logic:
#   For each harness/*.yaml that has a corresponding eval/<agent>/eval.yaml,
#   extract all file paths referenced in the harness config. If any changed
#   file matches a referenced path (or is under a referenced directory like
#   skills/ or plugins/), or if the harness file itself changed, or if a
#   file under eval/<agent>/ changed, output that agent name.
set -euo pipefail

REPO_ROOT="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Read changed files from stdin into an array
mapfile -t CHANGED_FILES

if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
  exit 0
fi

# Extract all file-path references from a harness YAML.
# Skips variable references (${...}) and null values.
extract_refs() {
  local harness_file="$1"
  yq -r '
    [
      .agent, .doc, .policy, .pre_script, .post_script,
      .validation_loop.script, .validation_loop.schema,
      (.host_files[]?.src),
      (.skills[]?),
      (.plugins[]?),
      .forge.github.pre_script, .forge.github.post_script
    ] | .[] | select(. != null)
  ' "$harness_file" 2>/dev/null | grep -v '^\$' | sort -u
}

# For each harness file with an eval config, check if any changed file is relevant.
for harness_file in "$REPO_ROOT"/harness/*.yaml; do
  [[ -f "$harness_file" ]] || continue
  agent="$(basename "$harness_file" .yaml)"

  # Only consider agents that have eval configs
  [[ -f "$REPO_ROOT/eval/$agent/eval.yaml" ]] || continue

  # Collect all paths this agent cares about
  mapfile -t REFS < <(extract_refs "$harness_file")

  selected=false
  for changed in "${CHANGED_FILES[@]}"; do
    # Direct harness file change
    if [[ "$changed" == "harness/${agent}.yaml" ]]; then
      selected=true
      break
    fi

    # File under eval/<agent>/
    if [[ "$changed" == eval/"$agent"/* ]]; then
      selected=true
      break
    fi

    # Check against referenced paths
    for ref in "${REFS[@]}"; do
      # Exact match
      if [[ "$changed" == "$ref" ]]; then
        selected=true
        break 2
      fi
      # Prefix match for directories (skills/, plugins/)
      if [[ "$changed" == "$ref"/* ]]; then
        selected=true
        break 2
      fi
    done
  done

  if [[ "$selected" == true ]]; then
    echo "$agent"
  fi
done
