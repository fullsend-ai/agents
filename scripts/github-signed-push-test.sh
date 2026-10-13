#!/usr/bin/env bash
# github-signed-push-test.sh — Test forge_push_branch from
# scripts/lib/github-signed-push.lib.sh against a bare repository, with
# test-fixtures/fake-gh-git-api.sh standing in for the GitHub API.
#
# Run from the repo root:
#   bash scripts/github-signed-push-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

MOCK_BIN="${TEST_TMPDIR}/bin"
mkdir -p "${MOCK_BIN}"
export FAKE_GH_GIT_API="${SCRIPT_DIR}/test-fixtures/fake-gh-git-api.sh"
cat > "${MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api -X") exec bash "${FAKE_GH_GIT_API}" "$@" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
MOCKEOF
cat > "${MOCK_BIN}/sleep" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "${MOCK_BIN}/gh" "${MOCK_BIN}/sleep"
export PATH="${MOCK_BIN}:${PATH}"
export REPO_FULL_NAME="test-org/test-repo"
export PUSH_TOKEN="fake-token"
# Hermetic git: no host signing or identity config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# shellcheck source=lib/github-signed-push.lib.sh
source "${SCRIPT_DIR}/lib/github-signed-push.lib.sh"

pass() {
  echo "PASS: $1"
}

fail() {
  local name="$1"
  shift
  echo "FAIL: ${name}"
  printf '  %s\n' "$@"
  FAILURES=$((FAILURES + 1))
}

BRANCH="agent/1-test"

# setup_repo NAME — bare remote with main and a clone on ${BRANCH}; prints
# the clone path. The bare repo is <clone>/../remote.git.
setup_repo() {
  local base="${TEST_TMPDIR}/$1"
  git init -q --bare -b main "${base}/remote.git"
  git clone -q "${base}/remote.git" "${base}/repo" 2>/dev/null
  git -C "${base}/repo" config user.email "test@example.com"
  git -C "${base}/repo" config user.name "Test"
  echo "init" > "${base}/repo/README.md"
  git -C "${base}/repo" add README.md
  git -C "${base}/repo" commit -q -m "init"
  git -C "${base}/repo" push -q origin main
  git -C "${base}/repo" checkout -q -b "${BRANCH}"
  echo "${base}/repo"
}

# diverge_remote CLONE — adds a commit to ${BRANCH} on the remote through a
# second clone, so the first clone's branch is no longer a fast-forward.
diverge_remote() {
  local bare="${1%/repo}/remote.git" seed="${1%/repo}/seed"
  git clone -q "${bare}" "${seed}"
  git -C "${seed}" config user.email "other@example.com"
  git -C "${seed}" config user.name "Other"
  git -C "${seed}" checkout -q "${BRANCH}"
  echo "theirs" > "${seed}/theirs.txt"
  git -C "${seed}" add theirs.txt
  git -C "${seed}" commit -q -m "theirs"
  git -C "${seed}" push -q origin "${BRANCH}"
}

commit_file() {
  local repo="$1" file="$2" content="$3" msg="$4"
  echo "${content}" > "${repo}/${file}"
  git -C "${repo}" add "${file}"
  git -C "${repo}" commit -q -m "${msg}"
}

# push_in CLONE [args...] — runs forge_push_branch in CLONE; sets PUSH_RC
# and PUSH_OUT (stdout and stderr).
push_in() {
  local repo="$1"
  shift
  PUSH_RC=0
  PUSH_OUT="$(cd "${repo}" && forge_push_branch "$@" 2>&1)" || PUSH_RC=$?
}

remote_rev() {
  git --git-dir="${1%/repo}/remote.git" rev-parse --verify --quiet "$2"
}

commit_message() {
  git --git-dir="$1" cat-file commit "$2" | sed '1,/^$/d'
}

# --- new branch: two commits covering every tree entry kind ---------------
repo="$(setup_repo new-branch)"
bare="${repo%/repo}/remote.git"
mkdir -p "${repo}/dir"
printf 'echo hi\n' > "${repo}/dir/run.sh"
chmod +x "${repo}/dir/run.sh"
printf 'a\0b\n\377' > "${repo}/bin.dat"
ln -s dir/run.sh "${repo}/link"
: > "${repo}/empty.txt"
git -C "${repo}" add -A
git -C "${repo}" commit -q -m "feat: add files" -m "Body line.

