#!/usr/bin/env bash
# signoff-strip-test.sh — Real-git tests for the Signed-off-by strip helpers.
#
# These exercise the actual rewrite against real repositories: git filter-branch
# on multi-commit ranges and git commit --amend on single-commit ranges. The
# earlier string-matching cases in post-code-test.sh / post-fix-test.sh could
# not observe identity preservation, commit counts, or authorship scoping,
# because they never created a commit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/precommit-gate.lib.sh
source "${SCRIPT_DIR}/lib/precommit-gate.lib.sh"

FAILURES=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

BOT_EMAIL="123+fullsend-ai-coder[bot]@users.noreply.github.com"
HUMAN_EMAIL="human@example.com"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — $2"; FAILURES=$((FAILURES + 1)); }

check() { # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

# mk_repo <name> — new repo with one base commit; echoes its path.
mk_repo() {
  local d="${TMPROOT}/$1"
  mkdir -p "${d}"
  git init -q -b main "${d}"
  git -C "${d}" config user.email "${BOT_EMAIL}"
  git -C "${d}" config user.name "Bot"
  echo base > "${d}/base.txt"
  git -C "${d}" add base.txt
  git -C "${d}" -c "user.email=${BOT_EMAIL}" commit -q -m "chore: base"
  printf '%s' "${d}"
}

# commit_as <repo> <email> <name> <adate> <cdate> <file> <message>
commit_as() {
  local d="$1" email="$2" who="$3" adate="$4" cdate="$5" f="$6" msg="$7"
  echo "${RANDOM}" > "${d}/${f}"
  git -C "${d}" add "${f}"
  GIT_AUTHOR_NAME="${who}" GIT_AUTHOR_EMAIL="${email}" GIT_AUTHOR_DATE="${adate}" \
  GIT_COMMITTER_NAME="${who}" GIT_COMMITTER_EMAIL="${email}" GIT_COMMITTER_DATE="${cdate}" \
    git -C "${d}" commit -q -F - <<< "${msg}"
}

TRAILER="Signed-off-by: Bot <${BOT_EMAIL}>"

# ---------------------------------------------------------------------------
# 1. Single bot commit: trailer stripped, rest of the message intact,
#    identity and dates preserved, commit count unchanged.
# ---------------------------------------------------------------------------
d="$(mk_repo single)"
base="$(git -C "${d}" rev-parse HEAD)"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-02-01T10:00:00+0000" "2024-02-02T11:00:00+0000" \
  f1 "feat: one

body line one

${TRAILER}"
before="$(git -C "${d}" log -1 --format='%an|%ae|%aI|%cn|%ce|%cI')"
count_before="$(git -C "${d}" rev-list --count "${base}..HEAD")"

( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" ) >/dev/null 2>&1
rc=$?

check "single-strip-exit-zero" "0" "${rc}"
check "single-no-residual-trailer" "0" \
  "$(git -C "${d}" log --format='%B' "${base}..HEAD" | grep -c '^Signed-off-by:')"
check "single-identity-and-dates-preserved" "${before}" \
  "$(git -C "${d}" log -1 --format='%an|%ae|%aI|%cn|%ce|%cI')"
check "single-commit-count-unchanged" "${count_before}" \
  "$(git -C "${d}" rev-list --count "${base}..HEAD")"
check "single-subject-intact" "feat: one" "$(git -C "${d}" log -1 --format='%s')"
check "single-body-intact" "body line one" \
  "$(git -C "${d}" log -1 --format='%b' | sed '/^$/d')"

# ---------------------------------------------------------------------------
# 2. Multi-commit: every trailered commit rewritten, untrailered one untouched,
#    order and count preserved, the range base left alone.
# ---------------------------------------------------------------------------
d="$(mk_repo multi)"
base="$(git -C "${d}" rev-parse HEAD)"
base_tree="$(git -C "${d}" rev-parse 'HEAD^{tree}')"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-02-01T10:00:00+0000" "2024-02-02T11:00:00+0000" \
  f1 "feat: one

${TRAILER}"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-03-01T10:00:00+0000" "2024-03-02T11:00:00+0000" \
  f2 "feat: two

no trailer here"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-04-01T10:00:00+0000" "2024-04-02T11:00:00+0000" \
  f3 "feat: three

mid body line

${TRAILER}

trailing prose after the trailer"
subjects_before="$(git -C "${d}" log --format='%s' "${base}..HEAD")"
idents_before="$(git -C "${d}" log --format='%an|%ae|%aI|%cn|%ce|%cI' "${base}..HEAD")"

( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" ) >/dev/null 2>&1
check "multi-strip-exit-zero" "0" "$?"
check "multi-no-residual-trailer" "0" \
  "$(git -C "${d}" log --format='%B' "${base}..HEAD" | grep -c '^Signed-off-by:')"
check "multi-commit-count-unchanged" "3" \
  "$(git -C "${d}" rev-list --count "${base}..HEAD")"
check "multi-order-and-subjects-unchanged" "${subjects_before}" \
  "$(git -C "${d}" log --format='%s' "${base}..HEAD")"
check "multi-identity-and-dates-preserved" "${idents_before}" \
  "$(git -C "${d}" log --format='%an|%ae|%aI|%cn|%ce|%cI' "${base}..HEAD")"
check "multi-range-base-untouched" "${base_tree}" "$(git -C "${d}" rev-parse "${base}^{tree}")"
check "multi-mid-body-prose-preserved" "1" \
  "$(git -C "${d}" log -1 --format='%B' HEAD | grep -c 'trailing prose after the trailer')"
check "multi-mid-body-first-line-preserved" "1" \
  "$(git -C "${d}" log -1 --format='%B' HEAD | grep -c 'mid body line')"

# Idempotence: a second pass must be a no-op, leaving SHAs untouched.
shas_after_first="$(git -C "${d}" rev-list "${base}..HEAD")"
( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" ) >/dev/null 2>&1
check "multi-idempotent-exit-zero" "0" "$?"
check "multi-idempotent-shas-unchanged" "${shas_after_first}" \
  "$(git -C "${d}" rev-list "${base}..HEAD")"

# ---------------------------------------------------------------------------
# 3. A human commit inside the range keeps its DCO sign-off.
#
# Regression test for the rebase path: SCAN_RANGE widens to merge-base, so the
# range can contain commits the human signed. Stripping those would destroy a
# legal attestation and fail the DCO check on their own commit.
# ---------------------------------------------------------------------------
d="$(mk_repo human)"
base="$(git -C "${d}" rev-parse HEAD)"
commit_as "${d}" "${HUMAN_EMAIL}" "Real Human" "2024-01-05T10:00:00+0000" "2024-01-05T10:00:00+0000" \
  h1 "feat: human work

Signed-off-by: Real Human <${HUMAN_EMAIL}>"
human_sha="$(git -C "${d}" rev-parse HEAD)"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-02-01T10:00:00+0000" "2024-02-02T11:00:00+0000" \
  f1 "fix: agent change

${TRAILER}"

check "human-in-range-counted-out" "1" \
  "$( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_count_range "${base}..HEAD" )"

( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" ) >/dev/null 2>&1
check "human-strip-exit-zero" "0" "$?"
check "human-signoff-survives" "1" \
  "$(git -C "${d}" log --format='%B' "${base}..HEAD" | grep -c "Signed-off-by: Real Human")"
check "human-commit-sha-unchanged" "${human_sha}" \
  "$(git -C "${d}" log --format='%H %ce' "${base}..HEAD" | awk -v e="${HUMAN_EMAIL}" '$2==e{print $1}')"
check "bot-trailer-still-removed" "0" \
  "$(git -C "${d}" log --format='%B' "${base}..HEAD" | grep -c "Signed-off-by: Bot")"

# ---------------------------------------------------------------------------
# 3b. A human commit the AGENT REBASED keeps its sign-off.
#
# A rebase re-stamps the committer, so after the agent rebases in the sandbox
# the human's commit carries the bot as committer while the author stays human.
# Scoping on committer email would strip it; scoping on author must not.
# This is the shape that reaches post-fix's merge-base widening in practice.
# ---------------------------------------------------------------------------
d="$(mk_repo rebased)"
git -C "${d}" checkout -q -b feature
commit_as "${d}" "${HUMAN_EMAIL}" "Real Human" "2024-01-05T10:00:00+0000" "2024-01-05T10:00:00+0000" \
  h1 "feat: human work

Signed-off-by: Real Human <${HUMAN_EMAIL}>"
git -C "${d}" checkout -q main
echo moved >> "${d}/base.txt"
git -C "${d}" -c "user.email=${BOT_EMAIL}" commit -qam "chore: main moves"
git -C "${d}" checkout -q feature
# The agent rebases with the bot identity configured, as it does in the sandbox.
git -C "${d}" -c "user.email=${BOT_EMAIL}" -c "user.name=Bot" rebase -q main
base="$(git -C "${d}" rev-parse main)"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-02-01T10:00:00+0000" "2024-02-02T11:00:00+0000" \
  f1 "fix: agent change

${TRAILER}"

check "rebased-human-committer-is-bot" "${BOT_EMAIL}" \
  "$(git -C "${d}" log --format='%ae %ce' "${base}..HEAD" | awk -v h="${HUMAN_EMAIL}" '$1==h{print $2}')"
check "rebased-human-counted-out" "1" \
  "$( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_count_range "${base}..HEAD" )"

( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" ) >/dev/null 2>&1
check "rebased-strip-exit-zero" "0" "$?"
check "rebased-human-signoff-survives" "1" \
  "$(git -C "${d}" log --format='%B' "${base}..HEAD" | grep -c "Signed-off-by: Real Human")"
check "rebased-bot-trailer-removed" "0" \
  "$(git -C "${d}" log --format='%B' "${base}..HEAD" | grep -c "Signed-off-by: Bot")"

# ---------------------------------------------------------------------------
# 3c. A GPG-signed human commit below the agent tip keeps its signature and
#     its SHA. filter-branch re-creates every commit it is handed, even
#     through a cat filter, and commit-tree drops gpgsig — so the rewrite must
#     never be handed the human's commit at all.
# ---------------------------------------------------------------------------
d="$(mk_repo signed)"
base="$(git -C "${d}" rev-parse HEAD)"
echo h > "${d}/h1"; git -C "${d}" add h1
signed_tree="$(git -C "${d}" write-tree)"
printf 'tree %s\nparent %s\nauthor Real Human <%s> 1700000000 +0000\ncommitter Real Human <%s> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n test-only\n -----END PGP SIGNATURE-----\n\nfeat: human work\n\nSigned-off-by: Real Human <%s>\n' \
  "${signed_tree}" "${base}" "${HUMAN_EMAIL}" "${HUMAN_EMAIL}" "${HUMAN_EMAIL}" > "${TMPROOT}/signed.obj"
signed_sha="$(git -C "${d}" hash-object -t commit -w "${TMPROOT}/signed.obj")"
git -C "${d}" update-ref refs/heads/main "${signed_sha}"
git -C "${d}" reset -q --hard
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-02-01T10:00:00+0000" "2024-02-02T11:00:00+0000" \
  f1 "fix: agent one

${TRAILER}"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-03-01T10:00:00+0000" "2024-03-02T11:00:00+0000" \
  f2 "fix: agent two

${TRAILER}"

check "signed-human-has-gpgsig-before" "1" "$(git -C "${d}" cat-file -p "${signed_sha}" | grep -c '^gpgsig')"
( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" ) >/dev/null 2>&1
check "signed-strip-exit-zero" "0" "$?"
check "signed-human-sha-unchanged" "${signed_sha}" \
  "$(git -C "${d}" log --format='%H %ae' "${base}..HEAD" | awk -v e="${HUMAN_EMAIL}" '$2==e{print $1}')"
check "signed-human-gpgsig-survives" "1" "$(git -C "${d}" cat-file -p "${signed_sha}" | grep -c '^gpgsig')"
check "signed-bot-trailers-removed" "0" \
  "$(git -C "${d}" log --format='%B' "${base}..HEAD" | grep -c "Signed-off-by: Bot")"
check "signed-commit-count-unchanged" "3" "$(git -C "${d}" rev-list --count "${base}..HEAD")"

# ---------------------------------------------------------------------------
# 3d. An agent trailer below a human commit cannot be reached without
#     rewriting the human's commit. Fail closed and leave everything alone.
# ---------------------------------------------------------------------------
d="$(mk_repo below)"
base="$(git -C "${d}" rev-parse HEAD)"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-01-01T10:00:00+0000" "2024-01-02T11:00:00+0000" \
  f0 "fix: agent early

${TRAILER}"
commit_as "${d}" "${HUMAN_EMAIL}" "Real Human" "2024-01-05T10:00:00+0000" "2024-01-05T10:00:00+0000" \
  h1 "feat: human work

Signed-off-by: Real Human <${HUMAN_EMAIL}>"
shas_before="$(git -C "${d}" rev-list "${base}..HEAD")"

err="$( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" 2>&1 >/dev/null )"
rc=$?
check "below-human-fails-closed" "1" "${rc}"
check "below-human-names-the-cause" "1" "$(printf '%s' "${err}" | grep -c 'below a non-agent commit')"
check "below-human-nothing-rewritten" "${shas_before}" "$(git -C "${d}" rev-list "${base}..HEAD")"

# ---------------------------------------------------------------------------
# 4. Trailer on line 2 with no blank line: folded into the subject, so the
#    body-only format (%b) cannot see it. Detection must still fire.
# ---------------------------------------------------------------------------
d="$(mk_repo folded)"
base="$(git -C "${d}" rev-parse HEAD)"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-02-01T10:00:00+0000" "2024-02-02T11:00:00+0000" \
  f1 "fix: thing
${TRAILER}"

check "folded-trailer-invisible-to-body-format" "" \
  "$(git -C "${d}" log --format='%b' "${base}..HEAD" | grep '^Signed-off-by:' || true)"
check "folded-trailer-detected" "1" \
  "$( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_count_range "${base}..HEAD" )"

( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" ) >/dev/null 2>&1
check "folded-strip-exit-zero" "0" "$?"
check "folded-no-residual-trailer" "0" \
  "$(git -C "${d}" log --format='%B' "${base}..HEAD" | grep -c '^Signed-off-by:')"
check "folded-subject-preserved" "fix: thing" "$(git -C "${d}" log -1 --format='%s')"

# ---------------------------------------------------------------------------
# 5. Staged-but-uncommitted content must not be folded into the amended commit
#    (it would ride past the secret scan that already ran).
# ---------------------------------------------------------------------------
d="$(mk_repo staged)"
base="$(git -C "${d}" rev-parse HEAD)"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-02-01T10:00:00+0000" "2024-02-02T11:00:00+0000" \
  f1 "feat: one

${TRAILER}"
echo "not-scanned" > "${d}/leaked.txt"
git -C "${d}" add leaked.txt

( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" ) >/dev/null 2>&1
check "staged-strip-exit-zero" "0" "$?"
check "staged-file-not-in-commit" "" \
  "$(git -C "${d}" show --name-only --format= HEAD | grep '^leaked.txt$' || true)"
check "staged-file-still-staged" "leaked.txt" \
  "$(git -C "${d}" diff --cached --name-only)"
check "staged-trailer-removed" "0" \
  "$(git -C "${d}" log --format='%B' "${base}..HEAD" | grep -c '^Signed-off-by:')"

# ---------------------------------------------------------------------------
# 6. A dirty worktree fails closed with a diagnostic, rather than letting
#    filter-branch abort the run under a misleading category.
# ---------------------------------------------------------------------------
d="$(mk_repo dirty)"
base="$(git -C "${d}" rev-parse HEAD)"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-02-01T10:00:00+0000" "2024-02-02T11:00:00+0000" \
  f1 "feat: one

${TRAILER}"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-03-01T10:00:00+0000" "2024-03-02T11:00:00+0000" \
  f2 "feat: two

${TRAILER}"
echo "modified" >> "${d}/base.txt"

err="$( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" 2>&1 >/dev/null )"
rc=$?
check "dirty-worktree-fails-closed" "1" "${rc}"
check "dirty-worktree-names-the-cause" "1" \
  "$(printf '%s' "${err}" | grep -c 'unstaged changes')"

# An untracked file is not a dirty worktree for this purpose.
git -C "${d}" checkout -- base.txt
echo junk > "${d}/untracked.txt"
( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" ) >/dev/null 2>&1
check "untracked-file-does-not-block" "0" "$?"

# ---------------------------------------------------------------------------
# 6b. Unknown agent identity refuses to rewrite.
#
# Without GIT_BOT_EMAIL every commit looks like the agent's, so a human's
# sign-off in range would be stripped. Fail closed instead.
# ---------------------------------------------------------------------------
d="$(mk_repo noident)"
base="$(git -C "${d}" rev-parse HEAD)"
commit_as "${d}" "${HUMAN_EMAIL}" "Real Human" "2024-01-05T10:00:00+0000" "2024-01-05T10:00:00+0000" \
  h1 "feat: human work

Signed-off-by: Real Human <${HUMAN_EMAIL}>"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-02-01T10:00:00+0000" "2024-02-02T11:00:00+0000" \
  f1 "fix: agent change

${TRAILER}"

err="$( cd "${d}" && GIT_BOT_EMAIL="" GIT_COMMITTER_EMAIL="" signoff_strip_range "${base}..HEAD" 2>&1 >/dev/null )"
rc=$?
check "unknown-identity-fails-closed" "1" "${rc}"
check "unknown-identity-names-the-cause" "1" \
  "$(printf '%s' "${err}" | grep -c 'identity unavailable')"
check "unknown-identity-leaves-human-signoff" "1" \
  "$(git -C "${d}" log --format='%B' "${base}..HEAD" | grep -c "Signed-off-by: Real Human")"

# ---------------------------------------------------------------------------
# 6c. A staged change blocks the multi-commit rewrite (filter-branch refuses
#     on a dirty index), while the single-commit --only path tolerates it.
# ---------------------------------------------------------------------------
d="$(mk_repo stagedmulti)"
base="$(git -C "${d}" rev-parse HEAD)"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-02-01T10:00:00+0000" "2024-02-02T11:00:00+0000" \
  f1 "feat: one

${TRAILER}"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-03-01T10:00:00+0000" "2024-03-02T11:00:00+0000" \
  f2 "feat: two

${TRAILER}"
echo staged > "${d}/staged.txt"
git -C "${d}" add staged.txt

err="$( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_strip_range "${base}..HEAD" 2>&1 >/dev/null )"
rc=$?
check "staged-index-blocks-multi-commit" "1" "${rc}"
check "staged-index-names-the-cause" "1" \
  "$(printf '%s' "${err}" | grep -c 'staged changes')"

# ---------------------------------------------------------------------------
# 7. Detection helpers on a clean range.
# ---------------------------------------------------------------------------
d="$(mk_repo clean)"
base="$(git -C "${d}" rev-parse HEAD)"
commit_as "${d}" "${BOT_EMAIL}" "Bot" "2024-02-01T10:00:00+0000" "2024-02-02T11:00:00+0000" \
  f1 "feat: no trailer

just a body"
check "clean-range-count-zero" "0" \
  "$( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_count_range "${base}..HEAD" )"
if ( cd "${d}" && GIT_BOT_EMAIL="${BOT_EMAIL}" signoff_present_in_range "${base}..HEAD" ); then
  fail "clean-range-not-present" "signoff_present_in_range returned true on a clean range"
else
  pass "clean-range-not-present"
fi

echo
if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
