#!/usr/bin/env bash
# pre-fix-test.sh — Test pre-fix.sh input validation, iteration caps, the
# fullsend-fix-budget/N label gate, and forge merge-conflict handling.
#
# Uses mock gh, curl and git commands so no forge or network is touched.
# The git mock delegates to the real git except for `fetch`, which it
# simulates (success updates the remote-tracking ref; failure echoes the
# credentialed origin URL so token redaction can be checked).
# Run from the repo root: bash scripts/pre-fix-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"
PRE_SCRIPT="$(resolve_agent_script pre-fix "${SCRIPT_DIR}")"
FAILURES=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

MOCK_BIN="${TMPDIR}/bin"
DATA="${TMPDIR}/data"
HOME_DIR="${TMPDIR}/home"
GH_LOG="${TMPDIR}/gh-calls.log"
CURL_LOG="${TMPDIR}/curl-calls.log"
GIT_LOG="${TMPDIR}/git-calls.log"
GITHUB_PATH_FILE="${TMPDIR}/github-path"
OUT="${TMPDIR}/out.log"
TARGET_REPO="${TMPDIR}/target-repo"
ORIGIN_URL="https://github.com/test-org/test-repo.git"
PUSH_TOKEN_VALUE='fake*push?token[1]'
REAL_GIT="$(command -v git)"
mkdir -p "${MOCK_BIN}" "${DATA}" "${HOME_DIR}"

# --- Mocks ---

# Mock gh: answers `gh pr view --json <field> --jq <expr>` by building the
# JSON gh would return from ${DATA}/<field>.txt (one label per line for
# labels, else a single value; empty means null) and applying the caller's
# --jq filter, so the library's filters are exercised. Exits 1 when
# ${DATA}/<field>.fail exists.
printf '#!/usr/bin/env bash\nLOG=%q\nDATA=%q\n' "${GH_LOG}" "${DATA}" > "${MOCK_BIN}/gh"
cat >> "${MOCK_BIN}/gh" <<'MOCKEOF'
echo "gh $*" >> "${LOG}"
field=""
filter="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) field="$2"; shift 2 ;;
    --jq) filter="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "${field}" ]] || exit 0
[[ -f "${DATA}/${field}.fail" ]] && exit 1
[[ -f "${DATA}/${field}.txt" ]] || exit 0
if [[ "${field}" == "labels" ]]; then
  json="$(jq -Rn '{labels: [inputs | select(length > 0) | {name: .}]}' < "${DATA}/${field}.txt")"
else
  json="$(jq -Rn --arg f "${field}" '[inputs] as $l | {($f): (if ($l | length) == 0 or $l[0] == "" then null else $l[0] end)}' < "${DATA}/${field}.txt")"
fi
printf '%s\n' "${json}" | jq -r "${filter}"
MOCKEOF

# Mock curl (GitLab API): returns ${DATA}/mr.json, or exits 22 when
# ${DATA}/mr.fail exists.
printf '#!/usr/bin/env bash\nLOG=%q\nDATA=%q\n' "${CURL_LOG}" "${DATA}" > "${MOCK_BIN}/curl"
cat >> "${MOCK_BIN}/curl" <<'MOCKEOF'
echo "curl $*" >> "${LOG}"
[[ -f "${DATA}/mr.fail" ]] && exit 22
[[ -f "${DATA}/mr.json" ]] && cat "${DATA}/mr.json"
exit 0
MOCKEOF

# Mock git: simulate `fetch`; optionally fail setting the credentialed
# origin URL (${DATA}/git-setpush.fail) or restoring the plain one
# (${DATA}/git-restore.fail); delegate everything else.
printf '#!/usr/bin/env bash\nLOG=%q\nDATA=%q\nREAL_GIT=%q\n' \
  "${GIT_LOG}" "${DATA}" "${REAL_GIT}" > "${MOCK_BIN}/git"
cat >> "${MOCK_BIN}/git" <<'MOCKEOF'
echo "git $*" >> "${LOG}"
repo="."
[[ "${1:-}" == "-C" ]] && repo="$2"
is_fetch=false
is_set_url=false
for arg in "$@"; do
  case "${arg}" in
    fetch) is_fetch=true ;;
    set-url) is_set_url=true ;;
  esac
