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

# --- Mock fullsend CLI (for Jira tests) ---
FULLSEND_LOG="${TMPDIR}/fullsend-calls.log"
FULLSEND_ENV_LOG="${TMPDIR}/fullsend-env.log"
FULLSEND_STDIN_LOG="${TMPDIR}/fullsend-stdin.log"
cat > "${MOCK_BIN}/fullsend" <<MOCKEOF
#!/usr/bin/env bash
echo "fullsend \$*" >> "${FULLSEND_LOG}"
echo "token=\${FULLSEND_JIRA_TOKEN-unset} email=\${FULLSEND_JIRA_EMAIL-unset}" >> "${FULLSEND_ENV_LOG}"
if [[ "\$1" == "issues" ]] && [[ "\$2" == "create" ]]; then
  if [[ "\$3" == "--help" ]]; then
    # Cobra prints the usage header and the command path on separate lines.
    case "\${FULLSEND_MOCK_CREATE_HELP:-}" in
      missing-fullsend-dir)
        printf 'Usage:\n  fullsend issues create [flags]\n\nFlags:\n'
        echo "  --tracker string"
        exit 0
        ;;
      missing-tracker)
        printf 'Usage:\n  fullsend issues create [flags]\n\nFlags:\n'
        echo "  --fullsend-dir string"
        exit 0
        ;;
      unrelated-usage)
        printf 'Usage:\n  fullsend issues something-else [flags]\n\nFlags:\n'
        echo "  --fullsend-dir string"
        echo "  --tracker string"
        exit 0
        ;;
    esac
    printf 'Usage:\n  fullsend issues create [flags]\n\nFlags:\n'
    echo "  --fullsend-dir string"
    echo "  --tracker string"
    exit 0
  fi
  if [[ -n "\${FULLSEND_MOCK_FAIL_TITLE:-}" ]] && [[ "\$*" == *"--title \${FULLSEND_MOCK_FAIL_TITLE}"* ]]; then
    echo "ERROR: mocked creation failure for \${FULLSEND_MOCK_FAIL_TITLE}" >&2
    exit 1
  fi
  # Answer with a key in the requested project, so a test that files into a
  # secondary target exercises the success path instead of failing the
  # ^<project>-[0-9]+$ key check.
  MOCK_PROJECT=""
  MOCK_PREV=""
  for mock_arg in "\$@"; do
    if [[ "\${MOCK_PREV}" == "--project" ]]; then
      MOCK_PROJECT="\${mock_arg}"
    fi
    MOCK_PREV="\${mock_arg}"
  done
  cat >> "${FULLSEND_STDIN_LOG}"
  echo "{\"number\":100,\"key\":\"\${MOCK_PROJECT:-PROJ}-100\",\"title\":\"mock title\",\"url\":\"https://mock.atlassian.net/browse/\${MOCK_PROJECT:-PROJ}-100\"}"
  exit 0
fi
if [[ "\$1" == "issues" ]] && [[ "\$2" == "post-comment" ]]; then
  if [[ "\$3" == "--help" ]]; then
    echo "Usage: fullsend issues post-comment [flags]"
    case "\${FULLSEND_MOCK_KEEP_HISTORY:-}" in
      supported)
        echo "  --keep-history          append previous content as collapsed history blocks (set false to replace in-place) (default true)"
        ;;
      deprecated)
        echo "  --keep-history          deprecated: no effect (every result is posted as a new comment; sticky comments were removed) (default true)"
        ;;
    esac
    exit 0
  fi
  cat >> "${FULLSEND_STDIN_LOG}"
  echo '{"id":10,"url":"https://mock.atlassian.net/browse/PROJ-10#comment-1"}'
  exit 0
fi
exit 0
MOCKEOF
chmod +x "${MOCK_BIN}/fullsend"

# --- Mock curl (for GitLab and Jira tests) ---
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

# Jira Cloud tenant info (cloud ID discovery, unauthenticated)
if [[ "${URL}" == *"/_edge/tenant_info" ]]; then
  if [[ "${JIRA_MOCK_TENANT_INFO_FAIL:-}" == "1" ]]; then
    echo "curl: (22) The requested URL returned error: 500" >&2
    exit 22
  fi
  echo '{"cloudId":"11111111-2222-3333-4444-555555555555","url":"https://mock.atlassian.net"}'
  exit 0
fi

# Atlassian OAuth token endpoint (client-credentials mode). Every call is
# already recorded in CURL_LOG, so tests can count exchanges.
if [[ "${URL}" == "https://auth.atlassian.com/oauth/token" ]]; then
  # Emulate --write-out '\n%{http_code}': _jira_auth_mint_now reads the status
  # from the last line of the response.
  if [[ "${JIRA_MOCK_TOKEN_FAIL:-}" == "1" ]]; then
    printf '%s\n%s' '{"error":"invalid_client"}' '500'
    exit 0
  fi
  printf '%s\n%s' '{"access_token":"mock-access-token","expires_in":3600,"token_type":"Bearer"}' '200'
  exit 0
fi

# Jira Cloud REST API
if [[ "${URL}" == *"/rest/api/3/"* ]]; then
  case "${URL}" in
    # Jira validates label updates against the edit screen, not the create
    # screen, so the edit metadata decides label support.
    */issue/PROJ-*/editmeta)
      if [[ "${JIRA_MOCK_NO_EDIT_LABELS:-}" == "1" ]]; then
        echo '{"fields":{"summary":{"required":true},"description":{"required":false}}}'
      else
        echo '{"fields":{"summary":{"required":true},"description":{"required":false},"labels":{"required":false,"schema":{"type":"array"}}}}'
      fi
      ;;
    */issue/createmeta/PROJ/issuetypes\?*)
      if [[ "${JIRA_MOCK_CREATEMETA_PAGES:-}" == "1" ]]; then
        META_START=$(printf '%s' "$*" | sed -n 's/.*startAt=\([0-9][0-9]*\).*/\1/p')
        if [[ "${META_START:-0}" == "0" ]]; then
          echo '{"issueTypes":[{"id":"10000","name":"Other"}],"total":2,"isLast":false}'
        else
          echo '{"issueTypes":[{"id":"10001","name":"Task"}],"total":2,"isLast":true}'
        fi
      else
        echo '{"issueTypes":[{"id":"10001","name":"Task"}]}'
      fi
      ;;
    */issue/createmeta/PROJ/issuetypes/10001\?*)
      if [[ "${JIRA_MOCK_REQUIRED_FIELD:-}" == "1" ]]; then
        echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false},{"fieldId":"customfield_10050","required":true,"hasDefaultValue":false}]}'
      elif [[ "${JIRA_MOCK_NO_DESCRIPTION:-}" == "1" ]]; then
        echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false},{"fieldId":"labels","required":false,"hasDefaultValue":false}]}'
      elif [[ "${JIRA_MOCK_CREATE_NO_LABELS:-}" == "1" ]]; then
        echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false},{"fieldId":"description","required":false,"hasDefaultValue":false}]}'
      else
        echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false},{"fieldId":"description","required":false,"hasDefaultValue":false},{"fieldId":"labels","required":false,"hasDefaultValue":false},{"fieldId":"reporter","required":true,"hasDefaultValue":true}]}'
      fi
      ;;
    */issue/createmeta/OTHER/issuetypes\?*)
      echo '{"issueTypes":[{"id":"10001","name":"Task"}]}'
      ;;
    */issue/createmeta/OTHER/issuetypes/10001\?*)
      echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false},{"fieldId":"description","required":false,"hasDefaultValue":false},{"fieldId":"labels","required":false,"hasDefaultValue":false}]}'
      ;;
    */issue/createmeta/PROJ/issuetypes/10000\?*)
      echo '{"fields":[{"fieldId":"summary","required":true,"hasDefaultValue":false},{"fieldId":"description","required":false,"hasDefaultValue":false},{"fieldId":"labels","required":false,"hasDefaultValue":false}]}'
      ;;
    */search/jql)
      if [[ "${JIRA_MOCK_BAD_SEARCH:-}" == "html" ]]; then
        echo '<html>maintenance</html>'
      elif [[ "${JIRA_MOCK_SEARCH_MISSING_TOKEN:-}" == "1" ]]; then
        echo '{"issues":[],"isLast":false}'
      elif [[ "${JIRA_MOCK_SEARCH_PAGE_CAP_DUP:-}" == "1" ]]; then
        echo '{"issues":[{"key":"PROJ-7","fields":{"summary":"Improve error handling in widget service"}}],"nextPageToken":"page-next","isLast":false}'
      elif [[ "${JIRA_MOCK_SEARCH_PAGE2_DUP:-}" == "1" ]]; then
        if [[ "$*" == *'page-2'* ]]; then
          echo '{"issues":[{"key":"PROJ-7","fields":{"summary":"Improve error handling in widget service"}}],"isLast":true}'
        else
          echo '{"issues":[],"nextPageToken":"page-2","isLast":false}'
        fi
      elif [[ "${JIRA_MOCK_SEARCH_ALWAYS_MORE:-}" == "1" ]]; then
        echo '{"issues":[],"nextPageToken":"page-next","isLast":false}'
      elif [[ "${JIRA_MOCK_DUP_PROJECT_ONLY:-}" == "1" ]]; then
        echo '{"issues":[{"key":"PROJ-7","fields":{"summary":"a to be"}}],"isLast":true}'
      elif [[ "${JIRA_MOCK_STOPWORD_DUP:-}" == "1" ]]; then
        echo '{"issues":[{"key":"PROJ-7","fields":{"summary":"Fix this bug"}}],"isLast":true}'
      elif [[ "${JIRA_MOCK_MULTILINE_DUP:-}" == "1" ]]; then
        echo '{"issues":[{"key":"PROJ-7","fields":{"summary":"Fix Jira API search"}}],"isLast":true}'
      elif [[ "${JIRA_MOCK_DUP:-}" == "1" ]]; then
        echo '{"issues":[{"key":"PROJ-7","fields":{"summary":"Improve error handling in widget service"}}],"isLast":true}'
      else
        echo '{"issues":[],"isLast":true}'
      fi
      ;;
    */issue/PROJ-*)
      if [[ "${JIRA_MOCK_LABEL_FAIL:-}" == "1" ]]; then
        echo '{"errorMessages":["Custom label field update failed"]}'
        printf '\n500'
      else
        printf '\n204'
      fi
      ;;
    *)
      exit 22
      ;;
  esac
  exit 0
