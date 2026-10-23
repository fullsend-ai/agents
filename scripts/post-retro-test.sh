#!/usr/bin/env bash
# post-retro-test.sh — Test post-retro.sh with fixture JSON inputs.
#
# Uses mock gh/curl commands to capture calls without hitting real APIs.
# Run from the repo root: bash scripts/post-retro-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"

POST_SCRIPT="$(resolve_agent_script post-retro)"
FAILURES=0

# Create a temp directory for test fixtures and mock state.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# --- Mock gh ---
# GH_MOCK_COMMENT_FAIL controls how the mock responds to the comment-posting
# gh api call:
#   "" (empty/unset)  — succeed (exit 0)
#   "403"             — fail with HTTP 403
#   "401"             — fail with HTTP 401
#   "500"             — fail with HTTP 500
#   "422"             — fail with HTTP 422
GH_LOG="${TMPDIR}/gh-calls.log"
MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"
cat > "${MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
# Capture stdin if --input - is passed. Save to GH_STDIN_LOG for API calls
# so tests can inspect the request body. Fall back to /dev/null.
for arg in "$@"; do
  if [[ "${arg}" == "--input" ]]; then
    if [[ "$1" == "api" && -n "${GH_STDIN_LOG:-}" ]]; then
      cat >> "${GH_STDIN_LOG}"
    else
      cat > /dev/null
    fi
    break
  fi
done

echo "gh $*" >> "${GH_LOG}"

# Label creation calls — succeed silently (mimics --force behavior).
if [[ "$1" == "label" && "$2" == "create" ]]; then
  exit 0
fi

# Issue creation calls — return a fake issue URL, or fail when the --repo
# value matches GH_MOCK_ISSUE_FAIL_REPO ("*" fails every repo).
if [[ "$1" == "issue" && "$2" == "create" ]]; then
  ISSUE_REPO=""
  prev=""
  for arg in "$@"; do
    if [[ "${prev}" == "--repo" ]]; then
      ISSUE_REPO="${arg}"
    fi
    prev="${arg}"
  done
  if [[ -n "${GH_MOCK_ISSUE_FAIL_REPO:-}" ]] && \
     [[ "${GH_MOCK_ISSUE_FAIL_REPO}" == "*" || "${GH_MOCK_ISSUE_FAIL_REPO}" == "${ISSUE_REPO}" ]]; then
    echo "GraphQL: Could not resolve to a Repository with the name '${ISSUE_REPO}'. (repository)" >&2
    exit 1
  fi
  echo "https://github.com/${ISSUE_REPO}/issues/99"
  exit 0
fi

# Comment posting via gh api — controlled by GH_MOCK_COMMENT_FAIL.
if [[ "$1" == "api" && "$2" == *"/comments" ]]; then
  case "${GH_MOCK_COMMENT_FAIL:-}" in
    403)
      echo "HTTP 403: Resource not accessible by integration" >&2
      exit 1
      ;;
    401)
      echo "HTTP 401: Unauthorized" >&2
      exit 1
      ;;
    500)
      echo "HTTP 500: Internal Server Error" >&2
      exit 1
      ;;
    422)
      echo "HTTP 422: Unprocessable Entity" >&2
      exit 1
      ;;
    *)
      echo '{"id": 1, "html_url": "https://github.com/test-org/test-repo/pull/10#issuecomment-1"}'
      exit 0
      ;;
  esac
fi

# Default: succeed silently.
exit 0
MOCKEOF
chmod +x "${MOCK_BIN}/gh"

# --- Mock curl (for GitLab tests) ---
# CURL_MOCK_COMMENT_FAIL controls how the mock responds to note-posting calls.
CURL_LOG="${TMPDIR}/curl-calls.log"
cat > "${MOCK_BIN}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
echo "curl $*" >> "${CURL_LOG}"

# Detect endpoint from the URL argument (last positional before data args).
URL=""
for arg in "$@"; do
  if [[ "${arg}" == https://* ]]; then
    URL="${arg}"
  fi
done

# Label creation — succeed silently
if [[ "${URL}" == *"/labels" ]] && [[ " $* " == *" POST "* || " $* " == *" -X POST "* ]]; then
  echo '{"id": 1, "name": "ready-for-triage"}'
  exit 0
fi

# Issue creation — return a fake issue URL
if [[ "${URL}" == *"/issues" ]] && [[ " $* " == *" POST "* || " $* " == *" -X POST "* ]] && [[ "${URL}" != *"/notes" ]]; then
  # CURL_MOCK_ISSUE_FAIL_PROJECT fails creation only for the matching
  # URL-encoded project path, so later proposals can still succeed.
  if [[ -n "${CURL_MOCK_ISSUE_FAIL_PROJECT:-}" && "${URL}" == *"/projects/${CURL_MOCK_ISSUE_FAIL_PROJECT}/issues" ]]; then
    echo "curl: (22) The requested URL returned error: 404" >&2
    exit 22
  fi
  case "${CURL_MOCK_ISSUE_FAIL:-}" in
    null-url)
      echo '{"iid": 99}'
      exit 0
      ;;
    api-error)
      echo "curl: (22) The requested URL returned error: 403" >&2
      exit 22
      ;;
    *)
      echo '{"web_url": "https://gitlab.com/test-group/target-project/-/issues/99", "iid": 99}'
      exit 0
      ;;
  esac
fi

# Comment posting (notes) — controlled by CURL_MOCK_COMMENT_FAIL
if [[ "${URL}" == *"/notes" ]] && [[ " $* " == *" POST "* || " $* " == *" -X POST "* ]]; then
  # Save the note body (passed as body@<file>) so tests can inspect it.
  for arg in "$@"; do
    if [[ "${arg}" == body@* && -n "${CURL_BODY_LOG:-}" ]]; then
      cat "${arg#body@}" >> "${CURL_BODY_LOG}"
    fi
  done
  case "${CURL_MOCK_COMMENT_FAIL:-}" in
    403)
      echo "curl: (22) The requested URL returned error: 403" >&2
      exit 22
      ;;
    401)
      echo "curl: (22) The requested URL returned error: 401" >&2
      exit 22
      ;;
    500)
      echo "curl: (22) The requested URL returned error: 500" >&2
      exit 22
      ;;
    422)
      echo "curl: (22) The requested URL returned error: 422" >&2
      exit 22
      ;;
    *)
      echo '{"id": 1}'
      exit 0
      ;;
  esac
fi

# Default: succeed silently
exit 0
MOCKEOF
chmod +x "${MOCK_BIN}/curl"

# Mock jq is not needed — we use the real jq.
# Mock sed is not needed — we use the real sed.

GH_STDIN_LOG="${TMPDIR}/gh-stdin.log"
CURL_BODY_LOG="${TMPDIR}/curl-body.log"

export PATH="${MOCK_BIN}:${PATH}"
export GH_LOG="${GH_LOG}"
export CURL_LOG="${CURL_LOG}"
export GH_STDIN_LOG="${GH_STDIN_LOG}"
export CURL_BODY_LOG="${CURL_BODY_LOG}"
export ORIGINATING_URL="https://github.com/test-org/test-repo/pull/10"
export GH_TOKEN="fake-token"
# shellcheck disable=SC2031 # FULLSEND_FORGE exported for subshell test runs
export FULLSEND_FORGE="github"

# allow_targets handler reads config.yaml from GITHUB_WORKSPACE.
# Create a minimal workspace with an allowlist so existing tests pass
# (test-org is allowed) and new tests can exercise the disallowed path.
WORKSPACE="${TMPDIR}/workspace"
mkdir -p "${WORKSPACE}"
cat > "${WORKSPACE}/config.yaml" <<CFGEOF
version: "1"
create_issues:
  allow_targets:
    orgs:
      - test-org
    repos:
      - allowed-org/allowed-repo
CFGEOF
export GITHUB_WORKSPACE="${WORKSPACE}"

# Fixture: a valid agent result with one proposal.
FIXTURE_ONE_PROPOSAL='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Improve error handling in widget service",
      "what_happened": "The widget service crashed on empty input.",
      "what_could_go_better": "Input validation should reject empty payloads.",
      "proposed_change": "Add a nil check at the entry point.",
      "validation_criteria": "Widget service returns 400 on empty input.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: a valid agent result with an evidence-for proposal.