Closes #1"
first_local="$(git -C "${repo}" rev-parse HEAD)"
echo "v2" > "${repo}/README.md"
git -C "${repo}" rm -q bin.dat
git -C "${repo}" mv dir/run.sh dir/run2.sh
chmod -x "${repo}/dir/run2.sh"
git -C "${repo}" add -A
git -C "${repo}" commit -q -m "fix: rework" -m "Notes.

---

After the rule."
local_head="$(git -C "${repo}" rev-parse HEAD)"
local_tree="$(git -C "${repo}" rev-parse 'HEAD^{tree}')"
local_first_msg="$(commit_message "${repo}/.git" "${first_local}")"
bin_blob="$(git -C "${repo}" rev-parse "${first_local}:bin.dat")"

push_in "${repo}" "${BRANCH}"
tip="$(remote_rev "${repo}" "refs/heads/${BRANCH}" || true)"
if [ "${PUSH_RC}" -ne 0 ] || [ -z "${tip}" ]; then
  fail "new-branch-created" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "new-branch-created"
  checks=(
    "tree matches local:$(git --git-dir="${bare}" rev-parse "${tip}^{tree}")=${local_tree}"
    "two commits ahead of main:$(git --git-dir="${bare}" rev-list --count "main..${tip}")=2"
    "committer is GitHub:$(git --git-dir="${bare}" log -1 --format=%cn "${tip}")=GitHub"
    "message preserved:$(commit_message "${bare}" "${tip}~1")=${local_first_msg}

Authored-by: Test <test@example.com>"
    "author kept in trailer:$(git --git-dir="${bare}" log -1 --format='%(trailers:key=Authored-by,valueonly)' "${tip}" | head -1)=Test <test@example.com>"
    "executable mode kept:$(git --git-dir="${bare}" ls-tree "${tip}~1" dir/run.sh | cut -d' ' -f1)=100755"
    "mode change applied:$(git --git-dir="${bare}" ls-tree "${tip}" dir/run2.sh | cut -d' ' -f1)=100644"
    "symlink kept:$(git --git-dir="${bare}" ls-tree "${tip}" link | cut -d' ' -f1)=120000"
    "binary blob identical:$(git --git-dir="${bare}" rev-parse "${tip}~1:bin.dat")=${bin_blob}"
    "deleted file gone:$(git --git-dir="${bare}" ls-tree "${tip}" bin.dat | wc -l | tr -d ' ')=0"
    "commits were recreated:$([ "${tip}" != "${local_head}" ] && echo yes)=yes"
    "local branch moved onto remote tip:$(git -C "${repo}" rev-parse HEAD)=${tip}"
    "upstream set:$(git -C "${repo}" rev-parse --abbrev-ref '@{u}')=origin/${BRANCH}"
    "worktree clean:$(git -C "${repo}" status --porcelain | wc -l | tr -d ' ')=0"
    "one log line per commit:$(printf '%s\n' "${PUSH_OUT}" | grep -c 'Created signed commit')=2"
  )
  for check in "${checks[@]}"; do
    name="${check%%:*}"
    rest="${check#*:}"
    if [ "${rest%%=*}" = "${rest#*=}" ]; then
      pass "new-branch ${name}"
    else
      fail "new-branch ${name}" "got '${rest%%=*}' want '${rest#*=}'" "${PUSH_OUT}"
    fi
  done
fi

# --- fast-forward onto the existing remote branch ------------------------
commit_file "${repo}" "more.txt" "more" "feat: more"
push_in "${repo}" "${BRANCH}"
new_tip="$(remote_rev "${repo}" "refs/heads/${BRANCH}" || true)"
if [ "${PUSH_RC}" -ne 0 ] \
   || [ "$(git --git-dir="${bare}" rev-parse "${new_tip}~1")" != "${tip}" ] \
   || [ "$(git --git-dir="${bare}" rev-parse "${new_tip}^{tree}")" != "$(git -C "${repo}" rev-parse 'HEAD^{tree}')" ] \
   || [ "$(git -C "${repo}" rev-parse HEAD)" != "${new_tip}" ]; then
  fail "fast-forward-existing-branch" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "fast-forward-existing-branch"
