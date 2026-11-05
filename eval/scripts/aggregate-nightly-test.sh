#!/usr/bin/env bash
# aggregate-nightly-test.sh — Tests for aggregate-nightly.sh, the nightly
# verdict over the last 3 nightly runs.
#
# Run from the repo root:
#   bash eval/scripts/aggregate-nightly-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGGREGATE="${SCRIPT_DIR}/aggregate-nightly.sh"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# A review-like eval.yaml: two behaviour checks with thresholds, one
# without (forbidden_labels), a quality judge and a contract judge.
cat > "${TMPDIR}/eval.yaml" <<'EOF'
thresholds:
  review_quality:
    min_mean: 3.5
    max_error_rate: 0.2
  required_labels:
    min_pass_rate: 1.0
  finding_expectations:
    min_pass_rate: 0.5
  pr_created:
    min_pass_rate: 1.0
EOF

# summary <name> <quality mean|null> <required_labels per case: a b c>
# Writes a summary.yaml with cases 001-a, 002-b, 003-c. Each per-case value
# is true, false, null, or "-" (the case has no entry for the judge).
summary() {
  local name="$1" mean="$2" va="$3" vb="$4" vc="$5"
  local file="${TMPDIR}/${name}.yaml"
  {
    echo "run_id: ${name}"
    echo "judges:"
    echo "  review_quality:"
    echo "    mean: ${mean}"
    echo "    scored_cases: 3"
    echo "  required_labels:"
    echo "    pass_rate: 0.67"
    echo "    scored_cases: 3"
    echo "  forbidden_labels:"
    echo "    pass_rate: 0.0"
    echo "    scored_cases: 3"
    echo "per_case:"
    local c v
    for c in 001-a 002-b 003-c; do
      case "$c" in
        001-a) v="$va" ;;
        002-b) v="$vb" ;;
        003-c) v="$vc" ;;
      esac
      echo "  ${c}:"
      echo "    forbidden_labels:"
      echo "      value: false"
      echo "    review_quality:"
      echo "      value: ${mean}"
      if [[ "$v" != "-" ]]; then
        echo "    required_labels:"
        echo "      value: ${v}"
      fi
    done
  } > "$file"
  echo "$file"
}

OUT=""
RC=0
run_agg() {
  RC=0
  OUT="$(bash "$AGGREGATE" "$@" 2>&1)" || RC=$?
}

# expect <name> <rc> [<grep pattern>...]: RC matches and OUT has each pattern.
expect() {
  local name="$1" want_rc="$2" pattern
  shift 2
  if [[ "$RC" -ne "$want_rc" ]]; then
    fail "${name} (rc=${RC}, want ${want_rc}; output: ${OUT})"
    return
  fi
  for pattern in "$@"; do
    if ! grep -qE -- "$pattern" <<< "$OUT"; then
      fail "${name} (output lacks '${pattern}': ${OUT})"
      return
    fi
  done
  pass "$name"
}

E="${TMPDIR}/eval.yaml"

# --- Behaviour checks ---------------------------------------------------

run_agg "$E" "$(summary r1 4 false true true)" "$(summary r2 4 true true true)" "$(summary r3 4 true true true)"
expect "a case failing a check in 1 of 3 runs passes" 0 \
  '^required_labels \(min_pass_rate 1.0\): runs 0.67 \| 1.00 \| 1.00; nightly pass rate 1.00 over 3 case\(s\) -> PASS$' \
  '^NIGHTLY VERDICT: PASS$'

run_agg "$E" "$(summary r1 4 false true true)" "$(summary r2 4 true true true)" "$(summary r3 4 false true true)"
expect "the same case failing a check in 2 of 3 runs fails" 1 \
  '^required_labels .*nightly pass rate 0.67 over 3 case\(s\), false in 2\+ runs: 001-a -> FAIL$' \
  '^NIGHTLY VERDICT: FAIL$'