FIXTURE_EVIDENCE_FOR='{
  "summary": "The retro analysis found corroborating evidence.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Evidence for #1234: review agent missed authorization check",
      "what_happened": "The review agent did not flag a missing auth check.",
      "what_could_go_better": "Authorization checks should be flagged.",
      "proposed_change": "Add auth-check detection to review prompts.",
      "validation_criteria": "Review agent flags missing auth checks."
    }
  ]
}'

# Fixture: mixed proposals — one evidence-for (filtered) and one normal (filed).
FIXTURE_MIXED='{
  "summary": "The retro analysis found two items.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Evidence for #5678: redundant review runs",
      "what_happened": "Five reviews ran on the same commit.",
      "what_could_go_better": "Dedup review triggers.",
      "proposed_change": "Check for existing review before dispatch.",
      "validation_criteria": "No duplicate reviews on same SHA.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    },
    {
      "target_repo": "test-org/target-repo",
      "title": "Improve error handling in widget service",
      "what_happened": "The widget service crashed on empty input.",
      "what_could_go_better": "Input validation should reject empty payloads.",
      "proposed_change": "Add a nil check at the entry point.",
      "validation_criteria": "Widget service returns 400 on empty input.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: title contains "evidence" but is NOT an evidence-for proposal.
FIXTURE_FALSE_POSITIVE='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Fix evidence gathering bug",
      "what_happened": "Evidence collection crashes on empty logs.",
      "what_could_go_better": "Handle empty log files gracefully.",
      "proposed_change": "Add empty-file guard in evidence collector.",
      "validation_criteria": "No crash on empty log input.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: evidence-for with uppercase title.
FIXTURE_EVIDENCE_UPPERCASE='{
  "summary": "The retro analysis found corroborating evidence.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "EVIDENCE FOR #999: review coverage gap",
      "what_happened": "Review coverage was low.",
      "what_could_go_better": "Increase review coverage.",
      "proposed_change": "Add coverage checks.",
      "validation_criteria": "Coverage above 80%."
    }
  ]
}'

# Fixture: "Additional evidence" title variant.
FIXTURE_ADDITIONAL_EVIDENCE='{
  "summary": "The retro analysis found additional evidence.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Additional evidence for pattern X in review agent",
      "what_happened": "Pattern X recurred.",
      "what_could_go_better": "Address pattern X.",
      "proposed_change": "Fix pattern X.",
      "validation_criteria": "Pattern X no longer appears."
    }
  ]
}'

# Fixture: "evidence for #N" appears mid-title — must NOT be rejected.
FIXTURE_MID_TITLE_EVIDENCE='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Add evidence for #1234 test failures to the report generator",
      "what_happened": "Report generator lacks test failure evidence.",
      "what_could_go_better": "Include evidence in reports.",
      "proposed_change": "Aggregate test failures into evidence section.",
      "validation_criteria": "Reports include test failure evidence.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: title starts with "Evidence for" but no issue ref — must NOT be rejected.
FIXTURE_EVIDENCE_NO_ISSUEREF='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Evidence for improving review coverage across all repos",
      "what_happened": "Review coverage is inconsistent.",
      "what_could_go_better": "Standardize review coverage.",
      "proposed_change": "Add coverage checks to CI.",
      "validation_criteria": "All repos have coverage checks.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: title with :: that could inject a workflow command.
FIXTURE_TITLE_DOUBLE_COLON='{
  "summary": "The retro analysis found corroborating evidence.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Evidence for #42: ::error::injected command",
      "what_happened": "Attempted injection.",
      "what_could_go_better": "Sanitize titles.",
      "proposed_change": "Strip dangerous sequences.",
      "validation_criteria": "No injection.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: title with %0A that could inject a newline in workflow commands.
FIXTURE_TITLE_PERCENT_ENCODED='{
  "summary": "The retro analysis found corroborating evidence.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Evidence for #42: test%0A::error::injected",
      "what_happened": "Attempted percent-encoded injection.",
      "what_could_go_better": "Sanitize titles.",
      "proposed_change": "Strip percent-encoded sequences.",
      "validation_criteria": "No injection.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: a valid agent result targeting a disallowed repo.
FIXTURE_DISALLOWED_TARGET='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "disallowed-org/other-repo",
      "title": "Improve logging in external service",
      "what_happened": "Logging was insufficient during incident.",
      "what_could_go_better": "Structured logging should be added.",
      "proposed_change": "Add structured log fields.",
      "validation_criteria": "Log entries include request IDs."
    }
  ]
}'

# Fixture: mixed proposals — one allowed, one disallowed.
FIXTURE_MIXED_TARGETS='{
  "summary": "The retro analysis found two improvement opportunities.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Fix allowed repo issue",
      "what_happened": "Something broke.",
      "what_could_go_better": "It should not break.",
      "proposed_change": "Fix the thing.",
      "validation_criteria": "Thing works.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    },
    {
      "target_repo": "disallowed-org/other-repo",
      "title": "Fix disallowed repo issue",
      "what_happened": "Something else broke.",
      "what_could_go_better": "It should also not break.",
      "proposed_change": "Fix the other thing.",
      "validation_criteria": "Other thing works.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: proposal targeting a repo allowed by the repo-level allowlist.
FIXTURE_REPO_ALLOWLIST_TARGET='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "allowed-org/allowed-repo",
      "title": "Fix repo-level allowed target",
      "what_happened": "Something needs fixing in allowed-repo.",
      "what_could_go_better": "It should be fixed.",
      "proposed_change": "Fix it.",
      "validation_criteria": "It is fixed.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: proposal targeting the originating repo (always allowed).
# Uses an org NOT in the allowlist so the test isolates the
# originating-repo check from the org-allowlist check.
FIXTURE_ORIGINATING_REPO_TARGET='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "unlisted-org/originating-repo",
      "title": "Improve self-repo handling",
      "what_happened": "The originating repo had a gap.",
      "what_could_go_better": "Should be handled.",
      "proposed_change": "Add handling.",
      "validation_criteria": "Handling works.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: a valid agent result with no proposals.
FIXTURE_NO_PROPOSALS='{
  "summary": "The retro analysis found no actionable improvements.",
  "proposals": []
}'

# Fixture: a proposal with a populated dedup receipt (candidates considered).
FIXTURE_RECEIPT_FOUND='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Improve error handling in widget service",
      "what_happened": "The widget service crashed on empty input.",
      "what_could_go_better": "Input validation should reject empty payloads.",
      "proposed_change": "Add a nil check at the entry point.",
      "validation_criteria": "Widget service returns 400 on empty input.",
      "related_issues": {
        "searched": [
          "error handling empty input",
          "widget service input validation"
        ],
        "found": [2476],
        "note": "#2476 covers the parser path only; this proposal adds the entry-point gate."
      }
    }
  ]
}'

# Fixture: a receipt mixing a bare target_repo integer with a cross-repo
# owner/repo#N reference — each must render in its own form.
FIXTURE_RECEIPT_CROSS_REPO='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Improve error handling in widget service",
      "what_happened": "The widget service crashed on empty input.",
      "what_could_go_better": "Input validation should reject empty payloads.",
      "proposed_change": "Add a nil check at the entry point.",
      "validation_criteria": "Widget service returns 400 on empty input.",
      "related_issues": {
        "searched": [
          "error handling empty input",
          "widget service input validation"
        ],
        "found": [2476, "fullsend-ai/fullsend#1887"],
        "note": "Root cause tracked cross-layer in fullsend-ai/fullsend#1887."
      }
    }
  ]
}'

# Fixture: a proposal whose receipt found no overlapping issues.
FIXTURE_RECEIPT_EMPTY='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Improve error handling in widget service",
      "what_happened": "The widget service crashed on empty input.",
      "what_could_go_better": "Input validation should reject empty payloads.",
      "proposed_change": "Add a nil check at the entry point.",
      "validation_criteria": "Widget service returns 400 on empty input.",
      "related_issues": {
        "searched": [
          "error handling empty input",
          "widget service input validation"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: a legacy six-field proposal without a dedup receipt.
FIXTURE_NO_RECEIPT='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Improve error handling in widget service",
      "what_happened": "The widget service crashed on empty input.",
      "what_could_go_better": "Input validation should reject empty payloads.",
      "proposed_change": "Add a nil check at the entry point.",
      "validation_criteria": "Widget service returns 400 on empty input."
    }
  ]
}'

