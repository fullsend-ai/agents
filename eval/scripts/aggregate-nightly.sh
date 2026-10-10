#!/usr/bin/env bash
# Combine the last 1 to 3 nightly full-tier runs of one agent into a single
# nightly verdict for the report-only judges.
#
# Usage:
#   eval/scripts/aggregate-nightly.sh <eval.yaml> <summary.yaml> [<summary.yaml> ...]
#
# <eval.yaml> is the agent's checked-in eval config (its thresholds are the
# ones run-functional.sh drops at runtime). Each <summary.yaml> is a run's
# score.py summary, newest first, 1 to 3 of them.
#
# Behaviour checks (finding_expectations, required_labels, forbidden_labels,
# risk_label_present, expected_files) with a min_pass_rate: a case fails the
# check when its per_case value is false in at least 2 of the given runs.
# The nightly pass rate is the share of cases (scored in at least one run)
# that do not fail; below min_pass_rate is a FAIL.
#
# Quality judges (name ends in _quality) with a min_mean: FAIL when 3
# non-null means are given and their median is below min_mean. With fewer,
# the judge reports "insufficient history" and does not fail.
#
# Missing data counts as neither pass nor fail: a case or judge absent from
# a run, a null value, or a judge with scored_cases: 0. A case that failed
# before the agent ran (its max_cost or max_turns rationale is "metrics.json
# not found", as on an infrastructure night) is skipped for every judge, so
# per-run pass rates and means are computed from per_case over the cases
# that reached the agent. Budget judges and the contract judges are not
# aggregated.
#
# Prints one line per judge and a final "NIGHTLY VERDICT: PASS|FAIL" line.
# When GITHUB_STEP_SUMMARY is set, also appends a Markdown table to it.
#
# Exit status:
#   0 — PASS
#   1 — FAIL
#   2 — usage or input error (no summaries, more than 3, or a file that is
#       missing, not a valid YAML mapping, or not shaped like its kind)
set -euo pipefail

usage() {
  echo "Usage: $0 <eval.yaml> <summary.yaml> [<summary.yaml> [<summary.yaml>]]" >&2
  echo "       summaries newest first, 1 to 3 of them" >&2
  exit 2
}

input_error() {
  echo "ERROR: $1" >&2
  exit 2
}

