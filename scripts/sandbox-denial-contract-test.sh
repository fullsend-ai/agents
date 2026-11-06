#!/usr/bin/env bash
# sandbox-denial-contract-test.sh — Verify the code and fix agents back off
# on possible sandbox permission denials (Permission denied, Operation not
# permitted, EACCES, EPERM) instead of routing around them, and report the
# denial and the checks it left unverified.
#
# Run from the repo root:
#   bash scripts/sandbox-denial-contract-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CODE_AGENT="${REPO_ROOT}/agents/code.md"
FIX_AGENT="${REPO_ROOT}/agents/fix.md"
CODE_SKILL="${REPO_ROOT}/skills/code-implementation/SKILL.md"
FIX_SKILL="${REPO_ROOT}/skills/fix-verification/SKILL.md"
FAILURES=0

# Normalize to a single space-separated line so assertions survive markdown
# re-wrapping.
normalize() {
  tr '\n' ' ' | tr -s ' '
}

# extract_section FILE START END — print FILE from the first line matching
# START up to (not including) the first later line matching END.
extract_section() {
  awk -v start="$2" -v end="$3" '
    $0 ~ start { found = 1 }
    found && $0 ~ end { exit }
    found { print }
  ' "$1"
}

assert_contains() {
  local label="$1" target="$2" name="$3" expected="$4"
  if grep -qF -- "${expected}" <<<"${target}"; then
    echo "PASS: ${label}: ${name}"
  else
    echo "FAIL: ${label}: ${name} — missing '${expected}'"
    FAILURES=$((FAILURES + 1))
  fi
}

# Contract shared by every surface: a command that keeps returning
# "Operation not permitted" is recognized, never routed around, reported
# with redaction and without an unverified cause, and leaves a list of
# unverified checks; genuine repository permission problems stay
# investigable.
assert_denial_contract() {
  local label="$1" target="$2"
  assert_contains "${label}" "${target}" "recognizes Permission denied" \
    '`Permission denied`'
  assert_contains "${label}" "${target}" "recognizes Operation not permitted" \
    '`Operation not permitted`'
  assert_contains "${label}" "${target}" "recognizes EACCES" '`EACCES`'
  assert_contains "${label}" "${target}" "recognizes EPERM" '`EPERM`'
  assert_contains "${label}" "${target}" "names a sandbox or environment cause" \
    'sandbox or environment'
  assert_contains "${label}" "${target}" "no alternate paths, wrappers, or shims" \
    'alternate path, wrapper, shim'
  assert_contains "${label}" "${target}" "no equivalent commands" \
    'equivalent command'
  assert_contains "${label}" "${target}" "warning names the denied command" \
    'the denied command'
  assert_contains "${label}" "${target}" "redacts credential-like arguments" \
    'credential-like arguments'
  assert_contains "${label}" "${target}" "lists unverified checks" \
    'unverified checks'
  assert_contains "${label}" "${target}" "continues only with independent checks" \
    'do not need the denied operation'
  assert_contains "${label}" "${target}" "repository permission problems stay investigable" \
    'points at the repository itself'
  assert_contains "${label}" "${target}" "reports in the final message" \
    'final message'
}

for f in "${CODE_AGENT}" "${FIX_AGENT}" "${CODE_SKILL}" "${FIX_SKILL}"; do
  if [[ ! -f "${f}" ]]; then
    echo "FAIL: ${f} not found"
    exit 1
  fi
done

CODE_AGENT_TEXT="$(normalize <"${CODE_AGENT}")"
FIX_AGENT_TEXT="$(extract_section "${FIX_AGENT}" '^## Sandbox permission denials' '^## Structured output' | normalize)"
CODE_9B="$(extract_section "${CODE_SKILL}" '^\*\*9b\. ' '^\*\*9c\. ' | normalize)"
CODE_9C="$(extract_section "${CODE_SKILL}" '^\*\*9c\. ' '^\*\*9d\. ' | normalize)"
FIX_7B="$(extract_section "${FIX_SKILL}" '^\*\*7b\. ' '^\*\*7c\. ' | normalize)"
FIX_7C="$(extract_section "${FIX_SKILL}" '^\*\*7c\. ' '^\*\*7d\. ' | normalize)"

