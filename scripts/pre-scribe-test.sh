#!/usr/bin/env bash
# pre-scribe-test.sh — Test the backlog fetch and metadata logic in
# pre-scribe.sh. Tests the paginated issue fetch pipeline in isolation
# (the full script requires Drive credentials that are unavailable in
# the test environment).
#
# Run from the repo root: bash scripts/pre-scribe-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"

FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

MOCK_BIN="${TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"

# --- Mock gh ---
# Simulates `gh api --paginate` for the issues endpoint. Returns fixture
# data from a file, applying the --jq filter via real jq to exercise
# the filter expression end-to-end.
build_mock_gh() {
  local fixture_file="$1"

  # Store fixture path in a side file the mock reads at runtime.
  # Avoids sed/awk placeholder substitution — safe regardless of
  # characters in the mktemp path.
  printf '%s' "${fixture_file}" > "${MOCK_BIN}/.gh-fixture"

  cat > "${MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
FIXTURE="$(cat "$(dirname "$0")/.gh-fixture")"

if [[ "$1" == "api" ]]; then
  shift
  JQ_EXPR=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --paginate) shift ;;
      --jq) JQ_EXPR="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -n "${JQ_EXPR}" ]]; then
    jq -r "${JQ_EXPR}" "${FIXTURE}"
  else
    cat "${FIXTURE}"
  fi
  exit 0
fi

exit 0
MOCKEOF

  chmod +x "${MOCK_BIN}/gh"
}

# --- Mock curl (for GitLab tests) ---
build_mock_curl() {
  local fixture_file="$1"

  printf '%s' "${fixture_file}" > "${MOCK_BIN}/.curl-fixture"

  cat > "${MOCK_BIN}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
FIXTURE="$(cat "$(dirname "$0")/.curl-fixture")"
cat "${FIXTURE}"
exit 0
MOCKEOF

  chmod +x "${MOCK_BIN}/curl"
}

# --- Source the forge ops libraries for forge_filter_issues_to_backlog ---
# We test the forge functions directly rather than running the full
# pre-scribe.sh (which requires Drive credentials).
# shellcheck disable=SC2034 # SCRIPT_DIR used by source
export SCRIPT_DIR

# --- Backlog fetch pipeline (GitHub) ---
# Reproduces the exact command chain from pre-scribe.src.sh so we test the
# real pipeline without requiring Drive credentials. Mirrors the two-step
# approach: save raw paginated output, then filter PRs and truncate bodies.
run_backlog_fetch_github() {
  local scribe_repo="$1"
  local backlog_file="$2"
  local raw_file="${TMPDIR}/raw-paginated.json"

  PATH="${MOCK_BIN}:${PATH}" \
  gh api --paginate "repos/${scribe_repo}/issues?state=open&per_page=100" \
    > "${raw_file}"

  jq -s '[.[][] | select(.pull_request == null) | {number, title, body, labels, milestone, url: .html_url}]' "${raw_file}" \
    | jq '[.[] | .body = ((.body // "")[:500] + if ((.body // "") | length) > 500 then "…" else "" end)]' \
    > "${backlog_file}"
  rm -f "${raw_file}"
}

