#!/usr/bin/env bash
# post-review-test.sh — Test the outcome-label logic in post-review.sh.
#
# Extracts and tests the label-application logic in isolation using shell
# functions. This avoids needing a live GitHub API or fullsend CLI.
#
# Run from the repo root:
#   bash scripts/post-review-test.sh

set -euo pipefail

FAILURES=0

# ---------------------------------------------------------------------------
# Test helper — reimplements the outcome-label logic from post-review.sh
# so we can test it without network access.
#
# Arguments:
#   $1 — ACTION (the original action from agent-result.json)
#   $2 — DOWNGRADED ("true" or "false")
#
# Prints the label that would be applied, or "none" if no label.
# ---------------------------------------------------------------------------
determine_outcome_label() {
  local action="$1"
  local downgraded="$2"
  local is_draft="${3:-false}"
  local has_human_approval="${4:-false}"

  if [ "${action}" = "approve" ] && [ "${is_draft}" != "true" ] && \
     { [ "${downgraded}" = "false" ] || [ "${has_human_approval}" = "true" ]; }; then
    echo "ready-for-merge"
  elif { [ "${action}" = "approve" ] && { [ "${downgraded}" = "true" ] || [ "${is_draft}" = "true" ]; }; } || \
       [ "${action}" = "comment" ]; then
    echo "requires-manual-review"
  elif [ "${action}" = "request-changes" ]; then
    echo "none"
  elif [ "${action}" = "reject" ]; then
    echo "rejected"
  else
    echo "none"
  fi
}

run_test() {
  local test_name="$1"
  local action="$2"
  local downgraded="$3"
  local expected="$4"
  local is_draft="${5:-false}"
  local has_human_approval="${6:-false}"

  local actual
  actual="$(determine_outcome_label "${action}" "${downgraded}" "${is_draft}" "${has_human_approval}")"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  action:              '${action}'"
    echo "  downgraded:          '${downgraded}'"
    echo "  is_draft:            '${is_draft}'"
    echo "  has_human_approval:  '${has_human_approval}'"
    echo "  expected:            '${expected}'"
    echo "  actual:              '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Test cases ---

# Approve without protected-path downgrade → ready-for-merge
run_test "approve-no-downgrade" \
  "approve" "false" "ready-for-merge"

# Approve with protected-path downgrade and no human approval → requires-manual-review
run_test "approve-with-downgrade" \
  "approve" "true" "requires-manual-review"

# Approve with protected-path downgrade but authorized human already approved → ready-for-merge
run_test "approve-downgrade-with-human-approval" \
  "approve" "true" "ready-for-merge" "false" "true"

# Draft + human approval must still yield requires-manual-review
run_test "approve-downgrade-human-approval-draft" \
  "approve" "true" "requires-manual-review" "true" "true"

# Genuine comment verdict is unchanged even if a human has approved
run_test "comment-with-human-approval-unchanged" \
  "comment" "false" "requires-manual-review" "false" "true"

# Comment (split/conflicting review) → requires-manual-review
run_test "comment-split-review" \
  "comment" "false" "requires-manual-review"

# request-changes → no outcome label
run_test "request-changes-no-label" \
  "request-changes" "false" "none"

# reject → rejected
run_test "reject-label" \
  "reject" "false" "rejected"

# Defensive: comment + downgraded=true can't occur in production (DOWNGRADED is
# only set inside the approve branch), but verify the label logic handles it.
run_test "comment-with-downgrade-flag" \
  "comment" "true" "requires-manual-review"

# Edge cases: ensure unknown/empty actions produce no label
run_test "empty-action-no-label" \
  "" "false" "none"

run_test "failure-action-no-label" \
  "failure" "false" "none"

run_test "unknown-action-no-label" \
  "banana" "false" "none"

# Draft PR tests: approve on a draft must not produce ready-for-merge
run_test "approve-draft-no-ready-for-merge" \
  "approve" "false" "requires-manual-review" "true"

# Draft + downgraded is redundant but must still yield requires-manual-review
run_test "approve-draft-with-downgrade" \
  "approve" "true" "requires-manual-review" "true"

# Non-approve actions on drafts are unaffected
run_test "comment-draft-unchanged" \
  "comment" "false" "requires-manual-review" "true"

run_test "request-changes-draft-unchanged" \
  "request-changes" "false" "none" "true"

run_test "reject-draft-unchanged" \
  "reject" "false" "rejected" "true"

# ---------------------------------------------------------------------------
# Severity-threshold filtering logic
# Mirrors severity_rank() in post-review.sh — keep in sync
# ---------------------------------------------------------------------------

severity_rank() {
  case "$1" in
    info)     echo 0 ;;
    low)      echo 1 ;;
    medium)   echo 2 ;;
    high)     echo 3 ;;
    critical) echo 4 ;;
    *)        echo 1 ;;
  esac
}

filter_findings_json() {
  local result_json="$1"
  local threshold="$2"
  local threshold_rank
  threshold_rank=$(severity_rank "$threshold")

  echo "$result_json" | jq --argjson rank "$threshold_rank" '
    if .findings then
      .findings |= [.[] | select(
        (if .severity == "info" then 0
         elif .severity == "low" then 1
         elif .severity == "medium" then 2
         elif .severity == "high" then 3
         elif .severity == "critical" then 4
         else 1 end) >= $rank
      )]
    else . end
  '
}

run_filter_test() {
  local test_name="$1"
  local input_json="$2"
  local threshold="$3"
  local expected_count="$4"

  local filtered
  filtered="$(filter_findings_json "$input_json" "$threshold")"
  local actual_count
  actual_count="$(echo "$filtered" | jq 'if .findings then (.findings | length) else -1 end')"

  if [ "${actual_count}" != "${expected_count}" ]; then
    echo "FAIL: ${test_name}"
    echo "  threshold:      '${threshold}'"
    echo "  expected count: '${expected_count}'"
    echo "  actual count:   '${actual_count}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Severity filter test cases ---

MIXED_FINDINGS='{"action":"request-changes","findings":[
  {"severity":"info","category":"style","file":"a.go","description":"x"},
  {"severity":"low","category":"style","file":"b.go","description":"y"},
  {"severity":"medium","category":"bug","file":"c.go","description":"z"},
  {"severity":"high","category":"security","file":"d.go","description":"w"},
  {"severity":"critical","category":"security","file":"e.go","description":"v"}
]}'

run_filter_test "threshold-low-drops-info" \
  "$MIXED_FINDINGS" "low" "4"

run_filter_test "threshold-medium-drops-low-and-info" \
  "$MIXED_FINDINGS" "medium" "3"

run_filter_test "threshold-high" \
  "$MIXED_FINDINGS" "high" "2"

run_filter_test "threshold-critical" \
  "$MIXED_FINDINGS" "critical" "1"

run_filter_test "threshold-info-keeps-all" \
  "$MIXED_FINDINGS" "info" "5"

NO_FINDINGS='{"action":"approve"}'
run_filter_test "no-findings-key-passthrough" \
  "$NO_FINDINGS" "low" "-1"

# ---------------------------------------------------------------------------
# Verdict-downgrade tests: when filtering empties all findings, the action
# must be downgraded from request-changes/reject to comment with findings
# key removed.
# Mirrors filter + downgrade logic in post-review.sh — keep in sync
# ---------------------------------------------------------------------------

filter_and_downgrade() {
  local result_json="$1"
  local threshold="$2"

  local filtered
  filtered="$(filter_findings_json "$result_json" "$threshold")"
  local count
  count="$(echo "$filtered" | jq 'if .findings then (.findings | length) else -1 end')"

  if [ "$count" -eq 0 ]; then
    local action
    action="$(echo "$filtered" | jq -r '.action')"
    if [ "$action" = "request-changes" ] || [ "$action" = "reject" ]; then
      echo "$filtered" | jq 'del(.findings) | .action = "comment"'
      return
    fi
    # For approve/comment, just remove the empty findings array
    echo "$filtered" | jq 'del(.findings)'
    return
  fi
  echo "$filtered"
}

run_downgrade_test() {
  local test_name="$1"
  local input_json="$2"
  local threshold="$3"
  local expected_action="$4"
  local expected_has_findings="$5"

  local result
  result="$(filter_and_downgrade "$input_json" "$threshold")"
  local actual_action
  actual_action="$(echo "$result" | jq -r '.action')"
  local has_findings
  has_findings="$(echo "$result" | jq 'has("findings")')"

  if [ "$actual_action" != "$expected_action" ] || [ "$has_findings" != "$expected_has_findings" ]; then
    echo "FAIL: ${test_name}"
    echo "  expected action:       '${expected_action}'"
    echo "  actual action:         '${actual_action}'"
    echo "  expected has_findings: '${expected_has_findings}'"
    echo "  actual has_findings:   '${has_findings}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# All findings are info-level; threshold=low removes them all → downgrade
ALL_INFO='{"action":"request-changes","findings":[
  {"severity":"info","category":"style","file":"a.go","description":"x"},
  {"severity":"info","category":"style","file":"b.go","description":"y"}
]}'

run_downgrade_test "request-changes-all-filtered-downgrade" \
  "$ALL_INFO" "low" "comment" "false"

# Same scenario with reject action
ALL_INFO_REJECT='{"action":"reject","findings":[
  {"severity":"info","category":"style","file":"a.go","description":"x"}
]}'

run_downgrade_test "reject-all-filtered-downgrade" \
  "$ALL_INFO_REJECT" "low" "comment" "false"

# Partial filtering: some findings remain → no downgrade
run_downgrade_test "request-changes-partial-filter-no-downgrade" \
  "$MIXED_FINDINGS" "medium" "request-changes" "true"

