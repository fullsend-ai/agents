#!/usr/bin/env bash
# scrub-eval-results-test.sh — Test the minimum-length guard on ::add-mask::.
#
# Verifies that scrub-eval-results.sh skips short mask values (< 4 chars)
# to avoid catastrophic over-redaction, while still masking real secrets,
# and that it redacts a retried case's preserved first-attempt files.
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
  local filename="${4:-output.log}"

  local test_dir="${TMPDIR}/${test_name}"
  mkdir -p "${test_dir}"
  printf '%s' "${input_content}" > "${test_dir}/${filename}"

  local exit_code=0
  bash "${SCRUB_SCRIPT}" "${test_dir}" > /dev/null 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — scrub script exited with code ${exit_code}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local actual
  actual="$(cat "${test_dir}/${filename}")"

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

# --- Captured PR diffs (.diff) are scrubbed like any text artifact ---

run_test "diff-file-token-redacted" \
  "diff --git a/config b/config
+url = https://x-access-token:ghs_abcdefghijklmnopqrstuv@github.com/o/r" \
  "diff --git a/config b/config
+url = https://x-access-token:***@github.com/o/r" \
  "pr-1.diff"

# --- Every attempt of a retried case is scrubbed ---

# run-functional.sh keeps each attempt of a run in
# <run-dir>/attempts/<n>/cases/<case>; scrubbing eval/runs must reach all of
# them, not only the final one.
# The token is assembled at runtime so no token-shaped literal is committed.
printf -v token_pad '%036d' 0
attempts_root="${TMPDIR}/attempts/eval/runs"
attempts_dir="${attempts_root}/testagent/20260101-000000-1/attempts"
for n in 1 2; do
  mkdir -p "${attempts_dir}/${n}/cases/001-case"
  printf 'clone with ghp_%s\n' "${token_pad}" > "${attempts_dir}/${n}/cases/001-case/stdout.log"
done
exit_code=0
bash "${SCRUB_SCRIPT}" "${attempts_root}" > /dev/null 2>&1 || exit_code=$?
for n in 1 2; do
  actual="$(cat "${attempts_dir}/${n}/cases/001-case/stdout.log")"
  if [[ ${exit_code} -eq 0 && "${actual}" == "clone with ghp_***" ]]; then
    echo "PASS: attempt-${n}-redacted"
  else
    echo "FAIL: attempt-${n}-redacted (exit ${exit_code})"
    FAILURES=$((FAILURES + 1))
  fi
done

# --- Summary ---

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi

echo "All scrub-eval-results tests passed"