fi

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
export FULLSEND_LOG="${FULLSEND_LOG}"
export FULLSEND_ENV_LOG="${FULLSEND_ENV_LOG}"
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
tracker:
  github:
    allowed_targets:
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
  : > "${FULLSEND_LOG}"
  : > "${FULLSEND_ENV_LOG}"
  : > "${FULLSEND_STDIN_LOG}"
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
  : > "${FULLSEND_LOG}"
  : > "${FULLSEND_ENV_LOG}"
  : > "${FULLSEND_STDIN_LOG}"
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
# Verify that proposals targeting repos not in tracker.<provider>.allowed_targets
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

# Skipped-proposal summary names the provider-specific config key.
run_test_stdin "allow-targets-summary-names-tracker-key" \
  "${FIXTURE_DISALLOWED_TARGET}" \
  "update \`tracker.github.allowed_targets\` in config.yaml"

# ---------------------------------------------------------------------------
# Layered config tests (config.base.yaml beneath config.yaml)
# tracker is replaced as a whole object when the overlay sets it and
# inherited from the base otherwise; an unparseable layer fails closed.
# ---------------------------------------------------------------------------

# layered_workspace NAME BASE OVERLAY — point GITHUB_WORKSPACE at a fresh
# workspace holding BASE as config.base.yaml and OVERLAY as config.yaml.
# An empty BASE or OVERLAY leaves that file absent.
layered_workspace() {
  local ws="${TMPDIR}/layered-$1"
  mkdir -p "${ws}"
  if [[ -n "$2" ]]; then
    printf '%s\n' "$2" > "${ws}/config.base.yaml"
  fi
  if [[ -n "$3" ]]; then
    printf '%s\n' "$3" > "${ws}/config.yaml"
  fi
  # shellcheck disable=SC2031 # GITHUB_WORKSPACE exported for subshell test runs
  export GITHUB_WORKSPACE="${ws}"
}

LAYERED_BASE_ORG='version: "1"
tracker:
  github:
    allowed_targets:
      orgs:
        - test-org'
LAYERED_SPARSE_OVERLAY='version: "1"'
LAYERED_OVERLAY_REPO='version: "1"
tracker:
  github:
    allowed_targets:
      repos:
        - allowed-org/allowed-repo'
LAYERED_OVERLAY_EMPTY='version: "1"
tracker:
  github:
    allowed_targets:
      orgs: []
      repos: []'
