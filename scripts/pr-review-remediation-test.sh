#!/usr/bin/env bash
# pr-review-remediation-test.sh — Verify re-review remediation guidance.
#
# Run from the repo root:
#   bash scripts/pr-review-remediation-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/pr-review/SKILL.md"
REREVIEW="${REPO_ROOT}/skills/pr-review/references/re-review.md"
INTENT="${REPO_ROOT}/skills/pr-review/sub-agents/intent-coherence.md"
REVIEW_AGENT="${REPO_ROOT}/agents/review.md"
CODE_REVIEW="${REPO_ROOT}/skills/code-review/SKILL.md"
GITHUB_FORGE="${REPO_ROOT}/skills/pr-review/github/SKILL.md"
GITLAB_FORGE="${REPO_ROOT}/skills/pr-review/gitlab/SKILL.md"
EVAL_SETUP="${REPO_ROOT}/eval/scripts/setup-fixture.sh"
EVAL_README="${REPO_ROOT}/eval/README.md"
EVAL_CONFIG="${REPO_ROOT}/eval/review/eval.yaml"
EVAL_RUNNER="${REPO_ROOT}/eval/scripts/run-fullsend.sh"
EVAL_UNMATCHED="${REPO_ROOT}/eval/review/cases/008-rereview-unmatched-file/input.yaml"
EVAL_UNMATCHED_EXPECTATIONS="${REPO_ROOT}/eval/review/cases/008-rereview-unmatched-file/annotations.yaml"
EVAL009_EXPECTATIONS="${REPO_ROOT}/eval/review/cases/009-rereview-severity-anchor/annotations.yaml"
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
  local merge_base_payload='{"id":"base"}' merge_base_exit="${13:-0}"
  [[ $# -ge 12 ]] && merge_base_payload="${12}"
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
  cat > "${case_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$(cat "${COMPARE_MARKER}")" == true ]]; then
  printf '%s\n' safe > "${PRECALL_STATE}"
else
  printf '%s\n' unsafe > "${PRECALL_STATE}"
fi
if [[ "$*" == *repository/merge_base* ]]; then
  if [[ "$*" != *'refs[]=base'* || "$*" != *'refs[]=head'* ]]; then
    exit 2
  fi
  printf '%s\n' "${MERGE_BASE_PAYLOAD}"
  exit "${MERGE_BASE_EXIT}"
fi
cat "${COMPARE_PAYLOAD}"
exit "${COMPARE_COMMAND_EXIT}"
EOF
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
    MERGE_BASE_PAYLOAD="${merge_base_payload}" MERGE_BASE_EXIT="${merge_base_exit}" \
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

GITHUB_COMPARE_COMPLETE='def safe_path: type == "string" and length > 0 and test("^[ -~]+$") and (test("(^/|/$|//|(^|/)\\.\\.?(/|$)|[\\\\\\r\\n<>])") | not); def binary_path: type == "string" and test("\\.(?i:png|jpe?g|gif|webp|bmp|ico|svgz|pdf|zip|gz|tgz|bz2|xz|7z|tar|mp3|mp4|mov|avi|webm|woff2?|ttf|otf|eot|wasm|exe|dll|so|dylib|jar|class|psd|ai|sketch)$"); def usable_patch: (.patch | type == "string" and length > 0); def content_free_rename: (.status == "renamed" and .additions == 0 and .deletions == 0 and (.previous_filename | safe_path)); type == "object" and (.status == "ahead" or .status == "identical") and (.behind_by == 0) and (.total_commits | type == "number") and (.files | type == "array") and ((.files | length) < 300) and all(.files[]?; (.filename | safe_path) and (.previous_filename == null or (.previous_filename | safe_path)) and (usable_patch or (.filename | binary_path) or content_free_rename))'
GITLAB_COMPARE_COMPLETE='def safe_path: type == "string" and length > 0 and test("^[ -~]+$") and (test("(^/|/$|//|(^|/)\\.\\.?(/|$)|[\\\\\\r\\n<>])") | not); type == "object" and (.diffs | type == "array") and ((.compare_timeout // false) == false) and all(.diffs[]?; (.old_path | safe_path) and (.new_path | safe_path))'

assert_contains "orchestrator requires re-review reference before dispatch" "${SKILL}" \
  "Before interpreting prior-review inputs or selecting sub-agents, **read and follow"
assert_contains "orchestrator links re-review reference" "${SKILL}" \
  "[the re-review procedure](references/re-review.md)"