# Fixture: a malformed receipt (searched is a string, not an array) in the first
# proposal, followed by a valid proposal. The gate must skip the first WITHOUT
# aborting — the second must still be filed and the summary posted. This is the
# regression guard for the length-on-string bug (the string would pass a bare
# length>=2 check and then crash the body builder's join under set -e).
FIXTURE_MALFORMED_THEN_VALID='{
  "summary": "The retro analysis found two improvement opportunities.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Proposal with malformed receipt",
      "what_happened": "First thing happened.",
      "what_could_go_better": "It could go better.",
      "proposed_change": "Change it.",
      "validation_criteria": "It works.",
      "related_issues": { "searched": "a single string not an array" }
    },
    {
      "target_repo": "test-org/target-repo",
      "title": "Proposal with valid receipt",
      "what_happened": "Second thing happened.",
      "what_could_go_better": "It could also go better.",
      "proposed_change": "Change it too.",
      "validation_criteria": "It also works.",
      "related_issues": {
        "searched": [
          "valid first phrase",
          "valid second phrase"
        ],
        "found": []
      }
    }
  ]
}'

# Fixture: a receipt with two empty-string phrases — length is 2 but they are
# blank, so the gate must skip.
FIXTURE_RECEIPT_EMPTY_STRINGS='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Proposal with blank search phrases",
      "what_happened": "Something happened.",
      "what_could_go_better": "It could go better.",
      "proposed_change": "Change it.",
      "validation_criteria": "It works.",
      "related_issues": { "searched": ["", ""] }
    }
  ]
}'

# Fixture: a receipt with a single phrase — fewer than the required two.
FIXTURE_RECEIPT_SINGLE_PHRASE='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Proposal with one search phrase",
      "what_happened": "Something happened.",
      "what_could_go_better": "It could go better.",
      "proposed_change": "Change it.",
      "validation_criteria": "It works.",
      "related_issues": { "searched": ["only one phrase"] }
    }
  ]
}'

# Fixture: a receipt with two identical phrases — not two distinct searches.
FIXTURE_RECEIPT_DUPLICATE_PHRASES='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-org/target-repo",
      "title": "Proposal with duplicate search phrases",
      "what_happened": "Something happened.",
      "what_could_go_better": "It could go better.",
      "proposed_change": "Change it.",
      "validation_criteria": "It works.",
      "related_issues": { "searched": ["same phrase", "same phrase"] }
    }
  ]
}'

# Fixture: two allowed proposals — the first targets a repo where issue
# creation fails (via GH_MOCK_ISSUE_FAIL_REPO), the second succeeds.
FIXTURE_CREATE_FAIL_THEN_OK='{
  "summary": "The retro analysis found two improvement opportunities.",
  "proposals": [
    {
      "target_repo": "test-org/unavailable-repo",
      "title": "Proposal in unavailable repo",
      "what_happened": "Something happened.",
      "what_could_go_better": "It could go better.",
      "proposed_change": "Change it.",
      "validation_criteria": "It works.",
      "related_issues": {
        "searched": [
          "unavailable repo proposal",
          "proposal filing failure"
        ],
        "found": []
      }
    },
    {
      "target_repo": "test-org/target-repo",
      "title": "Proposal in available repo",
      "what_happened": "Something else happened.",
      "what_could_go_better": "It could also go better.",
      "proposed_change": "Change it too.",
      "validation_criteria": "It also works.",
      "related_issues": {
        "searched": [
          "available repo proposal",
          "proposal filing success"
        ],
        "found": []
      }
    }
  ]
}'

run_test() {
  local test_name="$1"
  local json_content="$2"
  local expected_pattern="$3"
  local expect_failure="${4:-false}"
  local comment_fail="${5:-}"

  # Create iteration output structure.
  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"

  # Clear gh call log and stdin log.
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  : > "${CURL_LOG}"
  # shellcheck disable=SC2031 # GH_MOCK_COMMENT_FAIL exported for subshell test run
  export GH_MOCK_COMMENT_FAIL="${comment_fail}"

  # Run the post-script.
  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

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

  if [[ -n "${expected_pattern}" ]] && ! grep -qF -- "${expected_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — expected gh call pattern '${expected_pattern}' not found"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_stdout() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"
  local expect_failure="${4:-false}"
  local comment_fail="${5:-}"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  : > "${CURL_LOG}"
  # shellcheck disable=SC2031 # GH_MOCK_COMMENT_FAIL exported for subshell test run
  export GH_MOCK_COMMENT_FAIL="${comment_fail}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    if [[ -n "${expected_stdout}" ]] && ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout.log"; then
      echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
      echo "Actual stdout:"
      cat "${TMPDIR}/stdout.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure)"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_no_gh_call() {
  local test_name="$1"
  local json_content="$2"
  local forbidden_pattern="$3"
  local expected_stdout="$4"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  : > "${CURL_LOG}"
  # shellcheck disable=SC2031 # GH_MOCK_COMMENT_FAIL exported for subshell test run
  export GH_MOCK_COMMENT_FAIL=""

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF -- "${forbidden_pattern}" "${GH_LOG}"; then
    echo "FAIL: ${test_name} — forbidden gh call '${forbidden_pattern}' was made"
    echo "Actual calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_stdout}" ]] && ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_stdin() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdin_pattern="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  : > "${CURL_LOG}"
  # shellcheck disable=SC2031 # GH_MOCK_COMMENT_FAIL exported for subshell test run
  export GH_MOCK_COMMENT_FAIL=""

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_stdin_pattern}" "${GH_STDIN_LOG}"; then
    echo "FAIL: ${test_name} — expected stdin pattern '${expected_stdin_pattern}' not found in gh api body"
    echo "Actual stdin:"
    cat "${GH_STDIN_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_test_stdout_absent() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"
  local forbidden_stdout="$4"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  : > "${CURL_LOG}"
  # shellcheck disable=SC2031 # GH_MOCK_COMMENT_FAIL exported for subshell test run
  export GH_MOCK_COMMENT_FAIL=""

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF -- "${forbidden_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — forbidden stdout pattern '${forbidden_stdout}' found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# run_create_fail_case NAME FIXTURE MOCK_VAR MOCK_VALUE [COMMENT_FAIL]
# Runs the post-script with the issue-creation failure mock variable
# MOCK_VAR set to MOCK_VALUE for this run only, and the summary comment
# mock set to COMMENT_FAIL (default: succeed). Leaves stdout.log, GH_LOG,
# GH_STDIN_LOG, CURL_LOG and CURL_BODY_LOG for the assertions that follow,
# and stores the script's exit code in CREATE_FAIL_EXIT.
run_create_fail_case() {
  local test_name="$1"
  local json_content="$2"
  local mock_var="$3"
  local mock_value="$4"
  local comment_fail="${5:-}"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  : > "${CURL_LOG}"
  : > "${CURL_BODY_LOG}"
  # shellcheck disable=SC2031 # mock controls exported for subshell test run
  export GH_MOCK_COMMENT_FAIL="${comment_fail}" CURL_MOCK_COMMENT_FAIL="${comment_fail}" CURL_MOCK_ISSUE_FAIL=""

  CREATE_FAIL_EXIT=0
  (cd "${run_dir}" && env "${mock_var}=${mock_value}" bash "${POST_SCRIPT}") \
    > "${TMPDIR}/stdout.log" 2>&1 || CREATE_FAIL_EXIT=$?
}

# assert_create_fail_exit NAME [EXPECT_FAILURE] — the last
# run_create_fail_case exited 0 (or non-zero when EXPECT_FAILURE is "true").
assert_create_fail_exit() {
  if [[ "${2:-false}" == "true" ]]; then
    if [[ ${CREATE_FAIL_EXIT} -eq 0 ]]; then
      echo "FAIL: $1 — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: $1 (expected failure, got exit code ${CREATE_FAIL_EXIT})"
    return
  fi
  if [[ ${CREATE_FAIL_EXIT} -ne 0 ]]; then
    echo "FAIL: $1 — exit code ${CREATE_FAIL_EXIT}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: $1"
}

# assert_file_contains NAME FILE PATTERN — fixed-string PATTERN is in FILE.
assert_file_contains() {
  if ! grep -qF -- "$3" "$2"; then
    echo "FAIL: $1 — expected '$3' in $(basename "$2")"
    cat "$2"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: $1"
}

# assert_file_lacks NAME FILE PATTERN — fixed-string PATTERN is not in FILE.
assert_file_lacks() {
  if grep -qF -- "$3" "$2"; then
    echo "FAIL: $1 — unexpected '$3' in $(basename "$2")"
    cat "$2"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: $1"
}

# ===========================================================================
# GitHub test cases (FULLSEND_FORGE=github)
# ===========================================================================