fi

# --- pushing an up-to-date branch is a no-op ------------------------------
push_in "${repo}" "${BRANCH}"
if [ "${PUSH_RC}" -ne 0 ] || ! printf '%s' "${PUSH_OUT}" | grep -q "Everything up-to-date" \
   || [ "$(remote_rev "${repo}" "refs/heads/${BRANCH}")" != "${new_tip}" ]; then
  fail "up-to-date-noop" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "up-to-date-noop"
fi

# --- non-fast-forward: refused without the flag, applied with it ----------
repo="$(setup_repo non-ff)"
bare="${repo%/repo}/remote.git"
commit_file "${repo}" "a.txt" "a" "feat: a"
push_in "${repo}" "${BRANCH}"
diverge_remote "${repo}"
theirs="$(remote_rev "${repo}" "refs/heads/${BRANCH}")"
commit_file "${repo}" "b.txt" "b" "feat: b"
push_in "${repo}" "${BRANCH}"
if [ "${PUSH_RC}" -eq 0 ] || ! printf '%s' "${PUSH_OUT}" | grep -q "non-fast-forward" \
   || printf '%s' "${PUSH_OUT}" | grep -q "Created signed commit" \
   || [ "$(remote_rev "${repo}" "refs/heads/${BRANCH}")" != "${theirs}" ]; then
  fail "non-fast-forward-refused-before-any-api-write" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "non-fast-forward-refused-before-any-api-write"
fi

push_in "${repo}" "${BRANCH}" --force-with-lease
if [ "${PUSH_RC}" -eq 0 ] || ! printf '%s' "${PUSH_OUT}" | grep -q "moved from" \
   || [ "$(remote_rev "${repo}" "refs/heads/${BRANCH}")" != "${theirs}" ]; then
  fail "force-with-lease-stale-tracking-ref-refused" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "force-with-lease-stale-tracking-ref-refused"
fi

git -C "${repo}" fetch -q origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}"
push_in "${repo}" "${BRANCH}" --force-with-lease
forced_tip="$(remote_rev "${repo}" "refs/heads/${BRANCH}" || true)"
if [ "${PUSH_RC}" -ne 0 ] \
   || [ "$(git --git-dir="${bare}" rev-parse "${forced_tip}^{tree}")" != "$(git -C "${repo}" rev-parse 'HEAD^{tree}')" ] \
   || git --git-dir="${bare}" merge-base --is-ancestor "${theirs}" "${forced_tip}" \
   || [ "$(git -C "${repo}" rev-parse HEAD)" != "${forced_tip}" ]; then
  fail "force-with-lease-replaces-remote-branch" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "force-with-lease-replaces-remote-branch"
fi

# --- force-with-lease: the remote moved after the lease was taken ---------
repo="$(setup_repo lease)"
bare="${repo%/repo}/remote.git"
commit_file "${repo}" "a.txt" "a" "feat: a"
push_in "${repo}" "${BRANCH}"
diverge_remote "${repo}"
commit_file "${repo}" "b.txt" "b" "feat: b"
git -C "${repo}" fetch -q origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}"
main_sha="$(remote_rev "${repo}" "refs/heads/main")"
FAKE_GH_RACE="refs/heads/${BRANCH}=${main_sha}" push_in "${repo}" "${BRANCH}" --force-with-lease
if [ "${PUSH_RC}" -eq 0 ] || ! printf '%s' "${PUSH_OUT}" | grep -q "moved from" \
   || [ "$(remote_rev "${repo}" "refs/heads/${BRANCH}")" != "${main_sha}" ]; then
  fail "force-with-lease-stale-remote-refused" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "force-with-lease-stale-remote-refused"
fi

# --- a blob GitHub stores under another SHA aborts before the ref moves ---
repo="$(setup_repo corrupt-blob)"
commit_file "${repo}" "a.txt" "a" "feat: a"
FAKE_GH_CORRUPT_BLOB=1 push_in "${repo}" "${BRANCH}"
if [ "${PUSH_RC}" -eq 0 ] || ! printf '%s' "${PUSH_OUT}" | grep -q "stored blob" \
   || remote_rev "${repo}" "refs/heads/${BRANCH}" > /dev/null; then
  fail "blob-sha-mismatch-aborts" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "blob-sha-mismatch-aborts"
