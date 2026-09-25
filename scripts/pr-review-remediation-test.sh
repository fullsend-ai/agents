#!/usr/bin/env bash
# pr-review-remediation-test.sh — Verify re-review remediation guidance.
#
# Run from the repo root:
#   bash scripts/pr-review-remediation-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/pr-review/SKILL.md"
INTENT="${REPO_ROOT}/skills/pr-review/sub-agents/intent-coherence.md"
REVIEW_AGENT="${REPO_ROOT}/agents/review.md"
GITHUB_FORGE="${REPO_ROOT}/skills/pr-review/github/SKILL.md"
GITLAB_FORGE="${REPO_ROOT}/skills/pr-review/gitlab/SKILL.md"
EVAL_SETUP="${REPO_ROOT}/eval/scripts/setup-fixture.sh"
EVAL_RUNNER="${REPO_ROOT}/eval/scripts/run-fullsend.sh"
EVAL_UNMATCHED="${REPO_ROOT}/eval/review/cases/008-rereview-unmatched-file/input.yaml"
EVAL_UNMATCHED_EXPECTATIONS="${REPO_ROOT}/eval/review/cases/008-rereview-unmatched-file/annotations.yaml"
FAILURES=0

assert_contains() {
  local name="$1" file="$2" expected="$3"
  if grep -qF -- "${expected}" "${file}"; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name} — missing '${expected}' in ${file#"${REPO_ROOT}/"}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_not_contains() {
  local name="$1" file="$2" unexpected="$3"
  if grep -qF -- "${unexpected}" "${file}"; then
    echo "FAIL: ${name} — found obsolete '${unexpected}' in ${file#"${REPO_ROOT}/"}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${name}"
  fi
}

assert_order() {
  local name="$1" file="$2" first="$3" second="$4"
  local first_line second_line
  first_line=$(grep -nF -- "${first}" "${file}" | head -1 | cut -d: -f1 || true)
  second_line=$(grep -nF -- "${second}" "${file}" | head -1 | cut -d: -f1 || true)
  if [[ -n "${first_line}" && -n "${second_line}" && "${first_line}" -lt "${second_line}" ]]; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name} — expected '${first}' before '${second}' in ${file#"${REPO_ROOT}/"}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_jq_result() {
  local name="$1" filter="$2" payload="$3" expected="$4"
  local actual=false
  if printf '%s\n' "${payload}" | jq -e "${filter}" >/dev/null 2>&1; then
    actual=true
  fi
  if [[ "${actual}" == "${expected}" ]]; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name} — expected jq result ${expected}, got ${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

extract_compare_snippet() {
  local file="$1"
  awk '
    /^## Prior review comparison$/ { found = 1; next }
    found && /^```bash$/ { code = 1; next }
    code && /^```$/ { exit }
    code { print }
  ' "${file}"
}

assert_compare_snippet() {
  local name="$1" forge_file="$2" payload="$3" command_exit="$4"
  local expected_incomplete="$5" expected_files="$6" expected_incremental="$7"
  local fail_mv="${8:-false}" omit_full_diff="${9:-false}"
  local expected_exit="${10:-0}" fail_final_marker="${11:-false}"
  local case_dir snippet snippet_exit actual_incomplete actual_files
  local actual_incremental precall_state
  case_dir=$(mktemp -d)
  mkdir -p "${case_dir}/bin" "${case_dir}/workspace"
  printf '%s\n' "${payload}" > "${case_dir}/payload.json"
  if [[ "${omit_full_diff}" != true ]]; then
    printf '%s\n' "base diff fallback" > "${case_dir}/workspace/pr-diff.txt"
  fi
  printf '%s\n' false > "${case_dir}/workspace/pr-compare-incomplete"
  printf '%s\n' stale > "${case_dir}/workspace/pr-changed-files.txt"
  printf '%s\n' stale > "${case_dir}/workspace/pr-incremental-diff.txt"
  if [[ "${fail_final_marker}" == true ]]; then
    printf '%s\n' false > "${case_dir}/workspace/pr-compare-incomplete.tmp"
    chmod 0444 "${case_dir}/workspace/pr-compare-incomplete.tmp"
  fi

  cat > "${case_dir}/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$(cat "${COMPARE_MARKER}")" == true ]]; then
  printf '%s\n' safe > "${PRECALL_STATE}"