run_agg "$E" "$(summary r1 4 false true true)" "$(summary r2 4 true false true)" "$(summary r3 4 true true false)"
expect "different cases each failing once (a flake) passes" 0 \
  '^required_labels .*nightly pass rate 1.00 over 3 case\(s\) -> PASS$' \
  '^NIGHTLY VERDICT: PASS$'

run_agg "$E" "$(summary r1 4 false true true)" "$(summary r2 4 false true true)"
expect "two runs, the same case false in both, fails" 1 \
  '^required_labels .*false in 2\+ runs: 001-a -> FAIL$'

run_agg "$E" "$(summary r1 4 false true true)"
expect "a single run cannot fail a check" 0 \
  '^required_labels \(min_pass_rate 1.0\): runs 0.67; nightly pass rate 1.00 over 3 case\(s\) -> PASS$'

# A run whose cases failed before the agent ran: score.py records
# scored_cases: 0 for the judge. Its false values must not count.
INFRA="$(summary infra 4 false false false)"
yq -i '.judges.required_labels.scored_cases = 0 | .judges.required_labels.pass_rate = null' "$INFRA"
run_agg "$E" "$(summary r1 4 false true true)" "$INFRA" "$(summary r3 4 true true true)"
expect "a run with scored_cases: 0 is ignored" 0 \
  '^required_labels \(min_pass_rate 1.0\): runs 0.67 \| n/a \| 1.00; nightly pass rate 1.00 over 3 case\(s\) -> PASS$'

run_agg "$E" "$(summary r1 4 false true null)" "$(summary r2 4 null true -)" "$(summary r3 4 - true true)"
expect "a null or missing judge value counts as neither pass nor fail" 0 \
  '^required_labels .*nightly pass rate 1.00 over 3 case\(s\) -> PASS$'

run_agg "$E" "$(summary r1 4 false null -)" "$(summary r2 4 false - null)"
expect "a case with no boolean value in any run is left out of the pass rate" 1 \
  '^required_labels .*nightly pass rate 0.00 over 1 case\(s\), false in 2\+ runs: 001-a -> FAIL$'

NO_JUDGE="$(summary nojudge 4 true true true)"
yq -i 'del(.judges.required_labels) | del(.per_case[].required_labels)' "$NO_JUDGE"
run_agg "$E" "$(summary r1 4 false true true)" "$NO_JUDGE" "$(summary r3 4 false true true)"
expect "a judge missing from one run does not hide the other runs' votes" 1 \
  '^required_labels \(min_pass_rate 1.0\): runs 0.67 \| n/a \| 0.67; .*-> FAIL$'

run_agg "$E" "$NO_JUDGE"
expect "a check with no scored cases reports no data and passes" 0 \
  '^required_labels .*no scored cases -> NO DATA$' \
  '^NIGHTLY VERDICT: PASS$'

# forbidden_labels is false for every case in every run, but eval.yaml
# gives it no threshold; pr_created is a contract judge.
run_agg "$E" "$(summary r1 4 true true true)" "$(summary r2 4 true true true)" "$(summary r3 4 true true true)"
expect "a judge with no threshold in eval.yaml is ignored" 0 '^NIGHTLY VERDICT: PASS$'
if grep -qE '^(forbidden_labels|pr_created|max_turns|max_cost) ' <<< "$OUT"; then
  fail "judges without a threshold, contract and budget judges are not reported (output: ${OUT})"
else
  pass "judges without a threshold, contract and budget judges are not reported"
fi

# finding_expectations has a threshold but no data in these summaries.
expect "a behaviour check absent from every summary reports no data" 0 \
  '^finding_expectations \(min_pass_rate 0.5\): runs n/a \| n/a \| n/a; no scored cases -> NO DATA$'

# --- Quality judges -----------------------------------------------------

run_agg "$E" "$(summary r1 3 true true true)" "$(summary r2 4 true true true)" "$(summary r3 5 true true true)"
expect "quality means [3, 4, 5] against min_mean 3.5 pass (median 4)" 0 \
  '^review_quality \(min_mean 3.5\): runs 3.00 \| 4.00 \| 5.00; median 4.00 -> PASS$'