# Happy path: one proposal filed, comment posted successfully.
run_test "happy-path-one-proposal" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "repos/test-org/test-repo/issues/10/comments"

# Verify that the happy-path also called gh issue create.
run_test "happy-path-issue-created" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create"

# Verify that the happy-path applied the ready-for-triage label.
run_test "happy-path-triage-label" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "ready-for-triage"

# Verify that gh label create is called before gh issue create.
run_test "label-created-before-issue" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh label create ready-for-triage"

# Happy path: no proposals, comment posted successfully.
run_test "happy-path-no-proposals" \
  "${FIXTURE_NO_PROPOSALS}" \
  "repos/test-org/test-repo/issues/10/comments"

# 403 on comment posting is non-fatal — script should exit 0 with a warning.
run_test_stdout "comment-403-non-fatal" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "::warning::Could not post summary comment" \
  "false" \
  "403"

# 401 on comment posting is non-fatal — script should exit 0 with a warning.
run_test_stdout "comment-401-non-fatal" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "::warning::Could not post summary comment" \
  "false" \
  "401"

# 500 on comment posting remains fatal.
run_test_stdout "comment-500-fatal" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "ERROR: failed to post summary comment" \
  "true" \
  "500"

# 422 on comment posting remains fatal.
run_test_stdout "comment-422-fatal" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "ERROR: failed to post summary comment" \
  "true" \
  "422"

# 403 with no proposals — still non-fatal.
run_test_stdout "comment-403-no-proposals" \
  "${FIXTURE_NO_PROPOSALS}" \
  "::warning::Could not post summary comment" \
  "false" \
  "403"

# Post-retro complete should appear on successful runs.
run_test_stdout "complete-message" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Post-retro complete."

# ---------------------------------------------------------------------------
# Dedup receipt tests
# Verify that related_issues renders into the filed issue body and that the
# receipt gate rejects legacy proposals without one.
# ---------------------------------------------------------------------------

# Receipt with candidates: rendered into the filed issue body.
run_test "receipt-rendered-in-issue-body" \
  "${FIXTURE_RECEIPT_FOUND}" \
  "Related issues checked"

# Receipt with candidates: considered list and note rendered.
run_test "receipt-considered-rendered" \
  "${FIXTURE_RECEIPT_FOUND}" \
  "Considered: #2476"

# Receipt with empty found: no-overlap line rendered.
run_test "receipt-empty-found" \
  "${FIXTURE_RECEIPT_EMPTY}" \
  "No overlapping issues found."

# Cross-repo found: bare integer renders as #N, qualified ref renders as-is.
run_test "receipt-cross-repo-ref-rendered" \
  "${FIXTURE_RECEIPT_CROSS_REPO}" \
  "Considered: #2476, fullsend-ai/fullsend#1887"

# Receipt gate: legacy proposal without a receipt is not filed.
run_test_no_gh_call "receipt-gate-skips-filing" \
  "${FIXTURE_NO_RECEIPT}" \
  "gh issue create" \
  "::warning::proposal[0] not filed"

# Receipt gate: skipped proposal appears in the summary comment.
run_test_stdin "receipt-gate-skipped-in-summary" \
  "${FIXTURE_NO_RECEIPT}" \
  "Proposals skipped (no dedup receipt)"

# Receipt gate: skipped proposal folds its what_happened first line (not just
# title) into the summary comment.
run_test_stdin "receipt-gate-folds-content" \
  "${FIXTURE_NO_RECEIPT}" \
  "The widget service crashed on empty input."

# Receipt gate: a malformed receipt (searched is a string) must skip proposal[0]
# WITHOUT aborting — proposal[1] is still filed. Regression guard for the
# length-on-string bug that crashed the body builder mid-loop.
run_test "receipt-gate-malformed-does-not-abort-filing" \
  "${FIXTURE_MALFORMED_THEN_VALID}" \
  "gh issue create"

# Same fixture: the run still posts its summary comment (loop did not abort).
run_test_stdin "receipt-gate-malformed-still-posts-summary" \
  "${FIXTURE_MALFORMED_THEN_VALID}" \
  "Proposals skipped (no dedup receipt)"

# Receipt gate: two blank phrases (length 2 but empty) are skipped.
run_test_no_gh_call "receipt-gate-empty-strings-skipped" \
  "${FIXTURE_RECEIPT_EMPTY_STRINGS}" \
  "gh issue create" \
  "::warning::proposal[0] not filed"

# Receipt gate: a single search phrase is skipped.
run_test_no_gh_call "receipt-gate-single-phrase-skipped" \
  "${FIXTURE_RECEIPT_SINGLE_PHRASE}" \
  "gh issue create" \
  "::warning::proposal[0] not filed"

# Receipt gate: two identical phrases are skipped (not two distinct searches).
run_test_no_gh_call "receipt-gate-duplicate-phrases-skipped" \
  "${FIXTURE_RECEIPT_DUPLICATE_PHRASES}" \
  "gh issue create" \
  "::warning::proposal[0] not filed"

# Evidence-for gate: proposal titled "Evidence for #1234" is rejected.
run_test_no_gh_call "evidence-for-rejected" \
  "${FIXTURE_EVIDENCE_FOR}" \
  "gh issue create" \
  "::warning::proposal[0] rejected"

# Evidence-for gate: case-insensitive rejection.
run_test_no_gh_call "evidence-for-case-insensitive" \
  "${FIXTURE_EVIDENCE_UPPERCASE}" \
  "gh issue create" \
  "::warning::proposal[0] rejected"

# Evidence-for gate: "Additional evidence" variant rejected.
run_test_no_gh_call "evidence-for-additional" \
  "${FIXTURE_ADDITIONAL_EVIDENCE}" \
  "gh issue create" \
  "::warning::proposal[0] rejected"

# Evidence-for gate: "Fix evidence gathering bug" is NOT rejected.
run_test "evidence-false-positive" \
  "${FIXTURE_FALSE_POSITIVE}" \
  "gh issue create"

# Evidence-for gate: mixed proposals — evidence one filtered, normal one filed.
run_test "evidence-for-mixed-issue-created" \
  "${FIXTURE_MIXED}" \
  "gh issue create"

run_test_stdout "evidence-for-mixed" \
  "${FIXTURE_MIXED}" \
  "1 proposal(s) filtered (evidence-for pattern)"

# Evidence-for gate: "evidence for #N" mid-title is NOT rejected.
run_test "evidence-mid-title-not-rejected" \
  "${FIXTURE_MID_TITLE_EVIDENCE}" \
  "gh issue create"

# Evidence-for gate: "Evidence for <no issue ref>" is NOT rejected.
run_test "evidence-no-issueref-not-rejected" \
  "${FIXTURE_EVIDENCE_NO_ISSUEREF}" \
  "gh issue create"

# Evidence-for gate: filtered content folded into summary comment body.
run_test_stdin "evidence-for-folded-into-summary" \
  "${FIXTURE_EVIDENCE_FOR}" \
  "Evidence notes (not filed as issues)"

# Sanitization: :: in title replaced with : in warning output.
run_test_stdout_absent "sanitize-double-colon" \
  "${FIXTURE_TITLE_DOUBLE_COLON}" \
  "::warning::proposal[0] rejected" \
  "::error::injected"

# Sanitization: %0A stripped from title in warning output.
run_test_stdout_absent "sanitize-percent-encoded" \
  "${FIXTURE_TITLE_PERCENT_ENCODED}" \
  "::warning::proposal[0] rejected" \
  "%0A"

# Truncation: comment body over 65000 chars gets truncated.
BIG_SUMMARY=$(printf 'x%.0s' $(seq 1 66000))
FIXTURE_OVERSIZED=$(jq -nc --arg s "${BIG_SUMMARY}" '{summary: $s, proposals: []}')
run_test_stdin "comment-truncated-at-limit" \
  "${FIXTURE_OVERSIZED}" \
  "...(truncated)"

# Verify truncated body is under GitHub's 65536 limit.
POSTED_LEN=$(wc -c < "${GH_STDIN_LOG}")
if [[ ${POSTED_LEN} -gt 65536 ]]; then
  echo "FAIL: comment-truncated-length — posted body is ${POSTED_LEN} chars (limit 65536)"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: comment-truncated-length"
fi

# ---------------------------------------------------------------------------
# allow_targets tests
# Verify that proposals targeting repos not in create_issues.allow_targets
# are skipped with a warning, while allowed targets proceed normally.
# ---------------------------------------------------------------------------