done
last="${*: -1}"
if [[ "${is_fetch}" == "true" ]]; then
  if [[ -f "${DATA}/git-fetch.fail" ]]; then
    echo "fatal: unable to access '$("${REAL_GIT}" -C "${repo}" remote get-url origin)/': Could not resolve host"
    exit 128
  fi
  "${REAL_GIT}" -C "${repo}" update-ref "${last#*:}" HEAD
  exit 0
fi
if [[ "${is_set_url}" == "true" && -f "${DATA}/git-setpush.fail" \
      && ( "${last}" == *x-access-token* || "${last}" == *oauth2:* ) ]]; then
  echo "error: could not lock config file" >&2
  exit 1
fi
if [[ "${is_set_url}" == "true" && -f "${DATA}/git-restore.fail" \
      && "${last}" != *x-access-token* && "${last}" != *oauth2:* ]]; then
  echo "error: could not lock config file" >&2
  exit 1
fi
exec "${REAL_GIT}" "$@"
MOCKEOF
chmod +x "${MOCK_BIN}/gh" "${MOCK_BIN}/curl" "${MOCK_BIN}/git"

# --- Helpers ---

CASE=""
CASE_FAILED=0

fail() {
  echo "FAIL: ${CASE} — $*"
  CASE_FAILED=1
}

# reset_data — clear mock responses; GitHub PR defaults to a mergeable PR
# on main with no labels.
reset_data() {
  rm -rf "${DATA}"
  mkdir -p "${DATA}"
  printf 'main\n' > "${DATA}/baseRefName.txt"
  printf 'MERGEABLE\n' > "${DATA}/mergeable.txt"
  : > "${DATA}/labels.txt"
}

# make_target_repo — fresh checkout at ${TARGET_REPO} with origin set.
make_target_repo() {
  rm -rf "${TARGET_REPO}"
  "${REAL_GIT}" init -q "${TARGET_REPO}"
  "${REAL_GIT}" -C "${TARGET_REPO}" -c user.name=test -c user.email=test@example.com \
    -c commit.gpgsign=false commit -q --allow-empty -m init
  "${REAL_GIT}" -C "${TARGET_REPO}" remote add origin "${ORIGIN_URL}"
}

# run_pre_fix NAME EXPECTED_EXIT [VAR=value ...] — run pre-fix with a clean
# environment (GitHub bot run on test-org/test-repo#42 by default; later
# VAR=value arguments override the defaults).
run_pre_fix() {
  CASE="$1"
  CASE_FAILED=0
  local expected="$2"
  shift 2
  : > "${GH_LOG}"
  : > "${CURL_LOG}"
  : > "${GIT_LOG}"
  : > "${GITHUB_PATH_FILE}"
  local rc=0
  env -i \
    PATH="${MOCK_BIN}:${PATH}" \
    HOME="${HOME_DIR}" \
    GITHUB_PATH="${GITHUB_PATH_FILE}" \
    GH_TOKEN="fake-gh-token" \
    GITLAB_TOKEN="fake-gitlab-token" \
    FULLSEND_FORGE="github" \
    PR_NUMBER="42" \
    REPO_FULL_NAME="test-org/test-repo" \
    TRIGGER_SOURCE="fullsend-ai-review[bot]" \
    REPO_DIR="${TMPDIR}/no-such-repo" \
    "$@" \
    bash "${PRE_SCRIPT}" > "${OUT}" 2>&1 || rc=$?
  if [[ "${rc}" -ne "${expected}" ]]; then
    fail "exit code ${rc}, expected ${expected}"
  fi
}

expect_out() {
  grep -qF -- "$1" "${OUT}" || fail "output missing '$1'"
}

expect_no_out() {
  if grep -qF -- "$1" "${OUT}"; then fail "output unexpectedly contains '$1'"; fi
}

expect_log() {
  grep -qF -- "$2" "$1" || fail "$(basename "$1") missing '$2'"
}

expect_no_log() {
  if grep -qF -- "$2" "$1"; then fail "$(basename "$1") unexpectedly contains '$2'"; fi
}