# comment with all findings filtered → action stays comment, findings removed
COMMENT_ALL_INFO='{"action":"comment","body":"text","head_sha":"abcdef0123456789abcdef0123456789abcdef01","findings":[
  {"severity":"info","category":"style","file":"a.go","description":"x"}
]}'
run_downgrade_test "comment-all-filtered-removes-findings" \
  "$COMMENT_ALL_INFO" "low" "comment" "false"

# approve with all findings filtered → action stays approve, findings removed
APPROVE_ALL_INFO='{"action":"approve","body":"LGTM","head_sha":"abcdef0123456789abcdef0123456789abcdef01","findings":[
  {"severity":"info","category":"style","file":"a.go","description":"x"}
]}'
run_downgrade_test "approve-all-filtered-removes-findings" \
  "$APPROVE_ALL_INFO" "low" "approve" "false"

# ---------------------------------------------------------------------------
# Severity-threshold downgrade tests with actionable findings: the severity
# threshold is absolute — actionable findings below the threshold are
# filtered out and the verdict is downgraded, respecting the user's
# configured threshold.
# ---------------------------------------------------------------------------

# request-changes with actionable low findings filtered → downgraded
# (severity threshold is respected even for actionable findings)
ACTIONABLE_LOW='{"action":"request-changes","findings":[
  {"severity":"low","category":"naming-convention","file":"a.go","description":"rename type","remediation":"rename FooBar to fooBar","actionable":true}
]}'
run_downgrade_test "request-changes-actionable-filtered-downgraded" \
  "$ACTIONABLE_LOW" "medium" "comment" "false"

# request-changes with mixed actionable/non-actionable info findings
# filtered → downgraded (severity threshold applies to all findings)
MIXED_ACTIONABLE='{"action":"request-changes","findings":[
  {"severity":"info","category":"style","file":"a.go","description":"security: no SSRF bypass","actionable":false},
  {"severity":"low","category":"naming-convention","file":"b.go","description":"rename type","remediation":"rename FooBar to fooBar","actionable":true}
]}'
run_downgrade_test "request-changes-mixed-actionable-filtered-downgraded" \
  "$MIXED_ACTIONABLE" "medium" "comment" "false"

# request-changes with all non-actionable low findings filtered → downgraded
NON_ACTIONABLE_LOW='{"action":"request-changes","findings":[
  {"severity":"low","category":"style","file":"a.go","description":"observation","actionable":false},
  {"severity":"info","category":"style","file":"b.go","description":"note","actionable":false}
]}'
run_downgrade_test "request-changes-non-actionable-downgraded" \
  "$NON_ACTIONABLE_LOW" "medium" "comment" "false"

# reject with actionable findings filtered → downgraded
ACTIONABLE_REJECT='{"action":"reject","findings":[
  {"severity":"info","category":"style","file":"a.go","description":"rename","remediation":"fix it","actionable":true}
]}'
run_downgrade_test "reject-actionable-filtered-downgraded" \
  "$ACTIONABLE_REJECT" "low" "comment" "false"

# ---------------------------------------------------------------------------
# Control-label guard tests
# ---------------------------------------------------------------------------

REVIEW_CONTROL_LABELS=(
  "ready-for-merge" "requires-manual-review" "rejected"
  "ready-for-review" "fullsend-no-fix" "fullsend-fix"
)

