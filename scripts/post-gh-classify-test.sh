#!/usr/bin/env bash
# post-gh-classify-test.sh — Test post-gh-classify.sh with fixture JSON inputs.
#
# Run from the repo root: bash scripts/post-gh-classify-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST_SCRIPT="${SCRIPT_DIR}/post-gh-classify.sh"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

GH_LOG="${TMPDIR}/gh-calls.log"
MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/gh" <<MOCKEOF
#!/usr/bin/env bash
echo "gh \$*" >> "${GH_LOG}"
# Simulate gh api --jq extraction used by set_project_field.
if [[ "\$1" == "api" && "\$*" == *"/issues/"* && "\$*" == *"--jq"* ]]; then
  echo "I_mock_node"
  exit 0
fi
if [[ "\$1" == "api" && "\$2" == "graphql" && "\$*" == *"--jq"* && "\$*" == *"addProjectV2ItemById"* ]]; then
  echo "PVTI_mock_item"
  exit 0
fi
if [[ "\$1" == "api" && "\$2" == "graphql" ]]; then
  # updateProjectV2ItemFieldValue and other mutations
  echo '{}'
  exit 0
fi
exit 0
MOCKEOF
chmod +x "${MOCK_BIN}/gh"

export PATH="${MOCK_BIN}:${PATH}"
export CLASSIFY_SOURCE_REPO="mock-org/mock-repo"
export GH_TOKEN="fake-token"
export CLASSIFY_DRY_RUN="true"
export CLASSIFY_MIN_CONFIDENCE="0.7"
export CLASSIFY_MODE="unclassified"

CONTEXT_DIR="/tmp/workspace/context"
mkdir -p "${CONTEXT_DIR}"
cat > "${CONTEXT_DIR}/project-meta.json" <<'EOF'
{
  "project_id": "PVT_mock",
  "field_id": "PVTSSF_mock",
  "options": [
    {"name": "Bug fixes", "id": "opt_bug"},
    {"name": "New features", "id": "opt_feat"}
  ]
}
EOF
cat > "${CONTEXT_DIR}/open-issues.json" <<'EOF'
[
  {"number": 42, "title": "Login crash", "labels": [], "author": {"login": "alice"}, "createdAt": "2026-01-01T00:00:00Z"},
  {"number": 99, "title": "Ambiguous ask", "labels": [], "author": {"login": "bob"}, "createdAt": "2026-01-02T00:00:00Z"}
]
EOF
printf '42\n99\n' > "${CONTEXT_DIR}/issue-numbers.txt"

run_test_stdout() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"
  local expect_failure="${4:-false}"
  local extra_env="${5:-}"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2086
  (cd "${run_dir}" && env ${extra_env} bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure, got exit code ${exit_code})"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_stdout "dry-run-classifies-above-threshold" \
  '{"classifications":[{"issue_number":42,"workstream_category":"Bug fixes","reasoning":"Crash in login flow.","confidence":0.92}]}' \
  "CLASSIFY AGENT -- DRY RUN"

run_test_stdout "below-threshold-skipped" \
  '{"classifications":[{"issue_number":99,"workstream_category":"Bug fixes","reasoning":"Unclear.","confidence":0.4}]}' \
  "BELOW 70% CONFIDENCE"

run_test_stdout "null-category-unclassifiable" \
  '{"classifications":[{"issue_number":99,"workstream_category":null,"reasoning":"No clear match.","confidence":0.3}]}' \
  "UNCLASSIFIABLE"

# Prefer FULLSEND_VALIDATED_ITERATION_DIR over scanning iteration-*/output.
VALIDATED_DIR="${TMPDIR}/validated-iter"
mkdir -p "${VALIDATED_DIR}"
echo '{"classifications":[{"issue_number":42,"workstream_category":"Bug fixes","reasoning":"From validated dir.","confidence":0.95}]}' \
  > "${VALIDATED_DIR}/agent-result.json"
# Plant a different (stale) result in iteration-1 so we can tell which was read.
run_test_stdout "validated-iteration-dir-preferred" \
  '{"classifications":[{"issue_number":99,"workstream_category":null,"reasoning":"stale","confidence":0.1}]}' \
  "Reading classify result from: ${VALIDATED_DIR}/agent-result.json" \
  "false" \
  "FULLSEND_VALIDATED_ITERATION_DIR=${VALIDATED_DIR}"

# Live path: set_project_field must call gh api (issue node_id + GraphQL mutations).
export CLASSIFY_DRY_RUN="false"
run_test_stdout "live-run-sets-project-field" \
  '{"classifications":[{"issue_number":42,"workstream_category":"Bug fixes","reasoning":"Crash in login flow.","confidence":0.92}]}' \
  "CLASSIFY AGENT -- LIVE RUN"
if ! grep -q 'api graphql' "${GH_LOG}"; then
  echo "FAIL: live-run-sets-project-field — expected graphql mutation in gh log"
  cat "${GH_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: live-run-sets-project-field (graphql mutation observed)"
fi
export CLASSIFY_DRY_RUN="true"

# Race guard: more candidates than open issues must not yield negative counts.
printf '42\n99\n100\n' > "${CONTEXT_DIR}/issue-numbers.txt"
run_test_stdout "already-classified-never-negative" \
  '{"classifications":[{"issue_number":42,"workstream_category":null,"reasoning":"n/a","confidence":0.1}]}' \
  "SUMMARY"
if grep -E 'Already classified:[[:space:]]+-' "${TMPDIR}/stdout.log"; then
  echo "FAIL: already-classified-never-negative — negative count in summary"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: already-classified-never-negative (no negative count)"
fi
printf '42\n99\n' > "${CONTEXT_DIR}/issue-numbers.txt"

if [[ ${FAILURES} -gt 0 ]]; then
  echo ""
  echo "${FAILURES} test(s) failed"
  exit 1
fi

echo ""
echo "All post-gh-classify tests passed"