expect_no_forge_calls() {
  [[ -s "${GH_LOG}" ]] && fail "gh was called: $(cat "${GH_LOG}")"
  [[ -s "${CURL_LOG}" ]] && fail "curl was called: $(cat "${CURL_LOG}")"
  return 0
}

expect_origin_url() {
  local actual
  actual="$("${REAL_GIT}" -C "${TARGET_REPO}" remote get-url origin)"
  [[ "${actual}" == "$1" ]] || fail "origin URL is '${actual}', expected '$1'"
}

finish() {
  if [[ "${CASE_FAILED}" -eq 0 ]]; then
    echo "PASS: ${CASE}"
  else
    FAILURES=$((FAILURES + 1))
    echo "--- output (${CASE}) ---"
    cat "${OUT}"
  fi
}

# =====================================================================
# Input validation (GitHub)
# =====================================================================

reset_data

run_pre_fix "unset-forge-fails" 1 FULLSEND_FORGE=
expect_out "FULLSEND_FORGE is required"
expect_no_forge_calls
finish

run_pre_fix "invalid-forge-fails" 1 FULLSEND_FORGE=bitbucket
expect_out "invalid FULLSEND_FORGE"
expect_no_forge_calls
finish

for bad_pr in "" "0" "042" "abc" "1;rm"; do
  run_pre_fix "invalid-pr-number-'${bad_pr}'-fails" 1 PR_NUMBER="${bad_pr}"
  expect_out "PR_NUMBER must be a positive integer"
  expect_out "Input validation failed with 1 error(s)"
  expect_no_forge_calls
  finish
done

for bad_repo in "" "no-slash" "a/b/c" "org/repo name"; do
  run_pre_fix "invalid-repo-'${bad_repo}'-fails" 1 REPO_FULL_NAME="${bad_repo}"
  expect_out "REPO_FULL_NAME must be owner/repo format"
  expect_no_forge_calls
  finish
done

run_pre_fix "repo-dot-segment-fails" 1 REPO_FULL_NAME="../test-repo"
expect_out "must not contain '.' or '..' path segments"
expect_no_forge_calls
finish

run_pre_fix "empty-trigger-source-fails" 1 TRIGGER_SOURCE=
expect_out "TRIGGER_SOURCE is required"
expect_no_forge_calls
finish

run_pre_fix "multiple-validation-errors-counted" 1 PR_NUMBER=x REPO_FULL_NAME=bad TRIGGER_SOURCE=
expect_out "Input validation failed with 3 error(s)"
expect_no_forge_calls
finish

printf -v oversized '%*s' 10001 ''
oversized="${oversized// /x}"
run_pre_fix "human-instruction-too-long-fails" 1 TRIGGER_SOURCE=alice HUMAN_INSTRUCTION="${oversized}"
expect_out "HUMAN_INSTRUCTION is 10001 bytes (max: 10000)"
expect_no_forge_calls
finish

# The length cap applies to human runs only; a bot run ignores the field.
run_pre_fix "bot-oversized-instruction-ignored" 0 HUMAN_INSTRUCTION="${oversized}"
expect_no_out "HUMAN_INSTRUCTION is"
finish

# =====================================================================
# Success and iteration caps (GitHub)
# =====================================================================

reset_data
run_pre_fix "github-bot-success" 0
expect_out "Input validation passed:"
expect_out "FIX_ITERATION=1 of 5"
expect_out "base_branch=main"
expect_out "merge_state=MERGEABLE"
expect_out "conflict=false"
expect_out "strategy=merge"
expect_log "${GH_LOG}" "gh pr view 42 --repo test-org/test-repo --json labels"
expect_log "${GH_LOG}" "gh pr view 42 --repo test-org/test-repo --json baseRefName"
expect_log "${GH_LOG}" "gh pr view 42 --repo test-org/test-repo --json mergeable"
expect_no_log "${GIT_LOG}" "fetch"
expect_log "${GITHUB_PATH_FILE}" "${HOME_DIR}/.local/bin"
finish

run_pre_fix "github-human-success-shows-instruction" 0 \
  TRIGGER_SOURCE=alice HUMAN_INSTRUCTION="please fix the lint error"