assert_contains "skill materializes incremental diff" "${SKILL}" \
  "/sandbox/workspace/pr-incremental-diff.txt"
assert_contains "GitHub comparison writes incremental diff" "${GITHUB_FORGE}" \
  "pr-incremental-diff.txt"
assert_contains "GitLab comparison writes incremental diff" "${GITLAB_FORGE}" \
  "pr-incremental-diff.txt"
assert_contains "candidate matching uses structured file fields" "${REREVIEW}" \
  'prior structured `file`'
assert_not_contains "candidate matching rejects free-text targets" "${REREVIEW}" \
  "explicit remediation target named by the finding"
assert_contains "GitHub provenance authorizes remediation" "${REREVIEW}" \
  'Only `app-verified` may authorize remediation exemptions'
assert_contains "GitLab provenance only anchors severity" "${REREVIEW}" \
  '`bot-verified` may anchor'
assert_contains "skill rejects untrusted provenance" "${REREVIEW}" \
  "unknown values cannot authorize remediation"
assert_contains "skill provides provenance to sub-agent" "${SKILL}" \
  "Prior review provenance"
assert_contains "context assembly supplies candidates" "${SKILL}" \
  "remediation_candidates"
assert_contains "context assembly supplies provenance" "${SKILL}" \
  "prior_review_provenance"
assert_contains "context assembly supplies incremental diff" "${SKILL}" \
  "incremental_diff"
assert_contains "prior finding context includes id records" "${SKILL}" \
  "severity, category, file, line, id, and status records"
assert_contains "prior review data is fenced as untrusted" "${SKILL}" \
  "UNTRUSTED PRIOR-REVIEW DATA"
assert_contains "unsafe structured metadata is rejected" "${REREVIEW}" \
  "It rejects, never rewrites, invalid records"
assert_contains "optional prior finding fields remain optional" "${REREVIEW}" \
  "optional positive"
assert_contains "prior findings use a structured projection" "${SKILL}" \
  "structured projection"
assert_contains "severity matching uses available structural anchors" "${CODE_REVIEW}" \
  "same category, non-null path, and unchanged function/class"
assert_not_contains "severity matching does not require unavailable descriptions" "${CODE_REVIEW}" \
  "Description match:"
assert_contains "ambiguous severity matches remain unanchored" "${CODE_REVIEW}" \
  "Ambiguous matches are new."
assert_contains "null file retains context without anchoring" "${REREVIEW}" \
  "A null file is PR-level context: keep its category for dispatch,"
assert_contains "prior-review input is already validated JSON" "${REREVIEW}" \
  '`/sandbox/workspace/prior-review.txt` is already validated JSON'
assert_not_contains "agent does not parse prior-review markers" "${REREVIEW}" \
  "Parse the versioned"
assert_contains "host marker extraction is background context" "${REREVIEW}" \
  "Host validation background"
assert_not_contains "raw prior finding JSON is not prompted" "${SKILL}" \
  '<prior findings JSON or "none — first review">'
assert_contains "GitHub compare records unanchored missing patches" "${GITHUB_FORGE}" \
  'select(.patch | type == "string" and length > 0)'
assert_contains "GitLab compare records unanchored missing diffs" "${GITLAB_FORGE}" \
  'select((.diff | type == "string" and length > 0) and ((.too_large // false) == false) and ((.collapsed // false) == false))'
assert_contains "patchless paths re-qualify intent review" "${SKILL}" \
  "file without an incremental patch, or when a non-empty delta"
assert_contains "intent re-review has a dedicated scope constraint" "${SKILL}" \
  'intent-specific `trivial` constraint defined in the re-review override below'
assert_contains "intent re-review scope explicitly permits incremental diff" "${SKILL}" \
  'Read ONLY `/sandbox/workspace/pr-incremental-diff.txt`'
assert_contains "intent re-review scope includes supplied candidates" "${SKILL}" \
  'supplied remediation candidates, and the linked issue'
assert_not_contains "commit-list cap is not a changed-files fallback" "${SKILL}" \
  ">250 commits"
assert_contains "commit-message fetch remains available for commit-only scope bundling" "${GITHUB_FORGE}" \
  'pulls/${PR_NUMBER}/commits?per_page=100'
assert_not_contains "commit-message fetch avoids scanner-disallowed rm" "${GITHUB_FORGE}" \
  'rm -f'
assert_contains "commit-message fetch initializes state without deletion" "${GITHUB_FORGE}" \
  ': > "$COMMIT_MESSAGES_FILE"'
