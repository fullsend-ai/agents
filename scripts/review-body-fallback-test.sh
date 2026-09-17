#!/usr/bin/env bash
# review-body-fallback-test.sh — Tests the GitHub fix-review fallback trigger.
#
# The condition lives in skills/fix-review/github/SKILL.md (the recipe the
# fix agent runs). This test extracts that `if` condition and evaluates it
# against fixtures, including the pointer-only body from PR #1296.
#
# Run from the repo root:
#   bash scripts/review-body-fallback-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/fix-review/github/SKILL.md"
FIXTURES="${SCRIPT_DIR}/test-fixtures/review-body"

FAILURES=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — $2"; FAILURES=$((FAILURES + 1)); }

# Extract the fallback `if` condition from the skill's bash fence so the
# test tracks the recipe the agent actually runs.
extract_skill_condition() {
  python3 - "${SKILL}" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
blocks = re.findall(r"```bash\n(.*?)```", text, re.DOTALL)
for block in blocks:
    if "REVIEW_BODY_FILE=" in block and "fullsend:review-agent" in block:
        match = re.search(r"if (.+?); then", block, re.DOTALL)
        if not match:
            sys.stderr.write("FAIL: could not find if-condition in fallback bash fence\n")
            sys.exit(2)
        print(match.group(1).strip())
        sys.exit(0)
sys.stderr.write("FAIL: no fallback bash fence found in GitHub overlay\n")
sys.exit(2)
PY
}

CONDITION="$(extract_skill_condition)"

needs_fallback() {
  # Referenced by CONDITION via eval; keep the name the skill uses.
  # shellcheck disable=SC2034
  local REVIEW_BODY_FILE="$1"
  if eval "${CONDITION}"; then
    return 0
  fi
  return 1
}

expect_fallback() {
  local name="$1"
  local file="$2"
  if needs_fallback "${file}"; then
    pass "${name}"
  else
    fail "${name}" "expected fallback trigger for ${file}"
  fi
}

expect_no_fallback() {
  local name="$1"
  local file="$2"
  if needs_fallback "${file}"; then
    fail "${name}" "did not expect fallback trigger for ${file}"
  else
    pass "${name}"
  fi
}

# --- Skill recipe is present and extractable ---
if [[ -z "${CONDITION}" ]]; then
  fail "extract-condition" "empty condition extracted from ${SKILL}"
else
  pass "extract-condition"
fi

case "${CONDITION}" in
  *review\ comment*) pass "skill-mentions-pointer-template" ;;
  *) fail "skill-mentions-pointer-template" "condition lacks pointer template: ${CONDITION}" ;;
esac

case "${CONDITION}" in
  *-lt\ 200*) pass "skill-mentions-length-threshold" ;;
  *) fail "skill-mentions-length-threshold" "condition lacks 200-byte threshold: ${CONDITION}" ;;
esac

# Empty / whitespace-only files are created at runtime so end-of-file-fixer
# cannot turn a committed empty fixture into a one-byte newline file.
: > "${TMPDIR}/empty.txt"
printf '\n' > "${TMPDIR}/whitespace-only.txt"

expect_fallback "empty-file" "${TMPDIR}/empty.txt"
expect_fallback "whitespace-only" "${TMPDIR}/whitespace-only.txt"
expect_fallback "pointer-pr-1296" "${FIXTURES}/pointer-pr-1296.txt"
expect_fallback "pointer-no-url" "${FIXTURES}/pointer-no-url.txt"
# pointer-long is >= 200 bytes so only the pointer-regex clause can trigger
# fallback. The shorter pointer fixtures also match the length threshold.
expect_fallback "pointer-long" "${FIXTURES}/pointer-long.txt"
expect_fallback "short-non-pointer" "${FIXTURES}/short-non-pointer.txt"
expect_no_fallback "actionable-review" "${FIXTURES}/actionable.txt"

# The PR #1296 pointer must be non-empty so this is not the empty-file case.
POINTER_SIZE="$(wc -c < "${FIXTURES}/pointer-pr-1296.txt" | tr -d ' ')"
if [[ "${POINTER_SIZE}" -gt 0 ]]; then
  pass "pointer-pr-1296-non-empty"
else
  fail "pointer-pr-1296-non-empty" "fixture is empty; it must be the real pointer body"
fi

if grep -q 'See the \[review comment\]' "${FIXTURES}/pointer-pr-1296.txt"; then
  pass "pointer-pr-1296-matches-template"
else
  fail "pointer-pr-1296-matches-template" "fixture is not the PR #1296 pointer sentence"
fi

# Lock the isolation: if this fixture shrinks below 200 bytes, the length
# threshold would fire first and the regex clause would again be untested.
POINTER_LONG_SIZE="$(wc -c < "${FIXTURES}/pointer-long.txt" | tr -d ' ')"
if [[ "${POINTER_LONG_SIZE}" -ge 200 ]]; then
  pass "pointer-long-at-least-200"
else
  fail "pointer-long-at-least-200" "fixture is ${POINTER_LONG_SIZE} bytes; must be >= 200 to isolate the regex clause"
fi

if [[ "${FAILURES}" -ne 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