# Disallowed target: proposal is NOT filed, warning emitted.
run_test_no_gh_call "allow-targets-disallowed-skipped" \
  "${FIXTURE_DISALLOWED_TARGET}" \
  "gh issue create" \
  "::warning::Skipping issue creation in 'disallowed-org/other-repo'"

# Disallowed target: skipped proposal details appear in summary comment.
run_test_stdin "allow-targets-skipped-in-summary" \
  "${FIXTURE_DISALLOWED_TARGET}" \
  "Proposals skipped (target repo not allowed)"

# Allowed target: proposal IS filed (test-org is in the org allowlist).
run_test "allow-targets-allowed-filed" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create"

# Repo-level allowlist: allowed-org/allowed-repo is in repos allowlist.
run_test "allow-targets-repo-level-filed" \
  "${FIXTURE_REPO_ALLOWLIST_TARGET}" \
  "gh issue create"

# Originating repo is always allowed even without explicit allowlist entry.
# Override ORIGINATING_URL to an org NOT in the allowlist so this test
# isolates the originating-repo check from the org-allowlist check.
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://github.com/unlisted-org/originating-repo/pull/10"
run_test "allow-targets-originating-repo-allowed" \
  "${FIXTURE_ORIGINATING_REPO_TARGET}" \
  "gh issue create"
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://github.com/test-org/test-repo/pull/10"

# Mixed targets: allowed proposal filed, disallowed skipped.
run_test "allow-targets-mixed-allowed-filed" \
  "${FIXTURE_MIXED_TARGETS}" \
  "gh issue create"

run_test_stdout "allow-targets-mixed-disallowed-skipped" \
  "${FIXTURE_MIXED_TARGETS}" \
  "::warning::Skipping issue creation in 'disallowed-org/other-repo'"

# No GITHUB_WORKSPACE: only originating repo is allowed.
# Temporarily unset GITHUB_WORKSPACE so the config file is not found.
unset GITHUB_WORKSPACE
run_test_no_gh_call "allow-targets-no-workspace-cross-repo-blocked" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create" \
  "::warning::Skipping issue creation in 'test-org/target-repo'"

# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://github.com/unlisted-org/originating-repo/pull/10"
run_test "allow-targets-no-workspace-originating-allowed" \
  "${FIXTURE_ORIGINATING_REPO_TARGET}" \
  "gh issue create"
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://github.com/test-org/test-repo/pull/10"
# shellcheck disable=SC2031 # GITHUB_WORKSPACE exported for subshell test run
export GITHUB_WORKSPACE="${WORKSPACE}"

# ---------------------------------------------------------------------------
# Issue-creation failure tests
# A failed forge_create_issue is non-fatal: remaining proposals are still
# attempted, the summary is still posted, and failed proposals are listed
# separately from filed ones (never as issue links).
# ---------------------------------------------------------------------------

# First creation fails, second succeeds.
run_create_fail_case "create-fail-then-ok" \
  "${FIXTURE_CREATE_FAIL_THEN_OK}" \
  GH_MOCK_ISSUE_FAIL_REPO "test-org/unavailable-repo"
assert_create_fail_exit "create-fail-then-ok-exit-zero"
assert_file_contains "create-fail-then-ok-error-logged" "${TMPDIR}/stdout.log" \
  "::warning::Failed to create issue in test-org/unavailable-repo for proposal[0] (Proposal in unavailable repo)"
assert_file_contains "create-fail-then-ok-later-attempted" "${GH_LOG}" \
  "gh issue create --repo test-org/target-repo"
assert_file_contains "create-fail-then-ok-summary-posted" "${GH_LOG}" \
  "repos/test-org/test-repo/issues/10/comments"
assert_file_contains "create-fail-then-ok-success-linked" "${GH_STDIN_LOG}" \
  "- [Proposal in available repo](https://github.com/test-org/target-repo/issues/99)"
assert_file_contains "create-fail-then-ok-failed-section" "${GH_STDIN_LOG}" \
  "### Proposals not filed (issue creation failed)"
assert_file_contains "create-fail-then-ok-failed-listed" "${GH_STDIN_LOG}" \
  "- **Proposal in unavailable repo** (\`test-org/unavailable-repo\`)"
assert_file_lacks "create-fail-then-ok-failed-not-linked" "${GH_STDIN_LOG}" \
  "[Proposal in unavailable repo]("

# All creations fail: summary still posted, failures logged, no filed links.
run_create_fail_case "create-all-fail" \
  "${FIXTURE_CREATE_FAIL_THEN_OK}" \
  GH_MOCK_ISSUE_FAIL_REPO "*"
assert_create_fail_exit "create-all-fail-exit-zero"
assert_file_contains "create-all-fail-first-logged" "${TMPDIR}/stdout.log" \
  "::warning::Failed to create issue in test-org/unavailable-repo for proposal[0]"
assert_file_contains "create-all-fail-second-logged" "${TMPDIR}/stdout.log" \
  "::warning::Failed to create issue in test-org/target-repo for proposal[1]"
assert_file_contains "create-all-fail-summary-posted" "${GH_LOG}" \
  "repos/test-org/test-repo/issues/10/comments"
assert_file_lacks "create-all-fail-no-filed-section" "${GH_STDIN_LOG}" \
  "### Proposals filed"
assert_file_contains "create-all-fail-both-listed" "${GH_STDIN_LOG}" \
  "- **Proposal in available repo** (\`test-org/target-repo\`)"

# Allowlist gate still applies: a disallowed target is skipped (never
# attempted) and reported as skipped, not as a creation failure.
run_create_fail_case "create-fail-allowlist-preserved" \
  "${FIXTURE_MIXED_TARGETS}" \
  GH_MOCK_ISSUE_FAIL_REPO "*"
assert_create_fail_exit "create-fail-allowlist-preserved-exit-zero"
assert_file_lacks "create-fail-allowlist-preserved-not-attempted" "${GH_LOG}" \
  "gh issue create --repo disallowed-org/other-repo"
assert_file_contains "create-fail-allowlist-preserved-skipped" "${GH_STDIN_LOG}" \
  "Proposals skipped (target repo not allowed)"
assert_file_contains "create-fail-allowlist-preserved-failed" "${GH_STDIN_LOG}" \
  "- **Fix allowed repo issue** (\`test-org/target-repo\`)"

# Summary-posting errors stay fatal even after a creation failure.
run_create_fail_case "create-fail-comment-500" \
  "${FIXTURE_CREATE_FAIL_THEN_OK}" \
  GH_MOCK_ISSUE_FAIL_REPO "test-org/unavailable-repo" \
  "500"
assert_create_fail_exit "create-fail-comment-500-fatal" "true"
assert_file_contains "create-fail-comment-500-error" "${TMPDIR}/stdout.log" \
  "ERROR: failed to post summary comment"

# ---------------------------------------------------------------------------
# FULLSEND_VALIDATED_ITERATION_DIR tests
# Verify that when FULLSEND_VALIDATED_ITERATION_DIR is set, the script reads
# from that directory instead of scanning iteration-*/output.
# ---------------------------------------------------------------------------

run_validated_dir_test() {
  local test_name="$1"
  local validated_dir_file="$2"   # "agent-result.json", "result.json", or "none"
  local expected_pattern="$3"
  local expect_failure="${4:-false}"

  local run_dir="${TMPDIR}/run-${test_name}"
  local validated_dir="${run_dir}/validated-output"
  mkdir -p "${validated_dir}"

  # Place the fixture in the validated dir under the specified filename.
  if [[ "${validated_dir_file}" != "none" ]]; then
    echo "${FIXTURE_ONE_PROPOSAL}" > "${validated_dir}/${validated_dir_file}"
  fi

  # Also place a DIFFERENT result in iteration-2 to ensure the script does
  # NOT fall back to scanning when the validated dir is set.
  mkdir -p "${run_dir}/iteration-2/output"
  echo '{}' > "${run_dir}/iteration-2/output/agent-result.json"

  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  : > "${CURL_LOG}"
  # shellcheck disable=SC2031 # GH_MOCK_COMMENT_FAIL exported for subshell test run
  export GH_MOCK_COMMENT_FAIL=""

  local exit_code=0
  (
    cd "${run_dir}"
    # shellcheck disable=SC2031,SC2030 # FULLSEND_VALIDATED_ITERATION_DIR exported for subshell
    export FULLSEND_VALIDATED_ITERATION_DIR="${validated_dir}"
    bash "${POST_SCRIPT}"
  ) > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

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
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_pattern}" ]] && ! grep -qF -- "${expected_pattern}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout '${expected_pattern}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Validated dir has agent-result.json → used
run_validated_dir_test "validated-dir-expected-filename" \
  "agent-result.json" \
  "Reading retro result from: ${TMPDIR}/run-validated-dir-expected-filename/validated-output/agent-result.json"