fi

# --- an unsigned response is reported but does not fail the push ----------
repo="$(setup_repo unverified)"
commit_file "${repo}" "a.txt" "a" "feat: a"
FAKE_GH_UNVERIFIED=1 push_in "${repo}" "${BRANCH}"
if [ "${PUSH_RC}" -ne 0 ] || ! printf '%s' "${PUSH_OUT}" | grep -q "did not sign" \
   || ! remote_rev "${repo}" "refs/heads/${BRANCH}" > /dev/null; then
  fail "unverified-commit-warns" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "unverified-commit-warns"
fi

# --- a transient 5xx is retried ------------------------------------------
repo="$(setup_repo retry)"
commit_file "${repo}" "a.txt" "a" "feat: a"
FAKE_GH_FAIL_ONCE="${TEST_TMPDIR}/failed-once" push_in "${repo}" "${BRANCH}"
if [ "${PUSH_RC}" -ne 0 ] || [ ! -e "${TEST_TMPDIR}/failed-once" ] \
   || ! remote_rev "${repo}" "refs/heads/${BRANCH}" > /dev/null; then
  fail "transient-error-retried" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "transient-error-retried"
fi

# --- an empty commit reuses the parent tree -------------------------------
repo="$(setup_repo empty-commit)"
bare="${repo%/repo}/remote.git"
git -C "${repo}" commit -q --allow-empty -m "chore: empty"
push_in "${repo}" "${BRANCH}"
tip="$(remote_rev "${repo}" "refs/heads/${BRANCH}" || true)"
if [ "${PUSH_RC}" -ne 0 ] || [ -z "${tip}" ] \
   || [ "$(git --git-dir="${bare}" rev-parse "${tip}^{tree}")" != "$(git --git-dir="${bare}" rev-parse 'main^{tree}')" ]; then
  fail "empty-commit" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "empty-commit"
fi

# --- a merge commit keeps its second parent -------------------------------
repo="$(setup_repo merge-commit)"
bare="${repo%/repo}/remote.git"
git -C "${repo}" checkout -q -b side main
commit_file "${repo}" "side.txt" "side" "feat: side"
git -C "${repo}" push -q origin side
side_sha="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" checkout -q "${BRANCH}"
commit_file "${repo}" "a.txt" "a" "feat: a"
git -C "${repo}" merge -q --no-ff -m "merge side" side
push_in "${repo}" "${BRANCH}"
tip="$(remote_rev "${repo}" "refs/heads/${BRANCH}" || true)"
if [ "${PUSH_RC}" -ne 0 ] || [ -z "${tip}" ] \
   || [ "$(git --git-dir="${bare}" rev-parse "${tip}^2")" != "${side_sha}" ] \
   || [ "$(git --git-dir="${bare}" rev-parse "${tip}^{tree}")" != "$(git -C "${repo}" rev-parse 'HEAD^{tree}')" ]; then
  fail "merge-commit-keeps-second-parent" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "merge-commit-keeps-second-parent"
fi

# --- a merge whose second parent is not on origin either --------------------
# Side: 3 blobs; branch: 1; the merge, rebuilt against the side, needs only
# a.txt, already uploaded: 4 in all.
repo="$(setup_repo local-merge)"
bare="${repo%/repo}/remote.git"
git -C "${repo}" checkout -q -b side main
for f in s1 s2 s3; do echo "${f}" > "${repo}/${f}.txt"; done
git -C "${repo}" add -A
git -C "${repo}" commit -q -m "feat: side"
side_tree="$(git -C "${repo}" rev-parse 'HEAD^{tree}')"
git -C "${repo}" checkout -q "${BRANCH}"
commit_file "${repo}" "a.txt" "a" "feat: a"
git -C "${repo}" merge -q --no-ff -m "merge side" side
FAKE_GH_BLOB_LOG="${TEST_TMPDIR}/local-merge-blobs" push_in "${repo}" "${BRANCH}"
tip="$(remote_rev "${repo}" "refs/heads/${BRANCH}" || true)"
if [ "${PUSH_RC}" -ne 0 ] || [ -z "${tip}" ] \
   || [ "$(git --git-dir="${bare}" rev-parse "${tip}^2^{tree}")" != "${side_tree}" ] \
   || [ "$(git --git-dir="${bare}" log -1 --format=%cn "${tip}^2")" != "GitHub" ] \
   || [ "$(git --git-dir="${bare}" rev-parse "${tip}^{tree}")" != "$(git -C "${repo}" rev-parse 'HEAD^{tree}')" ] \
   || [ "$(printf '%s\n' "${PUSH_OUT}" | grep -c 'Created signed commit')" != "3" ] \
   || [ "$(wc -l < "${TEST_TMPDIR}/local-merge-blobs" | tr -d ' ')" != "4" ]; then
  fail "merge-commit-rebuilds-local-second-parent" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "merge-commit-rebuilds-local-second-parent"