else
  printf '%s\n' unsafe > "${PRECALL_STATE}"
fi
cat "${COMPARE_PAYLOAD}"
exit "${COMPARE_COMMAND_EXIT}"
EOF
  cp "${case_dir}/bin/gh" "${case_dir}/bin/curl"
  cat > "${case_dir}/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${COMPARE_FAIL_MV}" == true && "$1" == *pr-incremental-diff.txt.tmp ]]; then
  exit 1
fi
exec /bin/mv "$@"
EOF
  chmod +x "${case_dir}/bin/gh" "${case_dir}/bin/curl" "${case_dir}/bin/mv"

  snippet=$(extract_compare_snippet "${forge_file}" \
    | sed "s#/sandbox/workspace#${case_dir}/workspace#g")
  if env \
    PATH="${case_dir}/bin:${PATH}" \
    COMPARE_MARKER="${case_dir}/workspace/pr-compare-incomplete" \
    PRECALL_STATE="${case_dir}/precall-state" \
    COMPARE_PAYLOAD="${case_dir}/payload.json" \
    COMPARE_COMMAND_EXIT="${command_exit}" \
    COMPARE_FAIL_MV="${fail_mv}" \
    REPO_FULL_NAME=example/repo PRIOR_REVIEW_SHA=base HEAD_SHA=head \
    GITLAB_TOKEN=test GITLAB_HOST=gitlab.example.com REPO_ENCODED=example%2Frepo \
    bash -u -o pipefail -c "${snippet}" 2> "${case_dir}/snippet.stderr"; then
    snippet_exit=0
  else
    snippet_exit=$?
  fi

  precall_state=$(cat "${case_dir}/precall-state" 2>/dev/null || true)
  if [[ "${expected_exit}" != 0 ]]; then
    if [[ "${snippet_exit}" -ne 0 && -z "${precall_state}" ]]; then
      echo "PASS: ${name}"
    else
      echo "FAIL: ${name} — exit=${snippet_exit}, pre-call=${precall_state}"
      FAILURES=$((FAILURES + 1))
    fi
    return
  elif [[ "${snippet_exit}" -ne 0 ]]; then
    echo "FAIL: ${name} — compare snippet exited ${snippet_exit}"
    cat "${case_dir}/snippet.stderr"
    FAILURES=$((FAILURES + 1))
    return
  fi

  actual_incomplete=$(cat "${case_dir}/workspace/pr-compare-incomplete")
  actual_files=$(cat "${case_dir}/workspace/pr-changed-files.txt")
  actual_incremental=$(cat "${case_dir}/workspace/pr-incremental-diff.txt")
  if [[ "${actual_incomplete}" == "${expected_incomplete}" \
    && "${actual_files}" == "${expected_files}" \
    && "${actual_incremental}" == "${expected_incremental}" \
    && "${precall_state}" == safe ]]; then
    echo "PASS: ${name}"
  else
    printf 'FAIL: %s — incomplete=%s, files=%s, incremental=%q, pre-call=%s\n' \
      "${name}" "${actual_incomplete}" "${actual_files}" "${actual_incremental}" \
      "${precall_state}"
    FAILURES=$((FAILURES + 1))
  fi
}

GITHUB_COMPARE_COMPLETE='def safe_path: type == "string" and length > 0 and (test("(^/|/$|//|(^|/)\\.\\.?(/|$)|[\\\\\\r\\n<>])") | not); def binary_path: type == "string" and test("\\.(?i:png|jpe?g|gif|webp|bmp|ico|svgz|pdf|zip|gz|tgz|bz2|xz|7z|tar|mp3|mp4|mov|avi|webm|woff2?|ttf|otf|eot|wasm|exe|dll|so|dylib|jar|class|psd|ai|sketch)$"); def usable_patch: (.patch | type == "string" and length > 0); def content_free_rename: (.status == "renamed" and .additions == 0 and .deletions == 0 and (.previous_filename | safe_path)); type == "object" and (.total_commits | type == "number") and (.files | type == "array") and ((.files | length) < 300) and ((.truncated // false) == false) and (.total_commits <= 250) and all(.files[]?; (.filename | safe_path) and (.previous_filename == null or (.previous_filename | safe_path)) and (usable_patch or (.filename | binary_path) or content_free_rename))'
GITLAB_COMPARE_COMPLETE='def safe_path: type == "string" and length > 0 and (test("(^/|/$|//|(^|/)\\.\\.?(/|$)|[\\\\\\r\\n<>])") | not); type == "object" and (.diffs | type == "array") and ((.compare_timeout // false) == false) and all(.diffs[]?; (.old_path | safe_path) and (.new_path | safe_path))'