[[ $# -ge 2 && $# -le 4 ]] || usage
EVAL_YAML="$1"
shift
SUMMARIES=("$@")

command -v yq >/dev/null 2>&1 || input_error "yq is required"
for f in "$EVAL_YAML" "${SUMMARIES[@]}"; do
  [[ -f "$f" ]] || input_error "file not found: $f"
  yq -e 'tag == "!!map"' "$f" >/dev/null 2>&1 || input_error "not a valid YAML mapping: $f"
done

# q <expr> <file>: yq -r, exiting 2 on a read error. Only call it as a plain
# assignment (x="$(q ...)"): set -e then ends the script with its status,
# where a failure inside a process substitution or a command's argument
# would go unnoticed.
q() {
  yq -r "$1" "$2" || input_error "could not read $2"
}

# fmt <value>: a number to two decimals, anything else unchanged.
fmt() {
  awk -v v="$1" 'BEGIN { if (v ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) printf "%.2f", v; else printf "%s", v }'
}

# lt <a> <b>: true when a < b.
lt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'
}

# REACHED: yq prefix selecting the per_case entries whose case reached the
# agent (no "metrics.json not found" budget-judge rationale).
REACHED='.per_case // {} | to_entries[]
  | select([.value.max_cost.rationale, .value.max_turns.rationale]
    | any_c(. != null and (tostring | test("^metrics\\.json not found"))) | not)'

BEHAVIOUR_CHECKS=(finding_expectations required_labels forbidden_labels risk_label_present expected_files)

overall="PASS"
lines=()
table_rows=()

# add_result <judge> <threshold> <nightly> <detail> <verdict> <run value>...
add_result() {
  local judge="$1" threshold="$2" nightly="$3" detail="$4" verdict="$5"
  shift 5
  local runs
  runs="$(printf '%s | ' "$@")"
  lines+=("${judge} (${threshold}): runs ${runs% | }; ${detail} -> ${verdict}")
  table_rows+=("| \`${judge}\` | ${threshold} | ${runs}${nightly} | ${verdict} |")
  if [[ "$verdict" == "FAIL" ]]; then
    overall="FAIL"
  fi
}

for check in "${BEHAVIOUR_CHECKS[@]}"; do
  export J="$check"
  min="$(q '.thresholds[strenv(J)].min_pass_rate // ""' "$EVAL_YAML")"
  [[ -n "$min" ]] || continue

  declare -A false_votes=() scored=()
  run_values=()
  for s in "${SUMMARIES[@]}"; do
    scored_cases="$(q '.judges[strenv(J)].scored_cases // ""' "$s")"
    if [[ "$scored_cases" == "0" ]]; then
      run_values+=("n/a")
      continue
    fi
    # "<true|false> <case>" for each case that reached the agent and whose
    # value is a boolean.
    votes="$(q "${REACHED}"'
      | select((.value[strenv(J)].value | tag) == "!!bool")
      | (.value[strenv(J)].value | tostring) + " " + .key' "$s")"
    run_true=0
    run_total=0
    while read -r value case_name; do
      [[ -n "$case_name" ]] || continue
      scored[$case_name]=1
      run_total=$(( run_total + 1 ))
      if [[ "$value" == "false" ]]; then
        false_votes[$case_name]=$(( ${false_votes[$case_name]:-0} + 1 ))
      else
        run_true=$(( run_true + 1 ))
      fi
    done <<< "$votes"
    if [[ $run_total -eq 0 ]]; then
      run_values+=("n/a")
    else
      run_values+=("$(fmt "$(awk -v t="$run_true" -v n="$run_total" 'BEGIN { print t / n }')")")
    fi
  done

  total=${#scored[@]}
  failing=()
  for case_name in "${!false_votes[@]}"; do
    if [[ ${false_votes[$case_name]} -ge 2 ]]; then
      failing+=("$case_name")
    fi
  done
  unset false_votes scored

  if [[ $total -eq 0 ]]; then
    add_result "$check" "min_pass_rate ${min}" "n/a" "no scored cases" "NO DATA" "${run_values[@]}"
    continue
  fi
  nightly="$(awk -v p=$(( total - ${#failing[@]} )) -v n="$total" 'BEGIN { print p / n }')"
  verdict="PASS"
  if lt "$nightly" "$min"; then
    verdict="FAIL"
  fi
  detail="nightly pass rate $(fmt "$nightly") over ${total} case(s)"
  if [[ ${#failing[@]} -gt 0 ]]; then
    detail+=", false in 2+ runs: $(printf '%s\n' "${failing[@]}" | sort | paste -sd, -)"
  fi
  add_result "$check" "min_pass_rate ${min}" "$(fmt "$nightly")" "$detail" "$verdict" "${run_values[@]}"
done

quality_judges="$(q '.thresholds // {} | to_entries[]
  | select((.key | test("_quality$")) and .value.min_mean != null) | .key' "$EVAL_YAML")"

while read -r judge; do
  [[ -n "$judge" ]] || continue
  export J="$judge"
  min="$(q '.thresholds[strenv(J)].min_mean' "$EVAL_YAML")"
  run_values=()
  means=()
  for s in "${SUMMARIES[@]}"; do
    scored_cases="$(q '.judges[strenv(J)].scored_cases // ""' "$s")"
    mean=""
    if [[ "$scored_cases" != "0" ]]; then
      # Mean over the cases that reached the agent, from per_case.
      values="$(q "${REACHED}"'
        | .value[strenv(J)].value | select(tag == "!!int" or tag == "!!float")' "$s")"
      mean="$(awk 'NF { sum += $1; n++ } END { if (n) print sum / n }' <<< "$values")"
    fi
    if [[ -n "$mean" ]]; then
      means+=("$mean")
      run_values+=("$(fmt "$mean")")
    else
      run_values+=("n/a")
    fi
  done

  if [[ ${#means[@]} -lt 3 ]]; then
    add_result "$judge" "min_mean ${min}" "n/a" "insufficient history (${#means[@]} of 3 means)" \
      "INSUFFICIENT HISTORY" "${run_values[@]}"
    continue
  fi
  median="$(printf '%s\n' "${means[@]}" | sort -g | sed -n 2p)"
  verdict="PASS"
  if lt "$median" "$min"; then
    verdict="FAIL"
  fi
  add_result "$judge" "min_mean ${min}" "$(fmt "$median")" "median $(fmt "$median")" "$verdict" "${run_values[@]}"
done <<< "$quality_judges"

if [[ ${#lines[@]} -eq 0 ]]; then
  echo "No behaviour check or quality judge with a threshold in ${EVAL_YAML}"
else
  printf '%s\n' "${lines[@]}"
fi
echo "NIGHTLY VERDICT: ${overall}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Nightly verdict: \`${EVAL_YAML}\`"
    echo ""
    if [[ ${#table_rows[@]} -gt 0 ]]; then
      header="| Judge | Threshold | Run 1 (newest) |"
      rule="|---|---|---|"
      for (( i = 2; i <= ${#SUMMARIES[@]}; i++ )); do
        header+=" Run ${i} |"
        rule+="---|"
      done
      echo "${header} Nightly | Verdict |"
      echo "${rule}---|---|"
      printf '%s\n' "${table_rows[@]}"
      echo ""
    fi
    echo "**NIGHTLY VERDICT: ${overall}**"
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
fi

[[ "$overall" == "PASS" ]]
