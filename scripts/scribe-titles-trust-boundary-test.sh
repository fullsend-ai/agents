#!/usr/bin/env bash
# scribe-titles-trust-boundary-test.sh — Verify scribe-titles.json (the Drive
# document titles, issue #706) is never mounted into the scribe sandbox.
#
# Titles are untrusted Drive input; keeping this file off harness/scribe.yaml's
# host_files is what keeps them out of the sandboxed agent's context (post-scribe
# reads them back on the runner instead, in scribe-titles-json-only-host-reader
# below). This is defense-in-depth: even if a future edit to the harness
# accidentally mounts the file, this test catches it before merge.
#
# A plain grep rather than a YAML-aware parse: the only way this file's name
# can reach the sandbox is by appearing anywhere in harness/scribe.yaml (as a
# host_files src/dest, an env value, or otherwise), so a substring match is a
# sufficient and dependency-free guard — no yq required.
#
# Run from the repo root: bash scripts/scribe-titles-trust-boundary-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARNESS_FILE="${REPO_ROOT}/harness/scribe.yaml"
FAILURES=0

assert_pass() { echo "PASS: $1"; }
assert_fail() {
  local test_name="$1" detail="$2"
  echo "FAIL: ${test_name} — ${detail}"
  FAILURES=$((FAILURES + 1))
}

if [[ ! -f "${HARNESS_FILE}" ]]; then
  assert_fail "scribe-titles-not-mounted" "${HARNESS_FILE} not found"
else
  # Strip full-line comments first (this file's own comment explaining the
  # exclusion names scribe-titles.json, which would otherwise self-trigger).
  if grep -v '^[[:space:]]*#' "${HARNESS_FILE}" | grep -q 'scribe-titles.json'; then
    assert_fail "scribe-titles-not-mounted" \
      "scribe-titles.json is referenced in harness/scribe.yaml — titles are untrusted input (issue #706) and must stay out of the sandbox"
  else
    assert_pass "scribe-titles-not-mounted"
  fi

  # Sanity check that the grep above is a meaningful test and not trivially
  # passing because host_files is empty or scribe-meta.json was renamed out
  # from under it: scribe-meta.json (the sibling, sandbox-mounted file) must
  # still be present, proving host_files is populated and grep would have
  # caught scribe-titles.json had it been added the same way.
  if grep -v '^[[:space:]]*#' "${HARNESS_FILE}" | grep -q 'scribe-meta.json'; then
    assert_pass "scribe-meta-still-mounted-sanity-check"
  else
    assert_fail "scribe-meta-still-mounted-sanity-check" \
      "scribe-meta.json no longer referenced in harness/scribe.yaml — the scribe-titles.json check above may not be meaningful"
  fi
fi

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All scribe-titles trust boundary tests passed"