# Validated dir has only result.json → used as fallback
run_validated_dir_test "validated-dir-fallback-filename" \
  "result.json" \
  "Reading retro result from: ${TMPDIR}/run-validated-dir-fallback-filename/validated-output/result.json"

# Validated dir has neither filename → fails closed
run_validated_dir_test "validated-dir-neither-filename" \
  "none" \
  "" \
  "true"

# ===========================================================================
# GitLab test cases (FULLSEND_FORGE=gitlab)
# ===========================================================================

# Switch to GitLab forge context.
# shellcheck disable=SC2031 # FULLSEND_FORGE exported for subshell test runs
export FULLSEND_FORGE="gitlab"
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test runs
export ORIGINATING_URL="https://gitlab.com/test-group/test-project/-/merge_requests/10"
# shellcheck disable=SC2031 # GITLAB_TOKEN exported for subshell test runs
export GITLAB_TOKEN="fake-gitlab-token"
export CI_SERVER_HOST="gitlab.com"
unset GH_TOKEN

# GitLab workspace config — same allowlist structure.
GL_WORKSPACE="${TMPDIR}/gl-workspace"
mkdir -p "${GL_WORKSPACE}"
cat > "${GL_WORKSPACE}/config.yaml" <<CFGEOF
version: "1"
create_issues:
  allow_targets:
    orgs:
      - test-group
    repos:
      - allowed-org/allowed-repo
CFGEOF
# shellcheck disable=SC2031 # CI_PROJECT_DIR exported for subshell test runs
export CI_PROJECT_DIR="${GL_WORKSPACE}"

# GitLab fixture: one proposal targeting a GitLab project.
GL_FIXTURE_ONE_PROPOSAL='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-group/target-project",
      "title": "Improve error handling in widget service",
      "what_happened": "The widget service crashed on empty input.",
      "what_could_go_better": "Input validation should reject empty payloads.",
      "proposed_change": "Add a nil check at the entry point.",
      "validation_criteria": "Widget service returns 400 on empty input.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

GL_FIXTURE_NO_PROPOSALS='{
  "summary": "The retro analysis found no actionable improvements.",
  "proposals": []
}'

# GitLab fixture: evidence-for (should be filtered same as GitHub).
GL_FIXTURE_EVIDENCE_FOR='{
  "summary": "The retro analysis found corroborating evidence.",
  "proposals": [
    {
      "target_repo": "test-group/target-project",
      "title": "Evidence for #1234: review agent missed authorization check",
      "what_happened": "The review agent did not flag a missing auth check.",
      "what_could_go_better": "Authorization checks should be flagged.",
      "proposed_change": "Add auth-check detection to review prompts.",
      "validation_criteria": "Review agent flags missing auth checks."
    }
  ]
}'

# GitLab fixture: subgroup repo (tests multi-segment path support).
GL_FIXTURE_SUBGROUP='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-group/subgroup/target-project",
      "title": "Fix subgroup project issue",
      "what_happened": "Something broke in a subgroup project.",
      "what_could_go_better": "It should not break.",
      "proposed_change": "Fix the thing.",
      "validation_criteria": "Thing works.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# GitLab fixture: proposal targeting originating repo in an unlisted org.
# Tests that is_target_allowed always allows the originating repo regardless
# of allow_targets — the GitLab analogue of allow-targets-originating-repo-allowed.
GL_FIXTURE_ORIGINATING_REPO_TARGET='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "unlisted-group/originating-project",
      "title": "Improve self-repo handling",
      "what_happened": "The originating repo had a gap.",
      "what_could_go_better": "Should be handled.",
      "proposed_change": "Add handling.",
      "validation_criteria": "Handling works.",
      "related_issues": {
        "searched": [
          "skip review dispatch zero files",
          "review dispatch routing"
        ],
        "found": []
      }
    }
  ]
}'

# GitLab fixture: a legacy six-field proposal without a dedup receipt.
GL_FIXTURE_NO_RECEIPT='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "test-group/target-project",
      "title": "Improve error handling in widget service",
      "what_happened": "The widget service crashed on empty input.",
      "what_could_go_better": "Input validation should reject empty payloads.",
      "proposed_change": "Add a nil check at the entry point.",
      "validation_criteria": "Widget service returns 400 on empty input."
    }
  ]
}'

# GitLab fixture: evidence-for with MR reference (! prefix instead of #).
GL_FIXTURE_EVIDENCE_FOR_MR='{
  "summary": "The retro analysis found corroborating evidence for an MR.",
  "proposals": [
    {
      "target_repo": "test-group/target-project",
      "title": "Evidence for !42: review agent missed authorization check",
      "what_happened": "The review agent did not flag a missing auth check.",
      "what_could_go_better": "Authorization checks should be flagged.",
      "proposed_change": "Add auth-check detection to review prompts.",
      "validation_criteria": "Review agent flags missing auth checks."
    }
  ]
}'

# GitLab fixture: proposal targeting a disallowed org (not in allow_targets).
GL_FIXTURE_DISALLOWED_TARGET='{
  "summary": "The retro analysis found one improvement opportunity.",
  "proposals": [
    {
      "target_repo": "disallowed-org/some-project",
      "title": "Improve logging in external project",
      "what_happened": "Logs were insufficient.",
      "what_could_go_better": "Add structured logging.",
      "proposed_change": "Add log fields.",
      "validation_criteria": "Logs contain expected fields."
    }
  ]
}'

# GitLab fixture: two allowed proposals — the first targets a project where
# issue creation fails (via CURL_MOCK_ISSUE_FAIL_PROJECT), the second succeeds.
GL_FIXTURE_CREATE_FAIL_THEN_OK='{
  "summary": "The retro analysis found two improvement opportunities.",
  "proposals": [
    {
      "target_repo": "test-group/unavailable-project",
      "title": "Proposal in unavailable project",
      "what_happened": "Something happened.",
      "what_could_go_better": "It could go better.",
      "proposed_change": "Change it.",
      "validation_criteria": "It works.",
      "related_issues": {
        "searched": [
          "unavailable project proposal",
          "proposal filing failure"
        ],
        "found": []
      }
    },
    {
      "target_repo": "test-group/target-project",
      "title": "Proposal in available project",
      "what_happened": "Something else happened.",
      "what_could_go_better": "It could also go better.",
      "proposed_change": "Change it too.",
      "validation_criteria": "It also works.",
      "related_issues": {
        "searched": [
          "available project proposal",
          "proposal filing success"
        ],
        "found": []
      }
    }
  ]
}'

run_gl_test() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"
  local expect_failure="${4:-false}"
  local comment_fail="${5:-}"
  local issue_fail="${6:-}"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  : > "${CURL_LOG}"
  # shellcheck disable=SC2031 # CURL_MOCK_COMMENT_FAIL exported for subshell test run
  export CURL_MOCK_COMMENT_FAIL="${comment_fail}"
  # shellcheck disable=SC2031 # CURL_MOCK_ISSUE_FAIL exported for subshell test run
  export CURL_MOCK_ISSUE_FAIL="${issue_fail}"

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  # Verify no gh CLI calls were made on GitLab paths (checked for both
  # success and expected-failure runs to catch regressions in intermediate
  # operations like forge_create_label / forge_create_issue).
  if [[ -s "${GH_LOG}" ]]; then
    echo "FAIL: ${test_name} — gh CLI was called (expected none for GitLab)"
    echo "Actual gh calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ "${expect_failure}" == "true" ]]; then
    if [[ ${exit_code} -eq 0 ]]; then
      echo "FAIL: ${test_name} — expected failure but got success"
      FAILURES=$((FAILURES + 1))
      return
    fi
    if [[ -n "${expected_stdout}" ]] && ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout.log"; then
      echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
      echo "Actual stdout:"
      cat "${TMPDIR}/stdout.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
    echo "PASS: ${test_name} (expected failure)"
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_stdout}" ]] && ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_gl_test_no_gh_call() {
  local test_name="$1"
  local json_content="$2"
  local expected_stdout="$3"

  local run_dir="${TMPDIR}/run-${test_name}"
  mkdir -p "${run_dir}/iteration-1/output"
  echo "${json_content}" > "${run_dir}/iteration-1/output/agent-result.json"
  : > "${GH_LOG}"
  : > "${GH_STDIN_LOG}"
  : > "${CURL_LOG}"
  # shellcheck disable=SC2031 # CURL_MOCK_COMMENT_FAIL exported for subshell test run
  export CURL_MOCK_COMMENT_FAIL=""
  # shellcheck disable=SC2031 # CURL_MOCK_ISSUE_FAIL exported for subshell test run
  export CURL_MOCK_ISSUE_FAIL=""

  local exit_code=0
  (cd "${run_dir}" && bash "${POST_SCRIPT}") > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  # Verify no gh CLI calls were made (checked before exit-code handling to
  # catch leaks even on failure paths, matching run_gl_test's structure).
  if [[ -s "${GH_LOG}" ]]; then
    echo "FAIL: ${test_name} — gh CLI was called (expected none for GitLab)"
    echo "Actual gh calls:"
    cat "${GH_LOG}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — exit code ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_stdout}" ]] && ! grep -qF -- "${expected_stdout}" "${TMPDIR}/stdout.log"; then
    echo "FAIL: ${test_name} — expected stdout pattern '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# GitLab happy path: one proposal filed, no gh calls.