for pair in "fix agent section:FIX_AGENT_TEXT" "code skill 9b:CODE_9B" \
  "code skill 9c:CODE_9C" "fix skill 7b:FIX_7B" "fix skill 7c:FIX_7C"; do
  var="${pair#*:}"
  if [[ -z "${!var}" ]]; then
    echo "FAIL: could not extract ${pair%%:*}"
    exit 1
  fi
done

# Agent definitions.
assert_denial_contract "agents/code.md" "${CODE_AGENT_TEXT}"
assert_contains "agents/code.md" "${CODE_AGENT_TEXT}" "does not assert an unverified cause" \
  'without asserting a cause you have not verified'
assert_contains "agents/code.md" "${CODE_AGENT_TEXT}" "disclosed in pr_body" '`pr_body`'
assert_contains "agents/code.md" "${CODE_AGENT_TEXT}" "points at the skill procedure" \
  '`code-implementation` skill (step 9c)'

assert_denial_contract "agents/fix.md" "${FIX_AGENT_TEXT}"
assert_contains "agents/fix.md" "${FIX_AGENT_TEXT}" "does not assert an unverified cause" \
  'without asserting a cause you have not verified'
assert_contains "agents/fix.md" "${FIX_AGENT_TEXT}" "disclosed in the result summary" \
  "the result's \`summary\`"
assert_contains "agents/fix.md" "${FIX_AGENT_TEXT}" "points at the skill procedure" \
  '`fix-verification` skill (step 7c)'

# Skills: the procedure lives in the tests-and-linters step.
for spec in "code-implementation 9c:CODE_9C:9c" "fix-verification 7c:FIX_7C:7c"; do
  label="${spec%%:*}"
  rest="${spec#*:}"
  var="${rest%%:*}"
  step="${rest#*:}"
  text="${!var}"
  assert_denial_contract "${label}" "${text}"
  assert_contains "${label}" "${text}" "uses the GNU Make denial as the example" \
    'make: pnpm: Operation not permitted'
  assert_contains "${label}" "${text}" "emits a visible warning annotation" \
    "::warning::Possible sandbox denial in STEP ${step}"
  assert_contains "${label}" "${text}" "frames it as a possible denial" \
    'Call it a possible denial'
  assert_contains "${label}" "${text}" "does not assert an unverified cause" \
    'do not assert the sandbox caused it unless the output shows that'
  assert_contains "${label}" "${text}" "denial is final" \
    'Treat the denial as final for that operation'
  assert_contains "${label}" "${text}" "no probing for a way around it" \
    'do not probe for a way around it'
  assert_contains "${label}" "${text}" "denial does not consume a retry" \
    "Do not spend a ${step} retry on it"
  assert_contains "${label}" "${text}" "stops cleanly when the check is required" \
    'do not commit'
done

assert_contains "code-implementation 9c" "${CODE_9C}" "disclosed in pr_body" '`pr_body`'
assert_contains "fix-verification 7c" "${FIX_7C}" "disclosed in the result summary" \
  "the result's \`summary\`"
assert_contains "fix-verification 7c" "${FIX_7C}" "denied tests mark tests_passed false" \
  'Set `tests_passed` to `false`'

# Pre-commit: a permission error must not trigger the direct-execution
# fallback, which would route around the denial.
assert_contains "code-implementation 9b" "${CODE_9B}" "denial is not a fallback trigger" \
  'not an infrastructure failure for the fallback'
assert_contains "code-implementation 9b" "${CODE_9B}" "no direct hook runs around a denial" \
  'do not run the hooks directly to get around it'
assert_contains "code-implementation 9b" "${CODE_9B}" "stop-short list counts the denial" \
  'Exactly four things let you stop short'
assert_contains "fix-verification 7b" "${FIX_7B}" "denial is not a fallback trigger" \
  'not an infrastructure failure for that fallback'
assert_contains "fix-verification 7b" "${FIX_7B}" "no direct hook runs around a denial" \
  'do not run the hooks directly to get around it'

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All sandbox denial contract tests passed"