assert_contains "skill materializes incremental diff" "${SKILL}" \
  "/sandbox/workspace/pr-incremental-diff.txt"
assert_contains "GitHub comparison writes incremental diff" "${GITHUB_FORGE}" \
  "pr-incremental-diff.txt"
assert_contains "GitLab comparison writes incremental diff" "${GITLAB_FORGE}" \
  "pr-incremental-diff.txt"
assert_contains "candidate matching uses structured file fields" "${SKILL}" \
  'prior structured `file`'
assert_not_contains "candidate matching rejects free-text targets" "${SKILL}" \
  "explicit remediation target named by the finding"
assert_contains "GitHub provenance authorizes remediation" "${SKILL}" \
  'Only `app-verified` may authorize remediation exemptions'
assert_contains "GitLab provenance only anchors severity" "${SKILL}" \
  '`bot-verified` may anchor'
assert_contains "skill rejects untrusted provenance" "${SKILL}" \
  "unknown values cannot authorize remediation"
assert_contains "skill provides provenance to sub-agent" "${SKILL}" \
  "Prior review provenance"
assert_contains "context assembly supplies candidates" "${SKILL}" \
  "remediation_candidates"
assert_contains "context assembly supplies provenance" "${SKILL}" \
  "prior_review_provenance"
assert_contains "context assembly supplies incremental diff" "${SKILL}" \
  "incremental_diff"
assert_not_contains "prior finding context does not claim an id field" "${SKILL}" \
  "severity, category, file, line, and id records"
assert_contains "prior review data is fenced as untrusted" "${SKILL}" \
  "UNTRUSTED PRIOR-REVIEW DATA"
assert_contains "unsafe structured metadata is rejected" "${SKILL}" \
  "It rejects, never rewrites, invalid records"
assert_contains "optional prior finding fields remain optional" "${SKILL}" \
  "optional positive"
assert_contains "prior findings use a structured projection" "${SKILL}" \
  "structured projection"
assert_not_contains "raw prior finding JSON is not prompted" "${SKILL}" \
  '<prior findings JSON or "none — first review">'
assert_contains "GitHub compare records unanchored missing patches" "${GITHUB_FORGE}" \
  'select(.patch | type == "string" and length > 0)'
assert_contains "GitLab compare records unanchored missing diffs" "${GITLAB_FORGE}" \
  'select((.diff | type == "string" and length > 0) and ((.too_large // false) == false) and ((.collapsed // false) == false))'
assert_contains "patchless paths re-qualify intent review" "${SKILL}" \
  "file without an incremental patch, or when a non-empty delta"
assert_contains "GitHub compare requires proven completeness" "${GITHUB_FORGE}" \
  "${GITHUB_COMPARE_COMPLETE}"
assert_contains "GitLab compare requires proven completeness" "${GITLAB_FORGE}" \
  "${GITLAB_COMPARE_COMPLETE}"
assert_contains "GitHub compare API fails closed" "${GITHUB_FORGE}" \
  'if ! gh api'
assert_contains "GitHub comparison persists completeness" "${GITHUB_FORGE}" \
  'pr-compare-incomplete'
assert_contains "GitHub comparison persists changed files" "${GITHUB_FORGE}" \
  'pr-changed-files.txt'
assert_contains "GitLab comparison persists completeness" "${GITLAB_FORGE}" \
  'pr-compare-incomplete'