assert_contains "commit-message fetch records whether context is available" "${GITHUB_FORGE}" \
  'COMMIT_MESSAGES_AVAILABLE_FILE=/sandbox/workspace/pr-commit-messages-available'
assert_contains "commit-message fetch marks successful context available" "${GITHUB_FORGE}" \
  "printf '%s\\n' true > \"\$COMMIT_MESSAGES_AVAILABLE_FILE\""
assert_contains "issue context collects title body and available commit references" "${SKILL}" \
  'title/body/available commits'
assert_contains "issue context is fetched content rather than bare issue numbers" "${SKILL}" \
  'fetched title/body/comments'
assert_not_contains "issue context does not fetch contributor-named repositories" "${SKILL}" \
  'an `owner/repo#N` reference uses the named repository'
assert_contains "issue context stays in the reviewed repository" "${GITHUB_FORGE}" \
  'repos/${REPO_FULL_NAME}/issues/<issue-number>'
assert_contains "eval guide documents commit-message fixtures" "${EVAL_README}" \
  '`commit_message`'
assert_contains "review eval schema documents commit-message fixtures" "${EVAL_CONFIG}" \
  'commit_message (default'
assert_contains "intent review keeps explicit authorization-scope check" "${CODE_REVIEW}" \
  'Does the change go beyond what the linked issue authorized?'
assert_contains "intent review keeps module-fit check" "${CODE_REVIEW}" \
  'Does the change fit the overall design of the module/system?'
assert_contains "intent review keeps proportional-complexity check" "${CODE_REVIEW}" \
  'Is the complexity proportional to the value delivered?'
assert_contains "intent review keeps simpler-alternative check" "${CODE_REVIEW}" \
  'Are there simpler alternatives that achieve the same goal?'
assert_contains "GitHub file-list cap remains a changed-files fallback" "${SKILL}" \
  "the step 2a fallback for a failed compare or ≥300 files"
assert_contains "GitHub compare requires proven completeness" "${GITHUB_FORGE}" \
  "${GITHUB_COMPARE_COMPLETE}"
assert_not_contains "GitHub compare ignores undocumented truncation heuristic" "${GITHUB_FORGE}" \
  '.truncated // false'
assert_not_contains "GitHub commit count is not a file-list cap" "${GITHUB_FORGE}" \
  '.total_commits <= 250'
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
assert_contains "Prior identity is machine-readable" "${REREVIEW}" \
  'finding identity from review Markdown.'
assert_contains "Prior paths are rejected, never rewritten" "${REREVIEW}" \
  "It rejects, never rewrites, invalid records"
assert_contains "Missing-test counterpart wording tripwire" "${REREVIEW}" \
  '`.go` suffix with `_test.go` (for example, `pkg/foo.go` → `pkg/foo_test.go`).'
assert_jq_result "GitHub accepts complete compare" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' true
assert_jq_result "GitHub accepts comparisons with more than 250 commits" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":251,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' true
assert_jq_result "GitHub rejects diverged history" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"diverged","behind_by":1,"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' false
assert_jq_result "GitHub rejects API error JSON" "${GITHUB_COMPARE_COMPLETE}" \
  '{"message":"Not Found"}' false
assert_jq_result "GitHub rejects missing commit count" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' false
assert_jq_result "GitHub rejects missing compare status" "${GITHUB_COMPARE_COMPLETE}" \
  '{"behind_by":0,"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' false
assert_jq_result "GitHub rejects missing behind count" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' false
TOO_MANY_GITHUB_FILES="$(jq -cn '{status:"ahead",behind_by:0,total_commits:251,files:[range(300)|{filename:("file" + tostring + ".txt"),patch:"@@"}]}')"
assert_jq_result "GitHub rejects 300 returned files" "${GITHUB_COMPARE_COMPLETE}" \
  "${TOO_MANY_GITHUB_FILES}" false
