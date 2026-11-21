#!/usr/bin/env bash
# lint-gh-api-syntax-test.sh — Tests for hack/lint-gh-api-syntax
#
# Run from the repo root:
#   bash hack/lint-gh-api-syntax-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINTER="${SCRIPT_DIR}/lint-gh-api-syntax"

FAILURES=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# run_case NAME REL_PATH CONTENT EXPECTED_EXIT [EXPECTED_OUTPUT_SUBSTRING]
# Writes CONTENT to REL_PATH under a fresh fake repo root and runs the linter.
run_case() {
  local name="$1" rel_path="$2" content="$3" expected_exit="$4" expected_substring="${5:-}"

  local case_dir="${WORKDIR}/${name}"
  mkdir -p "${case_dir}/skills" "${case_dir}/agents" "$(dirname "${case_dir}/${rel_path}")"
  printf '%s\n' "${content}" > "${case_dir}/${rel_path}"

  local output
  local actual_exit=0
  output="$(REPO_ROOT="${case_dir}" "${LINTER}" 2>&1)" || actual_exit=$?

  if [[ "${actual_exit}" != "${expected_exit}" ]]; then
    echo "FAIL: ${name} (exit ${actual_exit}, expected ${expected_exit})"
    echo "${output}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_substring}" ]] && [[ "${output}" != *"${expected_substring}"* ]]; then
    echo "FAIL: ${name} (missing expected output: '${expected_substring}')"
    echo "${output}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${name}"
}

run_case "skill-colon-equals-fails" \
  "skills/widget/SKILL.md" \
  'gh api graphql -F number:=1 -f query=...' \
  1 "skills/widget/SKILL.md:1:"

run_case "nested-skill-colon-equals-fails" \
  "skills/widget/github/SKILL.md" \
  'gh api graphql -F owner="o" -F number:=1 -f query=...' \
  1 "skills/widget/github/SKILL.md:1:"

run_case "agent-colon-equals-fails" \
  "agents/widget.md" \
  'gh api graphql -F number:=1 -f query=...' \
  1 "agents/widget.md:1:"

run_case "skill-equals-passes" \
  "skills/widget/SKILL.md" \
  'gh api graphql -F number=1 -f query=...' \
  0

run_case "agent-equals-passes" \
  "agents/widget.md" \
  'gh api graphql -F owner="o" -F number=1 -f query=...' \
  0

run_case "non-markdown-ignored" \
  "skills/widget/script.sh" \
  'gh api graphql -F number:=1 -f query=...' \
  0

# The real skills/ and agents/ trees must lint clean.
actual_exit=0
output="$("${LINTER}" 2>&1)" || actual_exit=$?
if [[ "${actual_exit}" != 0 ]]; then
  echo "FAIL: repo-tree-passes (exit ${actual_exit}, expected 0)"
  echo "${output}" | sed 's/^/    /'
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: repo-tree-passes"
fi

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