assert_contains "GitLab comparison persists changed files" "${GITLAB_FORGE}" \
  'pr-changed-files.txt'
assert_contains "Prior identity is machine-readable" "${SKILL}" \
  'finding identity from review Markdown.'
assert_contains "Prior paths are rejected, never rewritten" "${SKILL}" \
  "It rejects, never rewrites, invalid records"
assert_contains "Missing-test counterpart is exact" "${SKILL}" \
  'safe `missing-test` `.go` → `_test.go`'
assert_jq_result "GitHub accepts complete compare" "${GITHUB_COMPARE_COMPLETE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' true
assert_jq_result "GitHub rejects API error JSON" "${GITHUB_COMPARE_COMPLETE}" \
  '{"message":"Not Found"}' false
assert_jq_result "GitHub rejects missing commit count" "${GITHUB_COMPARE_COMPLETE}" \
  '{"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' false
assert_jq_result "GitHub rejects truncated compare" "${GITHUB_COMPARE_COMPLETE}" \
  '{"truncated":true,"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' false
assert_jq_result "GitHub rejects commit overflow" "${GITHUB_COMPARE_COMPLETE}" \
  '{"total_commits":251,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' false
assert_jq_result "GitHub accepts unanchored binary path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"total_commits":1,"files":[{"filename":"image.png","patch":null}]}' true
assert_jq_result "GitHub accepts content-free rename without a patch" "${GITHUB_COMPARE_COMPLETE}" \
  '{"total_commits":1,"files":[{"filename":"new.txt","previous_filename":"old.txt","status":"renamed","additions":0,"deletions":0,"patch":null}]}' true
assert_jq_result "GitHub rejects patchless rename without previous path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"total_commits":1,"files":[{"filename":"new.txt","status":"renamed","additions":0,"deletions":0,"patch":null}]}' false
assert_jq_result "GitHub rejects unpatched source path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"total_commits":1,"files":[{"filename":"pkg/auth.go","patch":null}]}' false
assert_jq_result "GitHub rejects newline in current path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt\nb.md","patch":"@@"}]}' false
assert_jq_result "GitHub rejects traversal in previous path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt","previous_filename":"../old.txt","patch":"@@"}]}' false
assert_jq_result "GitHub rejects dot path component" "${GITHUB_COMPARE_COMPLETE}" \
  '{"total_commits":1,"files":[{"filename":"docs/./a.txt","patch":"@@"}]}' false
assert_jq_result "GitHub rejects backslash path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"total_commits":1,"files":[{"filename":"docs\\a.txt","patch":"@@"}]}' false
assert_jq_result "GitHub rejects prompt delimiter in previous path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt","previous_filename":"<old>.txt","patch":"@@"}]}' false
assert_jq_result "GitLab accepts complete compare" "${GITLAB_COMPARE_COMPLETE}" \
  '{"diffs":[{"old_path":"a.txt","new_path":"a.txt","diff":"@@ -1 +1 @@"}]}' true
assert_jq_result "GitLab rejects API error JSON" "${GITLAB_COMPARE_COMPLETE}" \
  '{"message":"404 Project Not Found"}' false
assert_jq_result "GitLab rejects timed-out compare" "${GITLAB_COMPARE_COMPLETE}" \
  '{"compare_timeout":true,"diffs":[{"old_path":"a.txt","new_path":"a.txt","diff":"@@"}]}' false
assert_jq_result "GitLab accepts unanchored empty diff path" "${GITLAB_COMPARE_COMPLETE}" \
  '{"diffs":[{"old_path":"a.txt","new_path":"a.txt","diff":""}]}' true
assert_jq_result "GitLab accepts unanchored oversized diff path" "${GITLAB_COMPARE_COMPLETE}" \
  '{"diffs":[{"old_path":"a.txt","new_path":"a.txt","diff":"@@","too_large":true}]}' true
assert_jq_result "GitLab rejects absolute current path" "${GITLAB_COMPARE_COMPLETE}" \
  '{"diffs":[{"old_path":"a.txt","new_path":"/a.txt","diff":"@@"}]}' false