LAYERED_INVALID='version: "1"
tracker: [unclosed'

layered_workspace "base-sparse" "${LAYERED_BASE_ORG}" "${LAYERED_SPARSE_OVERLAY}"
run_test "layered-base-only-target-allowed" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create --repo test-org/target-repo"

layered_workspace "base-no-overlay" "${LAYERED_BASE_ORG}" ""
run_test "layered-base-only-no-overlay-allowed" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create --repo test-org/target-repo"

# Per-repo layout: both layers live under .fullsend/.
LAYERED_PER_REPO="${TMPDIR}/layered-per-repo"
mkdir -p "${LAYERED_PER_REPO}/.fullsend"
printf '%s\n' "${LAYERED_BASE_ORG}" > "${LAYERED_PER_REPO}/.fullsend/config.base.yaml"
printf '%s\n' "${LAYERED_SPARSE_OVERLAY}" > "${LAYERED_PER_REPO}/.fullsend/config.yaml"
# shellcheck disable=SC2031 # GITHUB_WORKSPACE exported for subshell test run
export GITHUB_WORKSPACE="${LAYERED_PER_REPO}"
run_test "layered-per-repo-base-only-target-allowed" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create --repo test-org/target-repo"

layered_workspace "overlay-wins" "${LAYERED_BASE_ORG}" "${LAYERED_OVERLAY_REPO}"
run_test_no_gh_call "layered-overlay-tracker-replaces-base" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create" \
  "::warning::Skipping issue creation in 'test-org/target-repo'"
run_test "layered-overlay-tracker-target-allowed" \
  "${FIXTURE_REPO_ALLOWLIST_TARGET}" \
  "gh issue create --repo allowed-org/allowed-repo"

layered_workspace "overlay-empty" "${LAYERED_BASE_ORG}" "${LAYERED_OVERLAY_EMPTY}"
run_test_no_gh_call "layered-overlay-explicit-empty-not-inherited" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create" \
  "::warning::Skipping issue creation in 'test-org/target-repo'"

# An explicit null tracker inherits the base grants and warns about it; a
# sparse overlay (no tracker key) or an empty target policy does not.
layered_workspace "overlay-null" "${LAYERED_BASE_ORG}" 'version: "1"
tracker:'
run_test_stdout "layered-overlay-null-tracker-warns" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "::warning::config.yaml sets tracker to null, so cross-repo targets from config.base.yaml are inherited"
run_test "layered-overlay-null-tracker-inherits" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create --repo test-org/target-repo"
layered_workspace "base-sparse-nowarn" "${LAYERED_BASE_ORG}" "${LAYERED_SPARSE_OVERLAY}"
run_test_stdout_absent "layered-sparse-overlay-no-null-warning" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created:" \
  "sets tracker to null"

layered_workspace "no-base" "" "${LAYERED_SPARSE_OVERLAY}"
run_test_no_gh_call "layered-no-base-sparse-overlay-skipped" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create" \
  "::warning::Skipping issue creation in 'test-org/target-repo'"

layered_workspace "invalid-base" "${LAYERED_INVALID}" "${LAYERED_OVERLAY_REPO}"
run_test_no_gh_call "layered-invalid-base-fails-closed" \
  "${FIXTURE_REPO_ALLOWLIST_TARGET}" \
  "gh issue create" \
  "::warning::cannot parse config.base.yaml"

layered_workspace "invalid-overlay" "${LAYERED_BASE_ORG}" "${LAYERED_INVALID}"
run_test_no_gh_call "layered-invalid-overlay-fails-closed" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create" \
  "::warning::cannot parse config.yaml"

# The originating repo stays allowed even when config cannot be parsed.
layered_workspace "invalid-base-source" "${LAYERED_INVALID}" "${LAYERED_SPARSE_OVERLAY}"
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://github.com/unlisted-org/originating-repo/pull/10"
run_test "layered-invalid-base-originating-allowed" \
  "${FIXTURE_ORIGINATING_REPO_TARGET}" \
  "gh issue create --repo unlisted-org/originating-repo"
# shellcheck disable=SC2031 # ORIGINATING_URL exported for subshell test run
ORIGINATING_URL="https://github.com/test-org/test-repo/pull/10"

# Only the provider issues are created on grants targets: GitLab groups do
# not admit GitHub repositories, and an ambiguous multi-provider mapping
# grants nothing.
layered_workspace "other-provider" "" 'tracker:
  gitlab:
    allowed_targets:
      groups:
        - test-org'
run_test_no_gh_call "tracker-other-provider-not-honored" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create" \
  "::warning::Skipping issue creation in 'test-org/target-repo'"

layered_workspace "multi-provider" "" 'tracker:
  github:
    allowed_targets:
      orgs:
        - test-org
  gitlab:
    allowed_targets:
      groups:
        - test-org'
run_test_no_gh_call "tracker-multiple-providers-grant-nothing" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create" \
  "::warning::Skipping issue creation in 'test-org/target-repo'"
run_test_no_gh_call "tracker-multiple-providers-warns" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create" \
  "::warning::tracker mapping selects provider(s) 'github,gitlab'"

# A leftover create_issues.allow_targets key is no longer read and is named
# in a warning.
layered_workspace "old-key" "" 'create_issues:
  allow_targets:
    orgs:
      - test-org'
run_test_no_gh_call "old-allow-targets-key-warns" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create" \
  "::warning::config.yaml sets create_issues.allow_targets, which is no longer read"

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

# ---------------------------------------------------------------------------
# RETRO_MODE on a forge tracker
# RETRO_MODE applies to the GitHub/GitLab filing path, not only to Jira:
# summary_only must file nothing, and issues_only must file issues without
# posting the summary comment.
# ---------------------------------------------------------------------------

unset FULLSEND_TRACKER

# summary_only: no issue is created and the proposal is listed in the summary.
export RETRO_MODE="summary_only"
run_test_no_gh_call "github-summary-only-no-issue" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create" \
  "Mode is summary_only — skipping issue creation for proposal[0]"
assert_file_contains "github-summary-only-in-summary" "${GH_STDIN_LOG}" \
  "### Proposals (issue creation disabled)"
assert_file_contains "github-summary-only-proposal-listed" "${GH_STDIN_LOG}" \
  "- **Improve error handling in widget service** (\`test-org/target-repo\`)"

# issues_only: the issue is filed and no summary comment is posted.
export RETRO_MODE="issues_only"
run_test "github-issues-only-files-issue" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "gh issue create"
assert_file_contains "github-issues-only-skips-comment" "${TMPDIR}/stdout.log" \
  "Mode is issues_only — skipping summary comment posting"
if [[ -s "${GH_STDIN_LOG}" ]]; then
  echo "FAIL: github-issues-only-no-comment — a summary comment body was posted"
  cat "${GH_STDIN_LOG}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: github-issues-only-no-comment"
fi
unset RETRO_MODE

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
tracker:
  gitlab:
    allowed_targets:
      groups:
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
  "not in tracker.gitlab.allowed_targets"

# GitLab: a subgroup in allowed_targets.groups admits projects nested under
# it, but not projects in its parent group.
GL_SUBGROUP_WORKSPACE="${TMPDIR}/gl-subgroup-workspace"
mkdir -p "${GL_SUBGROUP_WORKSPACE}"
cat > "${GL_SUBGROUP_WORKSPACE}/config.yaml" <<CFGEOF
tracker:
  gitlab:
    allowed_targets:
      groups:
        - test-group/subgroup
CFGEOF
# shellcheck disable=SC2031 # CI_PROJECT_DIR exported for subshell test runs
export CI_PROJECT_DIR="${GL_SUBGROUP_WORKSPACE}"
run_gl_test_no_gh_call "gl-subgroup-group-target-allowed" \
  "${GL_FIXTURE_SUBGROUP}" \
  "Created: "
run_gl_test "gl-subgroup-group-parent-skipped" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "::warning::Skipping issue creation in 'test-group/target-project'"

# GitLab: base-only group target is inherited by a sparse overlay.
GL_LAYERED_WORKSPACE="${TMPDIR}/gl-layered-workspace"
mkdir -p "${GL_LAYERED_WORKSPACE}"
cat > "${GL_LAYERED_WORKSPACE}/config.base.yaml" <<CFGEOF
tracker:
  gitlab:
    allowed_targets:
      groups:
        - test-group
CFGEOF
printf 'version: "1"\n' > "${GL_LAYERED_WORKSPACE}/config.yaml"
# shellcheck disable=SC2031 # CI_PROJECT_DIR exported for subshell test runs
export CI_PROJECT_DIR="${GL_LAYERED_WORKSPACE}"
run_gl_test_no_gh_call "gl-layered-base-only-target-allowed" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "Created: "
# shellcheck disable=SC2031 # CI_PROJECT_DIR exported for subshell test runs
export CI_PROJECT_DIR="${GL_WORKSPACE}"

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

# ---------------------------------------------------------------------------
# Jira tracker test cases (FULLSEND_FORGE=github, FULLSEND_TRACKER=jira)
# ---------------------------------------------------------------------------

JIRA_WORKSPACE="${TMPDIR}/jira-workspace"
mkdir -p "${JIRA_WORKSPACE}"
export GITHUB_WORKSPACE="${JIRA_WORKSPACE}"

export FULLSEND_FORGE="github"
export GH_TOKEN="fake-token"
export ORIGINATING_URL="https://github.com/test-org/test-repo/pull/10"
export FULLSEND_TRACKER="jira"
export JIRA_BASE_URL="https://mock.atlassian.net"
mkdir -p "${TMPDIR}/dot-fullsend"
# For a Jira tracker the allowlist and primary project are read from
# FULLSEND_DIR, the directory the fullsend CLI reads.
cat > "${TMPDIR}/dot-fullsend/config.yaml" <<CFGEOF
tracker:
  jira:
    base_url: https://mock.atlassian.net
    project: PROJ
    allowed_targets:
      projects:
        - PROJ
CFGEOF
export JIRA_USER_EMAIL="bot@mock.example"
export JIRA_TOKEN="fake-jira-token"
export FULLSEND_DIR="${TMPDIR}/dot-fullsend"
export FULLSEND_JIRA_CLIENT_ID=""
export FULLSEND_JIRA_CLIENT_SECRET=""
export RETRO_JIRA_PROJECT="PROJ"
export RETRO_MODE="all"

# 1. Live creates issue in Jira
run_test_stdout "jira/live-creates-issue" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"

if grep -qF 'fullsend issues create --tracker jira' "${FULLSEND_LOG}" 2>/dev/null \
  && grep -qF -- '--project PROJ' "${FULLSEND_LOG}" 2>/dev/null; then
  echo "PASS: jira/live-create-scoped-to-project"
else
  echo "FAIL: jira/live-create-scoped-to-project — fullsend issues create not called with --project PROJ"
  cat "${FULLSEND_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -qF -- '--token'; then
  echo "FAIL: jira/live-create-no-token-arg — token exposed in command line arguments"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/live-create-no-token-arg"
fi

if grep -qF "token=fake-jira-token email=bot@mock.example" "${FULLSEND_ENV_LOG}" 2>/dev/null \
  && grep -qF -- '--user bot@mock.example:fake-jira-token' "${CURL_LOG}"; then
  echo "PASS: jira/live-basic-auth-with-email"
else
  echo "FAIL: jira/live-basic-auth-with-email — expected Basic auth with email"
  cat "${FULLSEND_ENV_LOG}" "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# Summary comment links Jira issue
if grep -qF -- "- [Improve error handling in widget service](https://mock.atlassian.net/browse/PROJ-100) (in \`PROJ\`)" "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/summary-links-jira-issue"
else
  echo "FAIL: jira/summary-links-jira-issue — Jira issue link missing from summary comment"
  cat "${GH_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# 2. Service account Bearer auth (when email unset/empty)
unset JIRA_USER_EMAIL
run_test_stdout "jira/live-bearer-auth" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF -- '--oauth2-bearer fake-jira-token' "${CURL_LOG}" \
  && ! grep -qF -- '--user' "${CURL_LOG}"; then
  echo "PASS: jira/live-bearer-auth-no-basic"
else
  echo "FAIL: jira/live-bearer-auth-no-basic — expected Bearer auth"
  cat "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
export JIRA_USER_EMAIL="bot@mock.example"

# 3. Duplicate issue check (idempotency): skips creation and links existing issue
export JIRA_MOCK_DUP="1"
run_test_stdout "jira/duplicate-skipped-and-linked" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "already exists in Jira: https://mock.atlassian.net/browse/PROJ-7"
if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -qvF -- '--help'; then
  echo "FAIL: jira/duplicate-no-creates — fullsend issues create called when duplicate exists"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/duplicate-no-creates"
fi
if grep -qF -- "- [Improve error handling in widget service](https://mock.atlassian.net/browse/PROJ-7) (in \`PROJ\`)" "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/duplicate-linked-in-summary"
else
  echo "FAIL: jira/duplicate-linked-in-summary — existing issue link missing from summary"
  cat "${GH_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
if grep -qF 'project = \"PROJ\" AND summary ~ \"handling\"' "${CURL_LOG}" 2>/dev/null \
  && ! grep -qF 'summary ~ \"\\\"' "${CURL_LOG}" 2>/dev/null; then
  echo "PASS: jira/duplicate-jql-unphrased"
else
  echo "FAIL: jira/duplicate-jql-unphrased — expected unphrased terms in JQL search"
  cat "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
unset JIRA_MOCK_DUP

# 4. Duplicate search failure: refuses to create blindly
export JIRA_MOCK_BAD_SEARCH="html"
run_test_stdout "jira/duplicate-check-fail-refuses-create" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Jira duplicate check failed"
if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -qvF -- '--help'; then
  echo "FAIL: jira/duplicate-fail-no-creates — create called after duplicate search failure"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/duplicate-fail-no-creates"
fi
if grep -qF "### Proposals not filed (issue creation failed)" "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/duplicate-fail-reported-not-filed"
else
  echo "FAIL: jira/duplicate-fail-reported-not-filed — proposal not listed under not filed"
  cat "${GH_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
unset JIRA_MOCK_BAD_SEARCH

# Duplicate search pagination fails closed on malformed continuation, checks
# later pages, and respects the configured page cap.
export JIRA_MOCK_SEARCH_PAGE2_DUP="1"
run_test_stdout "jira/duplicate-search-page-two-match" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "already exists in Jira: https://mock.atlassian.net/browse/PROJ-7"
unset JIRA_MOCK_SEARCH_PAGE2_DUP
export JIRA_MOCK_SEARCH_MISSING_TOKEN="1"
run_test_stdout "jira/duplicate-search-missing-token-fails-closed" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Jira duplicate check failed"
unset JIRA_MOCK_SEARCH_MISSING_TOKEN
export JIRA_MOCK_SEARCH_ALWAYS_MORE="1" RETRO_JIRA_MAX_PAGES=1
run_test_stdout "jira/duplicate-search-page-cap-fails-closed" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "duplicate check was truncated"
unset JIRA_MOCK_SEARCH_ALWAYS_MORE RETRO_JIRA_MAX_PAGES
export JIRA_MOCK_SEARCH_PAGE_CAP_DUP="1" RETRO_JIRA_MAX_PAGES=1
export JIRA_MOCK_DUP="1"
run_test_stdout "jira/duplicate-search-page-cap-match-wins" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "already exists in Jira: https://mock.atlassian.net/browse/PROJ-7"
unset JIRA_MOCK_SEARCH_PAGE_CAP_DUP RETRO_JIRA_MAX_PAGES
unset JIRA_MOCK_DUP

# Stop words are excluded from duplicate terms, title tokenization builds a
# single candidate query, and an empty term set uses project-only search.
JIRA_STOPWORD_TITLE_FIXTURE=$(printf '%s' "${FIXTURE_ONE_PROPOSAL}" | jq -c '.proposals[0].title = "Fix this bug"')
export JIRA_MOCK_STOPWORD_DUP="1"
run_test_stdout "jira/duplicate-stopword-title" \
  "${JIRA_STOPWORD_TITLE_FIXTURE}" \
  "already exists in Jira: https://mock.atlassian.net/browse/PROJ-7"
if grep -qF 'project = ' "${CURL_LOG}" && ! grep -qF 'summary ~ "this"' "${CURL_LOG}" \
  && ! grep -qF 'summary ~ "the"' "${CURL_LOG}"; then
  echo "PASS: jira/duplicate-stopword-title-search"
else
  echo "FAIL: jira/duplicate-stopword-title-search — stop word required or no project fallback"
  FAILURES=$((FAILURES + 1))
fi
unset JIRA_MOCK_STOPWORD_DUP
JIRA_MULTILINE_TITLE_FIXTURE=$(printf '%s' "${FIXTURE_ONE_PROPOSAL}" | jq -c '.proposals[0].title = "Fix Jira API search"')
export JIRA_MOCK_MULTILINE_DUP="1"
run_test_stdout "jira/duplicate-multiline-title" \
  "${JIRA_MULTILINE_TITLE_FIXTURE}" \
  "already exists in Jira: https://mock.atlassian.net/browse/PROJ-7"
unset JIRA_MOCK_MULTILINE_DUP
JIRA_ALL_STOPWORDS_FIXTURE=$(printf '%s' "${FIXTURE_ONE_PROPOSAL}" | jq -c '.proposals[0].title = "a to be"')
export JIRA_MOCK_DUP_PROJECT_ONLY="1"
run_test_stdout "jira/duplicate-stopword-project-fallback" \
  "${JIRA_ALL_STOPWORDS_FIXTURE}" \
  "already exists in Jira: https://mock.atlassian.net/browse/PROJ-7"
if grep -qF 'project = ' "${CURL_LOG}" && ! grep -qF 'summary ~ ' "${CURL_LOG}"; then
  echo "PASS: jira/duplicate-stopword-project-fallback-query"
else
  echo "FAIL: jira/duplicate-stopword-project-fallback-query"
  FAILURES=$((FAILURES + 1))
fi
unset JIRA_MOCK_DUP_PROJECT_ONLY

# 5. Createmeta preflight check failure: required field missing reports proposal as not filed and posts summary
export JIRA_MOCK_REQUIRED_FIELD="1"
run_test_stdout "jira/createmeta-required-field-reported-not-filed" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Jira project validation failed"
if grep -qF "### Proposals not filed (issue creation failed)" "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/createmeta-required-field-reported-not-filed"
else
  echo "FAIL: jira/createmeta-required-field-reported-not-filed — proposal not listed under not filed"
  cat "${GH_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
unset JIRA_MOCK_REQUIRED_FIELD

# 6. Createmeta preflight check failure: Description field missing reports proposal as not filed and posts summary
export JIRA_MOCK_NO_DESCRIPTION="1"
run_test_stdout "jira/createmeta-no-description-reported-not-filed" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "has no Description field on its create screen"
if grep -qF "### Proposals not filed (issue creation failed)" "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/createmeta-no-description-reported-not-filed"
else
  echo "FAIL: jira/createmeta-no-description-reported-not-filed — proposal not listed under not filed"
  cat "${GH_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
unset JIRA_MOCK_NO_DESCRIPTION

# Createmeta must collect all pages before choosing the configured issue type.
export JIRA_MOCK_CREATEMETA_PAGES="1"
run_test_stdout "jira/createmeta-paginated-issue-type" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
unset JIRA_MOCK_CREATEMETA_PAGES

# 7. Output mode: summary_only disables issue creation
export RETRO_MODE="summary_only"
run_test_stdout "jira/summary-only-mode" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Mode is summary_only — skipping issue creation"
if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -qvF -- '--help'; then
  echo "FAIL: jira/summary-only-no-creates — create called in summary_only mode"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/summary-only-no-creates"
fi
if grep -qF "### Proposals (issue creation disabled)" "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/summary-only-proposals-in-summary"
else
  echo "FAIL: jira/summary-only-proposals-in-summary — proposals not listed in summary"
  cat "${GH_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
export RETRO_MODE="all"

# 8. Output mode: issues_only skips posting summary comment
export RETRO_MODE="issues_only"
run_test_stdout "jira/issues-only-mode" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Mode is issues_only — skipping summary comment posting"
if grep -q "/comments" "${GH_LOG}" 2>/dev/null; then
  echo "FAIL: jira/issues-only-no-summary-post — summary comment was posted"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/issues-only-no-summary-post"
fi
if grep -qF 'fullsend issues create --tracker jira' "${FULLSEND_LOG}" 2>/dev/null; then
  echo "PASS: jira/issues-only-files-issue"
else
  echo "FAIL: jira/issues-only-files-issue — issue was not created in issues_only mode"
  cat "${FULLSEND_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
export RETRO_MODE="all"

# 8b. Client-credentials mode mints one token per run, not one per REST call.
# Every Jira REST call runs in a command substitution, so a mint performed
# there is lost with the subshell and repeats the OAuth exchange for the
# createmeta reads, the duplicate search, the label write and the create.
export JIRA_TOKEN=""
export FULLSEND_JIRA_CLIENT_ID="client-id"
export FULLSEND_JIRA_CLIENT_SECRET="client-secret"
run_test_stdout "jira/client-credentials-creates-issue" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
MINT_CALLS=$(grep -cF 'https://auth.atlassian.com/oauth/token' "${CURL_LOG}" 2>/dev/null || true)
if [[ "${MINT_CALLS}" == "1" ]]; then
  echo "PASS: jira/client-credentials-mints-once"
else
  echo "FAIL: jira/client-credentials-mints-once — ${MINT_CALLS:-0} token exchange(s), expected 1"
  grep -F 'https://auth.atlassian.com/oauth/token' "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
if grep -qF -- '--oauth2-bearer mock-access-token' "${CURL_LOG}" 2>/dev/null; then
  echo "PASS: jira/client-credentials-bearer-auth"
else
  echo "FAIL: jira/client-credentials-bearer-auth — REST calls did not use the minted token"
  FAILURES=$((FAILURES + 1))
fi
# The REST root (2-4 yq reads plus the tenant_info lookup) is resolved once
# too; re-resolving it per call repeats the unauthenticated tenant request.
TENANT_CALLS=$(grep -cF '/_edge/tenant_info' "${CURL_LOG}" 2>/dev/null || true)
if [[ "${TENANT_CALLS}" == "1" ]]; then
  echo "PASS: jira/client-credentials-resolves-cloud-id-once"
else
  echo "FAIL: jira/client-credentials-resolves-cloud-id-once — ${TENANT_CALLS:-0} tenant_info call(s), expected 1"
  FAILURES=$((FAILURES + 1))
fi
export JIRA_TOKEN="fake-jira-token"
export FULLSEND_JIRA_CLIENT_ID=""
export FULLSEND_JIRA_CLIENT_SECRET=""

# 8b2. A failed Jira init (here a token-endpoint error) must not stop the run
# before the summary comment: every proposal is reported as not filed and the
# summary is still posted.
export JIRA_TOKEN=""
export FULLSEND_JIRA_CLIENT_ID="client-id"
export FULLSEND_JIRA_CLIENT_SECRET="client-secret"
export JIRA_MOCK_TOKEN_FAIL="1"
run_test_stdout "jira/init-failure-still-posts-summary" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "cannot initialize Jira REST access"
if grep -qF "### Proposals not filed (issue creation failed)" "${GH_STDIN_LOG}" 2>/dev/null \
  && grep -qF '**Improve error handling in widget service**' "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/init-failure-summary-posted"
else
  echo "FAIL: jira/init-failure-summary-posted — summary comment missing or proposal not listed"
  cat "${GH_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -qvF -- '--help'; then
  echo "FAIL: jira/init-failure-no-create — create attempted without Jira REST access"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/init-failure-no-create"
fi
unset JIRA_MOCK_TOKEN_FAIL
export JIRA_TOKEN="fake-jira-token"
export FULLSEND_JIRA_CLIENT_ID=""
export FULLSEND_JIRA_CLIENT_SECRET=""

# 8c. Labels are applied with an issue update, which Jira validates against the
# edit screen: an issue type whose edit screen has no Labels field gets no
# label write, and the issue is still filed.
export JIRA_MOCK_NO_EDIT_LABELS="1"
run_test_stdout "jira/edit-screen-without-labels" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "has no Labels field on its edit screen; labels will be omitted"
if grep -qF -- '--request PUT' "${CURL_LOG}" 2>/dev/null; then
  echo "FAIL: jira/edit-screen-without-labels-no-label-write — label PUT issued without an edit-screen Labels field"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/edit-screen-without-labels-no-label-write"
fi
if grep -qF "Created: https://mock.atlassian.net/browse/PROJ-100" "${TMPDIR}/stdout.log" 2>/dev/null; then
  echo "PASS: jira/edit-screen-without-labels-still-created"
else
  echo "FAIL: jira/edit-screen-without-labels-still-created — issue was not filed"
  FAILURES=$((FAILURES + 1))
fi
unset JIRA_MOCK_NO_EDIT_LABELS

# 8c2. A create screen without a Labels field does not block the label write:
# the update is checked against the edit screen, which lists Labels here.
export JIRA_MOCK_CREATE_NO_LABELS="1"
run_test_stdout "jira/create-screen-without-labels-still-labelled" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF -- '--request PUT' "${CURL_LOG}" 2>/dev/null \
  && grep -qF '/issue/PROJ-100' "${CURL_LOG}" 2>/dev/null; then
  echo "PASS: jira/create-screen-without-labels-still-labelled-put"
else
  echo "FAIL: jira/create-screen-without-labels-still-labelled-put — label PUT was skipped"
  cat "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
unset JIRA_MOCK_CREATE_NO_LABELS

# 8c3. The edit-screen probe runs once per run, not once per proposal.
JIRA_LABEL_TWO_PROPOSAL_FIXTURE=$(printf '%s' "${FIXTURE_ONE_PROPOSAL}" \
  | jq -c '.proposals += [(.proposals[0] | .title = "Second proposal title")]')
run_test_stdout "jira/editmeta-probe-cached" \
  "${JIRA_LABEL_TWO_PROPOSAL_FIXTURE}" \
  "Post-retro complete."
JIRA_EDITMETA_PROBES=$(grep -cF '/editmeta' "${CURL_LOG}" 2>/dev/null || true)
if [[ "${JIRA_EDITMETA_PROBES}" -eq 1 ]]; then
  echo "PASS: jira/editmeta-probe-cached-once"
else
  echo "FAIL: jira/editmeta-probe-cached-once — ${JIRA_EDITMETA_PROBES} editmeta probe(s) for 2 proposals"
  grep -F '/editmeta' "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# 8d. A failed create is reported under "Proposals not filed" instead of
# silently disappearing from the summary.
export FULLSEND_MOCK_FAIL_TITLE="Improve error handling in widget service"
run_test_stdout "jira/create-failure-reported" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "All 1 proposal(s) validated"
if grep -qF "### Proposals not filed (issue creation failed)" "${GH_STDIN_LOG}" 2>/dev/null \
  && grep -qF '**Improve error handling in widget service**' "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/create-failure-listed-in-summary"
else
  echo "FAIL: jira/create-failure-listed-in-summary — failed proposal missing from summary"
  cat "${GH_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
unset FULLSEND_MOCK_FAIL_TITLE

# 9. Retrospectives on Jira-originated items (no forge token required under GHA)
SAVED_GH_TOKEN="${GH_TOKEN:-}"
SAVED_GITLAB_TOKEN="${GITLAB_TOKEN:-}"
unset GH_TOKEN GITLAB_TOKEN
GITHUB_ACTIONS="true" \
ORIGINATING_URL="https://mock.atlassian.net/browse/PROJ-123" \
  run_test_stdout "jira/originating-jira-item" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Posting summary comment on PROJ#PROJ-123"
if grep -qF 'fullsend issues post-comment --tracker jira' "${FULLSEND_LOG}" 2>/dev/null \
  && grep -qF -- '--project PROJ --number 123' "${FULLSEND_LOG}" 2>/dev/null; then
  echo "PASS: jira/originating-jira-comment-posted"
else
  echo "FAIL: jira/originating-jira-comment-posted — post-comment not called for Jira issue"
  cat "${FULLSEND_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# 9b. Retrospectives on Jira-originated items with GitLab forge (no gitlab token required under GHA)
unset GH_TOKEN GITLAB_TOKEN
FULLSEND_FORGE="gitlab" \
GITHUB_ACTIONS="true" \
ORIGINATING_URL="https://mock.atlassian.net/browse/PROJ-123" \
  run_test_stdout "jira/originating-jira-item-gitlab-forge-no-token" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Posting summary comment on PROJ#PROJ-123"
if grep -qF 'fullsend issues post-comment --tracker jira' "${FULLSEND_LOG}" 2>/dev/null \
  && grep -qF -- '--project PROJ --number 123' "${FULLSEND_LOG}" 2>/dev/null; then
  echo "PASS: jira/originating-jira-comment-posted-gitlab-forge"
else
  echo "FAIL: jira/originating-jira-comment-posted-gitlab-forge — post-comment not called for Jira issue"
  cat "${FULLSEND_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
[[ -n "${SAVED_GH_TOKEN}" ]] && export GH_TOKEN="${SAVED_GH_TOKEN}"
[[ -n "${SAVED_GITLAB_TOKEN}" ]] && export GITLAB_TOKEN="${SAVED_GITLAB_TOKEN}"
export FULLSEND_FORGE="github"

# 10. GitLab forge + Jira tracker: creates Jira issue and posts note to GitLab MR
ORIGINATING_URL="https://gitlab.com/test-group/test-project/-/merge_requests/10" \
FULLSEND_FORGE="gitlab" \
CI_SERVER_HOST="gitlab.com" \
GITLAB_TOKEN="fake-gitlab-token" \
CI_PROJECT_DIR="${JIRA_WORKSPACE}" \
  run_test_stdout "jira/gitlab-mr-originating" \
  "${GL_FIXTURE_ONE_PROPOSAL}" \
  "Posting summary comment on test-group/test-project#10"
if grep -qF 'fullsend issues create --tracker jira' "${FULLSEND_LOG}" 2>/dev/null \
  && grep -qF -- '--project PROJ' "${FULLSEND_LOG}" 2>/dev/null; then
  echo "PASS: jira/gitlab-mr-created-jira-issue"
else
  echo "FAIL: jira/gitlab-mr-created-jira-issue — fullsend issues create not called with --project PROJ"
  cat "${FULLSEND_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
if grep -q "/merge_requests/10/notes" "${CURL_LOG}" 2>/dev/null; then
  echo "PASS: jira/gitlab-mr-comment-posted"
else
  echo "FAIL: jira/gitlab-mr-comment-posted — notes endpoint not called for GitLab MR"
  cat "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# 11. Failed label update returns status 2, issue treated as created and linked in summary
export JIRA_MOCK_LABEL_FAIL="1"
export FULLSEND_FORGE="github"
export GH_TOKEN="fake-token"
export ORIGINATING_URL="https://github.com/test-org/test-repo/pull/10"
export FULLSEND_TRACKER="jira"
export JIRA_BASE_URL="https://mock.atlassian.net"
export JIRA_USER_EMAIL="bot@mock.example"
export JIRA_TOKEN="fake-jira-token"
export FULLSEND_DIR="${TMPDIR}/dot-fullsend"
mkdir -p "${FULLSEND_DIR}"
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
tracker:
  jira:
    base_url: https://mock.atlassian.net
    project: PROJ
    allowed_targets:
      projects:
        - PROJ
CFGEOF
export RETRO_JIRA_PROJECT="PROJ"
export RETRO_MODE="all"
export GITHUB_WORKSPACE="${JIRA_WORKSPACE}"

run_test_stdout "jira/label-fail-treated-as-created" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"

if grep -qF -- "- [Improve error handling in widget service](https://mock.atlassian.net/browse/PROJ-100) (in \`PROJ\`)" "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/label-fail-linked-in-summary"
else
  echo "FAIL: jira/label-fail-linked-in-summary — created issue link missing from summary"
  cat "${GH_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

if grep -qF "Proposals not filed" "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "FAIL: jira/label-fail-not-under-failed — issue incorrectly listed under Proposals not filed"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/label-fail-not-under-failed"
fi

if grep -qF "Issue created but failed to apply label in Jira" "${TMPDIR}/stdout.log" 2>/dev/null; then
  echo "PASS: jira/label-fail-warned"
else
  echo "FAIL: jira/label-fail-warned — label failure was not reported"
  cat "${TMPDIR}/stdout.log" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
unset JIRA_MOCK_LABEL_FAIL

# 12. An explicit empty list denies other projects when the primary project differs.
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: OTHER
    allowed_targets:
      projects: []
CFGEOF
export RETRO_JIRA_PROJECT="PROJ"
run_test_stdout "jira/allowlist-explicit-empty-denies" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Skipping issue creation in Jira project 'PROJ' — not in tracker.jira.allowed_targets"

if grep -qF "Proposals skipped (target repo not allowed)" "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/allowlist-explicit-empty-summary"
else
  echo "FAIL: jira/allowlist-explicit-empty-summary — proposal missing from skipped section"
  FAILURES=$((FAILURES + 1))
fi

# 12b. Explicit empty targets keep the primary project and exclude others.
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: PROJ
    allowed_targets:
      projects: []
CFGEOF
run_test_stdout "jira/allowlist-empty-only-revokes-cross-project" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"

# Without an explicit cross-project list, RETRO_JIRA_PROJECT must be the
# configured primary project; the CLI itself rejects any other project.
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: OTHER
CFGEOF
export RETRO_JIRA_PROJECT="PROJ"
run_test_stdout "jira/allowlist-unlisted-primary-mismatch-denies" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Skipping issue creation in Jira project 'PROJ'"
export RETRO_JIRA_PROJECT="PROJ"
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: PROJ
CFGEOF

cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: PROJ
    allowed_targets:
      projects:
        - OTHER
CFGEOF
run_test_stdout "jira/allowlist-primary-with-other-targets-allows" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF 'fullsend issues create --tracker jira' "${FULLSEND_LOG}"; then
  echo "PASS: jira/allowlist-primary-create-called"
else
  echo "FAIL: jira/allowlist-primary-create-not-called"
  FAILURES=$((FAILURES + 1))
fi

# 13. Allowlist: config parse error fails closed
printf 'version: "1"\ntracker: [invalid yaml\n' > "${FULLSEND_DIR}/config.yaml"
run_test_stdout "jira/allowlist-parse-failure-denies" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "cannot parse config.yaml — cross-repo issue creation disabled"

# 14. Allowlist: missing yq fails closed
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    allowed_targets:
      projects:
        - PROJ
CFGEOF
MOCK_NO_YQ_BIN="${TMPDIR}/bin-no-yq"
MOCK_BIN_NO_YQ="${TMPDIR}/mock-bin-no-yq"
mkdir -p "${MOCK_NO_YQ_BIN}"
mkdir -p "${MOCK_BIN_NO_YQ}"
for tool in bash jq sed grep awk cat date mktemp rm tr tail curl dirname basename seq printf cut head sort uniq env wc mkdir; do
  p=$(which "${tool}" 2>/dev/null || true)
  [[ -n "${p}" ]] && ln -sf "${p}" "${MOCK_NO_YQ_BIN}/${tool}"
  if [[ -x "${MOCK_BIN}/${tool}" ]]; then
    ln -sf "${MOCK_BIN}/${tool}" "${MOCK_BIN_NO_YQ}/${tool}"
  elif [[ -n "${p}" ]]; then
    ln -sf "${p}" "${MOCK_BIN_NO_YQ}/${tool}"
  fi
done
ln -sf "${MOCK_BIN}/gh" "${MOCK_BIN_NO_YQ}/gh"
SAVED_PATH="${PATH}"
SAVED_GITHUB_WORKSPACE="${GITHUB_WORKSPACE}"
export PATH="${MOCK_BIN_NO_YQ}"
export GITHUB_WORKSPACE="${JIRA_WORKSPACE}"
run_test_stdout "jira/allowlist-missing-yq-denies" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "yq not found"
export PATH="${SAVED_PATH}"
export GITHUB_WORKSPACE="${SAVED_GITHUB_WORKSPACE}"
if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -qvF -- '--help'; then
  echo "FAIL: jira/allowlist-missing-yq-no-creates — create called without yq"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/allowlist-missing-yq-no-creates"
fi
rm -rf "${MOCK_NO_YQ_BIN}" "${MOCK_BIN_NO_YQ}"
export PATH="${MOCK_BIN}:${SAVED_PATH}"

# 15. Allowlist: unset config denies issue creation
rm -f "${FULLSEND_DIR}/config.yaml"
rm -f "${FULLSEND_DIR}/config.base.yaml"
run_test_stdout "jira/allowlist-unset-denies" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Skipping issue creation in Jira project 'PROJ'"

# 15b. An overlay that sets tracker replaces the preset's tracker as a whole
# object, so a Jira tracker without a primary project grants nothing even
# when config.base.yaml names one (no base-layer fallback).
cat > "${FULLSEND_DIR}/config.base.yaml" <<CFGEOF
tracker:
  jira:
    base_url: https://mock.atlassian.net
    project: PROJ
CFGEOF
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira: {}
CFGEOF
run_test_stdout "jira/allowlist-overlay-without-project-denies" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Skipping issue creation in Jira project 'PROJ'"

cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    allowed_targets:
      projects: []
CFGEOF
run_test_stdout "jira/allowlist-empty-targets-no-project-denies" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Skipping issue creation in Jira project 'PROJ'"

# A null tracker inherits the preset, including its primary project.
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
CFGEOF
run_test_stdout "jira/allowlist-null-tracker-inherits-primary" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
rm -f "${FULLSEND_DIR}/config.base.yaml"

# A Jira tracker that also names another provider grants no cross-project
# targets, but keeps permitting the primary project.
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  github:
    allowed_targets:
      orgs:
        - test-org
  jira:
    project: PROJ
    allowed_targets:
      projects:
        - OTHER
CFGEOF
export RETRO_JIRA_PROJECT="PROJ"
run_test_stdout "jira/allowlist-multi-provider-primary-allowed" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
export RETRO_JIRA_PROJECT="OTHER"
run_test_stdout "jira/allowlist-multi-provider-cross-project-denied" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Skipping issue creation in Jira project 'OTHER'"
export RETRO_JIRA_PROJECT="PROJ"

cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: OTHER
CFGEOF
run_test_stdout "jira/allowlist-no-policy-primary-mismatch-denies" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Skipping issue creation in Jira project 'PROJ'"
# Restore valid config.yaml
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: PROJ
    allowed_targets:
      projects:
        - PROJ
CFGEOF

# 16. Summary-only mode with unset RETRO_JIRA_PROJECT and configured allowlist
export RETRO_MODE="summary_only"
unset RETRO_JIRA_PROJECT
run_test_stdout "jira/summary-only-unset-project-with-allowlist" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Mode is summary_only — skipping issue creation for proposal[0]"

if grep -qF "### Proposals (issue creation disabled)" "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/summary-only-unset-project-in-summary"
else
  echo "FAIL: jira/summary-only-unset-project-in-summary — proposal missing from summary"
  cat "${GH_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# 17. Summary-only mode includes proposals without dedup receipt
export RETRO_JIRA_PROJECT="PROJ"
run_test_stdout "jira/summary-only-no-dedup-receipt" \
  "${FIXTURE_NO_RECEIPT}" \
  "Mode is summary_only — skipping issue creation for proposal[0]"

if grep -qF "### Proposals (issue creation disabled)" "${GH_STDIN_LOG}" 2>/dev/null \
  && ! grep -qF "missing or malformed dedup receipt" "${TMPDIR}/stdout.log" 2>/dev/null; then
  echo "PASS: jira/summary-only-no-dedup-receipt-collected"
else
  echo "FAIL: jira/summary-only-no-dedup-receipt-collected — proposal not properly collected in summary-only mode"
  cat "${TMPDIR}/stdout.log" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
export RETRO_MODE="all"
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
tracker:
  jira:
    base_url: https://mock.atlassian.net
    project: PROJ
CFGEOF

# 18. An explicit empty list denies a non-primary project and does not fall
# through to the Jira-originating project's generic forge allowance.
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: OTHER
    allowed_targets:
      projects: []
CFGEOF
export RETRO_JIRA_PROJECT="PROJ"
run_test_stdout "jira/allowlist-primary-project-revoked-by-empty-targets" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Skipping issue creation in Jira project 'PROJ'"

# A case-insensitive explicit target is admitted by the pre-create gate.
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: PROJ
    allowed_targets:
      projects:
        - other
CFGEOF
export RETRO_JIRA_PROJECT="OTHER"
run_test_stdout "jira/allowlist-explicit-target-case-insensitive" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/OTHER-100"
# The mock answers with a key in the requested project, so this asserts the
# create actually succeeded rather than passing on a failed key check.
if grep -qF -- '--project OTHER' "${FULLSEND_LOG}" 2>/dev/null \
  && ! grep -qF "### Proposals not filed" "${GH_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/allowlist-explicit-target-case-insensitive-created"
else
  echo "FAIL: jira/allowlist-explicit-target-case-insensitive-created — create did not succeed for OTHER"
  cat "${FULLSEND_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
export RETRO_JIRA_PROJECT="PROJ"
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: PROJ
    allowed_targets:
      projects:
        - PROJ
CFGEOF

# A config that exists only under <FULLSEND_DIR>/.fullsend/ is not read: the
# CLI treats --fullsend-dir as the directory that holds config.yaml, and the
# Jira REST routing reads the same path. The run must say so and fail closed
# rather than admit targets from a config the CLI cannot see.
NESTED_FULLSEND="${TMPDIR}/nested-fullsend"
mkdir -p "${NESTED_FULLSEND}/.fullsend"
cat > "${NESTED_FULLSEND}/.fullsend/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: PROJ
CFGEOF
SAVED_FULLSEND_DIR="${FULLSEND_DIR}"
export FULLSEND_DIR="${NESTED_FULLSEND}"
export RETRO_MODE="issues_only"
run_test_stdout "jira/nested-config-not-read" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "no config.yaml in FULLSEND_DIR" \
  "true"
if grep -qF 'fullsend issues create --tracker jira' "${FULLSEND_LOG}" 2>/dev/null; then
  echo "FAIL: jira/nested-config-no-create — create attempted without a config the CLI can read"
  cat "${FULLSEND_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/nested-config-no-create"
fi
export RETRO_MODE="all"
export FULLSEND_DIR="${SAVED_FULLSEND_DIR}"

# 19. Issues_only mode exits non-zero if proposals are skipped due to allowlist
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: OTHER
    allowed_targets:
      projects: []
CFGEOF
export RETRO_JIRA_PROJECT="PROJ"
export RETRO_MODE="issues_only"
run_test_stdout "jira/issues-only-skipped-exits-error" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "issues_only mode encountered proposal failures or skipped targets" \
  "true"
export RETRO_MODE="all"

# RETRO_JIRA_LABELS is the applied-label allowlist; it can replace or suppress
# the default ready-for-triage label for Jira without changing forge labels.
export RETRO_JIRA_LABELS="retro"
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: PROJ
    allowed_targets:
      projects:
        - PROJ
CFGEOF
run_test_stdout "jira/custom-label-policy-applied" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF 'retro' "${CURL_LOG}" && grep -qF '/issue/PROJ-100' "${CURL_LOG}"; then
  echo "PASS: jira/custom-label-policy-label-sent"
else
  echo "FAIL: jira/custom-label-policy-label-sent"
  FAILURES=$((FAILURES + 1))
fi
export RETRO_JIRA_LABELS=""
run_test_stdout "jira/empty-label-policy-no-labels" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF 'curl ' "${CURL_LOG}" && grep -qF '/issue/PROJ-100' "${CURL_LOG}"; then
  echo "FAIL: jira/empty-label-policy-put — label update was sent"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/empty-label-policy-no-label-update"
fi
unset RETRO_JIRA_LABELS
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    project: PROJ
    allowed_targets:
      projects:
        - PROJ
CFGEOF

# Restore valid config.yaml
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    allowed_targets:
      projects:
        - PROJ
CFGEOF

# 20. Target repository line and forge issue URL rendered in Jira issue body
export RETRO_JIRA_PROJECT="PROJ"
export FULLSEND_TRACKER="jira"
export FULLSEND_FORGE="github"
export JIRA_BASE_URL="https://mock.atlassian.net"
export JIRA_TOKEN="fake-jira-token"
export FULLSEND_DIR="${TMPDIR}/dot-fullsend"
run_test_stdout "jira/body-target-repo-and-forge-url" \
  "${FIXTURE_RECEIPT_FOUND}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF "**Target repository:** test-org/target-repo" "${FULLSEND_STDIN_LOG}" 2>/dev/null \
  && grep -qF "https://github.com/test-org/target-repo/issues/2476" "${FULLSEND_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/body-target-repo-and-forge-url"
else
  echo "FAIL: jira/body-target-repo-and-forge-url — body missing target repo or full forge URL"
  cat "${FULLSEND_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# 20b. Target repository line and GitLab self-managed URL rendered in Jira issue body
export FULLSEND_FORGE="gitlab"
export ORIGINATING_URL="https://gitlab.example.com/test-org/source-repo/-/merge_requests/10"
export GITLAB_HOST="gitlab.example.com"
export CI_SERVER_HOST="gitlab.example.com"
export CI_PROJECT_DIR="${JIRA_WORKSPACE}"
run_test_stdout "jira/body-target-repo-and-gitlab-url" \
  "${FIXTURE_RECEIPT_FOUND}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF "**Target repository:** test-org/target-repo" "${FULLSEND_STDIN_LOG}" 2>/dev/null \
  && grep -qF "https://gitlab.example.com/test-org/target-repo/-/issues/2476" "${FULLSEND_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/body-target-repo-and-gitlab-url"
else
  echo "FAIL: jira/body-target-repo-and-gitlab-url — body missing target repo or self-managed GitLab URL"
  cat "${FULLSEND_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# 20c. Target repository line and GitLab fallback reference when host is unknown
unset GITLAB_HOST CI_SERVER_HOST
export ORIGINATING_URL="https://mock.atlassian.net/browse/PROJ-123"
export CI_PROJECT_DIR="${JIRA_WORKSPACE}"
run_test_stdout "jira/body-target-repo-and-gitlab-no-host" \
  "${FIXTURE_RECEIPT_FOUND}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF "test-org/target-repo#2476" "${FULLSEND_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/body-target-repo-and-gitlab-no-host"
else
  echo "FAIL: jira/body-target-repo-and-gitlab-no-host — body missing repo#number format when host unknown"
  cat "${FULLSEND_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
export FULLSEND_FORGE="github"

# 21. Comment truncation at the Jira 32000-byte cap for Jira-originated runs
ORIGINATING_URL="https://mock.atlassian.net/browse/PROJ-123" \
  run_test_stdout "jira/comment-truncated-at-32000" \
  "${FIXTURE_OVERSIZED}" \
  "Posting summary comment on PROJ#PROJ-123"
JIRA_COMMENT_LEN=$(wc -c < "${FULLSEND_STDIN_LOG}")
if [[ ${JIRA_COMMENT_LEN} -le 32000 ]]; then
  echo "PASS: jira/comment-truncated-length"
else
  echo "FAIL: jira/comment-truncated-length — comment length ${JIRA_COMMENT_LEN} exceeds 32000"
  FAILURES=$((FAILURES + 1))
fi
if grep -qF "...(truncated)" "${FULLSEND_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/comment-truncated-marker"
else
  echo "FAIL: jira/comment-truncated-marker — missing truncation notice"
  FAILURES=$((FAILURES + 1))
fi

# 21b. The Jira comment cap is in bytes, not characters: the CLI converts the
# comment to ADF and MarkdownToADF refuses anything over 32768 bytes. A
# summary of 32000 two-byte characters is 64000 bytes but only 32000
# characters, so a character-count cut leaves it over the limit and the post
# fails after the issues were already filed.
JIRA_WIDE_SUMMARY=$(jq -nr '"é" * 32000')
FIXTURE_JIRA_WIDE_COMMENT=$(jq -nc --arg s "${JIRA_WIDE_SUMMARY}" '{summary: $s, proposals: []}')
ORIGINATING_URL="https://mock.atlassian.net/browse/PROJ-123" \
  run_test_stdout "jira/comment-truncated-bytes" \
  "${FIXTURE_JIRA_WIDE_COMMENT}" \
  "Posting summary comment on PROJ#PROJ-123"
JIRA_WIDE_COMMENT_BYTES=$(wc -c < "${FULLSEND_STDIN_LOG}" | tr -d '[:space:]')
if [[ "${JIRA_WIDE_COMMENT_BYTES}" -le 32768 ]]; then
  echo "PASS: jira/comment-truncated-bytes-under-cap (${JIRA_WIDE_COMMENT_BYTES} bytes)"
else
  echo "FAIL: jira/comment-truncated-bytes-under-cap — comment is ${JIRA_WIDE_COMMENT_BYTES} bytes (limit 32768)"
  FAILURES=$((FAILURES + 1))
fi
if [[ "${JIRA_WIDE_COMMENT_BYTES}" -gt 31000 ]]; then
  echo "PASS: jira/comment-truncated-bytes-near-cap (${JIRA_WIDE_COMMENT_BYTES} bytes)"
else
  echo "FAIL: jira/comment-truncated-bytes-near-cap — comment shrank to ${JIRA_WIDE_COMMENT_BYTES} bytes"
  FAILURES=$((FAILURES + 1))
fi
if grep -qF "...(truncated)" "${FULLSEND_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/comment-truncated-bytes-marker"
else
  echo "FAIL: jira/comment-truncated-bytes-marker — truncation marker missing from the comment"
  FAILURES=$((FAILURES + 1))
fi
# The cut must land on a code-point boundary; a split two-byte character
# leaves invalid UTF-8, which iconv rejects.
if iconv -f UTF-8 -t UTF-8 "${FULLSEND_STDIN_LOG}" > /dev/null 2>&1; then
  echo "PASS: jira/comment-truncated-bytes-valid-utf8"
else
  echo "FAIL: jira/comment-truncated-bytes-valid-utf8 — truncation split a multi-byte character"
  FAILURES=$((FAILURES + 1))
fi

# 22. REST reads route through the Atlassian API gateway, as fullsend does:
# tracker.jira.api_url (default https://api.atlassian.com) plus the cloud ID
# discovered from the site. The site URL is never used as a REST base.
export FULLSEND_FORGE="github"
export ORIGINATING_URL="https://github.com/test-org/test-repo/pull/10"
export JIRA_BASE_URL="https://mock.atlassian.net"
export RETRO_JIRA_PROJECT="PROJ"
export RETRO_MODE="all"
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    base_url: https://mock.atlassian.net
    project: PROJ
CFGEOF
run_test_stdout "jira/rest-routes-through-gateway" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF "https://api.atlassian.com/ex/jira/11111111-2222-3333-4444-555555555555/rest/api/3/issue/createmeta/PROJ/issuetypes" "${CURL_LOG}" \
  && grep -qF "https://mock.atlassian.net/_edge/tenant_info" "${CURL_LOG}" \
  && ! grep -qF "https://mock.atlassian.net/rest/api/3" "${CURL_LOG}"; then
  echo "PASS: jira/rest-routes-through-gateway-endpoints"
else
  echo "FAIL: jira/rest-routes-through-gateway-endpoints — REST did not use the gateway"
  cat "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# tracker.jira.api_url overrides the gateway base.
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    base_url: https://mock.atlassian.net
    api_url: https://jira-gateway.example.com
    project: PROJ
CFGEOF
run_test_stdout "jira/rest-api-url-override" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF "https://jira-gateway.example.com/ex/jira/11111111-2222-3333-4444-555555555555/rest/api/3" "${CURL_LOG}"; then
  echo "PASS: jira/rest-api-url-override-endpoint"
else
  echo "FAIL: jira/rest-api-url-override-endpoint — api_url was not used"
  cat "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# A config that names another Jira tenant fails closed before any read.
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    base_url: https://other-site.atlassian.net
    project: PROJ
CFGEOF
run_test_stdout "jira/rest-base-url-mismatch-denies" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "does not match JIRA_BASE_URL"
if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -qvF -- '--help'; then
  echo "FAIL: jira/rest-base-url-mismatch-no-create — create called despite tenant mismatch"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/rest-base-url-mismatch-no-create"
fi

# Cloud ID discovery failure fails closed.
cat > "${FULLSEND_DIR}/config.yaml" <<CFGEOF
version: "1"
tracker:
  jira:
    base_url: https://mock.atlassian.net
    project: PROJ
CFGEOF
export JIRA_MOCK_TENANT_INFO_FAIL="1"
run_test_stdout "jira/rest-cloud-id-failure-denies" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "failed to discover the Jira cloud ID"
if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -qvF -- '--help'; then
  echo "FAIL: jira/rest-cloud-id-failure-no-create — create called without a cloud ID"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/rest-cloud-id-failure-no-create"
fi
unset JIRA_MOCK_TENANT_INFO_FAIL

# 23. issues_only files issues without posting a comment, so it does not
# need a forge token.
export RETRO_MODE="issues_only"
JIRA_SAVED_GH_TOKEN="${GH_TOKEN:-}"
unset GH_TOKEN
run_test_stdout "jira/issues-only-no-forge-token" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
export GH_TOKEN="${JIRA_SAVED_GH_TOKEN}"
export RETRO_MODE="all"

# 24. A failed createmeta check is not retried for every proposal.
JIRA_TWO_PROPOSAL_FIXTURE=$(printf '%s' "${FIXTURE_ONE_PROPOSAL}" \
  | jq -c '.proposals += [(.proposals[0] | .title = "Second proposal title")]')
export JIRA_MOCK_REQUIRED_FIELD="1"
run_test_stdout "jira/createmeta-failure-not-retried" \
  "${JIRA_TWO_PROPOSAL_FIXTURE}" \
  "Jira project validation failed"
JIRA_CREATEMETA_PROBES=$(grep -cF 'issue/createmeta/PROJ/issuetypes?' "${CURL_LOG}" || true)
if [[ "${JIRA_CREATEMETA_PROBES}" -eq 1 ]]; then
  echo "PASS: jira/createmeta-failure-not-retried-once"
else
  echo "FAIL: jira/createmeta-failure-not-retried-once — ${JIRA_CREATEMETA_PROBES} createmeta probes for 2 proposals"
  cat "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
unset JIRA_MOCK_REQUIRED_FIELD

# 24b. Help output must confirm the create command and both options used.
for jira_help_case in missing-fullsend-dir missing-tracker unrelated-usage; do
  export FULLSEND_MOCK_CREATE_HELP="${jira_help_case}"
  run_test_stdout "jira/cli-help-${jira_help_case}" \
    "${FIXTURE_ONE_PROPOSAL}" \
    "does not support 'issues create --tracker jira --fullsend-dir'"
  if grep -F 'fullsend issues create' "${FULLSEND_LOG}" 2>/dev/null | grep -qvF -- '--help'; then
    echo "FAIL: jira/cli-help-${jira_help_case}-no-create — create called with incomplete CLI support"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: jira/cli-help-${jira_help_case}-no-create"
  fi
done
unset FULLSEND_MOCK_CREATE_HELP

# 25. Numeric forge references on GitHub Enterprise link to the run's server.
export GITHUB_SERVER_URL="https://ghe.example.com"
export ORIGINATING_URL="https://ghe.example.com/test-org/test-repo/pull/10"
run_test_stdout "jira/body-ghes-link" \
  "${FIXTURE_RECEIPT_FOUND}" \
  "Created: https://mock.atlassian.net/browse/PROJ-100"
if grep -qF "https://ghe.example.com/test-org/target-repo/issues/2476" "${FULLSEND_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/body-ghes-link"
else
  echo "FAIL: jira/body-ghes-link — body did not use GITHUB_SERVER_URL"
  cat "${FULLSEND_STDIN_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
unset GITHUB_SERVER_URL
export ORIGINATING_URL="https://github.com/test-org/test-repo/pull/10"

# 26. Dotted and hyphenated tokens are not split into search fragments.
JIRA_DOTTED_TITLE_FIXTURE=$(printf '%s' "${FIXTURE_ONE_PROPOSAL}" \
  | jq -c '.proposals[0].title = "Fix post-retro.sh crash"')
run_test_stdout "jira/duplicate-dotted-token" \
  "${JIRA_DOTTED_TITLE_FIXTURE}" \
  "Post-retro complete."
if ! grep -qF 'summary ~ \"post\"' "${CURL_LOG}" 2>/dev/null \
  && ! grep -qF 'summary ~ \"retro\"' "${CURL_LOG}" 2>/dev/null \
  && grep -qF 'summary ~ \"crash\"' "${CURL_LOG}" 2>/dev/null; then
  echo "PASS: jira/duplicate-dotted-token-not-split"
else
  echo "FAIL: jira/duplicate-dotted-token-not-split — JQL split a dotted or hyphenated token"
  cat "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
JIRA_DOTTED_ONLY_FIXTURE=$(printf '%s' "${FIXTURE_ONE_PROPOSAL}" \
  | jq -c '.proposals[0].title = "post-retro.sh result.json"')
run_test_stdout "jira/duplicate-dotted-only" \
  "${JIRA_DOTTED_ONLY_FIXTURE}" \
  "Post-retro complete."
if grep -qF 'project = \"PROJ\"' "${CURL_LOG}" 2>/dev/null \
  && ! grep -qF 'summary ~ ' "${CURL_LOG}" 2>/dev/null; then
  echo "PASS: jira/duplicate-dotted-only-project-fallback"
else
  echo "FAIL: jira/duplicate-dotted-only-project-fallback — expected project-only search"
  cat "${CURL_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

# 27. On a CLI that still keeps sticky-comment history, pass
# --keep-history=false so a rerun replaces the summary instead of stacking
# copies; a CLI that marks the flag deprecated gets no flag. The deprecated
# branch models the shape fullsend-ai/fullsend#9399 (still open) proposes, so
# it pins the detection, not released CLI behaviour.
export FULLSEND_MOCK_KEEP_HISTORY="supported"
ORIGINATING_URL="https://mock.atlassian.net/browse/PROJ-123" \
  run_test_stdout "jira/keep-history-supported" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Posting summary comment on PROJ#PROJ-123"
if grep -qF -- '--keep-history=false' "${FULLSEND_LOG}" 2>/dev/null; then
  echo "PASS: jira/keep-history-supported-flag-passed"
else
  echo "FAIL: jira/keep-history-supported-flag-passed — --keep-history=false was not passed"
  cat "${FULLSEND_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi
export FULLSEND_MOCK_KEEP_HISTORY="deprecated"
ORIGINATING_URL="https://mock.atlassian.net/browse/PROJ-123" \
  run_test_stdout "jira/keep-history-deprecated" \
  "${FIXTURE_ONE_PROPOSAL}" \
  "Posting summary comment on PROJ#PROJ-123"
if grep -qF -- '--keep-history' "${FULLSEND_LOG}" 2>/dev/null; then
  echo "FAIL: jira/keep-history-deprecated-flag-omitted — deprecated flag was passed"
  cat "${FULLSEND_LOG}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: jira/keep-history-deprecated-flag-omitted"
fi
unset FULLSEND_MOCK_KEEP_HISTORY

# 28. Jira credentials never reach an xtrace line.
JIRA_XTRACE_RUN="${TMPDIR}/run-jira-xtrace"
mkdir -p "${JIRA_XTRACE_RUN}/iteration-1/output"
printf '%s' "${FIXTURE_ONE_PROPOSAL}" > "${JIRA_XTRACE_RUN}/iteration-1/output/agent-result.json"
: > "${GH_LOG}"
: > "${GH_STDIN_LOG}"
: > "${CURL_LOG}"
: > "${FULLSEND_LOG}"
: > "${FULLSEND_ENV_LOG}"
: > "${FULLSEND_STDIN_LOG}"
JIRA_SAVED_GITHUB_ACTIONS="${GITHUB_ACTIONS:-}"
unset GITHUB_ACTIONS
JIRA_XTRACE_EXIT=0
(
  cd "${JIRA_XTRACE_RUN}"
  bash -x "${POST_SCRIPT}"
) > "${TMPDIR}/xtrace.log" 2>&1 || JIRA_XTRACE_EXIT=$?
if [[ -n "${JIRA_SAVED_GITHUB_ACTIONS}" ]]; then
  export GITHUB_ACTIONS="${JIRA_SAVED_GITHUB_ACTIONS}"
fi
if [[ ${JIRA_XTRACE_EXIT} -eq 0 ]] && ! grep -qF "fake-jira-token" "${TMPDIR}/xtrace.log"; then
  echo "PASS: jira/xtrace-does-not-leak-token"
else
  echo "FAIL: jira/xtrace-does-not-leak-token — token appeared in the trace (exit ${JIRA_XTRACE_EXIT})"
  grep -F "fake-jira-token" "${TMPDIR}/xtrace.log" | head -5 || true
  FAILURES=$((FAILURES + 1))
fi

# 29. A schema-valid proposal body over the CLI's 32 KiB Jira limit is
# truncated, not refused. Each section below is 8160 characters of a two-byte
# character (well inside the schema's 8192-character cap), so the body is
# ~33000 bytes but only ~16500 characters: this pins that the cap is measured
# in bytes, as fullsend does (len(body) > jira.MaxMarkdownBytes).
JIRA_OVERSIZED_BODY_FIXTURE=$(jq -nc '
  ("\u00e9" * 60) as $line
  | ([range(0;136)] | map($line) | join("\n")) as $wide
  | {
      summary: "The retro analysis found one improvement opportunity.",
      proposals: [
        {
          target_repo: "test-org/target-repo",
          title: "Improve error handling in widget service",
          what_happened: $wide,
          what_could_go_better: $wide,
          proposed_change: "Add a nil check at the entry point.",
          validation_criteria: "Widget service returns 400 on empty input.",
          related_issues: {
            searched: [
              "skip review dispatch zero files",
              "review dispatch routing"
            ],
            found: []
          }
        }
      ]
    }')
# issues_only keeps the create body the only thing written to the stdin log,
# so its size can be measured directly.
export RETRO_MODE="issues_only"
run_test_stdout "jira/body-over-limit-truncated" \
  "${JIRA_OVERSIZED_BODY_FIXTURE}" \
  "body exceeded the Jira 32768-byte limit and was truncated"
JIRA_BODY_BYTES=$(wc -c < "${FULLSEND_STDIN_LOG}" | tr -d '[:space:]')
if [[ "${JIRA_BODY_BYTES}" -le 32768 ]]; then
  echo "PASS: jira/body-over-limit-under-cap (${JIRA_BODY_BYTES} bytes)"
else
  echo "FAIL: jira/body-over-limit-under-cap — body is ${JIRA_BODY_BYTES} bytes (limit 32768)"
  FAILURES=$((FAILURES + 1))
fi
# Truncated near the cap, not by discarding whole sections.
if [[ "${JIRA_BODY_BYTES}" -gt 32000 ]]; then
  echo "PASS: jira/body-over-limit-keeps-near-cap (${JIRA_BODY_BYTES} bytes)"
else
  echo "FAIL: jira/body-over-limit-keeps-near-cap — body shrank to ${JIRA_BODY_BYTES} bytes"
  FAILURES=$((FAILURES + 1))
fi
if grep -qF "truncated to fit the Jira issue body limit" "${FULLSEND_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/body-over-limit-marked"
else
  echo "FAIL: jira/body-over-limit-marked — truncation marker missing from the body"
  FAILURES=$((FAILURES + 1))
fi
if grep -qF "_Generated by retro agent from https://github.com/test-org/test-repo/pull/10_" "${FULLSEND_STDIN_LOG}" 2>/dev/null; then
  echo "PASS: jira/body-over-limit-keeps-footer"
else
  echo "FAIL: jira/body-over-limit-keeps-footer — originating-URL footer was cut"
  FAILURES=$((FAILURES + 1))
fi
export RETRO_MODE="all"

unset FULLSEND_TRACKER JIRA_BASE_URL JIRA_USER_EMAIL JIRA_TOKEN FULLSEND_DIR RETRO_JIRA_PROJECT RETRO_MODE

# --- Results ---

if [[ ${FAILURES} -gt 0 ]]; then
  echo ""
  echo "${FAILURES} test(s) failed."
  exit 1
fi

echo ""
echo "All post-retro tests passed."