run_gl_test_no_gh_call "gl-happy-path-one-proposal" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "Post-retro complete."

# GitLab: no proposals, comment posted.
run_gl_test_no_gh_call "gl-happy-path-no-proposals" \
  "${GL_FIXTURE_NO_PROPOSALS}" \
  "Post-retro complete."

# GitLab: curl is used for issue creation.
run_gl_test "gl-issue-created-via-curl" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "Created:"

# GitLab: evidence-for filtering works the same.
run_gl_test "gl-evidence-for-rejected" \
  "${GL_FIXTURE_EVIDENCE_FOR}" \
  "::warning::proposal[0] rejected"

# GitLab: subgroup repo paths accepted.
run_gl_test "gl-subgroup-accepted" \
  "${GL_FIXTURE_SUBGROUP}" \
  "Post-retro complete."

# GitLab: subgroup originating URL — verifies forge_parse_originating_url
# handles multi-segment paths (group/subgroup/project), not just two-segment.
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/test-group/subgroup/test-project/-/merge_requests/42"
run_gl_test_no_gh_call "gl-subgroup-originating-url" \
  "${GL_FIXTURE_NO_PROPOSALS}" \
  "Post-retro complete."
# Verify comment was posted to the correct subgroup project notes endpoint.
if ! grep -q "test-group%2Fsubgroup%2Ftest-project" "${CURL_LOG}"; then
  echo "FAIL: gl-subgroup-originating-url-endpoint — CURL_LOG missing URL-encoded subgroup originating path"
  echo "Actual curl calls:"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: gl-subgroup-originating-url-endpoint (notes posted to subgroup project)"
fi
if ! grep -q "/merge_requests/42/notes" "${CURL_LOG}"; then
  echo "FAIL: gl-subgroup-originating-url-mr — CURL_LOG missing /merge_requests/42/notes"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: gl-subgroup-originating-url-mr (correct MR number in notes endpoint)"
fi
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/test-group/test-project/-/merge_requests/10"

# GitLab: disallowed target org is skipped with warning.
run_gl_test "gl-disallowed-target-skipped" \
  "${GL_FIXTURE_DISALLOWED_TARGET}" \
  "not in create_issues.allow_targets"

# GitLab: originating repo is always allowed even when its org is NOT in the
# allowlist — isolates the originating-repo bypass from the org allowlist.
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/unlisted-group/originating-project/-/merge_requests/10"
run_gl_test_no_gh_call "gl-originating-repo-always-allowed" \
  "${GL_FIXTURE_ORIGINATING_REPO_TARGET}" \
  "Post-retro complete."

# GitLab receipt gate: legacy proposal without a receipt is not filed.
# The receipt rendering itself is shared jq (BODY) already covered by the
# GitHub receipt tests; here we verify the gate fires on the GitLab path.
run_gl_test "gl-receipt-gate-skips-filing" \
  "${GL_FIXTURE_NO_RECEIPT}" \
  "::warning::proposal[0] not filed"
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/test-group/test-project/-/merge_requests/10"

# GitLab: no CI_PROJECT_DIR — cross-repo proposals blocked, originating allowed.
# Mirrors the GitHub allow-targets-no-workspace tests.
unset CI_PROJECT_DIR
run_gl_test "gl-no-workspace-cross-repo-blocked" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "::warning::Skipping issue creation in 'test-group/target-project'"

# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/unlisted-group/originating-project/-/merge_requests/10"
run_gl_test_no_gh_call "gl-no-workspace-originating-allowed" \
  "${GL_FIXTURE_ORIGINATING_REPO_TARGET}" \
  "Post-retro complete."
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/test-group/test-project/-/merge_requests/10"
# shellcheck disable=SC2031 # CI_PROJECT_DIR exported for subshell test run
export CI_PROJECT_DIR="${GL_WORKSPACE}"

# GitLab: invalid originating URL rejected.
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://github.com/test-org/test-repo/pull/10"
run_gl_test "gl-rejects-github-url" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "ORIGINATING_URL does not match expected GitLab pattern" \
  "true"
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/test-group/test-project/-/merge_requests/10"

# GitLab: disallowed host rejected.
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://evil.com/test-group/test-project/-/issues/10"
run_gl_test "gl-rejects-disallowed-host" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "does not match CI_SERVER_HOST" \
  "true"
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/test-group/test-project/-/merge_requests/10"

# GitLab: issue URL accepted (not just MR).
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/test-group/test-project/-/issues/42"
run_gl_test_no_gh_call "gl-issue-url-accepted" \
  "${GL_FIXTURE_NO_PROPOSALS}" \
  "Post-retro complete."
# Verify comment was posted to /issues/42/notes (not /merge_requests/42/notes).
if ! grep -q "/issues/42/notes" "${CURL_LOG}"; then
  echo "FAIL: gl-issue-url-resource-path — CURL_LOG missing /issues/42/notes"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: gl-issue-url-resource-path (notes posted to /issues/ not /merge_requests/)"
fi
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/test-group/test-project/-/merge_requests/10"

# GitLab: gitlab.cee.redhat.com host accepted.
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.cee.redhat.com/team/project/-/issues/5"
CI_SERVER_HOST="gitlab.cee.redhat.com"
run_gl_test_no_gh_call "gl-redhat-host-accepted" \
  "${GL_FIXTURE_NO_PROPOSALS}" \
  "Post-retro complete."
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/test-group/test-project/-/merge_requests/10"
CI_SERVER_HOST="gitlab.com"

# GitLab: forge_get_comment_max_len returns 1000000 (not 65000).
# Use an oversized summary > 65000 chars (GitHub limit) but < 1000000 (GitLab limit).
# On GitLab this should NOT be truncated.
GL_BIG_SUMMARY=$(printf 'x%.0s' $(seq 1 70000))
GL_FIXTURE_BIG=$(jq -nc --arg s "${GL_BIG_SUMMARY}" '{summary: $s, proposals: []}')
run_gl_test "gl-no-truncation-at-65k" \
  "${GL_FIXTURE_BIG}" \
  "Post-retro complete."
# Verify the body was NOT truncated (contrast with GitHub's 65000 limit).
if grep -q "truncated" "${CURL_LOG}"; then
  echo "FAIL: gl-no-truncation-at-65k-body — body was truncated (should not be under GitLab's 1MB limit)"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: gl-no-truncation-at-65k-body (body posted untruncated)"
fi

# GitLab: 403 on comment posting is non-fatal.
run_gl_test "gl-comment-403-non-fatal" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "::warning::Could not post summary comment" \
  "false" \
  "403"

# GitLab: 401 on comment posting is non-fatal.
run_gl_test "gl-comment-401-non-fatal" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "::warning::Could not post summary comment" \
  "false" \
  "401"

# GitLab: 500 on comment posting remains fatal.
run_gl_test "gl-comment-500-fatal" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "ERROR: failed to post summary comment" \
  "true" \
  "500"

# GitLab: 422 on comment posting remains fatal.
run_gl_test "gl-comment-422-fatal" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "ERROR: failed to post summary comment" \
  "true" \
  "422"

# GitLab: issue creation returns response without web_url — reported,
# but non-fatal.
run_gl_test "gl-issue-null-web-url-non-fatal" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "GitLab API error: unexpected response from issue creation" \
  "false" \
  "" \
  "null-url"