is_control_label() {
  local label="$1"
  for cl in "${REVIEW_CONTROL_LABELS[@]}"; do
    if [[ "${cl}" == "${label}" ]]; then
      return 0
    fi
  done
  # Pipeline-managed label prefixes
  if [[ "${label}" == risk/* ]]; then
    return 0
  fi
  return 1
}

run_control_label_test() {
  local test_name="$1"
  local label="$2"
  local expected_control="$3"

  if is_control_label "${label}"; then
    local actual="true"
  else
    local actual="false"
  fi

  if [ "${actual}" != "${expected_control}" ]; then
    echo "FAIL: ${test_name}"
    echo "  label:    '${label}'"
    echo "  expected: '${expected_control}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Control labels should be recognized
run_control_label_test "ready-for-merge-is-control" "ready-for-merge" "true"
run_control_label_test "requires-manual-review-is-control" "requires-manual-review" "true"
run_control_label_test "rejected-is-control" "rejected" "true"
run_control_label_test "ready-for-review-is-control" "ready-for-review" "true"
run_control_label_test "fullsend-no-fix-is-control" "fullsend-no-fix" "true"
run_control_label_test "fullsend-fix-is-control" "fullsend-fix" "true"

# Pipeline-managed risk labels should be control labels
run_control_label_test "risk-low-is-control" "risk/low" "true"
run_control_label_test "risk-moderate-is-control" "risk/moderate" "true"
run_control_label_test "risk-elevated-is-control" "risk/elevated" "true"
run_control_label_test "risk-high-is-control" "risk/high" "true"
run_control_label_test "risk-critical-is-control" "risk/critical" "true"

# Non-control labels should NOT be recognized
run_control_label_test "area-api-not-control" "area/api" "false"
run_control_label_test "priority-high-not-control" "priority/high" "false"
run_control_label_test "bug-not-control" "bug" "false"
run_control_label_test "empty-not-control" "" "false"

# ---------------------------------------------------------------------------
# Integration tests for label_actions processing
# ---------------------------------------------------------------------------
# These tests run the full post-review.sh with mock gh/fullsend binaries
# to verify label_actions validation, body modification, and API calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST_SCRIPT="${SCRIPT_DIR}/post-review.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

GH_LOG="${TMPDIR}/gh-calls.log"
MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"

# harness/review.yaml always sets REVIEW_PROTECTED_PATHS (default, or a
# per-repo override via harness composition). Export it here so generic
# integration tests below — which don't exercise protected-path behavior —
# reflect that reality instead of leaving it unset. Tests that specifically
# cover protected-path resolution set or unset it within their own subshell.
export REVIEW_PROTECTED_PATHS=".claude/,.cursor/,.pi/,.gitattributes,.gitignore,.github/,.pre-commit-config.yaml,AGENTS.md,agents/,api-servers/,CLAUDE.md,CODEOWNERS,Containerfile,Dockerfile,harness/,images/,plugins/,policies/,profiles/,providers/,scripts/,skills/"
# Snapshot of the default for tests that exercise it inside a subshell.
DEFAULT_PROTECTED_PATHS="${REVIEW_PROTECTED_PATHS}"

cat > "${MOCK_BIN}/gh" <<MOCKEOF
#!/usr/bin/env bash
# Mock gh: handle specific subcommands, log everything else.

# gh pr view ... --json state,isDraft → JSON with both fields.
# MOCK_PR_IS_DRAFT can be set to "true" to simulate a draft PR.
if [[ "\$1" == "pr" ]] && [[ "\$2" == "view" ]] && [[ "\$*" == *"--json state"* ]]; then
  DRAFT="\${MOCK_PR_IS_DRAFT:-false}"
  echo "{\"state\":\"OPEN\",\"isDraft\":\${DRAFT}}"
  exit 0
fi

# gh pr view ... --json headRefOid (TOCTOU re-fetch, not the combined query)
if [[ "\$1" == "pr" ]] && [[ "\$2" == "view" ]] && [[ "\$*" == *"--json headRefOid"* ]] && [[ "\$*" != *"reviewDecision"* ]]; then
  if [[ -n "\${MOCK_HEAD_SHA_REFETCH_FAIL:-}" ]]; then
    echo "mock gh pr view headRefOid failure" >&2
    exit 1
  fi
  echo "\${MOCK_PR_HEAD_SHA_REFETCH:-\${MOCK_PR_HEAD_SHA:-abcdef0123456789abcdef0123456789abcdef01}}"
  exit 0
fi

# gh pr view ... --json reviewDecision,headRefOid,author
# Unset MOCK_REVIEW_DECISION → null (fail closed). Set to "null" for the
# same. MOCK_REVIEW_DECISION_FAIL simulates an API error.
if [[ "\$1" == "pr" ]] && [[ "\$2" == "view" ]] && [[ "\$*" == *"--json reviewDecision"* ]]; then
  if [[ -n "\${MOCK_REVIEW_DECISION_FAIL:-}" ]]; then
    echo "mock gh pr view reviewDecision failure" >&2
    exit 1
  fi
  SHA="\${MOCK_PR_HEAD_SHA:-abcdef0123456789abcdef0123456789abcdef01}"
  AUTHOR="\${MOCK_PR_AUTHOR:-alice}"
  if [[ -z "\${MOCK_REVIEW_DECISION+x}" ]] || [[ "\${MOCK_REVIEW_DECISION}" == "null" ]]; then
    echo "{\"reviewDecision\":null,\"headRefOid\":\"\${SHA}\",\"author\":{\"login\":\"\${AUTHOR}\"}}"
  else
    echo "{\"reviewDecision\":\"\${MOCK_REVIEW_DECISION}\",\"headRefOid\":\"\${SHA}\",\"author\":{\"login\":\"\${AUTHOR}\"}}"
  fi
  exit 0
fi

# gh api repos/.../pulls/{n}/reviews --paginate
if [[ "\$1" == "api" ]] && [[ "\$*" == *"/pulls/"*"/reviews"* ]]; then
  if [[ -n "\${MOCK_REVIEWS_FAIL:-}" ]]; then
    echo "mock gh api reviews failure" >&2
    exit 1
  fi
  echo "\${MOCK_REVIEWS_JSON:-[]}"
  exit 0
fi

# gh api repos/.../collaborators/{login}/permission
if [[ "\$1" == "api" ]] && [[ "\$*" == *"/collaborators/"* ]]; then
  if [[ -n "\${MOCK_PERMISSION_FAIL:-}" ]]; then
    echo "mock gh api permission failure" >&2
    exit 1
  fi
  ROLE="\${MOCK_COLLABORATOR_ROLE:-write}"
  echo "{\"permission\":\"\${ROLE}\",\"role_name\":\"\${ROLE}\"}"
  exit 0
fi

# gh api repos/.../pulls/{n}/files --paginate --jq '.[].filename'
# → configurable via MOCK_PR_FILES (the mock emits the already-jq'd
# filename list, matching what forge_get_pr_files consumes). Uses
# \${VAR-default} (not \${VAR:-default}) so an explicitly-empty
# MOCK_PR_FILES="" can simulate "no changed files" instead of falling
# back to the default.
#
# MOCK_PR_FILES_ON_RETRY, when set, makes the FIRST call return an empty
# list and later calls return its value — simulating the transient
# forge data race in fullsend-ai/fullsend#2093 that the call-site retry
# recovers from. MOCK_FILES_CALL_MARKER tracks whether the first call
# has happened; the retry test resets it before running.
if [[ "\$1" == "api" ]] && [[ "\$*" == *"/pulls/"* ]] && [[ "\$*" == *"/files"* ]]; then
  if [[ -n "\${MOCK_PR_FILES_FAIL:-}" ]]; then
    echo "src/partial-before-fetch-failure.go"
    echo "mock gh api failure" >&2
    exit 1
  fi
  if [[ -n "\${MOCK_PR_FILES_ON_RETRY:-}" ]]; then
    if [[ -f "\${MOCK_FILES_CALL_MARKER:-${TMPDIR}/pr-files-call-marker}" ]]; then
      echo "\${MOCK_PR_FILES_ON_RETRY}"
    else
      : > "\${MOCK_FILES_CALL_MARKER:-${TMPDIR}/pr-files-call-marker}"
    fi
    exit 0
  fi
  echo "\${MOCK_PR_FILES-src/main.go}"
  exit 0
fi

# gh pr view ... --json files ... → legacy summary path, retained for any
# caller still using it. Configurable via MOCK_PR_FILES (see above).
if [[ "\$1" == "pr" ]] && [[ "\$2" == "view" ]] && [[ "\$*" == *"--json files"* ]]; then
  echo "\${MOCK_PR_FILES-src/main.go}"
  exit 0
fi

# gh api repos/.../labels --paginate (list repo labels)
if [[ "\$1" == "api" ]] && [[ "\$2" == *"/labels" ]] && [[ "\$*" == *"--paginate"* ]] && [[ "\$*" != *"-f "* ]] && [[ "\$*" != *"-X "* ]]; then
  printf '%s\n' "area/api" "area/cli" "priority/high" "component/parser"
  exit 0
fi

# gh pr edit ... --remove-label risk/* → log and succeed
if [[ "\$1" == "pr" ]] && [[ "\$2" == "edit" ]] && [[ "\$*" == *"--remove-label"* ]] && [[ "\$*" == *"risk/"* ]]; then
  echo "gh \$*" >> "${GH_LOG}"
  exit 0
fi

# gh label create risk/* → log and succeed
if [[ "\$1" == "label" ]] && [[ "\$2" == "create" ]] && [[ "\$3" == risk/* ]]; then
  echo "gh \$*" >> "${GH_LOG}"
  exit 0
fi

# Log all other calls
echo "gh \$*" >> "${GH_LOG}"
MOCKEOF
chmod +x "${MOCK_BIN}/gh"

# Mock sleep: no-op. The empty-PR-files retry branch in post-review.sh
# calls `sleep 10` before re-fetching; without this mock the real sleep
# runs in every empty-list integration test, adding ~10s each to a
# serial suite run. The retry logic doesn't depend on real elapsed time.
cat > "${MOCK_BIN}/sleep" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${MOCK_BIN}/sleep"

cat > "${MOCK_BIN}/fullsend" <<MOCKEOF
#!/usr/bin/env bash
# Mock fullsend: log the call, consume stdin if --result - is used,
# and copy the result file so tests can inspect the body.
PREV=""
for arg in "\$@"; do
  if [[ "\${PREV}" == "--result" ]]; then
    if [[ "\${arg}" == "-" ]]; then
      cat > "${TMPDIR}/last-result.json"
    elif [[ -f "\${arg}" ]]; then
      cp "\${arg}" "${TMPDIR}/last-result.json"
    fi
  fi
  PREV="\${arg}"
done
echo "fullsend \$*" >> "${GH_LOG}"
MOCKEOF
chmod +x "${MOCK_BIN}/fullsend"

# Mock curl for GitLab forge tests — returns canned responses for
# GitLab REST API endpoints used by gitlab-review-ops.lib.sh.
cat > "${MOCK_BIN}/curl" <<MOCKEOF
#!/usr/bin/env bash
# Mock curl: handle GitLab API endpoints, log everything else.

URL=""
METHOD="GET"
for arg in "\$@"; do
  case "\${arg}" in
    https://*) URL="\${arg}" ;;
  esac
done
# Extract explicit --request METHOD
PREV=""
for arg in "\$@"; do
  if [[ "\${PREV}" == "--request" ]] || [[ "\${PREV}" == "-X" ]]; then
    METHOD="\${arg}"
  fi
  PREV="\${arg}"
done

# PUT /merge_requests/:iid (add/remove labels) → success
if [[ "\${METHOD}" == "PUT" ]]; then
  echo '{}'
  exit 0
fi

# POST /merge_requests/:iid/notes → success
if [[ "\${METHOD}" == "POST" ]]; then
  echo '{"id":1}'
  exit 0
fi

# GET /merge_requests/:iid/approvals
if [[ "\${URL}" == *"/approvals"* ]]; then
  if [[ -n "\${MOCK_MR_APPROVALS_FAIL:-}" ]]; then
    echo "mock curl approvals failure" >&2
    exit 1
  fi
  if [[ -n "\${MOCK_MR_APPROVALS_JSON:-}" ]]; then
    echo "\${MOCK_MR_APPROVALS_JSON}"
  else
    echo '{"approved":false,"approved_by":[]}'
  fi
  exit 0
fi

# GET /members/all/:id
if [[ "\${URL}" == *"/members/all/"* ]]; then
  if [[ -n "\${MOCK_MR_MEMBER_FAIL:-}" ]]; then
    echo "mock curl member failure" >&2
    exit 1
  fi
  LEVEL="\${MOCK_MR_ACCESS_LEVEL:-40}"
  echo "{\"access_level\":\${LEVEL}}"
  exit 0
fi

# GET /merge_requests/:iid/versions → diff versions. Used to bind the
# authorized-human-approval override to GitLab's own record of when the
# current HEAD SHA became the MR's HEAD, instead of the commit's
# committer date (not push-ordered). Page-aware so tests can exercise
# pagination: MOCK_MR_VERSIONS_JSON_PAGE<N> overrides a specific page;
# MOCK_MR_VERSIONS_JSON only seeds page 1; unset pages beyond page 1
# default to an empty array (end of pagination).
if [[ "\${URL}" == *"/merge_requests/"* ]] && [[ "\${URL}" == *"/versions"* ]]; then
  if [[ -n "\${MOCK_MR_VERSIONS_FAIL:-}" ]]; then
    echo "mock curl versions failure" >&2
    exit 1
  fi
  VPAGE=\$(printf '%s' "\${URL}" | sed -nE 's/.*[?&]page=([0-9]+).*/\1/p')
  [[ -z "\${VPAGE}" ]] && VPAGE=1
  VPAGE_VAR="MOCK_MR_VERSIONS_JSON_PAGE\${VPAGE}"
  if [[ -n "\${!VPAGE_VAR:-}" ]]; then
    echo "\${!VPAGE_VAR}"
  elif [[ "\${VPAGE}" == "1" ]]; then
    if [[ -n "\${MOCK_MR_VERSIONS_JSON:-}" ]]; then
      echo "\${MOCK_MR_VERSIONS_JSON}"
    else
      SHA="\${MOCK_MR_SHA:-abc123}"
      CREATED_AT="\${MOCK_MR_VERSION_CREATED_AT:-2024-01-01T00:00:00.000Z}"
      printf '[{"head_commit_sha":"%s","created_at":"%s"}]\n' "\${SHA}" "\${CREATED_AT}"
    fi
  else
    echo '[]'
  fi
  exit 0
fi

# GET /merge_requests/:iid/notes → discussion notes (approval system notes)
if [[ "\${URL}" == *"/merge_requests/"* ]] && [[ "\${URL}" == *"/notes"* ]]; then
  if [[ -n "\${MOCK_MR_NOTES_FAIL:-}" ]]; then
    echo "mock curl notes failure" >&2
    exit 1
  fi
  if [[ -n "\${MOCK_MR_NOTES_JSON:-}" ]]; then
    echo "\${MOCK_MR_NOTES_JSON}"
  else
    NOTE_AUTHOR="\${MOCK_MR_NOTE_AUTHOR:-alice}"
    printf '[{"system":true,"body":"approved this merge request","author":{"username":"%s"},"created_at":"2024-06-01T00:00:00.000Z"}]\n' "\${NOTE_AUTHOR}"
  fi
  exit 0
fi

# GET /merge_requests/:iid → MR metadata. Called once from forge_get_pr_info
# up front, then twice more inside forge_has_authorized_human_approval (the
# initial read and the TOCTOU re-fetch) — a call counter lets the mock
# simulate the HEAD SHA moving between those last two reads.
if [[ "\${URL}" == *"/merge_requests/"* ]] && [[ "\${URL}" != *"/notes"* ]] && [[ "\${URL}" != *"/changes"* ]] && [[ "\${URL}" != *"/labels"* ]] && [[ "\${URL}" != *"/approvals"* ]] && [[ "\${URL}" != *"/versions"* ]]; then
  COUNT_FILE=".gitlab-mr-fetch-count"
  MR_FETCH_COUNT=0
  [[ -f "\${COUNT_FILE}" ]] && MR_FETCH_COUNT="\$(cat "\${COUNT_FILE}")"
  MR_FETCH_COUNT=\$((MR_FETCH_COUNT + 1))
  echo "\${MR_FETCH_COUNT}" > "\${COUNT_FILE}"

  DRAFT="\${MOCK_MR_IS_DRAFT:-false}"
  AUTHOR="\${MOCK_MR_AUTHOR:-testuser}"
  SHA="\${MOCK_MR_SHA:-abc123}"
  if [[ "\${MR_FETCH_COUNT}" -ge 3 ]]; then
    if [[ -n "\${MOCK_MR_REFETCH_FAIL:-}" ]]; then
      echo "mock curl mr refetch failure" >&2
      exit 1
    fi
    SHA="\${MOCK_MR_SHA_REFETCH:-\${SHA}}"
  fi
  printf '{"state":"opened","draft":%s,"author":{"username":"%s"},"iid":99,"sha":"%s"}\n' "\${DRAFT}" "\${AUTHOR}" "\${SHA}"
  exit 0
fi

# GET /merge_requests/:iid/changes → changed files
if [[ "\${URL}" == *"/changes"* ]]; then
  if [[ -n "\${MOCK_MR_FILES_FAIL:-}" ]]; then
    echo "mock curl failure" >&2
    exit 1
  fi
  echo '{"changes":[{"new_path":"'"\${MOCK_MR_FILES:-src/main.go}"'"}]}'
  exit 0
fi

# GET /labels → repo labels
if [[ "\${URL}" == *"/labels"* ]] && [[ "\${URL}" != *"/merge_requests/"* ]]; then
  echo '[{"name":"area/api"},{"name":"area/cli"},{"name":"priority/high"},{"name":"component/parser"}]'
  exit 0
fi

echo "curl \$*" >> "${GH_LOG}"
MOCKEOF
chmod +x "${MOCK_BIN}/curl"

# ---------------------------------------------------------------------------
# GitLab forge integration tests
# ---------------------------------------------------------------------------

run_gitlab_label_test() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-gitlab-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-group/test-project"
    export PR_URL="https://gitlab.com/test-group/test-project/-/merge_requests/99"
    export CI_SERVER_HOST="gitlab.com"
    export FULLSEND_FORGE="gitlab"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — expected pattern '${expected_pattern}' not found in calls"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_gitlab_label_test_stdout() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-gitlab-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-group/test-project"
    export PR_URL="https://gitlab.com/test-group/test-project/-/merge_requests/99"
    export CI_SERVER_HOST="gitlab.com"
    export FULLSEND_FORGE="gitlab"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# GitLab: approve posts review via fullsend
run_gitlab_label_test "gitlab-approve-posts-review" \
  '{"action":"approve","pr_number":99,"repo":"test-group/test-project","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM"}' \
  "fullsend post-review --forge gitlab"

# GitLab: label_actions applied
run_gitlab_label_test_stdout "gitlab-label-actions-applied" \
  '{"action":"approve","pr_number":99,"repo":"test-group/test-project","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"Touches API surface.","actions":[{"action":"add","label":"area/api"}]}}' \
  "Adding contextual label 'area/api'"

# GitLab: control label refused
run_gitlab_label_test_stdout "gitlab-control-label-refused" \
  '{"action":"approve","pr_number":99,"repo":"test-group/test-project","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"Tried to set control label.","actions":[{"action":"add","label":"ready-for-merge"}]}}' \
  "::warning::Refused to add control label 'ready-for-merge'"

# GitLab: no label_actions field works without errors
run_gitlab_label_test "gitlab-no-label-actions-still-posts" \
  '{"action":"approve","pr_number":99,"repo":"test-group/test-project","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM"}' \
  "fullsend post-review"

run_gitlab_pr_files_fetch_error_fails_closed_test() {
  local test_name="gitlab-pr-files-fetch-error-fails-closed"
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo '{"action":"approve","pr_number":99,"repo":"test-group/test-project","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM"}' > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-gitlab-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-group/test-project"
    export PR_URL="https://gitlab.com/test-group/test-project/-/merge_requests/99"
    export CI_SERVER_HOST="gitlab.com"
    export FULLSEND_FORGE="gitlab"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export MOCK_MR_FILES_FAIL="1"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -qF "retrying once in case of a transient forge data race" "${TMPDIR}/stdout-${test_name}.log" || \
     ! grep -qF "Failed to fetch PR files or PR has no changed files" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected retry and fail-closed messages"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}
run_gitlab_pr_files_fetch_error_fails_closed_test

run_label_test() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — expected pattern '${expected_pattern}' not found in gh calls"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_label_test_stdout() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_label_test_no_pattern() {
  local test_name="$1"
  local json_content="$2"
  local forbidden_pattern="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF -- "${forbidden_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — forbidden pattern '${forbidden_pattern}' was found in gh calls"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# --- Label actions integration tests ---

# Approve with label_actions — label should be added via API
run_label_test "label-actions-applied" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"PR modifies API surface.","actions":[{"action":"add","label":"area/api"}]}}' \
  "gh api repos/test-org/test-repo/issues/99/labels -f labels[]=area/api --silent"

# Control label refused — should NOT call the labels API for it
run_label_test_stdout "label-actions-control-label-refused" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"Tried to set control label.","actions":[{"action":"add","label":"ready-for-merge"}]}}' \
  "::warning::Refused to add control label 'ready-for-merge'"

# Non-existent label skipped — label "bug" is not in mock label list
run_label_test_stdout "label-actions-nonexistent-label-skipped" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"Agent recommended a label that does not exist.","actions":[{"action":"add","label":"bug"}]}}' \
  "::warning::Skipping label 'bug'"