assert_jq_result "GitLab rejects repeated slash" "${GITLAB_COMPARE_COMPLETE}" \
  '{"diffs":[{"old_path":"a.txt","new_path":"docs//a.txt","diff":"@@"}]}' false
assert_jq_result "GitLab rejects trailing slash" "${GITLAB_COMPARE_COMPLETE}" \
  '{"diffs":[{"old_path":"a.txt","new_path":"docs/","diff":"@@"}]}' false
assert_jq_result "GitLab rejects newline in old path" "${GITLAB_COMPARE_COMPLETE}" \
  '{"diffs":[{"old_path":"a.txt\nb.md","new_path":"a.txt","diff":"@@"}]}' false
assert_compare_snippet "GitHub complete compare installs precise artifacts" "${GITHUB_FORGE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' 0 false a.txt \
  $'diff --git a/a.txt b/a.txt\n@@ -1 +1 @@'
assert_compare_snippet "GitHub keeps unpatched paths unanchored" "${GITHUB_FORGE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"},{"filename":"image.png","patch":null}]}' \
  0 false $'a.txt\nimage.png' \
  $'diff --git a/a.txt b/a.txt\n@@ -1 +1 @@'
assert_compare_snippet "GitHub falls back for unpatched source paths" "${GITHUB_FORGE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"},{"filename":"pkg/auth.go","patch":null}]}' \
  0 true all \
  "base diff fallback"
assert_compare_snippet "GitHub rename qualifies old and current paths" "${GITHUB_FORGE}" \
  '{"total_commits":1,"files":[{"previous_filename":"pkg/auth/token.go","filename":"pkg/util/helpers.go","patch":"@@ -1 +1 @@"}]}' \
  0 false $'pkg/auth/token.go\npkg/util/helpers.go' \
  $'diff --git a/pkg/auth/token.go b/pkg/util/helpers.go\n@@ -1 +1 @@'
assert_compare_snippet "GitHub command failure preserves fail-closed state" "${GITHUB_FORGE}" \
  '{"message":"Not Found"}' 1 true all "base diff fallback"
assert_compare_snippet "GitHub unsafe path preserves fail-closed state" "${GITHUB_FORGE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt\nb.md","patch":"@@"}]}' 0 true all "base diff fallback"
assert_compare_snippet "GitHub malformed payload preserves fail-closed state" "${GITHUB_FORGE}" \
  '{"message":"Not Found"}' 0 true all "base diff fallback"
assert_compare_snippet "GitHub artifact install failure preserves fail-closed state" "${GITHUB_FORGE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' 0 true all \
  "base diff fallback" true
assert_compare_snippet "GitHub conservative initialization failure aborts before API" "${GITHUB_FORGE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' 0 true all \
  "base diff fallback" false true 1
assert_compare_snippet "GitHub final marker failure cannot publish stale false" "${GITHUB_FORGE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' 0 true a.txt \
  $'diff --git a/a.txt b/a.txt\n@@ -1 +1 @@' false false 0 true
assert_compare_snippet "GitLab complete compare installs precise artifacts" "${GITLAB_FORGE}" \
  '{"compare_timeout":false,"diffs":[{"old_path":"a.txt","new_path":"a.txt","diff":"@@ -1 +1 @@"}]}' 0 false a.txt \
  $'diff --git a/a.txt b/a.txt\n@@ -1 +1 @@'
assert_compare_snippet "GitLab keeps undiffed paths unanchored" "${GITLAB_FORGE}" \
  '{"compare_timeout":false,"diffs":[{"old_path":"a.txt","new_path":"a.txt","diff":"@@ -1 +1 @@"},{"old_path":"image.png","new_path":"image.png","diff":""}]}' \
  0 false $'a.txt\nimage.png' \
  $'diff --git a/a.txt b/a.txt\n@@ -1 +1 @@'
assert_compare_snippet "GitLab rename qualifies old and current paths" "${GITLAB_FORGE}" \
  '{"compare_timeout":false,"diffs":[{"old_path":"pkg/auth/token.go","new_path":"pkg/util/helpers.go","diff":"@@ -1 +1 @@"}]}' \
  0 false $'pkg/auth/token.go\npkg/util/helpers.go' \
  $'diff --git a/pkg/auth/token.go b/pkg/util/helpers.go\n@@ -1 +1 @@'
