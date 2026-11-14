#!/usr/bin/env bash
# check-dco-signoff-test.sh — Tests for check-dco-signoff.sh
#
# Run from the repo root: bash .github/scripts/check-dco-signoff-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="${SCRIPT_DIR}/check-dco-signoff.sh"

FAILURES=0
TESTS=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

run_in_repo() {
  local repo_dir="$1"
  shift
  (cd "${repo_dir}" && "$@")
}

assert_pass() {
  local test_name="$1"
  shift
  TESTS=$((TESTS + 1))
  if "$@" >/dev/null 2>&1; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — expected exit 0"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_fail() {
  local test_name="$1"
  local expected_err="${2:-}"
  shift 2
  TESTS=$((TESTS + 1))
  local output rc=0
  output="$("$@" 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    echo "FAIL: ${test_name} — expected non-zero exit code"
    FAILURES=$((FAILURES + 1))
  elif [[ -n "${expected_err}" ]] && ! echo "${output}" | grep -Fiq "${expected_err}"; then
    echo "FAIL: ${test_name} — missing expected error string: '${expected_err}'"
    echo "Actual output:"
    echo "${output}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${test_name}"
  fi
}

# --- Setup test fixture repo ---
FIXTURE_REPO="${TMPDIR}/repo"
mkdir -p "${FIXTURE_REPO}"
git -C "${FIXTURE_REPO}" init -q
git -C "${FIXTURE_REPO}" config user.name "Test Author"
git -C "${FIXTURE_REPO}" config user.email "author@example.com"

# 1. Valid commit message with matching author signoff
MSG_VALID="${TMPDIR}/msg_valid.txt"
cat > "${MSG_VALID}" <<EOF
feat(test): add new feature

Detailed explanation of the change.

Signed-off-by: Test Author <author@example.com>
EOF

assert_pass "valid sign-off matching author" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_VALID}"

# 2. Valid commit message with git comments and CRLF
MSG_COMMENTS="${TMPDIR}/msg_comments.txt"
printf "feat(test): add new feature\r\n\r\n# Please enter the commit message\r\nSigned-off-by: Test Author <author@example.com>\r\n# Comments ignored\r\n" > "${MSG_COMMENTS}"

assert_pass "valid sign-off with CRLF and comments" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_COMMENTS}"

# 3. Valid sign-off with multiple co-signers
MSG_MULTI="${TMPDIR}/msg_multi.txt"
cat > "${MSG_MULTI}" <<EOF
chore(deps): update dependency

Signed-off-by: Another Person <other@example.com>
Signed-off-by: Test Author <author@example.com>
EOF

assert_pass "valid sign-off among multiple trailers" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_MULTI}"

# 4. Large message followed by verbose diff (>20000 lines) does not SIGPIPE under pipefail
MSG_LARGE="${TMPDIR}/msg_large.txt"
cat > "${MSG_LARGE}" <<EOF
feat(large): large commit message

Signed-off-by: Test Author <author@example.com>
EOF
# Append a large amount of non-comment text to exceed standard OS pipe buffer
for i in {1..20000}; do
  echo "diff line $i with substantial content to ensure pipe buffer fills 1234567890 1234567890" >> "${MSG_LARGE}"
done

assert_pass "large message with matching sign-off does not SIGPIPE" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_LARGE}"

# 5. Missing sign-off entirely
MSG_MISSING="${TMPDIR}/msg_missing.txt"
cat > "${MSG_MISSING}" <<EOF
fix(bug): resolve issue without signoff

No sign-off trailer here.
EOF

assert_fail "missing sign-off fails with actionable guidance" \
  "add a Signed-off-by trailer matching the author or committer" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_MISSING}"

# 6. Mismatched email in sign-off
MSG_MISMATCH_EMAIL="${TMPDIR}/msg_mismatch_email.txt"
cat > "${MSG_MISMATCH_EMAIL}" <<EOF
docs(readme): update guide

Signed-off-by: Test Author <wrong-email@example.com>
EOF

assert_fail "mismatched email fails" \
  "Signed-off-by: Test Author <author@example.com>" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_MISMATCH_EMAIL}"

# 7. Mismatched name in sign-off
MSG_MISMATCH_NAME="${TMPDIR}/msg_mismatch_name.txt"
cat > "${MSG_MISMATCH_NAME}" <<EOF
docs(readme): update guide

Signed-off-by: Different Name <author@example.com>
EOF

assert_fail "mismatched name fails" \
  "Signed-off-by: Test Author <author@example.com>" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_MISMATCH_NAME}"