# Invalid characters refused
run_label_test_stdout "label-actions-invalid-characters-refused" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"Injection attempt.","actions":[{"action":"add","label":"label;injection"}]}}' \
  "::warning::Refused label 'label;injection'"

# Remove label — should call DELETE
run_label_test "label-actions-remove" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"Stale area label removed.","actions":[{"action":"remove","label":"area/cli"}]}}' \
  "gh api repos/test-org/test-repo/issues/99/labels/area%2Fcli -X DELETE --silent"

# Multiple adds — both should be applied
run_label_test "label-actions-multiple-add" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"Multiple labels apply.","actions":[{"action":"add","label":"area/api"},{"action":"add","label":"priority/high"}]}}' \
  "gh api repos/test-org/test-repo/issues/99/labels -f labels[]=area/api --silent"

run_label_test "label-actions-multiple-second-label" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"Multiple labels apply.","actions":[{"action":"add","label":"area/api"},{"action":"add","label":"priority/high"}]}}' \
  "gh api repos/test-org/test-repo/issues/99/labels -f labels[]=priority/high --silent"

# When all label actions are refused, reason should NOT appear in the review body
run_label_test_no_pattern "label-actions-all-refused-no-body-append" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"Should not appear.","actions":[{"action":"add","label":"ready-for-merge"}]}}' \
  "labels[]=ready-for-merge"

# No label_actions field — should still post review without errors
run_label_test "label-actions-absent-still-posts" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM"}' \
  "fullsend post-review"

# request-changes with label_actions — labels should still be applied
run_label_test "label-actions-with-request-changes" \
  '{"action":"request-changes","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Issues found","findings":[{"severity":"high","category":"bug","file":"main.go","description":"nil deref"}],"label_actions":{"reason":"Touches CI config.","actions":[{"action":"add","label":"area/api"}]}}' \
  "gh api repos/test-org/test-repo/issues/99/labels -f labels[]=area/api --silent"

# Label with embedded newline (GHA command injection attempt) — should be refused
run_label_test_stdout "label-actions-newline-injection-refused" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"Injection.","actions":[{"action":"add","label":"ok\n::set-output name=x::pwned"}]}}' \
  "::warning::Refused label"

# Label with :: delimiter (GHA command injection attempt) — :: is sanitized to :,
# so the label becomes ":warning:injected" which passes the character regex but
# does not exist in the repo. The important thing is the :: is stripped.
run_label_test_stdout "label-actions-gha-delimiter-sanitized" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM","label_actions":{"reason":"Injection.","actions":[{"action":"add","label":"::warning::injected"}]}}' \
  "::warning::Skipping label ':warning:injected'"

# --- Severity filtering integration tests ---
# These invoke the real post-review.sh with REVIEW_FINDING_SEVERITY_THRESHOLD
# set to a non-default value, exercising the production severity_rank() and jq
# filter rather than the mirrored copies above.

run_label_test_with_env() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"
  local env_var="$4"
  local env_val="$5"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export "${env_var}=${env_val}"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — expected pattern '${expected_pattern}' not found in gh calls"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_label_test_with_env "severity-filter-downgrade-integration" \
  '{"action":"request-changes","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Issues found","findings":[{"severity":"low","category":"style","file":"a.go","description":"minor"}]}' \
  "requires-manual-review" \
  "REVIEW_FINDING_SEVERITY_THRESHOLD" "medium"

# Verify stdout mentions the downgrade
run_label_test_with_env_stdout() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"
  local env_var="$4"
  local env_val="$5"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export "${env_var}=${env_val}"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_label_test_with_env_stdout "severity-filter-downgrade-log-message" \
  '{"action":"request-changes","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Issues found","findings":[{"severity":"low","category":"style","file":"a.go","description":"minor"}]}' \
  "All findings removed by severity filter" \
  "REVIEW_FINDING_SEVERITY_THRESHOLD" "medium"

# Actionable low findings below threshold → downgraded (threshold is absolute)
run_label_test_with_env_stdout "severity-filter-actionable-still-downgrades" \
  '{"action":"request-changes","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Issues found","findings":[{"severity":"low","category":"naming-convention","file":"a.go","description":"rename type","remediation":"rename FooBar to fooBar","actionable":true}]}' \
  "All findings removed by severity filter" \
  "REVIEW_FINDING_SEVERITY_THRESHOLD" "medium"

