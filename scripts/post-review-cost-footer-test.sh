#!/usr/bin/env bash
# post-review-cost-footer-test.sh — Test the cost-footer jq program in
# post-review.sh.
#
# The program is extracted from the shipped script rather than duplicated
# here, so the test can never drift from what actually runs (same approach
# as eval/scripts/removed-symbols-judge-test.py).
#
# What matters: the footer is assembled from an optional set of fields. An
# older runner writes metrics.json without duration_seconds or over_budget,
# so every element has to be independently omittable without leaving a
# stray separator or the string "null" in a comment posted to a PR.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST_REVIEW="${SCRIPT_DIR}/post-review.sh"

# Extract the jq program: everything between the COST_FOOTER assignment and
# its closing quote. Fail loudly if the anchors move, rather than silently
# testing an empty program.
JQ_PROGRAM=$(awk '
  /COST_FOOTER=\$\(jq -r .$/ { capture = 1; next }
  capture && /^  '"'"' "\$\{METRICS_FILE\}"/ { capture = 0 }
  capture { print }
' "${POST_REVIEW}")

if [ -z "${JQ_PROGRAM}" ]; then
  echo "FAIL: could not extract the cost-footer jq program from ${POST_REVIEW}" >&2
  echo "      (the anchors in this test no longer match the script)" >&2
  exit 1
fi

FAILURES=0

run_test() {
  test_name="$1"
  metrics="$2"
  expected="$3"

  actual=$(printf '%s' "${metrics}" | jq -r "${JQ_PROGRAM}" 2>/dev/null) || actual="<jq-error>"

  if [ "${actual}" = "${expected}" ]; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name}"
    echo "      expected: '${expected}'"
    echo "      actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
  fi
}

# A current runner: every field present.
run_test "full-metrics" \
  '{"total_cost_usd":2.9187,"duration_seconds":679,"model":"claude-opus-4-6"}' \
  '$2.9187 · 11m 19s · claude-opus-4-6'

# The budget cap fired: reviewers must be told the review may be truncated.
run_test "over-budget-is-disclosed" \
  '{"total_cost_usd":4.5,"duration_seconds":65,"model":"claude-opus-4-6","over_budget":true}' \
  '$4.5 · 1m 5s · claude-opus-4-6 · halted at cost cap, review may be incomplete'

run_test "within-budget-omits-cap-notice" \
  '{"total_cost_usd":0.5,"duration_seconds":30,"model":"claude-opus-4-6","over_budget":false}' \
  '$0.5 · 30s · claude-opus-4-6'

# An older runner predates duration_seconds/over_budget — the footer keeps
# the fields it has instead of printing "null" into a PR comment.
run_test "old-runner-omits-missing-fields" \
  '{"total_cost_usd":1.5,"model":"claude-opus-4-6","num_turns":12}' \
  '$1.5 · claude-opus-4-6'

run_test "sub-minute-duration" \
  '{"total_cost_usd":0.17,"duration_seconds":42,"model":"claude-sonnet-4-6"}' \
  '$0.17 · 42s · claude-sonnet-4-6'

run_test "exactly-one-minute" \
  '{"total_cost_usd":0.2,"duration_seconds":60,"model":"m"}' \
  '$0.2 · 1m 0s · m'

# Degenerate metrics produce an empty string, which the caller treats as
# "no footer" — better than posting a bare "$0" under every review.
run_test "empty-metrics-yields-no-footer" '{}' ''

run_test "zero-cost-omits-cost" \
  '{"total_cost_usd":0,"model":"claude-opus-4-6"}' \
  'claude-opus-4-6'

# A truthy-but-not-true over_budget must not claim the cap fired, and an
# empty model must not leave a dangling separator.
run_test "over-budget-zero-is-not-true" \
  '{"total_cost_usd":1.0,"model":"m","over_budget":0}' \
  '$1 · m'

run_test "empty-model-omitted" \
  '{"total_cost_usd":1.0,"model":""}' \
  '$1'

run_test "zero-duration-omits-duration" \
  '{"total_cost_usd":1.0,"duration_seconds":0,"model":"m"}' \
  '$1 · m'

# Cost is rounded to 4 decimal places, not truncated.
run_test "cost-rounds-to-four-places" \
  '{"total_cost_usd":1.23456789,"model":"m"}' \
  '$1.2346 · m'

echo
if [ "${FAILURES}" -eq 0 ]; then
  echo "All cost-footer tests passed"
else
  echo "${FAILURES} test(s) failed"
  exit 1
fi
