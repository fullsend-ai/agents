#!/usr/bin/env bash
# select-eval-agents.sh — Given changed files on stdin, output agent names
# whose functional tests should run.
#
# Usage:
#   echo "env/gcp-vertex.env" | ./select-eval-agents.sh [--repo-root <path>]
#
# Logic:
#   For each harness/*.yaml that has a corresponding eval/<agent>/eval.yaml,
#   extract all file paths referenced in the harness config. If any changed
#   file matches a referenced path (or is under a referenced directory like
#   skills/ or plugins/), or if the harness file itself changed (or its
#   eval-only overlay, eval/harness/<agent>.yaml), or if a file under
#   eval/<agent>/ changed, output that agent name.
#
#   Files every eval depends on select every agent with an eval config: the
#   eval workspace config (config.yaml, which pins the eval models), the
#   eval runner (eval/run-functional.sh, eval/scripts/) and the harness
#   submodule (eval/.agent-eval-harness).
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
      (.providers[]?),
      (.openshell?.profiles[]?),
      (.forge[]? | (.pre_script, .post_script, .policy, (.skills[]?), (.host_files[]?.src), (.providers[]?), (.openshell?.profiles[]?))),
      (.overlays[]? | (.pre_script, .post_script, .policy, (.skills[]?), (.host_files[]?.src), (.providers[]?), (.openshell?.profiles[]?)))
    ] | .[] | select(. != null)
  ' "$harness_file" | { grep -v '\$' || true; } | sort -u
}

# A change to a file every eval depends on selects every agent.
select_all=false
for changed in "${CHANGED_FILES[@]}"; do
  case "$changed" in
    # A script's own test file does not change what any eval runs.
    eval/scripts/*-test.sh) ;;
    config.yaml|eval/run-functional.sh|eval/scripts/*|eval/.agent-eval-harness|eval/.agent-eval-harness/*)
      select_all=true
      break
      ;;
  esac
done

# For each harness file with an eval config, check if any changed file is relevant.
for harness_file in "$REPO_ROOT"/harness/*.yaml; do
  [[ -f "$harness_file" ]] || continue
  agent="$(basename "$harness_file" .yaml)"

  # Validate agent name — defense against injection via malicious filenames
  if [[ ! "$agent" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "::error::Invalid agent name: $agent" >&2
    exit 1
  fi

  # Only consider agents that have eval configs
  [[ -f "$REPO_ROOT/eval/$agent/eval.yaml" ]] || continue

  # Collect all paths this agent cares about
  if ! refs_output=$(extract_refs "$harness_file"); then
    echo "::error::Failed to parse $harness_file" >&2
    exit 1
  fi
  if [[ -n "$refs_output" ]]; then
    mapfile -t REFS <<< "$refs_output"
  else
    REFS=()
  fi

  selected="$select_all"
  for changed in "${CHANGED_FILES[@]}"; do
    [[ "$selected" == true ]] && break
    # Direct harness file change, or its eval-only overlay
    if [[ "$changed" == "harness/${agent}.yaml" || "$changed" == "eval/harness/${agent}.yaml" ]]; then
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