fi

# --- a ref update GitHub applied but answered with a 5xx is a success -----
repo="$(setup_repo ref-applied)"
commit_file "${repo}" "a.txt" "a" "feat: a"
FAKE_GH_REF_APPLIED_502="${TEST_TMPDIR}/ref-applied-once" push_in "${repo}" "${BRANCH}"
tip="$(remote_rev "${repo}" "refs/heads/${BRANCH}" || true)"
if [ "${PUSH_RC}" -ne 0 ] || [ ! -e "${TEST_TMPDIR}/ref-applied-once" ] || [ -z "${tip}" ] \
   || [ "$(git -C "${repo}" rev-parse HEAD)" != "${tip}" ]; then
  fail "applied-ref-update-with-5xx-succeeds" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "applied-ref-update-with-5xx-succeeds"
fi

# --- the remote moved right after the update: published, local branch left alone
repo="$(setup_repo moved-after)"
commit_file "${repo}" "a.txt" "a" "feat: a"
local_head="$(git -C "${repo}" rev-parse HEAD)"
main_sha="$(remote_rev "${repo}" "refs/heads/main")"
FAKE_GH_MOVE_AFTER_UPDATE="refs/heads/${BRANCH}=${main_sha}" push_in "${repo}" "${BRANCH}"
if [ "${PUSH_RC}" -ne 0 ] || ! printf '%s' "${PUSH_OUT}" | grep -q "warning: .* right after the update" \
   || [ "$(git -C "${repo}" rev-parse HEAD)" != "${local_head}" ] \
   || [ "$(git -C "${repo}" status --porcelain | wc -l | tr -d ' ')" != "0" ]; then
  fail "remote-moved-after-update-leaves-local-branch" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "remote-moved-after-update-leaves-local-branch"
fi

# --- the error body's detail reaches the caller ---------------------------
repo="$(setup_repo error-body)"
commit_file "${repo}" "a.txt" "a" "feat: a"
FAKE_GH_REJECT_COMMITS=1 push_in "${repo}" "${BRANCH}"
if [ "${PUSH_RC}" -eq 0 ] || ! printf '%s' "${PUSH_OUT}" | grep -q "Commits must have verified signatures." \
   || remote_rev "${repo}" "refs/heads/${BRANCH}" > /dev/null; then
  fail "error-body-detail-surfaced" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "error-body-detail-surfaced"
fi

# --- blobs GitHub already has are not uploaded again ----------------------
# Two paths with the same content, then a mode change and a rename: one
# upload in all.
repo="$(setup_repo dedup)"
bare="${repo%/repo}/remote.git"
echo "same" > "${repo}/x.txt"
echo "same" > "${repo}/y.txt"
git -C "${repo}" add -A
git -C "${repo}" commit -q -m "feat: two copies"
chmod +x "${repo}/x.txt"
git -C "${repo}" mv y.txt z.txt
git -C "${repo}" add -A
git -C "${repo}" commit -q -m "chore: mode and rename"
FAKE_GH_BLOB_LOG="${TEST_TMPDIR}/dedup-blobs" push_in "${repo}" "${BRANCH}"
tip="$(remote_rev "${repo}" "refs/heads/${BRANCH}" || true)"
if [ "${PUSH_RC}" -ne 0 ] || [ -z "${tip}" ] \
   || [ "$(git --git-dir="${bare}" rev-parse "${tip}^{tree}")" != "$(git -C "${repo}" rev-parse 'HEAD^{tree}')" ] \
   || [ "$(git --git-dir="${bare}" ls-tree "${tip}" x.txt | cut -d' ' -f1)" != "100755" ] \
   || [ "$(wc -l < "${TEST_TMPDIR}/dedup-blobs" | tr -d ' ')" != "1" ]; then
  fail "existing-blobs-not-reuploaded" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "existing-blobs-not-reuploaded"