# 8. Author != Committer: git commit -s produces committer sign-off
MSG_COMMITTER_SIGNOFF="${TMPDIR}/msg_committer_signoff.txt"
cat > "${MSG_COMMITTER_SIGNOFF}" <<EOF
feat(author): commit with different author

Signed-off-by: Committer Person <committer@example.com>
EOF

assert_pass "git commit -s with committer sign-off passes when author != committer" \
  run_in_repo "${FIXTURE_REPO}" env \
  GIT_AUTHOR_NAME="Original Author" \
  GIT_AUTHOR_EMAIL="author@example.com" \
  GIT_COMMITTER_NAME="Committer Person" \
  GIT_COMMITTER_EMAIL="committer@example.com" \
  "${CHECK_SCRIPT}" "${MSG_COMMITTER_SIGNOFF}"

# 9. Author != Committer: author sign-off also passes
MSG_AUTHOR_SIGNOFF="${TMPDIR}/msg_author_signoff.txt"
cat > "${MSG_AUTHOR_SIGNOFF}" <<EOF
feat(author): commit with original author sign-off

Signed-off-by: Original Author <author@example.com>
EOF

assert_pass "author sign-off passes when author != committer" \
  run_in_repo "${FIXTURE_REPO}" env \
  GIT_AUTHOR_NAME="Original Author" \
  GIT_AUTHOR_EMAIL="author@example.com" \
  GIT_COMMITTER_NAME="Committer Person" \
  GIT_COMMITTER_EMAIL="committer@example.com" \
  "${CHECK_SCRIPT}" "${MSG_AUTHOR_SIGNOFF}"

# 10. Author != Committer: neither signs off displays both expected trailers
assert_fail "author != committer error lists both candidates" \
  "Signed-off-by: Committer Person <committer@example.com>" \
  run_in_repo "${FIXTURE_REPO}" env \
  GIT_AUTHOR_NAME="Original Author" \
  GIT_AUTHOR_EMAIL="author@example.com" \
  GIT_COMMITTER_NAME="Committer Person" \
  GIT_COMMITTER_EMAIL="committer@example.com" \
  "${CHECK_SCRIPT}" "${MSG_MISSING}"

# 11. Author name differing only in case (case-insensitive name matching per Probot dco.js)
MSG_CASE_NAME="${TMPDIR}/msg_case_name.txt"
cat > "${MSG_CASE_NAME}" <<EOF
feat(case): author name differing in case

Signed-off-by: test author <author@example.com>
EOF

assert_pass "author name differing only in case passes" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_CASE_NAME}"

# 12. Email differing only in case (case-insensitive email matching per Probot dco.js)
MSG_CASE_EMAIL="${TMPDIR}/msg_case_email.txt"
cat > "${MSG_CASE_EMAIL}" <<EOF
feat(case): email differing in case

Signed-off-by: Test Author <AUTHOR@EXAMPLE.COM>
EOF

assert_pass "email differing only in case passes" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_CASE_EMAIL}"

# 13. Trailing whitespace on Signed-off-by line
MSG_TRAILING_WHITESPACE="${TMPDIR}/msg_trailing_whitespace.txt"
printf "feat(trailing): trailing spaces on trailer\n\nSigned-off-by: Test Author <author@example.com>   \t  \n" > "${MSG_TRAILING_WHITESPACE}"

assert_pass "trailing whitespace on Signed-off-by line is tolerated" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_TRAILING_WHITESPACE}"

# 14. Case-insensitive Signed-off-by prefix (e.g. signed-off-by:)
MSG_LOWER_PREFIX="${TMPDIR}/msg_lower_prefix.txt"
cat > "${MSG_LOWER_PREFIX}" <<EOF
feat(prefix): lowercase signed-off-by prefix

signed-off-by: Test Author <author@example.com>
EOF

assert_pass "case-insensitive Signed-off-by prefix passes" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_LOWER_PREFIX}"

# 15. Missing space after colon rejected (Probot exact format)
MSG_NO_SPACE_COLON="${TMPDIR}/msg_no_space_colon.txt"
cat > "${MSG_NO_SPACE_COLON}" <<EOF
feat(format): missing space after colon

Signed-off-by:Test Author <author@example.com>
EOF

assert_fail "missing space after colon fails" \
  "Missing or mismatched DCO Signed-off-by trailer" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_NO_SPACE_COLON}"

