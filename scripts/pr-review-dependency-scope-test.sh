#!/usr/bin/env bash
# pr-review-dependency-scope-test.sh — Verify dependency-PR diff scoping.
#
# Extracts the GitHub "Dependency-PR scoping" snippet from the pr-review
# forge skill and runs it against a stubbed `gh` for stacked, cherry-picked,
# and fallback cases.
#
# Run from the repo root:
#   bash scripts/pr-review-dependency-scope-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/pr-review/SKILL.md"
REFERENCE="${REPO_ROOT}/skills/pr-review/references/dependency-scope.md"
AGENT="${REPO_ROOT}/agents/review.md"
DOCS="${REPO_ROOT}/docs/review.md"
GITHUB_FORGE="${REPO_ROOT}/skills/pr-review/github/SKILL.md"
FAILURES=0
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "${TMP_ROOT}"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

assert_contains() {
  local name="$1" file="$2" expected="$3"
  if grep -qF -- "${expected}" "${file}"; then
    pass "${name}"
  else
    fail "${name} — missing '${expected}' in ${file#"${REPO_ROOT}/"}"
  fi
}

assert_not_contains() {
  local name="$1" file="$2" text="$3"
  if grep -qF "$text" "$file"; then
    fail "$name — unexpectedly found: $text"
  else
    pass "$name"
  fi
}

extract_snippet() {
  awk '
    /^## Dependency-PR scoping$/ { found = 1; next }
    found && /^```bash$/ { code = 1; next }
    code && /^```$/ { exit }
    code { print }
  ' "${GITHUB_FORGE}"
}

# patch <file> <new-line> — a one-line change to <file>.
patch() {
  printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1 +1 @@\n-old\n+%s\n' \
    "$1" "$1" "$1" "$1" "$2"
}

# commits <sha>... — a slurped (paginated) PR commits payload; a sha
# suffixed with ":merge" gets two parents.
commits() {
  local out="" sha parents
  for sha in "$@"; do
    parents='[{"sha":"p"}]'
    if [[ "${sha}" == *:merge ]]; then
      sha="${sha%:merge}"
      parents='[{"sha":"p"},{"sha":"q"}]'
    fi
    out="${out:+${out},}{\"sha\":\"${sha}\",\"parents\":${parents}}"
  done
  printf '[[%s]]\n' "${out}"
}

new_case() {
  CASE_DIR="${TMP_ROOT}/$1"
  FIX="${CASE_DIR}/fixtures"
  mkdir -p "${CASE_DIR}/bin" "${FIX}" "${CASE_DIR}/run" "${CASE_DIR}/workspace"
  printf '%s\n' "full pr diff" > "${CASE_DIR}/workspace/pr-diff.txt"
  cat > "${CASE_DIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
prefix=""; path=""; number=""
for arg in "$@"; do
  case "$arg" in number=*) number="${arg#number=}" ;; esac
done
if test "$2" = graphql; then
  if test -f "${FIXTURES}/graphql_${number}.next" && test -f "${FIXTURES}/graphql_${number}.seen"; then
    cat "${FIXTURES}/graphql_${number}.next"; exit 0
  fi
  touch "${FIXTURES}/graphql_${number}.seen"
  cat "${FIXTURES}/graphql_${number}" 2>/dev/null || exit 1
  exit 0