# --- Backlog fetch pipeline (GitLab) ---
# Simulates the GitLab forge_filter_issues_to_backlog normalization.
run_backlog_fetch_gitlab() {
  local _scribe_repo="$1"
  local backlog_file="$2"
  local raw_file="${TMPDIR}/raw-paginated.json"

  PATH="${MOCK_BIN}:${PATH}" \
  curl --fail --silent --show-error "https://gitlab.com/api/v4/dummy" \
    > "${raw_file}"

  jq '[.[] | {
    number: .iid,
    title,
    body: (.description // ""),
    labels: [.labels[]? | {name: .}],
    milestone,
    url: .web_url
  } | .body = ((.body // "")[:500] + if ((.body // "") | length) > 500 then "…" else "" end)]' \
    "${raw_file}" > "${backlog_file}"
  rm -f "${raw_file}"
}

# --- Test helpers ---
assert_eq() {
  local test_name="$1" expected="$2" actual="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    echo "FAIL: ${test_name} — expected '${expected}', got '${actual}'"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  return 0
}

# ===================================================================
# GitHub tests (FULLSEND_FORGE=github)
# ===================================================================

# ===================================================================
# Test 1: All issues included, PRs filtered out
# ===================================================================
test_pagination_filters_prs() {
  local test_name="github/pagination-filters-prs"
  local fixture="${TMPDIR}/fixture-${test_name//\//-}.json"
  local backlog="${TMPDIR}/backlog-${test_name//\//-}.json"

  # Fixture: 3 issues + 1 pull request (has pull_request field)
  cat > "${fixture}" <<'EOF'
[
  {"number": 1, "title": "Old bug", "body": "stale issue", "labels": [{"name": "bug"}], "milestone": null, "html_url": "https://github.com/o/r/issues/1"},
  {"number": 2, "title": "Feature request", "body": "add dark mode", "labels": [], "milestone": {"title": "v2"}, "html_url": "https://github.com/o/r/issues/2"},
  {"number": 3, "title": "A pull request", "body": "PR body", "labels": [], "milestone": null, "html_url": "https://github.com/o/r/pull/3", "pull_request": {"url": "https://api.github.com/repos/o/r/pulls/3"}},
  {"number": 4, "title": "Config issue", "body": "assignee config", "labels": [{"name": "enhancement"}], "milestone": null, "html_url": "https://github.com/o/r/issues/4"}
]
EOF

  build_mock_gh "${fixture}"
  run_backlog_fetch_github "o/r" "${backlog}"

  local count
  count=$(jq 'length' "${backlog}")
  if ! assert_eq "${test_name}: count" "3" "${count}"; then
    echo "  backlog: $(cat "${backlog}")"
    return
  fi

  # Verify PR (number 3) is excluded
  local has_pr
  has_pr=$(jq '[.[] | select(.number == 3)] | length' "${backlog}")
  if ! assert_eq "${test_name}: no PR" "0" "${has_pr}"; then return; fi

  # Verify issues 1, 2, 4 are present
  local has_1 has_2 has_4
  has_1=$(jq '[.[] | select(.number == 1)] | length' "${backlog}")
  has_2=$(jq '[.[] | select(.number == 2)] | length' "${backlog}")
  has_4=$(jq '[.[] | select(.number == 4)] | length' "${backlog}")
  if ! assert_eq "${test_name}: issue 1" "1" "${has_1}"; then return; fi
  if ! assert_eq "${test_name}: issue 2" "1" "${has_2}"; then return; fi
  if ! assert_eq "${test_name}: issue 4" "1" "${has_4}"; then return; fi

  # Verify url field is mapped from html_url
  local url_1
  url_1=$(jq -r '.[] | select(.number == 1) | .url' "${backlog}")
  if ! assert_eq "${test_name}: url mapped" "https://github.com/o/r/issues/1" "${url_1}"; then return; fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# Test 2: Body truncation at 500 chars
# ===================================================================
test_body_truncation() {
  local test_name="github/body-truncation"
  local fixture="${TMPDIR}/fixture-${test_name//\//-}.json"
  local backlog="${TMPDIR}/backlog-${test_name//\//-}.json"

  # Generate a body > 500 chars (600 'a' characters)
  local long_body
  long_body=$(printf 'a%.0s' $(seq 1 600))

  jq -n --arg body "${long_body}" \
    '[{"number": 10, "title": "Long body issue", "body": $body, "labels": [], "milestone": null, "html_url": "https://github.com/o/r/issues/10"}]' \
    > "${fixture}"

  build_mock_gh "${fixture}"
  run_backlog_fetch_github "o/r" "${backlog}"

  local body_len
  body_len=$(jq -r '.[0].body | length' "${backlog}")
  # 500 chars + 1 "…" character = 501
  if ! assert_eq "${test_name}: truncated length" "501" "${body_len}"; then
    echo "  actual body length: ${body_len}"
    return
  fi

  # Verify the truncation marker
  local ends_with
  ends_with=$(jq -r '.[0].body | .[-1:]' "${backlog}")
  if ! assert_eq "${test_name}: ends with ellipsis" "…" "${ends_with}"; then return; fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# Test 3: Short body is NOT truncated
# ===================================================================
test_short_body_preserved() {
  local test_name="github/short-body-preserved"
  local fixture="${TMPDIR}/fixture-${test_name//\//-}.json"
  local backlog="${TMPDIR}/backlog-${test_name//\//-}.json"

  cat > "${fixture}" <<'EOF'
[
  {"number": 20, "title": "Short issue", "body": "This is a short body.", "labels": [], "milestone": null, "html_url": "https://github.com/o/r/issues/20"}
]
EOF

  build_mock_gh "${fixture}"
  run_backlog_fetch_github "o/r" "${backlog}"

  local body
  body=$(jq -r '.[0].body' "${backlog}")
  if ! assert_eq "${test_name}: body preserved" "This is a short body." "${body}"; then return; fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# Test 4: Empty result (no open issues)
# ===================================================================
test_empty_issues() {
  local test_name="github/empty-issues"
  local fixture="${TMPDIR}/fixture-${test_name//\//-}.json"
  local backlog="${TMPDIR}/backlog-${test_name//\//-}.json"

  echo '[]' > "${fixture}"
  build_mock_gh "${fixture}"
  run_backlog_fetch_github "o/r" "${backlog}"

  local count
  count=$(jq 'length' "${backlog}")
  if ! assert_eq "${test_name}: empty array" "0" "${count}"; then
    echo "  backlog: $(cat "${backlog}")"
    return
  fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# Test 5: Null body handled gracefully
# ===================================================================
test_null_body() {
  local test_name="github/null-body"
  local fixture="${TMPDIR}/fixture-${test_name//\//-}.json"
  local backlog="${TMPDIR}/backlog-${test_name//\//-}.json"

  cat > "${fixture}" <<'EOF'
[
  {"number": 30, "title": "No body issue", "body": null, "labels": [], "milestone": null, "html_url": "https://github.com/o/r/issues/30"}
]
EOF

  build_mock_gh "${fixture}"
  run_backlog_fetch_github "o/r" "${backlog}"

  local body
  body=$(jq -r '.[0].body' "${backlog}")
  if ! assert_eq "${test_name}: null body becomes empty" "" "${body}"; then return; fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# Test 6: Metadata includes open_issue_total and backlog_truncated
# ===================================================================
test_metadata_fields() {
  local test_name="metadata-fields"
  local meta_file="${TMPDIR}/meta-${test_name}.json"
  local issue_count=1879

  # Run the same jq command from pre-scribe.sh to generate metadata.
  # open_total and truncated are now separate args (dynamic values in
  # the real script, derived from the repo API).
  jq -n \
    --arg cutoff "2026-08-06T09:00:00Z" \
    --arg notes_url "https://docs.google.com/document/d/abc" \
    --arg repo "mock-org/mock-repo" \
    --argjson doc_count 1 \
    --argjson issue_count "${issue_count}" \
    --argjson open_total "${issue_count}" \
    --argjson truncated false \
    --argjson closed_count 50 \
    --argjson pr_count 10 \
    --argjson doc_path_count 25 \
    '{
      cutoff_date: $cutoff,
      notes_url: $notes_url,
      repo: $repo,
      docs_downloaded: $doc_count,
      backlog_issues: $issue_count,
      open_issue_total: $open_total,
      backlog_truncated: $truncated,
      closed_issues: $closed_count,
      open_prs: $pr_count,
      repo_docs: $doc_path_count
    }' > "${meta_file}"

  # Verify new fields exist and have correct values
  local total truncated_val
  total=$(jq '.open_issue_total' "${meta_file}")
  truncated_val=$(jq '.backlog_truncated' "${meta_file}")
  if ! assert_eq "${test_name}: open_issue_total" "1879" "${total}"; then return; fi
  if ! assert_eq "${test_name}: backlog_truncated" "false" "${truncated_val}"; then return; fi

  # Verify existing fields still present
  local backlog_issues
  backlog_issues=$(jq '.backlog_issues' "${meta_file}")
  if ! assert_eq "${test_name}: backlog_issues" "1879" "${backlog_issues}"; then return; fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# Test 6b: backlog_truncated is true when counts diverge
# ===================================================================
test_metadata_truncated() {
  local test_name="metadata-truncated"
  local meta_file="${TMPDIR}/meta-${test_name}.json"

  # Simulate: fetched 950 issues but API reports 1879 total
  jq -n \
    --arg cutoff "2026-08-06T09:00:00Z" \
    --arg notes_url "https://docs.google.com/document/d/abc" \
    --arg repo "mock-org/mock-repo" \
    --argjson doc_count 1 \
    --argjson issue_count 950 \
    --argjson open_total 1879 \
    --argjson truncated true \
    --argjson closed_count 50 \
    --argjson pr_count 10 \
    --argjson doc_path_count 25 \
    '{
      cutoff_date: $cutoff,
      notes_url: $notes_url,
      repo: $repo,
      docs_downloaded: $doc_count,
      backlog_issues: $issue_count,
      open_issue_total: $open_total,
      backlog_truncated: $truncated,
      closed_issues: $closed_count,
      open_prs: $pr_count,
      repo_docs: $doc_path_count
    }' > "${meta_file}"

  local total truncated_val backlog_issues
  total=$(jq '.open_issue_total' "${meta_file}")
  truncated_val=$(jq '.backlog_truncated' "${meta_file}")
  backlog_issues=$(jq '.backlog_issues' "${meta_file}")
  if ! assert_eq "${test_name}: open_issue_total" "1879" "${total}"; then return; fi
  if ! assert_eq "${test_name}: backlog_truncated" "true" "${truncated_val}"; then return; fi
  if ! assert_eq "${test_name}: backlog_issues" "950" "${backlog_issues}"; then return; fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# Test 7: Labels and milestone are preserved from REST API format
# ===================================================================
test_labels_milestone_preserved() {
  local test_name="github/labels-milestone-preserved"
  local fixture="${TMPDIR}/fixture-${test_name//\//-}.json"
  local backlog="${TMPDIR}/backlog-${test_name//\//-}.json"

  cat > "${fixture}" <<'EOF'
[
  {
    "number": 40,
    "title": "Labeled issue",
    "body": "has labels and milestone",
    "labels": [{"id": 1, "name": "bug", "color": "d73a4a"}, {"id": 2, "name": "high-priority", "color": "ff0000"}],
    "milestone": {"id": 1, "title": "v2.0", "number": 3},
    "html_url": "https://github.com/o/r/issues/40"
  }
]
EOF

  build_mock_gh "${fixture}"
  run_backlog_fetch_github "o/r" "${backlog}"

  local label_count label_name milestone_title
  label_count=$(jq '.[0].labels | length' "${backlog}")
  label_name=$(jq -r '.[0].labels[0].name' "${backlog}")
  milestone_title=$(jq -r '.[0].milestone.title' "${backlog}")

  if ! assert_eq "${test_name}: label count" "2" "${label_count}"; then return; fi
  if ! assert_eq "${test_name}: label name" "bug" "${label_name}"; then return; fi
  if ! assert_eq "${test_name}: milestone title" "v2.0" "${milestone_title}"; then return; fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# Test 8: Truncation detection logic (bash arithmetic + comparison)
# ===================================================================
test_truncation_detection_logic() {
  local test_name="truncation-detection-logic"

  # Reproduces the bash arithmetic from pre-scribe.sh truncation detection.
  # Mirrors the tolerance-based comparison: only flag truncation when the
  # shortfall exceeds TRUNCATION_TOLERANCE (default 5), absorbing small
  # discrepancies from API timing between the paginated fetch and the
  # repo metadata call.
  # Takes: paginated_total, issue_count, repo_open_count (empty = API failed)
  # Outputs: "BACKLOG_TRUNCATED OPEN_ISSUE_TOTAL"
  run_truncation_logic() {
    local paginated_total="$1" issue_count="$2" repo_open_count="$3"
    local backlog_truncated open_issue_total
    local truncation_tolerance=5

    if [[ -n "${repo_open_count}" ]]; then
      local shortfall=$((repo_open_count - paginated_total))
      [[ "${shortfall}" -gt "${truncation_tolerance}" ]] && backlog_truncated=true || backlog_truncated=false
      local observed_pr_count=$((paginated_total - issue_count))
      open_issue_total=$((repo_open_count - observed_pr_count))
      [[ "${open_issue_total}" -lt 0 ]] && open_issue_total="${issue_count}"
    else
      open_issue_total="${issue_count}"
      backlog_truncated=false
    fi
    echo "${backlog_truncated} ${open_issue_total}"
  }

  local result truncated total

  # Case 1: No truncation — all items fetched, 21 PRs in response
  # paginated_total=1900 (1879 issues + 21 PRs), repo reports 1900
  result=$(run_truncation_logic 1900 1879 1900)
  truncated="${result%% *}"; total="${result##* }"
  if ! assert_eq "${test_name}: case1 truncated" "false" "${truncated}"; then return; fi
  if ! assert_eq "${test_name}: case1 total" "1879" "${total}"; then return; fi

  # Case 2: Truncation detected — pagination stopped early (large shortfall)
  # paginated_total=950 (900 issues + 50 PRs), repo reports 2000
  result=$(run_truncation_logic 950 900 2000)
  truncated="${result%% *}"; total="${result##* }"
  if ! assert_eq "${test_name}: case2 truncated" "true" "${truncated}"; then return; fi
  if ! assert_eq "${test_name}: case2 total" "1950" "${total}"; then return; fi

  # Case 3: >100 PRs — old code would undercount PRs and false-positive truncate
  # paginated_total=2100 (1900 issues + 200 PRs), repo reports 2100
  # Old logic: OPEN_ISSUE_TOTAL = 2100 - 100 (capped PR_COUNT) = 2000 → false truncation
  # New logic: compares paginated_total vs repo_open_count → equal → no truncation
  result=$(run_truncation_logic 2100 1900 2100)
  truncated="${result%% *}"; total="${result##* }"
  if ! assert_eq "${test_name}: case3 truncated" "false" "${truncated}"; then return; fi
  if ! assert_eq "${test_name}: case3 total" "1900" "${total}"; then return; fi

  # Case 4: API call failed (empty repo_open_count) — fallback
  result=$(run_truncation_logic 500 480 "")
  truncated="${result%% *}"; total="${result##* }"
  if ! assert_eq "${test_name}: case4 truncated" "false" "${truncated}"; then return; fi
  if ! assert_eq "${test_name}: case4 total" "480" "${total}"; then return; fi

  # Case 5: Zero PRs in response
  result=$(run_truncation_logic 500 500 500)
  truncated="${result%% *}"; total="${result##* }"
  if ! assert_eq "${test_name}: case5 truncated" "false" "${truncated}"; then return; fi
  if ! assert_eq "${test_name}: case5 total" "500" "${total}"; then return; fi

  # Case 6: Small discrepancy within tolerance (API timing race)
  # paginated_total=1897, repo reports 1900 — difference of 3 is within
  # tolerance of 5, so should NOT flag as truncated.
  result=$(run_truncation_logic 1897 1876 1900)
  truncated="${result%% *}"; total="${result##* }"
  if ! assert_eq "${test_name}: case6 truncated" "false" "${truncated}"; then return; fi
  if ! assert_eq "${test_name}: case6 total" "1879" "${total}"; then return; fi

  # Case 7: Shortfall exactly at tolerance boundary (5) — not truncated
  result=$(run_truncation_logic 1895 1875 1900)
  truncated="${result%% *}"; total="${result##* }"
  if ! assert_eq "${test_name}: case7 truncated" "false" "${truncated}"; then return; fi
  if ! assert_eq "${test_name}: case7 total" "1880" "${total}"; then return; fi

  # Case 8: Shortfall just above tolerance (6) — IS truncated
  result=$(run_truncation_logic 1894 1874 1900)
  truncated="${result%% *}"; total="${result##* }"
  if ! assert_eq "${test_name}: case8 truncated" "true" "${truncated}"; then return; fi
  if ! assert_eq "${test_name}: case8 total" "1880" "${total}"; then return; fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# GitLab tests
# ===================================================================

# ===================================================================
# Test GL-1: GitLab issues normalized (iid→number, description→body,
# web_url→url, labels as objects)
# ===================================================================
test_gitlab_normalization() {
  local test_name="gitlab/normalization"
  local fixture="${TMPDIR}/fixture-${test_name//\//-}.json"
  local backlog="${TMPDIR}/backlog-${test_name//\//-}.json"

  cat > "${fixture}" <<'EOF'
[
  {"iid": 1, "title": "GitLab bug", "description": "stale issue", "labels": ["bug"], "milestone": null, "web_url": "https://gitlab.com/g/p/-/issues/1"},
  {"iid": 2, "title": "Feature request", "description": "add dark mode", "labels": ["enhancement", "ui"], "milestone": {"title": "v2"}, "web_url": "https://gitlab.com/g/p/-/issues/2"}
]
EOF

  build_mock_curl "${fixture}"
  run_backlog_fetch_gitlab "g/p" "${backlog}"

  local count
  count=$(jq 'length' "${backlog}")
  if ! assert_eq "${test_name}: count" "2" "${count}"; then
    echo "  backlog: $(cat "${backlog}")"
    return
  fi

  # Verify field normalization
  local number url body label_name label_count
  number=$(jq '.[0].number' "${backlog}")
  url=$(jq -r '.[0].url' "${backlog}")
  body=$(jq -r '.[0].body' "${backlog}")
  label_name=$(jq -r '.[0].labels[0].name' "${backlog}")
  label_count=$(jq '.[1].labels | length' "${backlog}")

  if ! assert_eq "${test_name}: iid→number" "1" "${number}"; then return; fi
  if ! assert_eq "${test_name}: web_url→url" "https://gitlab.com/g/p/-/issues/1" "${url}"; then return; fi
  if ! assert_eq "${test_name}: description→body" "stale issue" "${body}"; then return; fi
  if ! assert_eq "${test_name}: labels as objects" "bug" "${label_name}"; then return; fi
  if ! assert_eq "${test_name}: multiple labels" "2" "${label_count}"; then return; fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# Test GL-2: GitLab body truncation
# ===================================================================
test_gitlab_body_truncation() {
  local test_name="gitlab/body-truncation"
  local fixture="${TMPDIR}/fixture-${test_name//\//-}.json"
  local backlog="${TMPDIR}/backlog-${test_name//\//-}.json"

  local long_body
  long_body=$(printf 'b%.0s' $(seq 1 600))

  jq -n --arg desc "${long_body}" \
    '[{"iid": 10, "title": "Long body", "description": $desc, "labels": [], "milestone": null, "web_url": "https://gitlab.com/g/p/-/issues/10"}]' \
    > "${fixture}"

  build_mock_curl "${fixture}"
  run_backlog_fetch_gitlab "g/p" "${backlog}"

  local body_len
  body_len=$(jq -r '.[0].body | length' "${backlog}")
  if ! assert_eq "${test_name}: truncated length" "501" "${body_len}"; then
    echo "  actual body length: ${body_len}"
    return
  fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# Test GL-3: GitLab null description handled gracefully
# ===================================================================
test_gitlab_null_body() {
  local test_name="gitlab/null-body"
  local fixture="${TMPDIR}/fixture-${test_name//\//-}.json"
  local backlog="${TMPDIR}/backlog-${test_name//\//-}.json"

  cat > "${fixture}" <<'EOF'
[
  {"iid": 30, "title": "No body issue", "description": null, "labels": [], "milestone": null, "web_url": "https://gitlab.com/g/p/-/issues/30"}
]
EOF

  build_mock_curl "${fixture}"
  run_backlog_fetch_gitlab "g/p" "${backlog}"

  local body
  body=$(jq -r '.[0].body' "${backlog}")
  if ! assert_eq "${test_name}: null body becomes empty" "" "${body}"; then return; fi

  echo "PASS: ${test_name}"
}

# ===================================================================
# Test GL-4: GitLab labels and milestone preserved
# ===================================================================
test_gitlab_labels_milestone_preserved() {
  local test_name="gitlab/labels-milestone-preserved"
  local fixture="${TMPDIR}/fixture-${test_name//\//-}.json"
  local backlog="${TMPDIR}/backlog-${test_name//\//-}.json"

  cat > "${fixture}" <<'EOF'
[
  {
    "iid": 40,
    "title": "Labeled issue",
    "description": "has labels and milestone",
    "labels": ["bug", "high-priority"],
    "milestone": {"id": 1, "title": "v2.0"},
    "web_url": "https://gitlab.com/g/p/-/issues/40"
  }
]
EOF

  build_mock_curl "${fixture}"
  run_backlog_fetch_gitlab "g/p" "${backlog}"

  local label_count label_name milestone_title
  label_count=$(jq '.[0].labels | length' "${backlog}")
  label_name=$(jq -r '.[0].labels[0].name' "${backlog}")
  milestone_title=$(jq -r '.[0].milestone.title' "${backlog}")

  if ! assert_eq "${test_name}: label count" "2" "${label_count}"; then return; fi
  if ! assert_eq "${test_name}: label name" "bug" "${label_name}"; then return; fi
  if ! assert_eq "${test_name}: milestone title" "v2.0" "${milestone_title}"; then return; fi

  echo "PASS: ${test_name}"
}

# --- Run tests ---

# GitHub tests
test_pagination_filters_prs
test_body_truncation
test_short_body_preserved
test_empty_issues
test_null_body
test_metadata_fields
test_metadata_truncated
test_labels_milestone_preserved
test_truncation_detection_logic

# GitLab tests
test_gitlab_normalization
test_gitlab_body_truncation
test_gitlab_null_body
test_gitlab_labels_milestone_preserved

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