fi

# --- a race lost at the ref update is reported as non-fast-forward --------
repo="$(setup_repo reuse)"
bare="${repo%/repo}/remote.git"
commit_file "${repo}" "a.txt" "a" "feat: a"
push_in "${repo}" "${BRANCH}"
commit_file "${repo}" "b.txt" "b" "feat: b"
# Someone else's commit, parked on a side ref for the fake to move the
# branch onto while b is being rebuilt.
seed="${repo%/repo}/seed"
git clone -q "${bare}" "${seed}"
git -C "${seed}" config user.email "other@example.com"
git -C "${seed}" config user.name "Other"
git -C "${seed}" checkout -q "${BRANCH}"
commit_file "${seed}" "theirs.txt" "theirs" "theirs"
git -C "${seed}" push -q origin "HEAD:refs/heads/theirs"
theirs="$(remote_rev "${repo}" "refs/heads/theirs")"
FAKE_GH_RACE="refs/heads/${BRANCH}=${theirs}" push_in "${repo}" "${BRANCH}"
if [ "${PUSH_RC}" -eq 0 ] || ! printf '%s' "${PUSH_OUT}" | grep -q "non-fast-forward" \
   || ! printf '%s' "${PUSH_OUT}" | grep -q "Created signed commit"; then
  fail "lost-race-reported-as-non-fast-forward" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "lost-race-reported-as-non-fast-forward"
fi

# --- an Authored-by trailer survives only on a bot-authored commit --------
# A crafted trailer in a human's commit is replaced by the human; a
# bot-authored commit keeps the trailer it came back from GitHub with.
repo="$(setup_repo trailer-owner)"
bare="${repo%/repo}/remote.git"
echo "h" > "${repo}/h.txt"
git -C "${repo}" add h.txt
git -C "${repo}" commit -q -m "feat: human" -m "Authored-by: fullsend-fix <bot@example.com>"
echo "b" > "${repo}/b.txt"
git -C "${repo}" add b.txt
GIT_AUTHOR_NAME='fullsend-ai-coder[bot]' GIT_AUTHOR_EMAIL='1+fullsend-ai-coder[bot]@users.noreply.github.com' \
  git -C "${repo}" commit -q -m "fix: rebuilt before" -m "Authored-by: fullsend-fix <bot@example.com>"
push_in "${repo}" "${BRANCH}"
tip="$(remote_rev "${repo}" "refs/heads/${BRANCH}" || true)"
trailer_of() { git --git-dir="${bare}" log -1 --format='%(trailers:key=Authored-by,valueonly)' "$1" | sed '/^$/d'; }
if [ "${PUSH_RC}" -ne 0 ] || [ -z "${tip}" ] \
   || [ "$(trailer_of "${tip}~1")" != "Test <test@example.com>" ] \
   || [ "$(trailer_of "${tip}")" != "fullsend-fix <bot@example.com>" ]; then
  fail "trailer-kept-only-for-bot-authors" "exit ${PUSH_RC}" "${PUSH_OUT}" \
    "human: $(trailer_of "${tip}~1")" "bot: $(trailer_of "${tip}")"
else
  pass "trailer-kept-only-for-bot-authors"
fi

# --- a branch with no commit on origin is refused -------------------------
repo="$(setup_repo orphan)"
git -C "${repo}" checkout -q --orphan "${BRANCH}-orphan"
git -C "${repo}" commit -q -m "orphan"
push_in "${repo}" "${BRANCH}-orphan"
if [ "${PUSH_RC}" -eq 0 ] || ! printf '%s' "${PUSH_OUT}" | grep -q "no commit on origin"; then
  fail "orphan-history-refused" "exit ${PUSH_RC}" "${PUSH_OUT}"
else
  pass "orphan-history-refused"
fi

echo
if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
