#!/usr/bin/env bash
# scrub-eval-results-test.sh — Test the minimum-length guard on ::add-mask::.
#
# Verifies that scrub-eval-results.sh skips short mask values (< 4 chars)
# to avoid catastrophic over-redaction, while still masking real secrets.
#
# Run from the repo root:
#   bash eval/scripts/scrub-eval-results-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRUB_SCRIPT="${SCRIPT_DIR}/scrub-eval-results.sh"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

run_test() {
  local test_name="$1"
  local input_content="$2"
  local expected_content="$3"

  local test_dir="${TMPDIR}/${test_name}"
  mkdir -p "${test_dir}"
  printf '%s' "${input_content}" > "${test_dir}/output.log"

  local exit_code=0
  bash "${SCRUB_SCRIPT}" "${test_dir}" > /dev/null 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — scrub script exited with code ${exit_code}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local actual
  actual="$(cat "${test_dir}/output.log")"

  if [[ "${actual}" != "${expected_content}" ]]; then
    echo "FAIL: ${test_name}"
    echo "  expected: $(printf '%s' "${expected_content}" | head -5)"
    echo "  actual:   $(printf '%s' "${actual}" | head -5)"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Short values must NOT be used for global replacement ---

run_test "single-char-not-redacted" \
  "::add-mask::a
The quick brown fox jumps over a lazy dog" \
  "::add-mask::***
The quick brown fox jumps over a lazy dog"

run_test "two-char-not-redacted" \
  "::add-mask::ab
Value ab appears in text ab here" \
  "::add-mask::***
Value ab appears in text ab here"

run_test "three-char-not-redacted" \
  "::add-mask::abc
Token abc is used abc twice" \
  "::add-mask::***
Token abc is used abc twice"

# --- Values at or above threshold MUST be redacted ---

run_test "four-char-redacted" \
  "::add-mask::abcd
Token abcd is a secret" \
  "::add-mask::***
Token *** is a secret"

run_test "long-secret-redacted" \
  "::add-mask::realsecret123
Token is realsecret123 here" \
  "::add-mask::***
Token is *** here"

# --- Existing skip values still work ---

run_test "skip-stars" \
  "::add-mask::***
Normal text here" \
  "::add-mask::***
Normal text here"

run_test "skip-redacted-tag" \
  "::add-mask::[REDACTED]
Normal text with [REDACTED] literal" \
  "::add-mask::***
Normal text with [REDACTED] literal"

run_test "skip-empty-value" \
  "::add-mask::
Normal text here" \
  "::add-mask::
Normal text here"

# --- Mixed: short ignored, long redacted ---

run_test "mixed-short-and-long" \
  "::add-mask::a
::add-mask::realsecret123
The quick brown fox jumps over a lazy dog
Token is realsecret123" \
  "::add-mask::***
::add-mask::***
The quick brown fox jumps over a lazy dog
Token is ***"

# --- Summary ---

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi

echo "All scrub-eval-results tests passed"
