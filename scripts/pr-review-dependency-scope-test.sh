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
  mkdir -p "${CASE_DIR}/bin" "${FIX}" "${CASE_DIR}/workspace"
  printf '%s\n' "full pr diff" > "${CASE_DIR}/workspace/pr-diff.txt"
  cat > "${CASE_DIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
prefix=""; path=""
for arg in "$@"; do
  case "${arg}" in
    *vnd.github.diff) prefix="diff_" ;;
    repos/*) path="${arg}" ;;
  esac
done
key="${prefix}$(printf '%s' "${path#repos/example/repo/}" | tr '/?=.' '____')"
test -f "${FIXTURES}/${key}" || exit 1
cat "${FIXTURES}/${key}"
EOF
  chmod +x "${CASE_DIR}/bin/gh"
  # Defaults: PR 10, open dependency PR 5.
  printf '%s\n' '{"state":"open"}' > "${FIX}/pulls_5"
  # The snippet derives the live head SHA itself (shell variables do not
  # survive between calls), so HEAD_SHA is deliberately not injected into the
  # run; the pinned step 1 SHA arrives as PINNED_SHA (PINNED overrides it).
  printf '%s\n' '{"head":{"sha":"head"}}' > "${FIX}/pulls_10"
  PINNED="head"
}

compare_ok() {
  printf '%s\n' '{"status":"ahead","behind_by":0,"files":[{"filename":"own.txt","patch":"@@ -1 +1 @@\n-old\n+mine"}]}' \
    > "${FIX}/compare_$1___head"
}

run_case() {
  local snippet
  snippet=$(extract_snippet | sed "s#/sandbox/workspace#${CASE_DIR}/workspace#g")
  env PATH="${CASE_DIR}/bin:${PATH}" FIXTURES="${FIX}" \
    REPO_FULL_NAME=example/repo PR_NUMBER=10 DEP_PRS=5 PINNED_SHA="${PINNED}" \
    bash -u -c "${snippet}" > "${CASE_DIR}/out" 2> "${CASE_DIR}/err" || true
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

# --- Wiring -----------------------------------------------------------------

assert_contains "orchestrator links dependency-scope reference" "${SKILL}" \
  "(references/dependency-scope.md)"
assert_contains "reference names the forge command" "${REFERENCE}" \
  '"Dependency-PR scoping" command'
assert_contains "reference reads every page of author comments" "${REFERENCE}" \
  '`--paginate --slurp`'
assert_contains "reference keeps protected paths on the whole PR" "${REFERENCE}" \
  "Protected paths and the PR body injection defense"
assert_contains "reference blocks approve while dependency is open" "${REFERENCE}" \
  'Do not `approve` while a dependency PR is open.'
assert_contains "reference never drops injection findings" "${REFERENCE}" \
  'never drop an injection finding (`prompt-injection`,'
for category in instruction-smuggling unicode-steganography bidi-override homoglyph-attack; do
  assert_contains "reference covers ${category} findings" "${REFERENCE}" "\`${category}\`"
done
assert_contains "reference fetches manifest-less scoped paths at the pinned head" "${REFERENCE}" \
  'fetch it at `HEAD_SHA` as step'
assert_contains "reference reconciles prior finding ids" "${REFERENCE}" \
  'Answer it with a `reclassified` disposition'
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

# --- Fallbacks: pr-diff.txt stays the full diff -------------------------------

new_case merged-dependency
printf '%s\n' '{"state":"closed"}' > "${FIX}/pulls_5"
commits a1 c3 > "${FIX}/pulls_10_commits_per_page_100"
run_case
assert_skipped "a dependency PR that is not open is ignored" "no open dependency PR"

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

echo
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "All dependency-scope tests passed."