expect_out "TRIGGER_SOURCE=alice"
expect_out "FIX_ITERATION=1 of 10"
expect_out "HUMAN_INSTRUCTION=please fix the lint error..."
expect_no_log "${GH_LOG}" "--json labels"
finish

run_pre_fix "bot-at-cap-passes" 0 FIX_ITERATION=5
expect_out "FIX_ITERATION=5 of 5"
finish

run_pre_fix "bot-over-cap-fails" 1 FIX_ITERATION=6
expect_out "Fix iteration 6 exceeds bot cap of 5. Escalating to human."
expect_out "up to 10 total iterations"
expect_no_log "${GH_LOG}" "--json mergeable"
finish

run_pre_fix "bot-custom-cap-fails" 1 FIX_ITERATION=3 ITERATION_CAP=2
expect_out "exceeds bot cap of 2"
finish

run_pre_fix "human-at-cap-passes" 0 TRIGGER_SOURCE=alice FIX_ITERATION=10
expect_out "FIX_ITERATION=10 of 10"
finish

run_pre_fix "human-over-cap-fails" 1 TRIGGER_SOURCE=alice FIX_ITERATION=11
expect_out "Fix iteration 11 exceeds human cap of 10."
finish

run_pre_fix "human-custom-cap-fails" 1 TRIGGER_SOURCE=alice FIX_ITERATION=4 ITERATION_CAP_HUMAN=3
expect_out "exceeds human cap of 3"
finish

# =====================================================================
# fullsend-fix-budget/N label gate (GitHub)
# =====================================================================

reset_data
printf 'bug\nfullsend-fix-budget/2\n' > "${DATA}/labels.txt"

run_pre_fix "budget-label-lowers-bot-cap" 0 FIX_ITERATION=2
expect_out "Label fullsend-fix-budget/2 lowers the automatic fix cap from 5 to 2"
expect_out "FIX_ITERATION=2 of 2"
finish

run_pre_fix "budget-label-blocks-bot-run" 1 FIX_ITERATION=3
expect_out "Fix iteration 3 exceeds the per-PR automatic fix budget of 2 set by label fullsend-fix-budget/2."
expect_log "${GH_LOG}" "--json labels"
finish

run_pre_fix "budget-label-ignored-for-human" 0 TRIGGER_SOURCE=alice FIX_ITERATION=3
expect_out "FIX_ITERATION=3 of 10"
expect_no_log "${GH_LOG}" "--json labels"
finish

printf 'fullsend-fix-budget/9\n' > "${DATA}/labels.txt"
run_pre_fix "budget-label-never-raises-cap" 1 FIX_ITERATION=6
expect_out "exceeds bot cap of 5"
expect_no_out "lowers the automatic fix cap"
finish

rm -f "${DATA}/labels.txt"
touch "${DATA}/labels.fail"
run_pre_fix "label-read-failure-uses-bot-cap" 0 FIX_ITERATION=5
expect_out "Could not read PR labels"
expect_out "FIX_ITERATION=5 of 5"
finish

# =====================================================================
# Base branch and merge-state reads (GitHub)
# =====================================================================

reset_data
touch "${DATA}/baseRefName.fail"
run_pre_fix "base-branch-read-failure-uses-target-branch" 0 TARGET_BRANCH=develop
expect_out "Could not read PR/MR base branch from forge — using develop"
expect_out "base_branch=develop"
finish

run_pre_fix "base-branch-read-failure-defaults-main" 0
expect_out "using main"
finish

reset_data
touch "${DATA}/mergeable.fail"
run_pre_fix "merge-state-read-failure-is-not-conflict" 0
expect_out "merge_state=unknown"
expect_out "conflict=false"
finish

reset_data
: > "${DATA}/mergeable.txt"
run_pre_fix "empty-merge-state-is-unknown" 0
expect_out "merge_state=unknown"
expect_out "conflict=false"
finish

reset_data
run_pre_fix "unknown-strategy-warns-and-defaults-merge" 0 FIX_CONFLICT_UPDATE_STRATEGY=squash
expect_out "Unknown FIX_CONFLICT_UPDATE_STRATEGY='squash' — defaulting to merge"
expect_out "strategy=merge"
finish