run_agg "$E" "$(summary r1 5 true true true)" "$(summary r2 2 true true true)" "$(summary r3 2 true true true)"
expect "quality means [2, 2, 5] against min_mean 3.5 fail (median 2)" 1 \
  '^review_quality \(min_mean 3.5\): runs 5.00 \| 2.00 \| 2.00; median 2.00 -> FAIL$' \
  '^NIGHTLY VERDICT: FAIL$'

run_agg "$E" "$(summary r1 1 true true true)" "$(summary r2 1 true true true)"
expect "fewer than 3 quality samples do not fail" 0 \
  '^review_quality .*insufficient history \(2 of 3 means\) -> INSUFFICIENT HISTORY$' \
  '^NIGHTLY VERDICT: PASS$'

UNSCORED="$(summary unscored 1 true true true)"
yq -i '.judges.review_quality.scored_cases = 0' "$UNSCORED"
run_agg "$E" "$(summary r1 1 true true true)" "$(summary r2 null true true true)" "$UNSCORED"
expect "a null mean or scored_cases: 0 leaves fewer than 3 quality samples" 0 \
  '^review_quality \(min_mean 3.5\): runs 1.00 \| n/a \| n/a; insufficient history \(1 of 3 means\) -> INSUFFICIENT HISTORY$'

# --- Cases that failed before the agent ran ----------------------------
# On an infrastructure night most cases never reach the agent and their
# judges score false or 1. The run_result.json beside summary.yaml says
# which: a non-zero exit that is not a timeout, with no turns, cost or
# tokens. Those cases are no data; a timed-out case reached the agent.

# not_reached_run <name> <exit code for 002-b> <exit code for 003-c>
# Writes <name>/summary.yaml (001-a passes; 002-b and 003-c fail
# required_labels and score 1 on quality) and <name>/run_result.json
# where 002-b and 003-c have no turns, cost or tokens.
not_reached_run() {
  local name="$1" eb="$2" ec="$3" dir="${TMPDIR}/$1"
  mkdir -p "$dir"
  cat > "${dir}/summary.yaml" <<'EOF'
judges:
  review_quality:
    mean: 2.33
    scored_cases: 3
  required_labels:
    pass_rate: 0.33
    scored_cases: 3
per_case:
  001-a:
    required_labels:
      value: true
    review_quality:
      value: 5
  002-b:
    required_labels:
      value: false
    review_quality:
      value: 1
  003-c:
    required_labels:
      value: false
    review_quality:
      value: 1
EOF
  cat > "${dir}/run_result.json" <<EOF
{"exit_code": 1, "per_case": {
  "001-a": {"exit_code": 0, "num_turns": 9, "cost_usd": 0.2, "token_usage": {"input": 10, "output": 400}},
  "002-b": {"exit_code": ${eb}, "num_turns": null, "cost_usd": null, "token_usage": null},
  "003-c": {"exit_code": ${ec}, "num_turns": 0, "cost_usd": 0, "token_usage": {}}
}}
EOF
  echo "${dir}/summary.yaml"
}

run_agg "$E" "$(summary r1 4 true false true)" "$(not_reached_run infra 1 1)" "$(summary r3 4 true true true)"
expect "a case that failed before the agent ran is no data" 0 \
  '^required_labels \(min_pass_rate 1.0\): runs 0.67 \| 1.00 \| 1.00; nightly pass rate 1.00 over 3 case\(s\) -> PASS$' \
  '^review_quality \(min_mean 3.5\): runs 4.00 \| 5.00 \| 4.00; median 4.00 -> PASS$' \
  '^NIGHTLY VERDICT: PASS$'

run_agg "$E" "$(summary r1 4 true false true)" "$(not_reached_run timeouts 124 -1)" "$(summary r3 4 true true true)"
expect "a timed-out case reached the agent and still counts" 1 \
  '^required_labels \(min_pass_rate 1.0\): runs 0.67 \| 0.33 \| 1.00; nightly pass rate 0.67 over 3 case\(s\), false in 2\+ runs: 002-b -> FAIL$' \
  '^NIGHTLY VERDICT: FAIL$'