# 16. Tab after colon rejected (Probot exact format)
MSG_TAB_COLON="${TMPDIR}/msg_tab_colon.txt"
printf "feat(format): tab after colon\n\nSigned-off-by:\tTest Author <author@example.com>\n" > "${MSG_TAB_COLON}"

assert_fail "tab after colon fails" \
  "Missing or mismatched DCO Signed-off-by trailer" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_TAB_COLON}"

# 17. Missing space before < rejected (Probot exact format)
MSG_NO_SPACE_LT="${TMPDIR}/msg_no_space_lt.txt"
cat > "${MSG_NO_SPACE_LT}" <<EOF
feat(format): missing space before email

Signed-off-by: Test Author<author@example.com>
EOF

assert_fail "missing space before < fails" \
  "Missing or mismatched DCO Signed-off-by trailer" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_NO_SPACE_LT}"

# 18. Commented-out sign-off fails
MSG_COMMENTED="${TMPDIR}/msg_commented.txt"
cat > "${MSG_COMMENTED}" <<EOF
refactor(core): clean up functions

# Signed-off-by: Test Author <author@example.com>
EOF

assert_fail "commented-out sign-off fails" \
  "Missing or mismatched DCO Signed-off-by trailer" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_COMMENTED}"

# 19. Commented look-alike scissors line (# --- 8< ---) does not cut off validation
MSG_LOOKALIKE_SCISSORS="${TMPDIR}/msg_lookalike_scissors.txt"
cat > "${MSG_LOOKALIKE_SCISSORS}" <<EOF
feat(scissors): commented look-alike scissors line

# --- 8< ---
Signed-off-by: Test Author <author@example.com>
EOF

assert_pass "commented look-alike scissors line does not cut off validation" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_LOOKALIKE_SCISSORS}"

# 20. Sign-off below exact scissors cutoff line is discarded by git and must fail
MSG_BELOW_SCISSORS="${TMPDIR}/msg_below_scissors.txt"
cat > "${MSG_BELOW_SCISSORS}" <<EOF
feat(scissors): commit with sign-off below scissors line

# ------------------------ >8 ------------------------
Signed-off-by: Test Author <author@example.com>
EOF

assert_fail "sign-off below scissors line fails" \
  "Missing or mismatched DCO Signed-off-by trailer" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_BELOW_SCISSORS}"

# 21. Sign-off above scissors line passes
MSG_ABOVE_SCISSORS="${TMPDIR}/msg_above_scissors.txt"
cat > "${MSG_ABOVE_SCISSORS}" <<EOF
feat(scissors): commit with sign-off above scissors line

Signed-off-by: Test Author <author@example.com>
# ------------------------ >8 ------------------------
diff --git a/foo b/foo
EOF

assert_pass "sign-off above scissors line passes" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_ABOVE_SCISSORS}"

# 22. Uncommented '--- >8 ---' in commit body does not truncate message
MSG_UNCOMMENTED_SCISSORS="${TMPDIR}/msg_uncommented_scissors.txt"
cat > "${MSG_UNCOMMENTED_SCISSORS}" <<EOF
feat(scissors): commit message with uncommented scissors text

Here is an example in documentation:
--- >8 ---
This text should not be treated as a cutoff.

Signed-off-by: Test Author <author@example.com>
EOF

assert_pass "uncommented '--- >8 ---' in body does not truncate message" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_UNCOMMENTED_SCISSORS}"

# 23. Author name containing backslash is read verbatim via ENVIRON (no awk -v escape)
MSG_BACKSLASH="${TMPDIR}/msg_backslash.txt"
cat > "${MSG_BACKSLASH}" <<'EOF'
feat(author): author name with backslash

Signed-off-by: Test\ Author <author@example.com>
EOF

assert_pass "author name containing backslash is matched verbatim" \
  run_in_repo "${FIXTURE_REPO}" env \
  GIT_AUTHOR_NAME='Test\ Author' \
  GIT_AUTHOR_EMAIL='author@example.com' \
  "${CHECK_SCRIPT}" "${MSG_BACKSLASH}"

# 24. Respect custom core.commentChar (e.g. ';')
CUSTOM_REPO="${TMPDIR}/custom_repo"
mkdir -p "${CUSTOM_REPO}"
git -C "${CUSTOM_REPO}" init -q
git -C "${CUSTOM_REPO}" config user.name "Test Author"
git -C "${CUSTOM_REPO}" config user.email "author@example.com"
git -C "${CUSTOM_REPO}" config core.commentChar ";"