# Non-actionable low findings below threshold → downgraded
run_label_test_with_env_stdout "severity-filter-non-actionable-downgrades" \
  '{"action":"request-changes","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Issues found","findings":[{"severity":"low","category":"style","file":"a.go","description":"minor","actionable":false}]}' \
  "All findings removed by severity filter" \
  "REVIEW_FINDING_SEVERITY_THRESHOLD" "medium"

# --- Severity-threshold sanitization tests ---
# Invalid REVIEW_FINDING_SEVERITY_THRESHOLD values are echoed into a GHA
# `::error::` workflow command. Verify the sanitizer neutralizes both
# raw `::` sequences and URL-encoded newlines rather than being bypassable.

run_severity_sanitize_test() {
  local test_name="$1"
  local threshold_value="$2"
  local expected_pattern="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abc123","body":"LGTM"}' \
    > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="${threshold_value}"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit for invalid threshold"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_pattern}" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected stdout '${expected_pattern}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# ':::error:::injected' collapses to '::error::injected' under a single
# non-overlapping '::' -> ':' pass, reviving a live workflow-command
# delimiter. Full colon-stripping must leave no '::' in the sanitized value.
run_severity_sanitize_test "severity-threshold-non-idempotent-colon-collapse" \
  ":::error:::injected" \
  "REVIEW_FINDING_SEVERITY_THRESHOLD='errorinjected' is invalid"

# URL-encoded newlines are interpreted by GHA as literal newlines in
# workflow command parameters. Stripping the '%' character (rather than the
# literal "%0A"/"%0D" tokens) neutralizes them without matching a specific
# case or leaving a way for adjacent fragments to reassemble the token.
run_severity_sanitize_test "severity-threshold-url-encoded-newline-upper" \
  "bad%0Ainjected" \
  "REVIEW_FINDING_SEVERITY_THRESHOLD='bad0Ainjected' is invalid"

run_severity_sanitize_test "severity-threshold-url-encoded-carriage-return-lower" \
  "bad%0dinjected" \
  "REVIEW_FINDING_SEVERITY_THRESHOLD='bad0dinjected' is invalid"

# Adjacent-fragment reassembly: stripping the literal 3-char token "%0a" from
# "%0%0aA" in a single pass leaves the surrounding "%0" + "A" fragments
# adjacent, spelling a live "%0A" — which GHA decodes as a literal newline.
# The sanitizer must not leave any '%' character behind, at any position.
run_severity_sanitize_test "severity-threshold-percent-adjacent-fragment-reassembly" \
  "%0%0aA" \
  "REVIEW_FINDING_SEVERITY_THRESHOLD='00aA' is invalid"

# --- Draft PR integration tests ---
# These invoke the real post-review.sh with MOCK_PR_IS_DRAFT=true to verify
# that draft PRs never receive the ready-for-merge label.

# Approve on a draft PR → requires-manual-review, NOT ready-for-merge
run_label_test_with_env "draft-approve-gets-manual-review" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM"}' \
  "requires-manual-review" \
  "MOCK_PR_IS_DRAFT" "true"

# Approve on a draft PR → stdout should mention draft skip
run_label_test_with_env_stdout "draft-approve-log-message" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM"}' \
  "PR is a draft" \
  "MOCK_PR_IS_DRAFT" "true"

# ---------------------------------------------------------------------------
# FULLSEND_VALIDATED_ITERATION_DIR tests
# Verify that when FULLSEND_VALIDATED_ITERATION_DIR is set, the script reads
# from that directory instead of scanning iteration-*/output.
# ---------------------------------------------------------------------------

run_validated_dir_test() {
  local test_name="$1"
  local setup_fn="$2"
  local expected_pattern="$3"
  local expect_failure="${4:-false}"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}"
  : > "${GH_LOG}"

  # Let the setup function arrange files and set env vars.
  local validated_dir="${run_dir}/validated-output"
  ${setup_fn} "${run_dir}" "${validated_dir}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export FULLSEND_VALIDATED_ITERATION_DIR="${validated_dir}"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure)"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_pattern}" ]] && ! grep -qF -- "${expected_pattern}" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected stdout '${expected_pattern}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Setup: validated dir has agent-result.json
setup_validated_dir_expected_filename() {
  local run_dir="$1"
  local validated_dir="$2"
  mkdir -p "${validated_dir}"
  echo '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM"}' \
    > "${validated_dir}/agent-result.json"
  # Also put a DIFFERENT result in iteration-2 to verify it's NOT used.
  mkdir -p "${run_dir}/iteration-2/output"
  echo '{"action":"reject","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"BAD"}' \
    > "${run_dir}/iteration-2/output/agent-result.json"
}

# Setup: validated dir has only result.json (fallback filename)
setup_validated_dir_fallback_filename() {
  local run_dir="$1"
  local validated_dir="$2"
  mkdir -p "${validated_dir}"
  echo '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM"}' \
    > "${validated_dir}/result.json"
}

# Setup: validated dir has neither filename
setup_validated_dir_neither_filename() {
  local run_dir="$1"
  local validated_dir="$2"
  mkdir -p "${validated_dir}"
  # Empty directory — no result files at all.
}

run_validated_dir_test "validated-dir-expected-filename" \
  setup_validated_dir_expected_filename \
  "Using result: ${TMPDIR}/run-validated-dir-expected-filename/validated-output/agent-result.json"

run_validated_dir_test "validated-dir-fallback-filename" \
  setup_validated_dir_fallback_filename \
  "Using result: ${TMPDIR}/run-validated-dir-fallback-filename/validated-output/result.json"

run_validated_dir_test "validated-dir-neither-filename" \
  setup_validated_dir_neither_filename \
  "" \
  "true"

# --- No-op label cycle tests ---
# Verify the stale-label loop skips the label we are about to apply.
# When approve disposition is chosen, ready-for-merge must NOT appear in
# a --remove-label call.
run_label_test_no_pattern "no-op-skip-ready-for-merge-removal" \
  '{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"LGTM"}' \
  "--remove-label ready-for-merge"

# ---------------------------------------------------------------------------
# Body-content tests: verify the assembled body passed to fullsend post-review
# ---------------------------------------------------------------------------

run_body_test() {
  local test_name="$1"
  local json_content="$2"
  local expected_body_pattern="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  rm -f "${TMPDIR}/last-result.json"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ ! -f "${TMPDIR}/last-result.json" ]]; then
    echo "FAIL: ${test_name} — no result file captured"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local body
  body="$(jq -r '.body' "${TMPDIR}/last-result.json")"
  if ! echo "${body}" | grep -qF "${expected_body_pattern}"; then
    echo "FAIL: ${test_name} — expected body pattern '${expected_body_pattern}' not found"
    echo "Actual body:"
    echo "${body}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_body_count_test() {
  local test_name="$1"
  local json_content="$2"
  local pattern="$3"
  local expected_count="$4"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  rm -f "${TMPDIR}/last-result.json"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ ! -f "${TMPDIR}/last-result.json" ]]; then
    echo "FAIL: ${test_name} — no result file captured"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local body
  body="$(jq -r '.body' "${TMPDIR}/last-result.json")"
  local actual_count
  actual_count="$(echo "${body}" | grep -cF -- "${pattern}" || true)"

  if [[ "${actual_count}" -ne "${expected_count}" ]]; then
    echo "FAIL: ${test_name} — expected ${expected_count} occurrences of '${pattern}', found ${actual_count}"
    echo "Actual body:"
    echo "${body}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# request-changes + label_actions → body has label notice (---) AND action-hints footer (---)
LABEL_PLUS_HINTS_JSON='{"action":"request-changes","pr_number":99,"repo":"test-org/test-repo","head_sha":"abcdef0123456789abcdef0123456789abcdef01","body":"Issues found","findings":[{"severity":"high","category":"bug","file":"main.go","description":"nil deref"}],"label_actions":{"reason":"Touches API surface.","actions":[{"action":"add","label":"area/api"}]}}'

run_body_count_test "label-actions-plus-action-hints-two-hrs" \
  "${LABEL_PLUS_HINTS_JSON}" "---" "2"

run_body_test "label-actions-plus-action-hints-has-labels-section" \
  "${LABEL_PLUS_HINTS_JSON}" "**Labels:** Touches API surface."

run_body_test "label-actions-plus-action-hints-has-next-steps" \
  "${LABEL_PLUS_HINTS_JSON}" "**Next steps:**"

# ---------------------------------------------------------------------------
# REVIEW_PROTECTED_PATHS override tests
# Verify that setting REVIEW_PROTECTED_PATHS overrides the default list.
# ---------------------------------------------------------------------------

# Helper that sets two env vars (reuses run_label_test_with_env pattern but
# needs two env vars: REVIEW_PROTECTED_PATHS + MOCK_PR_FILES).
run_protected_paths_test() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"
  local match_mode="$4"  # "present" or "absent"
  local protected_paths="$5"
  local mock_files="$6"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export MOCK_PR_FILES="${mock_files}"
    if [[ -n "${protected_paths}" ]]; then
      export REVIEW_PROTECTED_PATHS="${protected_paths}"
    else
      unset REVIEW_PROTECTED_PATHS
    fi
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ "${match_mode}" == "present" ]]; then
    if ! grep -qF -- "${expected_pattern}" "${TMPDIR}/stdout-${test_name}.log"; then
      echo "FAIL: ${test_name} — expected '${expected_pattern}' in stdout"
      echo "Actual stdout:"
      cat "${TMPDIR}/stdout-${test_name}.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
  else
    if grep -qF -- "${expected_pattern}" "${TMPDIR}/stdout-${test_name}.log"; then
      echo "FAIL: ${test_name} — '${expected_pattern}' should NOT be in stdout"
      echo "Actual stdout:"
      cat "${TMPDIR}/stdout-${test_name}.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