assert_jq_result "GitHub accepts unanchored binary path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"image.png","patch":null}]}' true
assert_jq_result "GitHub accepts content-free rename without a patch" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"new.txt","previous_filename":"old.txt","status":"renamed","additions":0,"deletions":0,"patch":null}]}' true
assert_jq_result "GitHub rejects patchless rename without previous path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"new.txt","status":"renamed","additions":0,"deletions":0,"patch":null}]}' false
assert_jq_result "GitHub rejects unpatched source path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"pkg/auth.go","patch":null}]}' false
assert_jq_result "GitHub rejects newline in current path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a.txt\nb.md","patch":"@@"}]}' false
assert_jq_result "GitHub rejects traversal in previous path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a.txt","previous_filename":"../old.txt","patch":"@@"}]}' false
assert_jq_result "GitHub rejects dot path component" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"docs/./a.txt","patch":"@@"}]}' false
assert_jq_result "GitHub rejects backslash path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"docs\\a.txt","patch":"@@"}]}' false
assert_jq_result "GitHub rejects prompt delimiter in previous path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a.txt","previous_filename":"<old>.txt","patch":"@@"}]}' false
assert_jq_result "GitHub rejects tab in current path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a\\tb.txt","patch":"@@"}]}' false
assert_jq_result "GitHub rejects bidi override in current path" "${GITHUB_COMPARE_COMPLETE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a\\u202eb.txt","patch":"@@"}]}' false
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
assert_jq_result "GitLab rejects tab in old path" "${GITLAB_COMPARE_COMPLETE}" \
  '{"diffs":[{"old_path":"a\\tb.txt","new_path":"a.txt","diff":"@@"}]}' false
assert_jq_result "GitLab rejects bidi override in old path" "${GITLAB_COMPARE_COMPLETE}" \
  '{"diffs":[{"old_path":"a\\u202eb.txt","new_path":"a.txt","diff":"@@"}]}' false
assert_compare_snippet "GitHub complete compare installs precise artifacts" "${GITHUB_FORGE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' 0 false a.txt \
  $'diff --git a/a.txt b/a.txt\n@@ -1 +1 @@'
assert_compare_snippet "GitHub keeps unpatched paths unanchored" "${GITHUB_FORGE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"},{"filename":"image.png","patch":null}]}' \
  0 false $'a.txt\nimage.png' \
  $'diff --git a/a.txt b/a.txt\n@@ -1 +1 @@'
assert_compare_snippet "GitHub falls back for unpatched source paths" "${GITHUB_FORGE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"},{"filename":"pkg/auth.go","patch":null}]}' \
  0 true all \
  "base diff fallback"
assert_compare_snippet "GitHub rename qualifies old and current paths" "${GITHUB_FORGE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"previous_filename":"pkg/auth/token.go","filename":"pkg/util/helpers.go","patch":"@@ -1 +1 @@"}]}' \
  0 false $'pkg/auth/token.go\npkg/util/helpers.go' \
  $'diff --git a/pkg/auth/token.go b/pkg/util/helpers.go\n@@ -1 +1 @@'
assert_compare_snippet "GitHub command failure preserves fail-closed state" "${GITHUB_FORGE}" \
  '{"message":"Not Found"}' 1 true all "base diff fallback"
assert_compare_snippet "GitHub unsafe path preserves fail-closed state" "${GITHUB_FORGE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a.txt\nb.md","patch":"@@"}]}' 0 true all "base diff fallback"
assert_compare_snippet "GitHub malformed payload preserves fail-closed state" "${GITHUB_FORGE}" \
  '{"message":"Not Found"}' 0 true all "base diff fallback"
assert_compare_snippet "GitHub diverged history preserves fail-closed state" "${GITHUB_FORGE}" \
  '{"status":"diverged","behind_by":1,"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' \
  0 true all "base diff fallback"
assert_compare_snippet "GitHub missing status preserves fail-closed state" "${GITHUB_FORGE}" \
  '{"behind_by":0,"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' \
  0 true all "base diff fallback"
assert_compare_snippet "GitHub artifact install failure preserves fail-closed state" "${GITHUB_FORGE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' 0 true all \
  "base diff fallback" true
assert_compare_snippet "GitHub conservative initialization failure aborts before API" "${GITHUB_FORGE}" \
  '{"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' 0 true all \
  "base diff fallback" false true 1
assert_compare_snippet "GitHub final marker failure cannot publish stale false" "${GITHUB_FORGE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"a.txt","patch":"@@ -1 +1 @@"}]}' 0 true a.txt \
  $'diff --git a/a.txt b/a.txt\n@@ -1 +1 @@' false false 0 true
for ancestry_payload in '{"id":"other"}' '{}' 'null' 'invalid JSON'; do
  assert_compare_snippet "GitLab rejects unproven ancestry: ${ancestry_payload}" "${GITLAB_FORGE}" \
    '{"diffs":[{"old_path":"a.go","new_path":"a.go","diff":"+new"}]}' 0 \
    true all 'base diff fallback' false false 0 false "${ancestry_payload}"
