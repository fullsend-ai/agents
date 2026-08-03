#!/usr/bin/env bash
# lint-agent-docs-test.sh — Tests for hack/lint-agent-docs
#
# Run from the repo root:
#   bash hack/lint-agent-docs-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINTER="${SCRIPT_DIR}/lint-agent-docs"

FAILURES=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

VALID_DOC='# Widget Agent

## How it helps

Does things.

## Setup

No additional setup required.

## Triggers

- Something happens.

## Commands

None.

## Control labels

None.

## Configuration

See configuration docs.

### Variables

None.

## How the agent works

It works.

## Source

[`harness/widget.yaml`](../harness/widget.yaml)
'

# run_case NAME DOC_CONTENT EXPECTED_EXIT [EXPECTED_OUTPUT_SUBSTRING]
# Passing an empty DOC_CONTENT means "omit the doc: field from the harness YAML".
run_case() {
  local name="$1" doc_content="$2" expected_exit="$3" expected_substring="${4:-}"

  local case_dir="${WORKDIR}/${name}"
  local harness_dir="${case_dir}/harness"
  mkdir -p "${harness_dir}"

  local doc_path="${case_dir}/widget.md"
  local yaml_path="${harness_dir}/widget.yaml"

  if [[ -n "${doc_content}" ]]; then
    printf '%s' "${doc_content}" > "${doc_path}"
    printf 'doc: widget.md\n' > "${yaml_path}"
  else
    printf 'name: widget\n' > "${yaml_path}"
  fi

  local output
  local actual_exit=0
  output="$(REPO_ROOT="${case_dir}" HARNESS_DIR="${harness_dir}" "${LINTER}" 2>&1)" || actual_exit=$?

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

run_case "valid-doc-passes" \
  "${VALID_DOC}" 0

run_case "missing-doc-field" \
  "" 1 "missing 'doc:' field"

run_case "missing-section" \
  "$(echo "${VALID_DOC}" | grep -v '^## Triggers$')" 1 'missing: "## Triggers"'

run_case "duplicate-section" \
  "${VALID_DOC}
## Setup

Again.
" 1 'duplicate section "## Setup"'

run_case "unterminated-fence" \
  "${VALID_DOC}
\`\`\`
unterminated
" 1 "unterminated fenced code block"

run_case "near-miss-configuration-heading-not-treated-as-configuration" \
  "$(echo "${VALID_DOC}" | sed 's/^## Configuration$/## Configuration Overrides/')" \
  1 'missing: "## Configuration"'

run_case "missing-variables-under-configuration" \
  "$(printf '%s\n' "${VALID_DOC}" | sed '/^### Variables$/,+2d')" \
  1 'missing "### Variables" subsection under "## Configuration"'

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