run_pre_fix "rebase-strategy-reported" 0 FIX_CONFLICT_UPDATE_STRATEGY=REBASE
expect_no_out "Unknown FIX_CONFLICT_UPDATE_STRATEGY"
expect_out "strategy=rebase"
finish

# =====================================================================
# Merge-conflict path and push-remote setup (GitHub)
# =====================================================================

reset_data
printf 'release-1\n' > "${DATA}/baseRefName.txt"
printf 'CONFLICTING\n' > "${DATA}/mergeable.txt"

make_target_repo
run_pre_fix "conflict-fetches-pr-base-branch" 0 REPO_DIR="${TARGET_REPO}"
expect_out "conflict=true"
expect_out "Fetching latest target branch release-1 for conflict reconciliation..."
expect_out "Fetched origin/release-1 ($("${REAL_GIT}" -C "${TARGET_REPO}" rev-parse HEAD))"
expect_log "${GIT_LOG}" "fetch origin +refs/heads/release-1:refs/remotes/origin/release-1"
expect_no_log "${GIT_LOG}" "set-url"
expect_origin_url "${ORIGIN_URL}"
finish

make_target_repo
run_pre_fix "conflict-with-push-token-restores-origin" 0 \
  REPO_DIR="${TARGET_REPO}" PUSH_TOKEN="${PUSH_TOKEN_VALUE}"
expect_out "Fetched origin/release-1"
expect_log "${GIT_LOG}" "remote set-url origin https://x-access-token:${PUSH_TOKEN_VALUE}@github.com/test-org/test-repo.git"
expect_log "${GIT_LOG}" "remote set-url origin ${ORIGIN_URL}"
expect_origin_url "${ORIGIN_URL}"
finish

make_target_repo
touch "${DATA}/git-fetch.fail"
run_pre_fix "conflict-fetch-failure-redacts-token" 0 \
  REPO_DIR="${TARGET_REPO}" PUSH_TOKEN="${PUSH_TOKEN_VALUE}"
expect_out "Could not fetch target branch release-1"
expect_out "https://x-access-token:[REDACTED]@github.com/test-org/test-repo.git"
expect_no_out "${PUSH_TOKEN_VALUE}"
expect_origin_url "${ORIGIN_URL}"
finish
rm -f "${DATA}/git-fetch.fail"

make_target_repo
touch "${DATA}/git-restore.fail"
run_pre_fix "conflict-origin-restore-failure-aborts" 1 \
  REPO_DIR="${TARGET_REPO}" PUSH_TOKEN="${PUSH_TOKEN_VALUE}"
expect_out "Could not restore original origin URL"
expect_no_log "${GITHUB_PATH_FILE}" ".local/bin"
finish
rm -f "${DATA}/git-restore.fail"

make_target_repo
run_pre_fix "conflict-masks-push-token-on-actions" 0 \
  REPO_DIR="${TARGET_REPO}" PUSH_TOKEN="${PUSH_TOKEN_VALUE}" GITHUB_ACTIONS=true
expect_out "::add-mask::${PUSH_TOKEN_VALUE}"
expect_origin_url "${ORIGIN_URL}"
finish

make_target_repo
touch "${DATA}/git-setpush.fail"
run_pre_fix "conflict-set-push-remote-failure-warns" 0 \
  REPO_DIR="${TARGET_REPO}" PUSH_TOKEN="${PUSH_TOKEN_VALUE}"
expect_out "Could not set authenticated origin URL before fetching release-1"
expect_log "${GIT_LOG}" "fetch origin +refs/heads/release-1:refs/remotes/origin/release-1"
expect_no_log "${GIT_LOG}" "remote set-url origin ${ORIGIN_URL}"
expect_origin_url "${ORIGIN_URL}"
finish
rm -f "${DATA}/git-setpush.fail"

run_pre_fix "conflict-without-target-repo-warns" 0
expect_out "conflict=true"
expect_out "Target repo not found at ${TMPDIR}/no-such-repo — skipping target-branch fetch"
expect_no_log "${GIT_LOG}" "fetch"
finish