done
assert_compare_snippet "GitLab ancestry API failure stays conservative" "${GITLAB_FORGE}" \
  '{"diffs":[]}' 0 true all 'base diff fallback' false false 0 false '{"id":"base"}' 1

assert_compare_snippet "GitLab complete compare installs precise artifacts" "${GITLAB_FORGE}" \
  '{"compare_timeout":false,"diffs":[{"old_path":"a.txt","new_path":"a.txt","diff":"@@ -1 +1 @@"}]}' 0 false a.txt \
  $'diff --git a/a.txt b/a.txt\n@@ -1 +1 @@'
assert_compare_snippet "GitLab artifact install failure preserves fail-closed state" "${GITLAB_FORGE}" \
  '{"compare_timeout":false,"diffs":[{"old_path":"a.txt","new_path":"a.txt","diff":"@@ -1 +1 @@"}]}' \
  0 true all "base diff fallback" true
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
# Complete delta must include direct remediation and unrelated same-file/file edits.
ADVERSARIAL_DIFF=$'diff --git a/docs/foo.md b/docs/foo.md\n+Foo documentation\n+Unrelated deployment\ndiff --git a/CHANGELOG.md b/CHANGELOG.md\n+Unrelated release\ndiff --git a/internal/foo.go b/internal/foo.go\n+func Unrelated() {}'
ADVERSARIAL_PATHS=$'CHANGELOG.md\ndocs/foo.md\ninternal/foo.go'
assert_compare_snippet "GitHub preserves complete adversarial delta" "${GITHUB_FORGE}" \
  '{"status":"ahead","behind_by":0,"total_commits":1,"files":[{"filename":"docs/foo.md","patch":"+Foo documentation\n+Unrelated deployment"},{"filename":"CHANGELOG.md","patch":"+Unrelated release"},{"filename":"internal/foo.go","patch":"+func Unrelated() {}"}]}' \
  0 false "${ADVERSARIAL_PATHS}" "${ADVERSARIAL_DIFF}"
assert_compare_snippet "GitLab preserves complete adversarial delta" "${GITLAB_FORGE}" \
  '{"diffs":[{"old_path":"docs/foo.md","new_path":"docs/foo.md","diff":"+Foo documentation\n+Unrelated deployment"},{"old_path":"CHANGELOG.md","new_path":"CHANGELOG.md","diff":"+Unrelated release"},{"old_path":"internal/foo.go","new_path":"internal/foo.go","diff":"+func Unrelated() {}"}]}' \
  0 false "${ADVERSARIAL_PATHS}" "${ADVERSARIAL_DIFF}"

assert_contains "skill keeps incomplete patch bodies unanchored" "${REREVIEW}" \
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
assert_contains "intent exemption requires a direct remediation" "${INTENT}" \
  "matched candidate as authorized only when"
assert_contains "orchestrator shares direct-remediation exemption" "${SKILL}" \
  "treat it as authorized scope even when the"
assert_not_contains "intent removes do-not-only-when ambiguity" "${INTENT}" \
  "Do not report a matched remediation candidate as scope creep only when"
assert_contains "intent retains issue authorization" "${INTENT}" \
  "scope creep only when a change is authorized by"
assert_contains "intent keeps correctness ownership separate" "${INTENT}" \
  "not a second correctness pass"
assert_contains "ambiguous candidates remain unanchored" "${INTENT}" \
  "ambiguous matches stay unanchored"
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
assert_contains "isolated unmatched-file eval accepts either scope finding" "${EVAL_UNMATCHED_EXPECTATIONS}" \
  "required_any:"
assert_contains "isolated unmatched-file eval lists scope-creep" "${EVAL_UNMATCHED_EXPECTATIONS}" \
  "- scope-creep"
assert_contains "isolated unmatched-file eval lists unauthorized-change" "${EVAL_UNMATCHED_EXPECTATIONS}" \
  "- unauthorized-change"
assert_contains "isolated unmatched-file eval rubric names both categories" "${EVAL_UNMATCHED_EXPECTATIONS}" \
  "scope-creep or unauthorized-change"
assert_contains "isolated unmatched-file eval documents its isolation" "${EVAL_UNMATCHED_EXPECTATIONS}" \
  "only follow-up file is CHANGELOG.md"
assert_contains "severity-anchor eval matches projection line" "${EVAL009_EXPECTATIONS}" \
  "line 2; it has no prior description"

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi

echo "All PR review remediation tests passed"