# GitLab: issue creation HTTP error (curl fails) — reported, but non-fatal.
run_gl_test "gl-issue-api-error-non-fatal" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "GitLab API error: issue creation failed" \
  "false" \
  "" \
  "api-error"

# GitLab: first creation fails, second succeeds — later proposal attempted,
# summary posted, failure listed separately from the filed link.
run_create_fail_case "gl-create-fail-then-ok" \
  "${GL_FIXTURE_CREATE_FAIL_THEN_OK}" \
  CURL_MOCK_ISSUE_FAIL_PROJECT "test-group%2Funavailable-project"
assert_create_fail_exit "gl-create-fail-then-ok-exit-zero"
assert_file_lacks "gl-create-fail-then-ok-no-gh" "${GH_LOG}" "gh "
assert_file_contains "gl-create-fail-then-ok-error-logged" "${TMPDIR}/stdout.log" \
  "::warning::Failed to create issue in test-group/unavailable-project for proposal[0] (Proposal in unavailable project)"
assert_file_contains "gl-create-fail-then-ok-later-attempted" "${CURL_LOG}" \
  "/projects/test-group%2Ftarget-project/issues"
assert_file_contains "gl-create-fail-then-ok-summary-posted" "${CURL_LOG}" \
  "/merge_requests/10/notes"
assert_file_contains "gl-create-fail-then-ok-success-linked" "${CURL_BODY_LOG}" \
  "- [Proposal in available project](https://gitlab.com/test-group/target-project/-/issues/99)"
assert_file_contains "gl-create-fail-then-ok-failed-section" "${CURL_BODY_LOG}" \
  "### Proposals not filed (issue creation failed)"
assert_file_contains "gl-create-fail-then-ok-failed-listed" "${CURL_BODY_LOG}" \
  "- **Proposal in unavailable project** (\`test-group/unavailable-project\`)"
assert_file_lacks "gl-create-fail-then-ok-failed-not-linked" "${CURL_BODY_LOG}" \
  "[Proposal in unavailable project]("

# GitLab: all creations fail — summary still posted, failures logged.
run_create_fail_case "gl-create-all-fail" \
  "${GL_FIXTURE_CREATE_FAIL_THEN_OK}" \
  CURL_MOCK_ISSUE_FAIL "api-error"
assert_create_fail_exit "gl-create-all-fail-exit-zero"
assert_file_contains "gl-create-all-fail-first-logged" "${TMPDIR}/stdout.log" \
  "::warning::Failed to create issue in test-group/unavailable-project for proposal[0]"
assert_file_contains "gl-create-all-fail-second-logged" "${TMPDIR}/stdout.log" \
  "::warning::Failed to create issue in test-group/target-project for proposal[1]"
assert_file_contains "gl-create-all-fail-summary-posted" "${CURL_LOG}" \
  "/merge_requests/10/notes"
assert_file_lacks "gl-create-all-fail-no-filed-section" "${CURL_BODY_LOG}" \
  "### Proposals filed"
assert_file_contains "gl-create-all-fail-both-listed" "${CURL_BODY_LOG}" \
  "- **Proposal in available project** (\`test-group/target-project\`)"

# GitLab: summary-posting errors stay fatal even after a creation failure.
run_create_fail_case "gl-create-fail-comment-500" \
  "${GL_FIXTURE_CREATE_FAIL_THEN_OK}" \
  CURL_MOCK_ISSUE_FAIL_PROJECT "test-group%2Funavailable-project" \
  "500"
assert_create_fail_exit "gl-create-fail-comment-500-fatal" "true"
assert_file_contains "gl-create-fail-comment-500-error" "${TMPDIR}/stdout.log" \
  "ERROR: failed to post summary comment"

# GitLab: verify curl calls hit expected API endpoints (not just exit code).
# Catches regressions in URL construction that the mock would silently accept.
run_gl_test_no_gh_call "gl-curl-endpoints-correct" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "Post-retro complete."
if ! grep -q "/projects/" "${CURL_LOG}"; then
  echo "FAIL: gl-curl-endpoints-correct — CURL_LOG missing /projects/ endpoint"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: gl-curl-endpoints-correct (CURL_LOG has /projects/ calls)"
fi
if ! grep -q "/labels" "${CURL_LOG}"; then
  echo "FAIL: gl-curl-endpoints-labels — CURL_LOG missing /labels endpoint"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: gl-curl-endpoints-labels (CURL_LOG has /labels calls)"
fi
if ! grep -q "/issues" "${CURL_LOG}"; then
  echo "FAIL: gl-curl-endpoints-issues — CURL_LOG missing /issues endpoint"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: gl-curl-endpoints-issues (CURL_LOG has /issues calls)"
fi
if ! grep -q "/merge_requests/10/notes" "${CURL_LOG}"; then
  echo "FAIL: gl-curl-endpoints-notes — CURL_LOG missing /merge_requests/10/notes endpoint"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: gl-curl-endpoints-notes (CURL_LOG has /merge_requests/10/notes)"
fi

# GitLab: subgroup project paths are correctly URL-encoded in API calls.
run_gl_test_no_gh_call "gl-subgroup-url-encoding" \
  "${GL_FIXTURE_SUBGROUP}" \
  "Post-retro complete."
if ! grep -q "test-group%2Fsubgroup%2Ftarget-project" "${CURL_LOG}"; then
  echo "FAIL: gl-subgroup-url-encoding — CURL_LOG missing URL-encoded subgroup path"
  echo "Actual curl calls:"
  cat "${CURL_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: gl-subgroup-url-encoding (CURL_LOG has encoded subgroup path)"
fi

# GitLab: evidence-for with MR reference (!) filtered same as # reference.
run_gl_test "gl-evidence-for-mr-ref-rejected" \
  "${GL_FIXTURE_EVIDENCE_FOR_MR}" \
  "::warning::proposal[0] rejected"

# GitLab: single-segment project path rejected by URL validation.
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/only-one-segment/-/issues/1"
run_gl_test "gl-rejects-single-segment-url" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "ORIGINATING_URL does not match expected GitLab pattern" \
  "true"
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://gitlab.com/test-group/test-project/-/merge_requests/10"

# GitLab: FULLSEND_VALIDATED_ITERATION_DIR path works with GitLab forge.
# Mirrors the GitHub validated-dir-expected-filename test under GL context.
gl_vdir_run="${TMPDIR}/run-gl-validated-dir"
gl_vdir="${gl_vdir_run}/validated-output"
mkdir -p "${gl_vdir}"
echo "${GL_FIXTURE_ONE_PROPOSAL}" > "${gl_vdir}/agent-result.json"
mkdir -p "${gl_vdir_run}/iteration-2/output"
echo '{}' > "${gl_vdir_run}/iteration-2/output/agent-result.json"
: > "${GH_LOG}"
: > "${CURL_LOG}"
# shellcheck disable=SC2031 # CURL_MOCK_COMMENT_FAIL exported for subshell test run
export CURL_MOCK_COMMENT_FAIL=""
# shellcheck disable=SC2031 # CURL_MOCK_ISSUE_FAIL exported for subshell test run
export CURL_MOCK_ISSUE_FAIL=""
gl_vdir_exit=0
(
  cd "${gl_vdir_run}"
  # shellcheck disable=SC2031,SC2030 # FULLSEND_VALIDATED_ITERATION_DIR exported for subshell
  export FULLSEND_VALIDATED_ITERATION_DIR="${gl_vdir}"
  bash "${POST_SCRIPT}"
) > "${TMPDIR}/stdout.log" 2>&1 || gl_vdir_exit=$?
if [[ ${gl_vdir_exit} -ne 0 ]]; then
  echo "FAIL: gl-validated-dir — exit code ${gl_vdir_exit}"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
elif ! grep -qF "Reading retro result from: ${gl_vdir}/agent-result.json" "${TMPDIR}/stdout.log"; then
  echo "FAIL: gl-validated-dir — expected validated dir path in stdout"
  cat "${TMPDIR}/stdout.log"
  FAILURES=$((FAILURES + 1))
elif [[ -s "${GH_LOG}" ]]; then
  echo "FAIL: gl-validated-dir — gh CLI was called (expected none for GitLab)"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: gl-validated-dir (FULLSEND_VALIDATED_ITERATION_DIR works under GitLab)"
fi

# --- Results ---

if [[ ${FAILURES} -gt 0 ]]; then
  echo ""
  echo "${FAILURES} test(s) failed."
  exit 1
fi

echo ""
echo "All post-retro tests passed."