MSG_CUSTOM_COMMENT="${TMPDIR}/msg_custom_comment.txt"
cat > "${MSG_CUSTOM_COMMENT}" <<EOF
feat(custom): test custom comment char

; Signed-off-by: Test Author <author@example.com>
EOF

assert_fail "commented-out sign-off with custom core.commentChar fails" \
  "Missing or mismatched DCO Signed-off-by trailer" \
  run_in_repo "${CUSTOM_REPO}" "${CHECK_SCRIPT}" "${MSG_CUSTOM_COMMENT}"

# 25. Bot author skipped (dependabot[bot])
assert_pass "bot author skipped without sign-off" \
  run_in_repo "${FIXTURE_REPO}" env \
  GIT_AUTHOR_NAME="dependabot[bot]" \
  GIT_AUTHOR_EMAIL="49699333+dependabot[bot]@users.noreply.github.com" \
  "${CHECK_SCRIPT}" "${MSG_MISSING}"

# 26. Bot committer does not exempt human author (matching Probot dco.js author.type === "Bot")
assert_fail "bot committer does not exempt human author without sign-off" \
  "Missing or mismatched DCO Signed-off-by trailer" \
  run_in_repo "${FIXTURE_REPO}" env \
  GIT_AUTHOR_NAME="Human Contributor" \
  GIT_AUTHOR_EMAIL="human@example.com" \
  GIT_COMMITTER_NAME="github-actions[bot]" \
  GIT_COMMITTER_EMAIL="41898282+github-actions[bot]@users.noreply.github.com" \
  "${CHECK_SCRIPT}" "${MSG_MISSING}"

# 27. Bot author with uppercase [BOT] in name skipped
assert_pass "bot author uppercase [BOT] skipped" \
  run_in_repo "${FIXTURE_REPO}" env \
  GIT_AUTHOR_NAME="ci-bot[BOT]" \
  GIT_AUTHOR_EMAIL="ci@example.com" \
  "${CHECK_SCRIPT}" "${MSG_MISSING}"

# 28. Autonomous agent bot without [bot] in name but with GitHub bot noreply email skipped
assert_pass "agent bot noreply email skipped without sign-off" \
  run_in_repo "${FIXTURE_REPO}" env \
  GIT_AUTHOR_NAME="fullsend-ai-coder" \
  GIT_AUTHOR_EMAIL="12345+fullsend-ai-coder[bot]@users.noreply.github.com" \
  "${CHECK_SCRIPT}" "${MSG_MISSING}"

# 29. Human author with +[bot] in custom email is NOT exempt and fails without sign-off
assert_fail "human with +[bot] in email is not exempt" \
  "Missing or mismatched DCO Signed-off-by trailer" \
  run_in_repo "${FIXTURE_REPO}" env \
  GIT_AUTHOR_NAME="Human User" \
  GIT_AUTHOR_EMAIL="human+[bot]@example.com" \
  "${CHECK_SCRIPT}" "${MSG_MISSING}"

# 30. Merge commit with MERGE_HEAD skipped
MERGE_REPO="${TMPDIR}/merge_repo"
mkdir -p "${MERGE_REPO}"
git -C "${MERGE_REPO}" init -q
git -C "${MERGE_REPO}" config user.name "Test Author"
git -C "${MERGE_REPO}" config user.email "author@example.com"
touch "${MERGE_REPO}/.git/MERGE_HEAD"

assert_pass "merge commit with MERGE_HEAD skipped without sign-off" \
  run_in_repo "${MERGE_REPO}" "${CHECK_SCRIPT}" "${MSG_MISSING}"

# 31. Single-parent commit starting with "Merge " without MERGE_HEAD requires sign-off
MSG_MERGE="${TMPDIR}/msg_merge.txt"
cat > "${MSG_MERGE}" <<EOF
Merge branch 'feature-branch' into main

Detailed explanation of commit.
EOF

assert_fail "single-parent commit starting with 'Merge ' requires sign-off" \
  "Missing or mismatched DCO Signed-off-by trailer" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${MSG_MERGE}"

# 32. Missing argument fails
assert_fail "missing argument fails" \
  "Commit message file argument missing" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}"

# 33. Non-existent file fails
assert_fail "non-existent file fails" \
  "not found" \
  run_in_repo "${FIXTURE_REPO}" "${CHECK_SCRIPT}" "${TMPDIR}/does_not_exist.txt"

# --- Summary ---
echo ""
echo "Ran ${TESTS} tests, ${FAILURES} failures"
if [[ "${FAILURES}" -gt 0 ]]; then
  exit 1
fi