# --- Step summary -------------------------------------------------------

STEP_SUMMARY="${TMPDIR}/step-summary.md"
RC=0
OUT="$(GITHUB_STEP_SUMMARY="$STEP_SUMMARY" bash "$AGGREGATE" "$E" \
  "$(summary r1 3 false true true)" "$(summary r2 4 false true true)" "$(summary r3 5 true true true)" 2>&1)" || RC=$?
SUMMARY_TEXT="$(cat "$STEP_SUMMARY" 2>/dev/null || true)"
if [[ "$RC" -eq 1 ]] \
  && grep -qF '| Judge | Threshold | Run 1 (newest) | Run 2 | Run 3 | Nightly | Verdict |' <<< "$SUMMARY_TEXT" \
  && grep -qF '| `required_labels` | min_pass_rate 1.0 | 0.67 | 0.67 | 1.00 | 0.67 | FAIL |' <<< "$SUMMARY_TEXT" \
  && grep -qF '| `review_quality` | min_mean 3.5 | 3.00 | 4.00 | 5.00 | 4.00 | PASS |' <<< "$SUMMARY_TEXT" \
  && grep -qF '**NIGHTLY VERDICT: FAIL**' <<< "$SUMMARY_TEXT"; then
  pass "GITHUB_STEP_SUMMARY gets a Markdown table"
else
  fail "GITHUB_STEP_SUMMARY gets a Markdown table (rc=${RC}, summary: ${SUMMARY_TEXT})"
fi

# --- Usage and input errors ---------------------------------------------

S1="$(summary r1 4 true true true)"

run_agg
expect "no arguments exit 2" 2 'Usage:'

run_agg "$E"
expect "no summaries exit 2" 2 'Usage:'

run_agg "$E" "$S1" "$S1" "$S1" "$S1"
expect "more than 3 summaries exit 2" 2 'Usage:'

run_agg "$E" "$S1" "${TMPDIR}/does-not-exist.yaml"
expect "a missing summary exits 2" 2 'file not found: .*does-not-exist.yaml'

run_agg "${TMPDIR}/no-eval.yaml" "$S1"
expect "a missing eval.yaml exits 2" 2 'file not found: .*no-eval.yaml'

printf 'judges: [\n' > "${TMPDIR}/broken.yaml"
run_agg "$E" "$S1" "${TMPDIR}/broken.yaml"
expect "a summary that is not valid YAML exits 2" 2 'not a valid YAML mapping: .*broken.yaml'

printf 'per_case: 7\n' > "${TMPDIR}/bad-shape.yaml"
run_agg "$E" "$S1" "${TMPDIR}/bad-shape.yaml"
expect "a summary whose per_case is not a mapping exits 2" 2 'not a summary \(needs judges and per_case mappings\): .*bad-shape.yaml'

cat > "${TMPDIR}/bad-threshold.yaml" <<'EOF'
thresholds:
  required_labels:
    min_pass_rate: "high"
  review_quality:
    min_mean: 3.5
EOF
run_agg "${TMPDIR}/bad-threshold.yaml" "$S1"
expect "a non-numeric threshold exits 2" 2 'threshold is not a number in range in .*bad-threshold.yaml: required_labels.min_pass_rate = high'

printf 'thresholds:\n  required_labels:\n    min_pass_rate: 1.5\n' > "${TMPDIR}/out-of-range.yaml"
run_agg "${TMPDIR}/out-of-range.yaml" "$S1"
expect "a min_pass_rate above 1 exits 2" 2 'required_labels.min_pass_rate = 1.5'

printf '{}\n' > "${TMPDIR}/empty.yaml"
run_agg "$E" "${TMPDIR}/empty.yaml"
expect "an empty summary exits 2" 2 'not a summary \(needs judges and per_case mappings\): .*empty.yaml'

echo ""
if [[ $FAILURES -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