APPROVE_JSON='{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abc123","body":"LGTM"}'

# Custom REVIEW_PROTECTED_PATHS: .github/ is no longer protected
run_protected_paths_test "custom-paths-removes-default" \
  "${APPROVE_JSON}" "PR touches protected paths" "absent" \
  "deploy/,manifests/" ".github/workflows/ci.yml"

# Custom REVIEW_PROTECTED_PATHS: deploy/ is now protected
run_protected_paths_test "custom-paths-adds-new" \
  "${APPROVE_JSON}" "PR touches protected paths" "present" \
  "deploy/,manifests/" "deploy/production.yaml"

# Custom REVIEW_PROTECTED_PATHS with whitespace around entries
run_protected_paths_test "custom-paths-whitespace-trimmed" \
  "${APPROVE_JSON}" "PR touches protected paths" "present" \
  " deploy/ , manifests/ " "deploy/production.yaml"

# Custom REVIEW_PROTECTED_PATHS: non-matching file is not protected
run_protected_paths_test "custom-paths-no-match" \
  "${APPROVE_JSON}" "PR touches protected paths" "absent" \
  "deploy/,manifests/" "src/main.go"

# Default list: pi agent settings (.pi/) are protected like .claude/ (#935)
run_protected_paths_test "default-paths-pi-protected" \
  "${APPROVE_JSON}" "PR touches protected paths" "present" \
  "${DEFAULT_PROTECTED_PATHS}" ".pi/settings.json"

# Default list: .gitignore changes require human review (#850)
run_protected_paths_test "default-paths-gitignore-protected" \
  "${APPROVE_JSON}" "PR touches protected paths" "present" \
  "${DEFAULT_PROTECTED_PATHS}" ".gitignore"

# Default list: a file merely named like the prefix is not protected
run_protected_paths_test "default-paths-pi-prefix-not-substring" \
  "${APPROVE_JSON}" "PR touches protected paths" "absent" \
  "${DEFAULT_PROTECTED_PATHS}" "docs/.pi/notes.md"

# Empty entries from leading/trailing/consecutive commas must not match all files
run_protected_paths_test "custom-paths-empty-entries-ignored" \
  "${APPROVE_JSON}" "PR touches protected paths" "absent" \
  ",deploy/,,manifests/," "src/main.go"

# Empty entries still allow valid entries to match
run_protected_paths_test "custom-paths-empty-entries-valid-match" \
  "${APPROVE_JSON}" "PR touches protected paths" "present" \
  ",deploy/,,manifests/," "deploy/production.yaml"