fi
for arg in "$@"; do
  case "${arg}" in
    *vnd.github.diff) prefix="diff_" ;;
    repos/*) path="${arg}" ;;
  esac
done
key="${prefix}$(printf '%s' "${path#repos/example/repo/}" | tr '/?=.' '____')"
if test "$key" = pulls_10 && test -f "${FIXTURES}/${key}.next"; then
  count=$(cat "${FIXTURES}/${key}.count" 2>/dev/null || echo 0)
  count=$((count + 1)); echo "$count" > "${FIXTURES}/${key}.count"
  if test "$count" -ge 3; then cat "${FIXTURES}/${key}.next"; exit 0; fi
fi
test -f "${FIXTURES}/${key}" || exit 1
cat "${FIXTURES}/${key}"
EOF
  chmod +x "${CASE_DIR}/bin/gh"
  # Defaults: PR 10, open dependency PR 5.
  printf '%s\n' '{"state":"open"}' > "${FIX}/pulls_5"
  # The snippet derives the live head SHA itself (shell variables do not
  # survive between calls), so HEAD_SHA is deliberately not injected into the
  # run; the pinned step 1 SHA arrives as PINNED_SHA (PINNED overrides it).
  printf '%s\n' '{"head":{"sha":"head"},"base":{"ref":"main","sha":"base"}}' > "${FIX}/pulls_10"
  printf '%s\n' 'diff --git a/own.txt b/own.txt
@@ -1 +1 @@
-old
+mine' > "${FIX}/diff_compare_a1___head"
  PINNED="head"
}

compare_ok() {
  printf '%s\n' '{"status":"ahead","behind_by":0,"files":[{"filename":"own.txt","patch":"@@ -1 +1 @@\n-old\n+mine"}]}' \
    > "${FIX}/compare_$1___head"
  printf '%s\n' 'diff --git a/own.txt b/own.txt
@@ -1 +1 @@
-old
+mine' > "${FIX}/diff_compare_$1___head"
}

run_case() {
  local snippet dep_head run_pin own_head key net_count
  own_head=$(jq -r 'add | last.sha // "head"' "${FIX}/pulls_10_commits_per_page_100" 2>/dev/null || echo head)
  run_pin="$PINNED"
  if test "$run_pin" = head; then run_pin="$own_head"; fi
  if test -f "${FIX}/pulls_10"; then
    jq --arg sha "$own_head" 'if .head.sha == "head" then .head.sha = $sha else . end' "${FIX}/pulls_10" > "${FIX}/own-meta"
    mv "${FIX}/own-meta" "${FIX}/pulls_10"
  fi
  # Fixture compare endpoints use a readable head placeholder.
  for key in "${FIX}"/*___head; do
    if test -f "$key" && test "$key" != "${key%head}${own_head}"; then cp "$key" "${key%head}${own_head}"; fi
  done
  # Default approved current-head dependency; individual cases override it.
  if ! test -f "${FIX}/graphql_5"; then
    dep_head=$(jq -r 'add | last.sha // "a1"' "${FIX}/pulls_5_commits_per_page_100" 2>/dev/null || echo a1)
    jq -n --arg head "$dep_head" --arg state "$(jq -r '.state | ascii_upcase' "${FIX}/pulls_5")" \
      '{data:{repository:{pullRequest:{state:$state,isDraft:false,baseRefName:"main",baseRefOid:"base",headRefOid:$head,
        author:{login:"author"},reviewDecision:"APPROVED",latestReviews:{pageInfo:{hasNextPage:false},nodes:[
          {state:"APPROVED",authorCanPushToRepository:true,author:{login:"maintainer"},commit:{oid:$head}}]}}}}}' \
      > "${FIX}/graphql_5"
  fi
  # Raw net compares for cherry-pick fixtures; these remain distinct API
  # responses so negative cases can supply a different aggregate patch.
  local own_prefix sha dep_net own_net
  dep_head=$(jq -r '.data.repository.pullRequest.headRefOid' "${FIX}/graphql_5")
  own_prefix=$(jq -r 'add | .[-2].sha // "none"' "${FIX}/pulls_10_commits_per_page_100" 2>/dev/null || echo none)
  dep_net="${FIX}/diff_compare_base___${dep_head}"
  own_net="${FIX}/diff_compare_base___${own_prefix}"
  net_count=$(jq 'add | length' "${FIX}/pulls_5_commits_per_page_100" 2>/dev/null || echo 0)
  for key in "$dep_head" "$own_prefix"; do
    if ! test -f "${FIX}/compare_base___${key}"; then
      jq -n --argjson count "$net_count" '{status:"ahead",behind_by:0,total_commits:$count,files:[{filename:"dep.txt",patch:"@@ -1 +1 @@\n-old\n+new"}]}' \
        > "${FIX}/compare_base___${key}"
    fi
  done
  if ! test -f "$dep_net"; then
    : > "$dep_net"
    while read -r sha; do
      if test -f "${FIX}/diff_commits_${sha}"; then cat "${FIX}/diff_commits_${sha}" >> "$dep_net"; fi
    done < <(jq -r 'add | .[].sha' "${FIX}/pulls_5_commits_per_page_100" 2>/dev/null || true)
  fi
  if ! test -f "$own_net"; then
    : > "$own_net"
    while read -r sha; do
      if test -f "${FIX}/diff_commits_${sha}"; then cat "${FIX}/diff_commits_${sha}" >> "$own_net"; fi
    done < <(jq -r 'add | .[:-1][].sha' "${FIX}/pulls_10_commits_per_page_100" 2>/dev/null || true)
  fi
  snippet=$(extract_snippet | sed "s#/sandbox/workspace#${CASE_DIR}/workspace#g")
  CASE_RC=0
  (cd "${CASE_DIR}/run" && env PATH="${CASE_DIR}/bin:${PATH}" FIXTURES="${FIX}" \
    REPO_FULL_NAME=example/repo PR_NUMBER=10 DEP_PRS="${DEP_PRS:-5}" PINNED_SHA="${run_pin}" \
    bash -u -c "${snippet}") > "${CASE_DIR}/out" 2> "${CASE_DIR}/err" || CASE_RC=$?
}

assert_scoped() {
  local name="$1" expected_classified="$2"
  local ws="${CASE_DIR}/workspace"
  if grep -q '^SCOPED: 1 own commit' "${CASE_DIR}/out" \
    && test "$(cat "${ws}/pr-full-diff.txt")" = "full pr diff" \
    && grep -qF '+mine' "${ws}/pr-diff.txt" \
    && grep -qxF 'diff --git a/own.txt b/own.txt' "${ws}/pr-diff.txt" \
    && test "$(cat "${ws}/dep-scope/files")" = "own.txt" \
    && test "$(cat "${ws}/dep-scope/classified")" = "${expected_classified}"; then
    pass "${name}"
  else
    fail "${name} — out: $(cat "${CASE_DIR}/out") err: $(cat "${CASE_DIR}/err")"
  fi
}

assert_skipped() {
  local name="$1" reason="$2"
  local ws="${CASE_DIR}/workspace"
  if grep -qF "SKIP: ${reason}" "${CASE_DIR}/out" \
    && test "$(cat "${ws}/pr-diff.txt")" = "full pr diff" \
    && ! test -e "${ws}/pr-full-diff.txt"; then
    pass "${name}"
  else
    fail "${name} — out: $(cat "${CASE_DIR}/out") err: $(cat "${CASE_DIR}/err")"
  fi
}

assert_scoped_incremental_diff() {
  local name="$1" expected_classified="$2" first_path="$3" second_path="$4"
  local ws="${CASE_DIR}/workspace"
  if grep -q '^SCOPED: 2 own commit(s)' "${CASE_DIR}/out" \
    && test "$(cat "${ws}/dep-scope/classified")" = "${expected_classified}" \
    && grep -qF "diff --git a/${first_path} b/${first_path}" "${ws}/pr-diff.txt" \
    && grep -qF "diff --git a/${second_path} b/${second_path}" "${ws}/pr-diff.txt" \
    && grep -qF '+remediation' "${ws}/pr-diff.txt" \
    && grep -qF '+unrelated-after' "${ws}/pr-diff.txt" \
    && test "$(cat "${ws}/dep-scope/files")" = "$(printf '%s\n%s' "${first_path}" "${second_path}")"; then
    pass "${name}"
  else
    fail "${name} — out: $(cat "${CASE_DIR}/out") err: $(cat "${CASE_DIR}/err")"
  fi
}

assert_scoped_with_classification() {
  local name="$1" summary="$2" expected_classified="$3"
  local ws="${CASE_DIR}/workspace"
  if grep -qF "SCOPED: ${summary}" "${CASE_DIR}/out" \
    && test "$(cat "${ws}/pr-full-diff.txt")" = "full pr diff" \
    && grep -qF '+mine' "${ws}/pr-diff.txt" \
    && test "$(cat "${ws}/dep-scope/files")" = "own.txt" \
    && test "$(cat "${ws}/dep-scope/classified")" = "${expected_classified}"; then
    pass "${name}"
  else
    fail "${name} — out: $(cat "${CASE_DIR}/out") err: $(cat "${CASE_DIR}/err")"
  fi
}

# --- Wiring -----------------------------------------------------------------

assert_contains "orchestrator links dependency-scope reference" "${SKILL}" \
  "(references/dependency-scope.md)"
assert_contains "reference names the forge command" "${REFERENCE}" \
  '"Dependency-PR scoping" command'
assert_contains "reference reads every page of author comments" "${REFERENCE}" \
  '`--paginate --slurp`'
assert_contains "reference keeps protected paths on the whole PR" "${REFERENCE}" \
  "Protected paths and the PR body injection defense"
assert_not_contains "reference does not make an open dependency an approval veto" "${REFERENCE}" \
  'Do not `approve` while a dependency PR is open.'
assert_contains "reference keeps dependency scoping separate from merge policy" "${REFERENCE}" \
  'does not impose merge ordering or change the approval criteria'
assert_contains "review agent keeps dependency scoping out of approval criteria" "${AGENT}" \
  'merge ordering or alter these approval criteria.'
assert_contains "user docs distinguish scoped review from merge ordering" "${DOCS}" \
  'does not impose merge ordering or prevent an approval'
assert_contains "reference never drops security findings" "${REFERENCE}" \
  'never drop a security finding (any finding from the'
assert_contains "reference keeps prior security findings at original severity" "${REFERENCE}" \
  'A prior security id keeps its original severity and'
assert_contains "reference keeps security inspection on the whole PR" "${REFERENCE}" \
  'Still run security inspection over the whole PR'
assert_contains "security dispatch uses the full PR inputs" "${REFERENCE}" \
  'Select security dispatch from the full PR diff and full changed-file list'
assert_contains "orchestrator gives security the full scoped-PR context" "${SKILL}" \
  'security uses `/sandbox/workspace/pr-full-diff.txt` and the full changed-file list'
assert_contains "reference does not treat an open dependency as security clearance" "${REFERENCE}" \
  'not that its defects were fixed or dismissed'
for category in instruction-smuggling unicode-steganography bidi-override homoglyph-attack; do
  assert_contains "reference covers ${category} findings" "${REFERENCE}" "\`${category}\`"
done
assert_contains "reference fetches manifest-less scoped paths at the pinned head" "${REFERENCE}" \
  'fetch it at `HEAD_SHA` as step'
assert_contains "reference reconciles prior finding ids" "${REFERENCE}" \
  'answer it with a `reclassified` disposition'
assert_not_contains "GitHub scope command avoids scanner-rejected here-strings" "${GITHUB_FORGE}" \
  'read -r -a DEP_PR_LIST <<<'
assert_not_contains "GitHub scope command avoids scanner-rejected compound regex checks" "${GITHUB_FORGE}" \
  '[[ $PID =~ ^[0-9a-f]{40,64}$ && $EXACT =~ ^[0-9a-f]{64}$ ]]'
if test -n "$(extract_snippet)"; then
  pass "GitHub forge has a dependency-scoping snippet"
else
  fail "GitHub forge has a dependency-scoping snippet"
fi

# --- Cherry-picked commits: new SHAs, same patches ----------------------------

new_case cherry-pick
commits c1 c2 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 a2 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch dep2.txt two > "${FIX}/diff_commits_a2"
patch dep1.txt one > "${FIX}/diff_commits_c1"
patch dep2.txt two > "${FIX}/diff_commits_c2"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok c2
run_case
assert_scoped "cherry-picked dependency commits are excluded" \
  "$(printf 'dep c1\ndep c2\nown c3')"

# --- Stacked branch: shared SHAs ----------------------------------------------

new_case stacked
commits a1 a2 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 a2 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch dep2.txt two > "${FIX}/diff_commits_a2"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok a2
run_case
assert_scoped "stacked dependency commits are excluded" \
  "$(printf 'dep a1\ndep a2\nown c3')"

# A matching SHA is sufficient for an empty dependency commit.
new_case empty-exact-dependency-commit
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
: > "${FIX}/diff_commits_a1"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok a1
run_case
assert_scoped "an empty exact-SHA dependency commit still scopes" \
  "$(printf 'dep a1\nown c3')"

# A successfully fetched empty diff without an exact-SHA match is not a
# patch candidate and must not disable scoping for other matching commits.
new_case empty-unmatched-dependency-commit
commits a1 e0 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 e0 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
: > "${FIX}/diff_commits_e0"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok e0
run_case
assert_scoped "an empty dependency tail matched by SHA does not disable scoping" \
  "$(printf 'dep a1\ndep e0\nown c3')"

# A successful empty own diff has no patch ID, but the commit remains own.
new_case empty-own-commit
commits a1 c2 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
: > "${FIX}/diff_commits_c2"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok a1
run_case
assert_scoped_with_classification "an empty own commit stays in scoped history" \
  "2 own commit(s)" "$(printf 'dep a1\nown c2\nown c3')"

# Exact-SHA dependency matches do not require a diff retrieval.
new_case exact-sha-without-diff
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok a1
run_case
assert_scoped "an exact-SHA dependency match needs no patch-ID fetch" \
  "$(printf 'dep a1\nown c3')"

# A scoped re-review must retain both a direct remediation in a dependency
# file, an unrelated edit in that file, and an unrelated own-file edit, so
# the responsible reviewers see the complete incremental diff.
new_case adversarial-rereview
commits a1 c2 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch existing.txt dependency > "${FIX}/diff_commits_a1"
printf '%s\n' 'diff --git a/existing.txt b/existing.txt
--- a/existing.txt
+++ b/existing.txt
@@ -1,3 +1,3 @@
-old
+remediation
 unchanged
-unrelated-before
+unrelated-after' > "${FIX}/diff_commits_c2"
patch unrelated.txt incidental > "${FIX}/diff_commits_c3"
printf '%s\n' '{"status":"ahead","behind_by":0,"files":[{"filename":"existing.txt","patch":"@@ -1,3 +1,3 @@\n-old\n+remediation\n unchanged\n-unrelated-before\n+unrelated-after"},{"filename":"unrelated.txt","patch":"@@ -1 +1 @@\n-old\n+incidental"}]}' \
  > "${FIX}/compare_a1___head"
printf '%s\n' 'diff --git a/existing.txt b/existing.txt
@@ -1,3 +1,3 @@
-old
+remediation
 unchanged
-unrelated-before
+unrelated-after
diff --git a/unrelated.txt b/unrelated.txt
@@ -1 +1 @@
-old
+incidental' > "${FIX}/diff_compare_a1___head"
run_case
assert_scoped_incremental_diff "scoped re-review retains remediation and unrelated edits" \
  "$(printf 'dep a1\nown c2\nown c3')" existing.txt unrelated.txt

# The scoped diff must preserve metadata as well as patch hunks. Otherwise a
# content change that also flips the executable bit hides the mode change.
new_case content-and-mode
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch script.sh mine > "${FIX}/diff_commits_c3"
printf '%s\n' '{"status":"ahead","behind_by":0,"files":[{"filename":"script.sh","patch":"@@ -1 +1 @@\n-old\n+mine"}]}' \
  > "${FIX}/compare_a1___head"
printf '%s\n' 'diff --git a/script.sh b/script.sh
old mode 100644
new mode 100755
index 3367afd..3e75765
--- a/script.sh
+++ b/script.sh
@@ -1 +1 @@
-old
+mine' > "${FIX}/diff_compare_a1___head"
run_case
if grep -q '^old mode 100644$' "${CASE_DIR}/workspace/pr-diff.txt" \
  && grep -q '^new mode 100755$' "${CASE_DIR}/workspace/pr-diff.txt"; then
  pass "scoped diffs retain content-and-mode changes"
else
  fail "scoped diffs retain content-and-mode changes — diff: $(cat "${CASE_DIR}/workspace/pr-diff.txt")"
fi

# --- Fallbacks: pr-diff.txt stays the full diff -------------------------------

new_case merged-dependency
printf '%s\n' '{"state":"closed"}' > "${FIX}/pulls_5"
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
run_case
assert_skipped "a dependency PR that is not open is ignored" "no open dependency PR"

new_case malformed-dependency-number
DEP_PRS='5 *'
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok a1
run_case
assert_skipped "a malformed dependency candidate falls back" "malformed dependency PR number"
unset DEP_PRS

new_case globbed-dependency-number
DEP_PRS='*'
touch "${CASE_DIR}/run/5"
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok a1
run_case
assert_skipped "dependency candidates are not pathname-expanded" "malformed dependency PR number"
unset DEP_PRS

new_case interleaved
commits c3 c1 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch dep1.txt one > "${FIX}/diff_commits_c1"
patch own.txt mine > "${FIX}/diff_commits_c3"
run_case
assert_skipped "own commits before dependency commits fall back" \
  "commits are not dependency commits followed by own commits"

new_case merge-commit
commits a1 m1:merge c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
run_case
assert_skipped "a PR with merge commits falls back" "PR has merge commits"

new_case conflict-resolved
commits c1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch dep1.txt resolved-differently > "${FIX}/diff_commits_c1"
patch own.txt mine > "${FIX}/diff_commits_c3"
run_case
assert_skipped "a cherry-pick with a different patch stays in scope" \
  "commits are not dependency commits followed by own commits (own )"

new_case whitespace-only-difference
commits c1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch auth.py "    check()" > "${FIX}/diff_commits_a1"
patch auth.py "check()" > "${FIX}/diff_commits_c1"
patch own.txt mine > "${FIX}/diff_commits_c3"
run_case
assert_skipped "a cherry-pick differing only in indentation stays in scope" \
  "commits are not dependency commits followed by own commits (own )"

new_case final-newline-difference
commits c1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch dep1.txt one > "${FIX}/diff_commits_c1"
printf '\\ No newline at end of file\n' >> "${FIX}/diff_commits_c1"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok c1
run_case
assert_skipped "a cherry-pick differing only in final newline stays in scope" \
  "commits are not dependency commits followed by own commits (own )"

new_case own-diff-unavailable
commits c1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch own.txt mine > "${FIX}/diff_commits_c3"
run_case
assert_skipped "a commit diff that cannot be fetched falls back" \
  "cannot compare patches of own commits"

new_case dependency-diff-unavailable
commits c1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_c1"
patch own.txt mine > "${FIX}/diff_commits_c3"
run_case
assert_skipped "a dependency diff that cannot be fetched falls back" \
  "cannot compare patches of dependency commits"

new_case binary-compare
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch own.txt mine > "${FIX}/diff_commits_c3"
printf '%s\n' '{"status":"ahead","behind_by":0,"files":[{"filename":"logo.png"}]}' \
  > "${FIX}/compare_a1___head"
run_case
assert_skipped "an incomplete compare falls back" "compare incomplete"

new_case head-sha-unavailable
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch own.txt mine > "${FIX}/diff_commits_c3"
rm "${FIX}/pulls_10"
compare_ok a1
run_case
assert_skipped "an unresolvable head SHA falls back" "cannot determine PR head SHA"

new_case head-moved
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok a1
PINNED=older-head
run_case
assert_skipped "a PR head that moved since step 1 falls back" "PR head moved since step 1"

new_case head-not-pinned
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok a1
PINNED=""
run_case
assert_skipped "a missing pinned SHA falls back" "PR head moved since step 1"

new_case newline-filename
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch own.txt mine > "${FIX}/diff_commits_c3"
printf '%s\n' '{"status":"ahead","behind_by":0,"files":[{"filename":"own.txt\n+forged","patch":"@@ -1 +1 @@\n-old\n+mine"}]}' \
  > "${FIX}/compare_a1___head"
run_case
assert_skipped "a newline in a compare filename falls back" "compare incomplete"

new_case unsafe-previous-filename
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch own.txt mine > "${FIX}/diff_commits_c3"
printf '%s\n' '{"status":"ahead","behind_by":0,"files":[{"filename":"own.txt","previous_filename":"../etc\nx","patch":"@@ -1 +1 @@\n-old\n+mine"}]}' \
  > "${FIX}/compare_a1___head"
run_case
assert_skipped "a newline in a previous filename falls back" "compare incomplete"

new_case hash-step-fails
commits c1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch dep1.txt one > "${FIX}/diff_commits_c1"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok c1
printf '#!/usr/bin/env bash\nexit 1\n' > "${CASE_DIR}/bin/sha256sum"
chmod +x "${CASE_DIR}/bin/sha256sum"
run_case
assert_skipped "a failed hash step falls back instead of matching" \
  "cannot compare patches of dependency commits"

# --- Review provenance, complete history, and retry safety --------------------

setup_stack() {
  new_case "$1"
  commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
  commits a1 > "${FIX}/pulls_5_commits_per_page_100"
  patch dep1.txt one > "${FIX}/diff_commits_a1"
  patch own.txt mine > "${FIX}/diff_commits_c3"
  compare_ok a1
  # Populate defaults before modifying review metadata, without running code.
  jq -n '{data:{repository:{pullRequest:{state:"OPEN",isDraft:false,baseRefName:"main",baseRefOid:"base",headRefOid:"a1",
    author:{login:"author"},reviewDecision:"APPROVED",latestReviews:{pageInfo:{hasNextPage:false},nodes:[
      {state:"APPROVED",authorCanPushToRepository:true,author:{login:"maintainer"},commit:{oid:"a1"}}]}}}}}' \
    > "${FIX}/graphql_5"
}

for variant in unapproved stale dismissed requested draft base self readonly incomplete; do
  setup_stack "review-${variant}"
  case "$variant" in
    unapproved) filter='.data.repository.pullRequest.reviewDecision = "REVIEW_REQUIRED"' ;;
    stale) filter='.data.repository.pullRequest.latestReviews.nodes[0].commit.oid = "old"' ;;
    dismissed) filter='.data.repository.pullRequest.latestReviews.nodes[0].state = "DISMISSED"' ;;
    requested) filter='.data.repository.pullRequest.reviewDecision = "CHANGES_REQUESTED"' ;;
    draft) filter='.data.repository.pullRequest.isDraft = true' ;;
    base) filter='.data.repository.pullRequest.baseRefName = "other"' ;;
    self) filter='.data.repository.pullRequest.latestReviews.nodes[0].author.login = "author"' ;;
    readonly) filter='.data.repository.pullRequest.latestReviews.nodes[0].authorCanPushToRepository = false' ;;
    incomplete) filter='.data.repository.pullRequest.latestReviews.pageInfo.hasNextPage = true' ;;
  esac
  jq "$filter" "${FIX}/graphql_5" > "${FIX}/modified"
  mv "${FIX}/modified" "${FIX}/graphql_5"
  run_case
  assert_skipped "${variant} dependency cannot suppress ordinary review" "dependency #5 is not verified at its current head"
done

for variant in later-revert partial-prefix; do
  setup_stack "$variant"
  commits a1 a2 > "${FIX}/pulls_5_commits_per_page_100"
  if test "$variant" = later-revert; then
    printf '%s\n' 'diff --git a/dep1.txt b/dep1.txt
--- a/dep1.txt
+++ b/dep1.txt
@@ -1 +1 @@
-one
+old' > "${FIX}/diff_commits_a2"
  else
    patch dep1.txt changed-again > "${FIX}/diff_commits_a2"
  fi
  jq '.data.repository.pullRequest.headRefOid = "a2" | .data.repository.pullRequest.latestReviews.nodes[0].commit.oid = "a2"' \
    "${FIX}/graphql_5" > "${FIX}/modified"
  mv "${FIX}/modified" "${FIX}/graphql_5"
  run_case
  assert_skipped "${variant} cannot exclude a historical dependency prefix" "excluded prefix is not a complete dependency"
done

new_case reordered-cherry-picks
commits c2 c1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 a2 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch dep2.txt two > "${FIX}/diff_commits_a2"
patch dep1.txt one > "${FIX}/diff_commits_c1"
patch dep2.txt two > "${FIX}/diff_commits_c2"
patch own.txt mine > "${FIX}/diff_commits_c3"
compare_ok c1
run_case
assert_skipped "reordered dependency cherry-picks fall back" "excluded prefix is not a complete dependency"

new_case different-net-change
commits c1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch dep1.txt one > "${FIX}/diff_commits_c1"
patch own.txt mine > "${FIX}/diff_commits_c3"
# Same per-commit fingerprints, but aggregate targets a different block.
patch dep1.txt one | sed 's/@@ -1 +1 @@/@@ -20 +20 @@/' > "${FIX}/diff_compare_base___c1"
compare_ok c1
run_case
assert_skipped "matching commit IDs cannot override different net changes" "excluded prefix is not a complete dependency"

setup_stack commit-list-moved
commits a1 other > "${FIX}/pulls_10_commits_per_page_100"
printf '%s\n' '{"head":{"sha":"c3"},"base":{"ref":"main","sha":"base"}}' > "${FIX}/pulls_10"
PINNED=c3
run_case
assert_skipped "a commit list from another head falls back" "PR commit list does not end at pinned head"

setup_stack retarget-during-scope
printf '%s\n' '{"head":{"sha":"c3"},"base":{"ref":"other","sha":"base"}}' > "${FIX}/pulls_10.next"
run_case
assert_skipped "retargeting during scope falls back" "PR head or base moved during scoping"

setup_stack approval-withdrawn
jq '.data.repository.pullRequest.reviewDecision = "REVIEW_REQUIRED"' "${FIX}/graphql_5" > "${FIX}/graphql_5.next"
run_case
assert_skipped "withdrawn upstream approval falls back" "dependency review or head moved during scoping"

new_case incomplete-net-compare
commits c1 c3 > "${FIX}/pulls_10_commits_per_page_100"
commits a1 > "${FIX}/pulls_5_commits_per_page_100"
patch dep1.txt one > "${FIX}/diff_commits_a1"
patch dep1.txt one > "${FIX}/diff_commits_c1"
patch own.txt mine > "${FIX}/diff_commits_c3"
jq -n '{status:"ahead",behind_by:0,total_commits:1,files:[range(300)|{filename:"dep.txt",patch:"+new"}]}' > "${FIX}/compare_base___a1"
compare_ok c1
run_case
assert_skipped "an incomplete net compare cannot prove equivalence" "excluded prefix is not a complete dependency"

for operation in sed paste; do
  new_case "failed-${operation}-net-compare"
  commits c1 c3 > "${FIX}/pulls_10_commits_per_page_100"
  commits a1 > "${FIX}/pulls_5_commits_per_page_100"
  patch dep1.txt one > "${FIX}/diff_commits_a1"
  patch dep1.txt one > "${FIX}/diff_commits_c1"
  patch own.txt mine > "${FIX}/diff_commits_c3"
  patch dep1.txt one | sed 's/@@ -1 +1 @@/@@ -20 +20 @@/' > "${FIX}/diff_compare_base___c1"
  compare_ok c1
  printf '#!/usr/bin/env bash\nexit 1\n' > "${CASE_DIR}/bin/${operation}"
  chmod +x "${CASE_DIR}/bin/${operation}"
  run_case
  if ! grep -q '^SCOPED:' "${CASE_DIR}/out" \
    && test "$(cat "${CASE_DIR}/workspace/pr-diff.txt")" = "full pr diff"; then
    pass "failed ${operation} cannot prove net-change equivalence"
  else
    fail "failed ${operation} cannot prove net-change equivalence"
  fi
done

for operation in cp mv; do
  setup_stack "failed-publish-${operation}"
  # Fail only at publication, after the full backup has been preserved.
  cat > "${CASE_DIR}/bin/${operation}" <<EOF
#!/usr/bin/env bash
case "\$*" in *publish.diff*) exit 1 ;; esac
exec /bin/${operation} "\$@"
EOF
  chmod +x "${CASE_DIR}/bin/${operation}"
  run_case
  if ! grep -q '^SCOPED:' "${CASE_DIR}/out" \
    && test "$(cat "${CASE_DIR}/workspace/pr-diff.txt")" = "full pr diff" \
    && test "$(cat "${CASE_DIR}/workspace/pr-full-diff.txt")" = "full pr diff"; then
    pass "failed publication ${operation} preserves both full diffs"
  else
    fail "failed publication ${operation} preserves both full diffs"
  fi
done

setup_stack retry-provenance
run_case
rm "${CASE_DIR}/workspace/dep-scope/full-head"
run_case
if test "$CASE_RC" -ne 0 && ! grep -q '^SCOPED:' "${CASE_DIR}/out" \
  && test "$(cat "${CASE_DIR}/workspace/pr-full-diff.txt")" = "full pr diff"; then
  pass "missing retry provenance aborts before dispatch"
else
  fail "missing retry provenance aborts before dispatch"
fi

setup_stack retry
run_case
assert_scoped "first scope preserves full security diff" "$(printf 'dep a1\nown c3')"
run_case
assert_scoped "retry preserves full security diff" "$(printf 'dep a1\nown c3')"
# On a retry whose verification fails, the ordinary diff must be full again.
jq '.data.repository.pullRequest.reviewDecision = "REVIEW_REQUIRED"' "${FIX}/graphql_5" > "${FIX}/modified"
mv "${FIX}/modified" "${FIX}/graphql_5"
run_case
if grep -q '^SKIP:' "${CASE_DIR}/out" \
  && test "$(cat "${CASE_DIR}/workspace/pr-full-diff.txt")" = "full pr diff" \
  && test "$(cat "${CASE_DIR}/workspace/pr-diff.txt")" = "full pr diff"; then
  pass "a failed retry restores full ordinary and security review"
else
  fail "a failed retry restores full ordinary and security review"
fi

for operation in cp mv; do
  setup_stack "failed-${operation}"
  printf '#!/usr/bin/env bash\nexit 1\n' > "${CASE_DIR}/bin/${operation}"
  chmod +x "${CASE_DIR}/bin/${operation}"
  run_case
  if ! grep -q '^SCOPED:' "${CASE_DIR}/out" \
    && test "$(cat "${CASE_DIR}/workspace/pr-diff.txt")" = "full pr diff"; then
    pass "failed ${operation} cannot report scoped success"
  else
    fail "failed ${operation} cannot report scoped success"
  fi
done

# --- Commit-count handling in the base fetch snippets -------------------------

assert_contains "PR data fetching records the total commit count" "${GITHUB_FORGE}" \
  'PR_COMMIT_COUNT=$(echo "$PR_DATA" | jq -r '"'"'.commits'"'"')'
assert_contains "PR data fetching writes the commit count file" "${GITHUB_FORGE}" \
  '"$PR_COMMIT_COUNT" > "$PR_COMMIT_COUNT_FILE"'
assert_contains "issue context keeps the same-repository guard" "${GITHUB_FORGE}" \
  'same-repository issue URLs; never fetch contributor-named repos.'

# A complete small PR (count recorded by "PR data fetching") must not be
# marked commit_messages_incomplete.
extract_commit_messages_snippet() {
  awk '
    /^## Commit messages$/ { found = 1; next }
    found && /^```bash$/ { code = 1; next }
    code && /^```$/ { exit }
    code { print }
  ' "${GITHUB_FORGE}"
}

new_case commit-count-complete
commits c1 > "${FIX}/pulls_10_commits_per_page_100"
printf '%s\n' 1 > "${CASE_DIR}/workspace/pr-commit-count"
snippet=$(extract_commit_messages_snippet | sed "s#/sandbox/workspace#${CASE_DIR}/workspace#g")
env PATH="${CASE_DIR}/bin:${PATH}" FIXTURES="${FIX}" REPO_FULL_NAME=example/repo PR_NUMBER=10 \
  bash -u -c "${snippet}" > "${CASE_DIR}/out" 2> "${CASE_DIR}/err" || true
if test "$(cat "${CASE_DIR}/workspace/pr-commit-messages-incomplete")" = false; then
  pass "a complete small PR is not marked commit_messages_incomplete"
else
  fail "a complete small PR is not marked commit_messages_incomplete — err: $(cat "${CASE_DIR}/err")"
fi

echo
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "All dependency-scope tests passed."