assert_compare_snippet "GitLab timeout preserves fail-closed state" "${GITLAB_FORGE}" \
  '{"compare_timeout":true,"diffs":[{"old_path":"a.txt","new_path":"a.txt","diff":"@@"}]}' 0 true all \
  "base diff fallback"
assert_compare_snippet "GitLab unsafe path preserves fail-closed state" "${GITLAB_FORGE}" \
  '{"diffs":[{"old_path":"../a.txt","new_path":"a.txt","diff":"@@"}]}' 0 true all \
  "base diff fallback"
assert_contains "skill keeps incomplete patch bodies unanchored" "${SKILL}" \
  "without a usable patch"
assert_order "remediation candidates precede budget allocation" "${SKILL}" \
  "#### 3a-1. Prior-finding remediation candidates" \
  "#### 3a-2. Budget allocation priority"
assert_contains "re-review examples dispatch intent" "${SKILL}" \
  "intent-coherence (trivial scope)"
assert_contains "GitHub re-review example names app provenance" "${SKILL}" \
  "GitHub app-verified re-review"
assert_contains "GitLab re-review example keeps base dispatch" "${SKILL}" \
  "GitLab bot-verified re-review"
assert_not_contains "obsolete unconditional dispatch removed" "${SKILL}" \
  'always re-qualifies when `changed_since_prior` is non-empty'
assert_contains "intent exemption is stated without ambiguous negation" "${INTENT}" \
  "matched candidate as scope creep unless"
assert_not_contains "intent removes do-not-only-when ambiguity" "${INTENT}" \
  "Do not report a matched remediation candidate as scope creep only when"
assert_contains "intent retains issue authorization" "${INTENT}" \
  "scope creep only when a change is authorized by"
assert_contains "intent keeps correctness ownership separate" "${INTENT}" \
  "not a second correctness pass"
assert_contains "ambiguous candidates remain unanchored" "${INTENT}" \
  "structured metadata is insufficient to establish directness"
assert_not_contains "intent does not claim correctness ownership" "${INTENT}" \
  "candidates for correctness and completeness"
assert_contains "review agent documents GitLab provenance" "${REVIEW_AGENT}" \
  "bot-verified"
assert_contains "review agent limits GitLab provenance authority" "${REVIEW_AGENT}" \
  "does not authorize remediation exemptions"
assert_contains "review agent documents GitLab provenance rejection" "${REVIEW_AGENT}" \
  "unverifiable-wrong-user"
assert_contains "review agent describes the validated prior projection" "${REVIEW_AGENT}" \
  "Canonical prior-finding JSON"
assert_not_contains "review agent does not describe prior-review file as raw body" "${REVIEW_AGENT}" \
  'The prior review body (`/sandbox/workspace/prior-review.txt`)'
assert_contains "eval setup creates a re-review follow-up" "${EVAL_SETUP}" \
  "FOLLOWUP_FILES"
assert_contains "eval setup writes trusted prior review input" "${EVAL_SETUP}" \
  "PRIOR_REVIEW_FILE"
assert_contains "eval setup gates prior review SHA" "${EVAL_SETUP}" \
  'PRIOR_REVIEW_SHA="${FIXTURE_INITIAL_SHA:-}"'
assert_contains "eval runner forwards prior review input" "${EVAL_RUNNER}" \
  "PRIOR_REVIEW_FILE"
assert_contains "re-review fixed-scope heading covers conditional intent" "${SKILL}" \
  "Fixed-scope sub-agent assignments WITHOUT prior findings"
assert_contains "isolated unmatched-file eval changes only changelog" "${EVAL_UNMATCHED}" \
  "path: CHANGELOG.md"
assert_contains "isolated unmatched-file eval requires scope creep" "${EVAL_UNMATCHED_EXPECTATIONS}" \
  "- scope-creep"
assert_contains "isolated unmatched-file eval documents its isolation" "${EVAL_UNMATCHED_EXPECTATIONS}" \
  "only follow-up file is CHANGELOG.md"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi

echo "All PR review remediation tests passed"