# Abort when REVIEW_PROTECTED_PATHS is unset. harness/review.yaml always
# sets it (with a default, overridable per-repo via harness composition),
# so an unset value on an approve indicates a genuine misconfiguration.
run_unset_env_var_test() {
  local test_name="unset-env-var-aborts"
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${APPROVE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    unset REVIEW_PROTECTED_PATHS
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "REVIEW_PROTECTED_PATHS is not set" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected abort message in stderr"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}
run_unset_env_var_test

# Degenerate REVIEW_PROTECTED_PATHS that trims to empty must abort (fail-closed).
run_empty_paths_test() {
  local test_name="degenerate-paths-aborts"
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${APPROVE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export REVIEW_PROTECTED_PATHS=",,, ,"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "likely misconfigured" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected misconfiguration abort message in stderr"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF 'REVIEW_PROTECTED_PATHS=",,, ,"' "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected abort message to include the raw value"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}
run_empty_paths_test

# Non-approve action must succeed even with degenerate REVIEW_PROTECTED_PATHS.
run_nonapprove_degenerate_test() {
  local test_name="nonapprove-degenerate-paths-succeeds"
  local comment_json='{"action":"comment","pr_number":99,"repo":"test-org/test-repo","head_sha":"abc123","body":"Looks good overall."}'
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${comment_json}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export REVIEW_PROTECTED_PATHS=",,, ,"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected success but got exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}
run_nonapprove_degenerate_test

# Non-approve action must succeed even when REVIEW_PROTECTED_PATHS is unset —
# the protected-path block only runs for "approve".
run_nonapprove_unset_env_var_test() {
  local test_name="nonapprove-unset-env-var-succeeds"
  local comment_json='{"action":"comment","pr_number":99,"repo":"test-org/test-repo","head_sha":"abc123","body":"Looks good overall."}'
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${comment_json}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    unset REVIEW_PROTECTED_PATHS
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected success but got exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}
run_nonapprove_unset_env_var_test

# Explicitly empty REVIEW_PROTECTED_PATHS="" disables protected-path
# enforcement entirely — this is a deliberate operator opt-out, distinct
# from the comma-noise case above (degenerate-paths-aborts), which is
# treated as a likely misconfiguration and fails closed instead.
run_explicit_empty_test() {
  local test_name="explicit-empty-string-disables-protection"
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${APPROVE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export REVIEW_PROTECTED_PATHS=""
    export MOCK_PR_FILES=".github/workflows/ci.yml"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected success but got exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "protected-path enforcement disabled" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected disabled-enforcement notice in output"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF "PR touches protected paths" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — approve should not be downgraded when protection is disabled"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}
run_explicit_empty_test

# The "PR has no changed files" safety net is independent of
# protected-path enforcement and must still apply even when an operator
# has explicitly opted out of protected-path enforcement.
run_empty_pr_files_with_protection_disabled_test() {
  local test_name="empty-pr-files-safety-net-independent-of-protected-paths"
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${APPROVE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export REVIEW_PROTECTED_PATHS=""
    export MOCK_PR_FILES=""
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "Failed to fetch PR files or PR has no changed files" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected empty-PR-files abort message in output"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}
run_empty_pr_files_with_protection_disabled_test

run_github_pr_files_fetch_error_fails_closed_test() {
  local test_name="github-pr-files-fetch-error-fails-closed"
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${APPROVE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export REVIEW_PROTECTED_PATHS=""
    export MOCK_PR_FILES_FAIL="1"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -qF "retrying once in case of a transient forge data race" "${TMPDIR}/stdout-${test_name}.log" || \
     ! grep -qF "Failed to fetch PR files or PR has no changed files" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected retry and fail-closed messages"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}
run_github_pr_files_fetch_error_fails_closed_test

# forge_get_pr_files can transiently return an empty list right after a
# merge-commit update (fullsend-ai/fullsend#2093). The call site retries
# once before refusing to approve: a first-empty-then-populated response
# must recover and proceed rather than abort.
run_empty_pr_files_retry_recovers_test() {
  local test_name="empty-pr-files-retry-recovers"
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${APPROVE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  rm -f "${TMPDIR}/marker-${test_name}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export REVIEW_PROTECTED_PATHS=""
    # First files call returns empty, the retry returns a real file.
    export MOCK_PR_FILES_ON_RETRY="src/main.go"
    export MOCK_FILES_CALL_MARKER="${TMPDIR}/marker-${test_name}"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected success after retry recovered the file list"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "retrying once in case of a transient forge data race" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected retry notice in output"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF "Failed to fetch PR files or PR has no changed files" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — should not abort once the retry returned files"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}
run_empty_pr_files_retry_recovers_test

# When both the initial fetch and the retry come back empty, the safety
# net must still refuse to approve — the retry loosens the guard for
# transient races only, not for genuinely empty results.
run_empty_pr_files_retry_still_fails_test() {
  local test_name="empty-pr-files-retry-still-fails"
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${APPROVE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export REVIEW_PROTECTED_PATHS=""
    export MOCK_PR_FILES=""
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit when both attempts are empty"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "retrying once in case of a transient forge data race" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected the retry to be attempted before aborting"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "Failed to fetch PR files or PR has no changed files" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected empty-PR-files abort message after retry"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}
run_empty_pr_files_retry_still_fails_test

# The REVIEW_PROTECTED_PATHS default above is duplicated verbatim in
# harness/review.yaml's env.runner/env.sandbox (there's no single structural
# source of truth since env/default-review-protected-paths.txt was removed).
# Guard against silent drift: if a future edit updates one copy and misses
# another, this test suite would otherwise keep passing against a stale
# default. Skips (doesn't fail) when yq is unavailable, matching the
# fallback pattern in post-triage.sh.
run_protected_paths_default_drift_test() {
  local test_name="protected-paths-default-matches-harness-review-yaml"

  if ! command -v yq &>/dev/null; then
    echo "SKIP: ${test_name} — yq not found"
    return
  fi

  local harness_file="${SCRIPT_DIR}/../harness/review.yaml"
  local runner_default sandbox_default
  runner_default="$(yq -r '.env.runner.REVIEW_PROTECTED_PATHS' "${harness_file}")"
  sandbox_default="$(yq -r '.env.sandbox.REVIEW_PROTECTED_PATHS' "${harness_file}")"

  # shellcheck disable=SC2030,SC2031
  if [[ "${runner_default}" != "${REVIEW_PROTECTED_PATHS}" ]]; then
    echo "FAIL: ${test_name} — harness/review.yaml env.runner.REVIEW_PROTECTED_PATHS does not match this test file's default"
    echo "  harness/review.yaml: ${runner_default}"
    echo "  post-review-test.sh: ${REVIEW_PROTECTED_PATHS}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # shellcheck disable=SC2030,SC2031
  if [[ "${sandbox_default}" != "${REVIEW_PROTECTED_PATHS}" ]]; then
    echo "FAIL: ${test_name} — harness/review.yaml env.sandbox.REVIEW_PROTECTED_PATHS does not match this test file's default"
    echo "  harness/review.yaml: ${sandbox_default}"
    echo "  post-review-test.sh: ${REVIEW_PROTECTED_PATHS}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}
run_protected_paths_default_drift_test

# ---------------------------------------------------------------------------
# Human-approval override for protected-path downgrades
# ---------------------------------------------------------------------------
# When the agent approves a PR that touches protected paths, the post-script
# normally applies requires-manual-review. If an authorized human has already
# approved the current HEAD, the outcome is ready-for-merge instead.

HUMAN_APPROVAL_HEAD_SHA="abc123"
HUMAN_APPROVAL_REVIEWS='[{"state":"APPROVED","commit_id":"abc123","user":{"login":"alice","type":"User"},"submitted_at":"2026-01-01T00:00:00Z"}]'

run_human_approval_test() {
  local test_name="$1"
  local expected_pattern="$2"
  local match_where="$3"  # "log" (GH_LOG) or "stdout"
  shift 3

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${APPROVE_JSON}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-org/test-repo"
    export PR_URL="https://github.com/test-org/test-repo/pull/99"
    export FULLSEND_FORGE="github"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export REVIEW_PROTECTED_PATHS="${DEFAULT_PROTECTED_PATHS}"
    export MOCK_PR_FILES="scripts/post-review.src.sh"
    export MOCK_PR_HEAD_SHA="${HUMAN_APPROVAL_HEAD_SHA}"
    export MOCK_PR_AUTHOR="bob"
    for assignment in "$@"; do
      name="${assignment%%=*}"
      value="${assignment#*=}"
      printf -v "${name}" '%s' "${value}"
      export "${name?}"
    done
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local haystack
  if [[ "${match_where}" == "stdout" ]]; then
    haystack="${TMPDIR}/stdout-${test_name}.log"
  else
    haystack="${GH_LOG}"
  fi
  if ! grep -qF -- "${expected_pattern}" "${haystack}"; then
    echo "FAIL: ${test_name} — expected '${expected_pattern}' in ${match_where}"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout-${test_name}.log"
    echo "Actual gh calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Happy path: reviewDecision APPROVED + human write approval on HEAD
run_human_approval_test "human-approval-on-head-ready-for-merge" \
  "--add-label ready-for-merge" "log" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_JSON=${HUMAN_APPROVAL_REVIEWS}" \
  "MOCK_COLLABORATOR_ROLE=write"

run_human_approval_test "human-approval-on-head-log-message" \
  "Protected-path requirement satisfied by authorized human approval" "stdout" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_JSON=${HUMAN_APPROVAL_REVIEWS}" \
  "MOCK_COLLABORATOR_ROLE=write"

# Stale SHA: approval is on a different commit than current HEAD
run_human_approval_test "human-approval-stale-sha-manual-review" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_JSON=[{\"state\":\"APPROVED\",\"commit_id\":\"oldsha\",\"user\":{\"login\":\"alice\",\"type\":\"User\"},\"submitted_at\":\"2026-01-01T00:00:00Z\"}]" \
  "MOCK_COLLABORATOR_ROLE=write"

# Bot-only approval (type=Bot)
run_human_approval_test "human-approval-bot-type-manual-review" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_JSON=[{\"state\":\"APPROVED\",\"commit_id\":\"abc123\",\"user\":{\"login\":\"some-app[bot]\",\"type\":\"Bot\"},\"submitted_at\":\"2026-01-01T00:00:00Z\"}]" \
  "MOCK_COLLABORATOR_ROLE=write"

# OAuth-style bot: type=User but login ends with [bot]
run_human_approval_test "human-approval-bot-login-manual-review" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_JSON=[{\"state\":\"APPROVED\",\"commit_id\":\"abc123\",\"user\":{\"login\":\"some-app[bot]\",\"type\":\"User\"},\"submitted_at\":\"2026-01-01T00:00:00Z\"}]" \
  "MOCK_COLLABORATOR_ROLE=write"

# No reviews at all
run_human_approval_test "human-approval-no-reviews-manual-review" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_JSON=[]"

# reviewDecision CHANGES_REQUESTED even with a human APPROVED row
run_human_approval_test "human-approval-changes-requested-manual-review" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION=CHANGES_REQUESTED" \
  "MOCK_REVIEWS_JSON=${HUMAN_APPROVAL_REVIEWS}" \
  "MOCK_COLLABORATOR_ROLE=write"

# Human approved but only has read permission
run_human_approval_test "human-approval-read-permission-manual-review" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_JSON=${HUMAN_APPROVAL_REVIEWS}" \
  "MOCK_COLLABORATOR_ROLE=read"

# Reviews API failure → fail closed
run_human_approval_test "human-approval-reviews-api-fail-closed" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_FAIL=1"

# reviewDecision fetch failure → fail closed
run_human_approval_test "human-approval-decision-api-fail-closed" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION_FAIL=1"

# Permission API failure → fail closed
run_human_approval_test "human-approval-permission-api-fail-closed" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_JSON=${HUMAN_APPROVAL_REVIEWS}" \
  "MOCK_PERMISSION_FAIL=1"

# PR author approving their own PR does not count
run_human_approval_test "human-approval-self-approve-manual-review" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_PR_AUTHOR=alice" \
  "MOCK_REVIEWS_JSON=${HUMAN_APPROVAL_REVIEWS}" \
  "MOCK_COLLABORATOR_ROLE=write"

# Draft PR with human approval still requires-manual-review (check is skipped)
run_human_approval_test "human-approval-draft-manual-review" \
  "--add-label requires-manual-review" "log" \
  "MOCK_PR_IS_DRAFT=true" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_JSON=${HUMAN_APPROVAL_REVIEWS}" \
  "MOCK_COLLABORATOR_ROLE=write"

# TOCTOU: HEAD SHA changed between the first snapshot and the re-fetch
run_human_approval_test "human-approval-toctou-sha-changed" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_JSON=${HUMAN_APPROVAL_REVIEWS}" \
  "MOCK_COLLABORATOR_ROLE=write" \
  "MOCK_PR_HEAD_SHA_REFETCH=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# TOCTOU re-fetch API failure → fail closed (not fail open)
run_human_approval_test "human-approval-toctou-refetch-fail-closed" \
  "--add-label requires-manual-review" "log" \
  "MOCK_REVIEW_DECISION=APPROVED" \
  "MOCK_REVIEWS_JSON=${HUMAN_APPROVAL_REVIEWS}" \
  "MOCK_COLLABORATOR_ROLE=write" \
  "MOCK_HEAD_SHA_REFETCH_FAIL=1"

# ---------------------------------------------------------------------------
# GitLab human-approval override
# ---------------------------------------------------------------------------

run_gitlab_human_approval_test() {
  local test_name="$1"
  local expected_stdout="$2"
  shift 2

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo '{"action":"approve","pr_number":99,"repo":"test-group/test-project","head_sha":"abc123","body":"LGTM"}' \
    > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"

  local exit_code=0
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${MOCK_BIN}:${PATH}"
    export REVIEW_TOKEN="fake-gitlab-token"
    export PR_NUMBER="99"
    export REPO_FULL_NAME="test-group/test-project"
    export PR_URL="https://gitlab.com/test-group/test-project/-/merge_requests/99"
    export CI_SERVER_HOST="gitlab.com"
    export FULLSEND_FORGE="gitlab"
    export REVIEW_FINDING_SEVERITY_THRESHOLD="low"
    export REVIEW_PROTECTED_PATHS="${DEFAULT_PROTECTED_PATHS}"
    export MOCK_MR_FILES="scripts/post-review.src.sh"
    export MOCK_MR_SHA="abc123"
    export MOCK_MR_AUTHOR="bob"
    for assignment in "$@"; do
      name="${assignment%%=*}"
      value="${assignment#*=}"
      printf -v "${name}" '%s' "${value}"
      export "${name?}"
    done
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout-${test_name}.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout-${test_name}.log"; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout-${test_name}.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

GITLAB_APPROVED_JSON='{"approved":true,"approved_by":[{"user":{"id":2,"username":"alice","bot":false}}]}'

run_gitlab_human_approval_test "gitlab-human-approval-ready-for-merge" \
  "Protected-path requirement satisfied by authorized human approval" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=40"

run_gitlab_human_approval_test "gitlab-human-approval-not-approved" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON={\"approved\":false,\"approved_by\":[]}"

run_gitlab_human_approval_test "gitlab-human-approval-bot-only" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON={\"approved\":true,\"approved_by\":[{\"user\":{\"id\":1,\"username\":\"project_123_bot\",\"bot\":true}}]}"

run_gitlab_human_approval_test "gitlab-human-approval-guest-access" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=20"

run_gitlab_human_approval_test "gitlab-human-approval-api-fail-closed" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_FAIL=1"

# Approval note predates the current HEAD's push — the scenario the
# MR-level approved_by flag misses when a project disables
# reset_approvals_on_push: approved=true and approved_by persist across
# pushes, but the human never saw this commit. Analogous to GitHub's
# human-approval-stale-sha-manual-review. The MR version whose
# head_commit_sha matches current HEAD — GitLab's own record of when this
# SHA became MR HEAD — was created after the approval note, i.e. the human
# approved, then the branch was pushed again. This must fail closed even
# though the underlying commit object's own committer date (git metadata,
# not push-ordered) could still claim an earlier timestamp than the
# approval — that committer-date gap is exactly what the prior fail-open
# bug relied on; gate 3 no longer reads it at all.
run_gitlab_human_approval_test "gitlab-human-approval-stale-approval-manual-review" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=40" \
  "MOCK_MR_VERSION_CREATED_AT=2024-12-01T00:00:00.000Z"

# No diff version's head_commit_sha matches current HEAD → fail closed
run_gitlab_human_approval_test "gitlab-human-approval-no-matching-version-manual-review" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=40" \
  'MOCK_MR_VERSIONS_JSON=[{"head_commit_sha":"deadbeef","created_at":"2024-01-01T00:00:00.000Z"}]'

# Versions API failure → fail closed (not fail open)
run_gitlab_human_approval_test "gitlab-human-approval-versions-api-fail-closed" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=40" \
  "MOCK_MR_VERSIONS_FAIL=1"

# Versions pagination: an older version matching current HEAD sits on page 1
# (padded to a full 100-item page so the mock's "page returned < 100 → last
# page" pagination stop condition doesn't fire early), and a newer version
# also matching current HEAD only appears on page 2. Without consulting page
# 2, gate 3's threshold would be the older version's timestamp and the
# approval note below (dated between the two) would incorrectly satisfy it —
# the fail-open this pagination fix closes. With both pages consulted,
# version_epoch is the newer (page 2) timestamp, the note predates it, and
# the override must fail closed.
GITLAB_VERSIONS_PAGE1_OLD_MATCH=$(jq -nc '
  [range(99) | {head_commit_sha: ("filler-" + (. | tostring)), created_at: "2024-02-01T00:00:00.000Z"}]
  + [{head_commit_sha: "abc123", created_at: "2024-01-01T00:00:00.000Z"}]
')
run_gitlab_human_approval_test "gitlab-human-approval-versions-pagination-fail-closed" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=40" \
  "MOCK_MR_VERSIONS_JSON_PAGE1=${GITLAB_VERSIONS_PAGE1_OLD_MATCH}" \
  'MOCK_MR_VERSIONS_JSON_PAGE2=[{"head_commit_sha":"abc123","created_at":"2024-07-01T00:00:00.000Z"}]' \
  'MOCK_MR_NOTES_JSON=[{"system":true,"body":"approved this merge request","author":{"username":"alice"},"created_at":"2024-03-01T00:00:00.000Z"}]'

# Versions pagination hits the 50-page cap with the final page still full
# (100 items) — page 1 has an older version matching current HEAD (reusing
# the fixture above) and every subsequent page up to the cap is a full,
# non-matching filler page, so the loop never finds a short final page and
# exhausts version_max_pages instead. Without detecting that the cap (not a
# short page) ended pagination, gate 3 would compute version_epoch from the
# page-1 match alone and the approval note below — dated after it — would
# incorrectly satisfy the override, even though a newer matching version
# could exist past page 50. The fix must fail closed whenever the cap is
# hit with a full last page, regardless of what matched before the cap.
# Filler pages use bare `null` entries (rather than realistic version
# objects) purely to keep the accumulated `--argjson` payload well under
# the ~128KB single-argument exec limit across 49 filler pages — the
# `.head_commit_sha`/`.created_at` accesses in the gate-3 jq are null-safe
# for these entries, so they never match `$sha` and cannot mask what
# page 1's real fixture is exercising.
GITLAB_VERSIONS_FILLER_PAGE=$(jq -nc '[range(100) | null]')
GITLAB_VERSIONS_CAP_ARGS=("MOCK_MR_VERSIONS_JSON_PAGE1=${GITLAB_VERSIONS_PAGE1_OLD_MATCH}")
for gitlab_versions_cap_page in $(seq 2 50); do
  GITLAB_VERSIONS_CAP_ARGS+=("MOCK_MR_VERSIONS_JSON_PAGE${gitlab_versions_cap_page}=${GITLAB_VERSIONS_FILLER_PAGE}")
done
run_gitlab_human_approval_test "gitlab-human-approval-versions-cap-exceeded-fail-closed" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=40" \
  "${GITLAB_VERSIONS_CAP_ARGS[@]}" \
  'MOCK_MR_NOTES_JSON=[{"system":true,"body":"approved this merge request","author":{"username":"alice"},"created_at":"2024-03-01T00:00:00.000Z"}]'

# Happy path with non-"Z" offset timestamps (with and without milliseconds),
# matching GitLab's documented Commit/Note timestamp format. Guards against
# the normalization only ever being exercised by the mock's default
# "...000Z" fixtures — real GitLab responses can use an offset form like
# "+00:00" that the old `sub("\\.[0-9]+Z$"; "Z")` normalization silently
# failed to parse (fromdateiso8601 requires literal "Z"), so the approval
# override would never fire against a real API despite passing this suite.
run_gitlab_human_approval_test "gitlab-human-approval-offset-timestamps-ready-for-merge" \
  "Protected-path requirement satisfied by authorized human approval" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=40" \
  "MOCK_MR_VERSION_CREATED_AT=2024-01-01T00:00:00+00:00" \
  'MOCK_MR_NOTES_JSON=[{"system":true,"body":"approved this merge request","author":{"username":"alice"},"created_at":"2024-06-01T02:00:00.500+02:00"}]'

# Approval note timestamped in the same UTC second as, but milliseconds
# before, the matching MR version's created_at — the exact stale-approval
# scenario gate 3 exists to reject (approve, then push in the same second)
# when reset_approvals_on_push is disabled. Whole-second truncation used to
# discard the fractional component on both sides, so the note's epoch and
# the version's epoch floored to the same second and satisfied
# `approval_epoch >= version_epoch`, incorrectly treating a pre-push
# approval as covering the post-push HEAD. With millisecond-resolution
# comparison the note (.100) is strictly before the version (.900) and the
# override must fail closed.
run_gitlab_human_approval_test "gitlab-human-approval-subsecond-stale-approval-manual-review" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=40" \
  "MOCK_MR_VERSION_CREATED_AT=2024-06-01T12:00:00.900Z" \
  'MOCK_MR_NOTES_JSON=[{"system":true,"body":"approved this merge request","author":{"username":"alice"},"created_at":"2024-06-01T12:00:00.100Z"}]'

# PR author approving their own MR does not count
run_gitlab_human_approval_test "gitlab-human-approval-self-approve-manual-review" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=40" \
  "MOCK_MR_AUTHOR=alice"

# Member-permission lookup failure → fail closed
run_gitlab_human_approval_test "gitlab-human-approval-member-permission-fail-closed" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_MEMBER_FAIL=1"

# HEAD SHA changes between the initial read and the TOCTOU re-fetch → fail closed
run_gitlab_human_approval_test "gitlab-human-approval-sha-moved-manual-review" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=40" \
  "MOCK_MR_SHA_REFETCH=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# TOCTOU re-fetch API failure → fail closed (not fail open)
run_gitlab_human_approval_test "gitlab-human-approval-refetch-fail-closed" \
  "No authorized human approval on current HEAD" \
  "MOCK_MR_APPROVALS_JSON=${GITLAB_APPROVED_JSON}" \
  "MOCK_MR_ACCESS_LEVEL=40" \
  "MOCK_MR_REFETCH_FAIL=1"

# ---------------------------------------------------------------------------
# Risk assessment label + comment tests
# ---------------------------------------------------------------------------

# Result with risk_assessment → risk label applied
RISK_HIGH_RESULT='{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abc123","body":"LGTM","risk_assessment":{"score":4,"level":"high","rationale":"Auth middleware refactor.","tier1_signals":[{"dimension":"blast_radius","value":"large"}]}}'

run_label_test "risk-label-high-applied" \
  "${RISK_HIGH_RESULT}" \
  "gh label create risk/high"

# Result with risk_assessment → sticky comment posted
run_label_test "risk-comment-posted" \
  "${RISK_HIGH_RESULT}" \
  "fullsend post-comment"

# Stdout should mention risk label
run_label_test_stdout "risk-label-log-message" \
  "${RISK_HIGH_RESULT}" \
  "Applying risk/high label"

# Result WITHOUT risk_assessment → stale risk labels removed
APPROVE_NO_RISK='{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abc123","body":"LGTM"}'

run_label_test "risk-absent-stale-removal" \
  "${APPROVE_NO_RISK}" \
  "--remove-label risk/low"

run_label_test_no_pattern "risk-absent-no-create" \
  "${APPROVE_NO_RISK}" \
  "gh label create risk/"

# Result with risk_assessment level=low → risk/low label
RISK_LOW_RESULT='{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abc123","body":"LGTM","risk_assessment":{"score":1,"level":"low","rationale":"Typo fix."}}'

run_label_test "risk-label-low-applied" \
  "${RISK_LOW_RESULT}" \
  "gh label create risk/low"

# Risk labels work with request-changes too
RISK_RC_RESULT='{"action":"request-changes","pr_number":99,"repo":"test-org/test-repo","head_sha":"abc123","body":"Issues","findings":[{"severity":"high","category":"bug","file":"main.go","description":"nil deref"}],"risk_assessment":{"score":3,"level":"elevated","rationale":"Medium change."}}'

run_label_test "risk-label-with-request-changes" \
  "${RISK_RC_RESULT}" \
  "gh label create risk/elevated"

# Invalid risk level → warning, no risk label applied
RISK_INVALID_LEVEL='{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abc123","body":"LGTM","risk_assessment":{"score":3,"level":"bogus","rationale":"Bad level."}}'

run_label_test_stdout "risk-invalid-level-warning" \
  "${RISK_INVALID_LEVEL}" \
  "Invalid risk level"

run_label_test_no_pattern "risk-invalid-level-no-label" \
  "${RISK_INVALID_LEVEL}" \
  "gh label create risk/"

# Invalid risk score → warning but label still applied (level is valid)
RISK_INVALID_SCORE='{"action":"approve","pr_number":99,"repo":"test-org/test-repo","head_sha":"abc123","body":"LGTM","risk_assessment":{"score":99,"level":"high","rationale":"Bad score."}}'

run_label_test_stdout "risk-invalid-score-warning" \
  "${RISK_INVALID_SCORE}" \
  "Invalid risk score"

run_label_test "risk-invalid-score-label-still-applied" \
  "${RISK_INVALID_SCORE}" \
  "gh label create risk/high"

# Stale risk label removal — high result should remove other risk labels
run_label_test "risk-stale-label-removal" \
  "${RISK_HIGH_RESULT}" \
  "--remove-label risk/low"

# --- Summary ---

echo ""
if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