# =====================================================================
# GitLab: PR_URL validation, label gate, merge conflict
# =====================================================================

GL_HOST="gitlab.example.com"
GL_URL="https://${GL_HOST}/group/sub/project/-/merge_requests/7"
GL_ENV=(FULLSEND_FORGE=gitlab CI_SERVER_HOST="${GL_HOST}" PR_URL="${GL_URL}"
  REPO_FULL_NAME=group/sub/project PR_NUMBER=7 TRIGGER_SOURCE=project_7_bot)

reset_data
printf '{"target_branch":"main","detailed_merge_status":"mergeable","labels":["bug"]}' > "${DATA}/mr.json"

run_pre_fix "gitlab-pr-url-missing-fails" 1 "${GL_ENV[@]}" PR_URL=
expect_out "PR_URL is required for GitLab forge"
expect_no_forge_calls
finish

run_pre_fix "gitlab-pr-url-untrusted-host-fails" 1 "${GL_ENV[@]}" \
  PR_URL="https://evil.example/group/sub/project/-/merge_requests/7"
expect_out "PR_URL format/host invalid"
expect_out "does not match CI_SERVER_HOST"
expect_no_forge_calls
finish

run_pre_fix "gitlab-pr-url-malformed-fails" 1 "${GL_ENV[@]}" \
  PR_URL="https://${GL_HOST}/group/sub/project/merge_requests/7"
expect_out "PR_URL format/host invalid"
expect_no_forge_calls
finish

run_pre_fix "gitlab-repo-mismatch-fails" 1 "${GL_ENV[@]}" REPO_FULL_NAME=group/other
expect_out "REPO_FULL_NAME does not match PR URL repo ('group/other' vs 'group/sub/project')"
expect_no_forge_calls
finish

run_pre_fix "gitlab-pr-number-mismatch-fails" 1 "${GL_ENV[@]}" PR_NUMBER=8
expect_out "PR_NUMBER does not match PR URL number ('8' vs '7')"
expect_no_forge_calls
finish

run_pre_fix "gitlab-bot-success" 0 "${GL_ENV[@]}"
expect_out "Input validation passed:"
expect_out "FIX_ITERATION=1 of 5"
expect_out "merge_state=mergeable"
expect_out "conflict=false"
expect_log "${CURL_LOG}" "https://${GL_HOST}/api/v4/projects/group%2Fsub%2Fproject/merge_requests/7"
expect_no_log "${GH_LOG}" "gh"
expect_log "${GITHUB_PATH_FILE}" "${HOME_DIR}/.local/bin"
finish

printf '{"target_branch":"main","detailed_merge_status":"mergeable","labels":["fullsend-fix-budget/1"]}' > "${DATA}/mr.json"
run_pre_fix "gitlab-budget-label-blocks-bot-run" 1 "${GL_ENV[@]}" FIX_ITERATION=2
expect_out "per-PR automatic fix budget of 1 set by label fullsend-fix-budget/1"
finish

printf '{"target_branch":"release-2","detailed_merge_status":"conflict","labels":[]}' > "${DATA}/mr.json"
make_target_repo
"${REAL_GIT}" -C "${TARGET_REPO}" remote set-url origin "https://${GL_HOST}/group/sub/project.git"
run_pre_fix "gitlab-conflict-fetches-and-restores-origin" 0 "${GL_ENV[@]}" \
  REPO_DIR="${TARGET_REPO}" PUSH_TOKEN="${PUSH_TOKEN_VALUE}"
expect_out "base_branch=release-2"
expect_out "conflict=true"
expect_out "Fetched origin/release-2"
expect_log "${GIT_LOG}" "remote set-url origin https://oauth2:${PUSH_TOKEN_VALUE}@${GL_HOST}/group/sub/project.git"
expect_origin_url "https://${GL_HOST}/group/sub/project.git"
finish

reset_data
touch "${DATA}/mr.fail"
run_pre_fix "gitlab-api-failure-not-conflict" 0 "${GL_ENV[@]}" FIX_ITERATION=5
expect_out "Could not read PR labels"
expect_out "Could not read PR/MR base branch from forge — using main"
expect_out "merge_state=unknown"
expect_out "conflict=false"
finish

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
