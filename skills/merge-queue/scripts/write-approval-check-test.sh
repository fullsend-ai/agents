#!/usr/bin/env bash
# write-approval-check-test.sh — Tests the jq filters in
# lib/write-approval-check.lib.sh against fixture JSON, without live gh calls.
#
# Run from the repo root:
#   bash skills/merge-queue/scripts/write-approval-check-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILURES=0

if ! grep -q 'enforce_write_approval_gate' "${SCRIPT_DIR}/enqueue-pr.sh"; then
  echo "FAIL: enqueue-pr-has-write-approval-gate"
  echo "  enqueue-pr.sh does not enforce the write-approval gate (this is the primary documented enqueue entry point)"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: enqueue-pr-has-write-approval-gate"
fi

if ! grep -q 'write_approval_ever_required' "${SCRIPT_DIR}/await-and-enqueue.sh"; then
  echo "FAIL: await-and-enqueue-has-write-approval-gate"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: await-and-enqueue-has-write-approval-gate"
fi

# ---------------------------------------------------------------------------
# write_approval_ever_required — same jq filter as lib/write-approval-check.lib.sh
# ---------------------------------------------------------------------------
EVER_REQUIRED_FILTER='
  [add // [] | .[] | select(.event == "labeled" and .label.name == "needs-write-approval")]
  | length > 0
'

run_ever_required_test() {
  local test_name="$1"
  local events_json="$2"
  local expected="$3"  # "true" or "false"

  local actual
  actual="$(echo "${events_json}" | jq -s -r "${EVER_REQUIRED_FILTER}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

run_ever_required_test "never-labeled" \
  '[{"event": "commented"}, {"event": "assigned"}]' \
  "false"

run_ever_required_test "currently-labeled" \
  '[{"event": "labeled", "label": {"name": "needs-write-approval"}}]' \
  "true"

run_ever_required_test "labeled-then-unlabeled-still-counts" \
  '[{"event": "labeled", "label": {"name": "needs-write-approval"}}, {"event": "unlabeled", "label": {"name": "needs-write-approval"}}]' \
  "true"

run_ever_required_test "different-label-does-not-count" \
  '[{"event": "labeled", "label": {"name": "ready-for-review"}}]' \
  "false"

run_ever_required_test "empty-events" \
  '[]' \
  "false"

# ---------------------------------------------------------------------------
# has_write_plus_approval's approved_users filter — same jq filter as
# lib/write-approval-check.lib.sh, run against fixture PR reviews.
# ---------------------------------------------------------------------------
APPROVED_USERS_FILTER='
  add // []
  | group_by(.user.login)
  | map(max_by(.submitted_at))
  | map(select(.state == "APPROVED" and .commit_id == $head))
  | map(select((.user.login // "") | test("\\[bot\\]$") | not))
  | map(select(.user.login != "dependabot"))
  | .[].user.login
'

run_approved_users_test() {
  local test_name="$1"
  local reviews_json="$2"
  local head_sha="$3"
  local expected="$4"  # newline-separated expected logins, or "" for none

  local actual
  actual="$(echo "${reviews_json}" | jq -s -r --arg head "${head_sha}" "${APPROVED_USERS_FILTER}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

run_approved_users_test "single-human-approval-on-head" \
  '[{"user": {"login": "alice"}, "state": "APPROVED", "commit_id": "abc123", "submitted_at": "2026-01-01T00:00:00Z"}]' \
  "abc123" \
  "alice"

run_approved_users_test "bot-approval-excluded" \
  '[{"user": {"login": "some-bot[bot]"}, "state": "APPROVED", "commit_id": "abc123", "submitted_at": "2026-01-01T00:00:00Z"}]' \
  "abc123" \
  ""

run_approved_users_test "dependabot-excluded" \
  '[{"user": {"login": "dependabot"}, "state": "APPROVED", "commit_id": "abc123", "submitted_at": "2026-01-01T00:00:00Z"}]' \
  "abc123" \
  ""

run_approved_users_test "stale-approval-on-old-commit-excluded" \
  '[{"user": {"login": "alice"}, "state": "APPROVED", "commit_id": "old-sha", "submitted_at": "2026-01-01T00:00:00Z"}]' \
  "new-sha" \
  ""

run_approved_users_test "latest-review-wins-approve-then-request-changes" \
  '[{"user": {"login": "alice"}, "state": "APPROVED", "commit_id": "abc123", "submitted_at": "2026-01-01T00:00:00Z"}, {"user": {"login": "alice"}, "state": "CHANGES_REQUESTED", "commit_id": "abc123", "submitted_at": "2026-01-02T00:00:00Z"}]' \
  "abc123" \
  ""

run_approved_users_test "latest-review-wins-request-changes-then-approve" \
  '[{"user": {"login": "alice"}, "state": "CHANGES_REQUESTED", "commit_id": "abc123", "submitted_at": "2026-01-01T00:00:00Z"}, {"user": {"login": "alice"}, "state": "APPROVED", "commit_id": "abc123", "submitted_at": "2026-01-02T00:00:00Z"}]' \
  "abc123" \
  "alice"

run_approved_users_test "multiple-approvers-mixed" \
  '[{"user": {"login": "alice"}, "state": "APPROVED", "commit_id": "abc123", "submitted_at": "2026-01-01T00:00:00Z"}, {"user": {"login": "bot-account[bot]"}, "state": "APPROVED", "commit_id": "abc123", "submitted_at": "2026-01-01T00:00:00Z"}]' \
  "abc123" \
  "alice"

run_approved_users_test "no-reviews" \
  '[]' \
  "abc123" \
  ""

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
