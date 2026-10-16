#!/usr/bin/env bash
# fix-review-scanner-test.sh — Guard Project CI skill blocks against
# sandbox command-scanner (tirith) refusals from issue #1422.
#
# The recipes live in skills/fix-review/{github,gitlab}/SKILL.md. This
# test extracts those fenced bash blocks and asserts they use the
# write-to-file dialect instead of `$(gh …)` / `$(curl …)` / `curl --config -`.
# When `tirith` is on PATH, it also runs `tirith check --shell posix` and
# asserts each Project CI block is allowed.
#
# Run from the repo root:
#   bash scripts/fix-review-scanner-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GH_SKILL="${REPO_ROOT}/skills/fix-review/github/SKILL.md"
GL_SKILL="${REPO_ROOT}/skills/fix-review/gitlab/SKILL.md"

FAILURES=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — $2"; FAILURES=$((FAILURES + 1)); }

# Extract fenced bash blocks whose body matches a Python regex (first group).
# Prints one block per NUL-delimited record via a numbered file.
extract_blocks() {
  local skill="$1"
  local pattern="$2"
  local out_dir="$3"
  python3 - "${skill}" "${pattern}" "${out_dir}" <<'PY'
import pathlib
import re
import sys

skill, pattern, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(skill).read_text()
blocks = re.findall(r"```bash\n(.*?)```", text, re.DOTALL)
rx = re.compile(pattern)
n = 0
for block in blocks:
    if rx.search(block):
        n += 1
        pathlib.Path(out_dir, f"block-{n:02d}.sh").write_text(block)
print(n)
PY
}

assert_contains() {
  local name="$1"
  local file="$2"
  local needle="$3"
  if grep -q -F -- "${needle}" "${file}"; then
    pass "${name}"
  else
    fail "${name}" "expected ${file} to contain: ${needle}"
  fi
}

assert_absent() {
  local name="$1"
  local file="$2"
  local needle="$3"
  if grep -q -F -- "${needle}" "${file}"; then
    fail "${name}" "expected ${file} not to contain: ${needle}"
  else
    pass "${name}"
  fi
}

# --- GitHub Project CI (head SHA + gh pr checks) ---
GH_CI="${TMPDIR}/gh-ci"
mkdir -p "${GH_CI}"
GH_CI_COUNT="$(extract_blocks "${GH_SKILL}" 'gh pr checks' "${GH_CI}")"
if [ "${GH_CI_COUNT}" -eq 1 ]; then
  pass "github-project-ci-block-count"
else
  fail "github-project-ci-block-count" "expected 1 block, got ${GH_CI_COUNT}"
fi
GH_CI_FILE="${GH_CI}/block-01.sh"
if [ -f "${GH_CI_FILE}" ]; then
  assert_contains "github-writes-head-sha-file" "${GH_CI_FILE}" "> /sandbox/workspace/head_sha.txt"
  assert_contains "github-reads-head-sha-file" "${GH_CI_FILE}" 'HEAD_SHA=$(cat /sandbox/workspace/head_sha.txt)'
  assert_absent "github-no-gh-command-substitution" "${GH_CI_FILE}" '$(gh '
fi

# --- GitHub exclusion block (re-reads the SHA file) ---
GH_EX="${TMPDIR}/gh-ex"
mkdir -p "${GH_EX}"
GH_EX_COUNT="$(extract_blocks "${GH_SKILL}" '\.workflowName // ""' "${GH_EX}")"
if [ "${GH_EX_COUNT}" -eq 1 ]; then
  pass "github-exclusion-block-count"
else
  fail "github-exclusion-block-count" "expected 1 block, got ${GH_EX_COUNT}"
fi
GH_EX_FILE="${GH_EX}/block-01.sh"
if [ -f "${GH_EX_FILE}" ]; then
  assert_contains "github-exclusion-reads-head-sha-file" "${GH_EX_FILE}" 'HEAD_SHA=$(cat /sandbox/workspace/head_sha.txt)'
  assert_absent "github-exclusion-no-gh-command-substitution" "${GH_EX_FILE}" '$(gh '
fi

# --- GitLab Project CI ---
GL_CI="${TMPDIR}/gl-ci"
mkdir -p "${GL_CI}"
GL_CI_COUNT="$(extract_blocks "${GL_SKILL}" 'head_pipeline' "${GL_CI}")"
if [ "${GL_CI_COUNT}" -eq 1 ]; then
  pass "gitlab-project-ci-block-count"
else
  fail "gitlab-project-ci-block-count" "expected 1 block, got ${GL_CI_COUNT}"
fi
GL_CI_FILE="${GL_CI}/block-01.sh"
if [ -f "${GL_CI_FILE}" ]; then
  assert_contains "gitlab-writes-mr-json" "${GL_CI_FILE}" "> /sandbox/workspace/mr.json"
  assert_contains "gitlab-writes-pipeline-id" "${GL_CI_FILE}" "> /sandbox/workspace/pipeline_id.txt"
  assert_contains "gitlab-uses-curl-K" "${GL_CI_FILE}" "curl -K"
  assert_contains "gitlab-uses-test-n" "${GL_CI_FILE}" 'if test -n "${HEAD_PIPELINE_ID}"; then'
  assert_absent "gitlab-no-curl-command-substitution" "${GL_CI_FILE}" '$(curl'
  assert_absent "gitlab-no-config-dash" "${GL_CI_FILE}" "--config -"
  assert_absent "gitlab-no-here-string" "${GL_CI_FILE}" "<<<"
  assert_absent "gitlab-no-bracket-test" "${GL_CI_FILE}" "if [ -n"
fi

# --- GitLab trace / artifacts ---
GL_TR="${TMPDIR}/gl-tr"
mkdir -p "${GL_TR}"
GL_TR_COUNT="$(extract_blocks "${GL_SKILL}" 'ci-artifacts-' "${GL_TR}")"
if [ "${GL_TR_COUNT}" -eq 1 ]; then
  pass "gitlab-trace-block-count"
else
  fail "gitlab-trace-block-count" "expected 1 block, got ${GL_TR_COUNT}"
fi
GL_TR_FILE="${GL_TR}/block-01.sh"
if [ -f "${GL_TR_FILE}" ]; then
  assert_contains "gitlab-trace-uses-curl-K" "${GL_TR_FILE}" "curl -K"
  assert_absent "gitlab-trace-no-config-dash" "${GL_TR_FILE}" "--config -"
  assert_absent "gitlab-trace-no-here-string" "${GL_TR_FILE}" "<<<"
  assert_absent "gitlab-trace-no-curl-command-substitution" "${GL_TR_FILE}" '$(curl'
fi

# --- tirith, when the sandbox scanner binary is present ---
run_tirith() {
  local name="$1"
  local file="$2"
  local empty_home="${TMPDIR}/empty-home"
  mkdir -p "${empty_home}"
  local output rc
  rc=0
  output="$(HOME="${empty_home}" tirith check --shell posix --format json --offline --non-interactive -- "$(cat "${file}")" 2>&1)" || rc=$?
  if echo "${output}" | grep -q '"action":"allow"'; then
    pass "tirith-${name}"
  else
    fail "tirith-${name}" "tirith did not allow ${file} (exit ${rc}): ${output}"
  fi
}

if command -v tirith >/dev/null 2>&1; then
  [ -f "${GH_CI_FILE}" ] && run_tirith "github-project-ci" "${GH_CI_FILE}"
  [ -f "${GH_EX_FILE}" ] && run_tirith "github-exclusion" "${GH_EX_FILE}"
  [ -f "${GL_CI_FILE}" ] && run_tirith "gitlab-project-ci" "${GL_CI_FILE}"
  [ -f "${GL_TR_FILE}" ] && run_tirith "gitlab-trace" "${GL_TR_FILE}"
else
  echo "SKIP: tirith not on PATH — structural assertions still ran"
fi

if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
