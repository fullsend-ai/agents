#!/usr/bin/env bash
# pre-review-test.sh — Test pre-review.sh author-skip and input-validation logic.
#
# Uses a mock gh command to capture calls without hitting GitHub.
# Run from the repo root: bash scripts/pre-review-test.sh

set -euo pipefail

FAILURES=0

# Create a temp directory for mock state.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# --- Mock builder ---

# build_mock creates a mock gh binary that returns preconfigured responses.
# Arguments:
#   $1 — PR state to return for "gh pr view ... --json state" (e.g. OPEN, MERGED)
#   $2 — PR author login to return for "gh pr view ... --json author"
build_mock() {
  local pr_state="$1"
  local pr_author="$2"
  local mock_bin="${TMPDIR}/bin"
  local gh_log="${TMPDIR}/gh-calls.log"

  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"
  : > "${gh_log}"

  # Write mock data files for the gh mock to read.
  printf '%s' "${pr_state}" > "${TMPDIR}/pr-state.txt"
  printf '%s' "${pr_author}" > "${TMPDIR}/pr-author.txt"

  cat > "${mock_bin}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
CALL_LOG="LOGFILE_PLACEHOLDER"
DATA_DIR="DATADIR_PLACEHOLDER"

echo "gh $*" >> "${CALL_LOG}"

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  # Determine which --json field was requested and find --jq expression.
  JSON_FIELD=""
  JQ_EXPR=""
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) JSON_FIELD="$2"; shift 2 ;;
      --jq)  JQ_EXPR="$2"; shift 2 ;;
      *)     shift ;;
    esac
  done

  # Build the appropriate JSON response.
  PR_STATE="$(cat "${DATA_DIR}/pr-state.txt")"
  PR_AUTHOR="$(cat "${DATA_DIR}/pr-author.txt")"

  case "${JSON_FIELD}" in
    state)
      RESPONSE="{\"state\":\"${PR_STATE}\"}"
      ;;
    author)
      RESPONSE="{\"author\":{\"login\":\"${PR_AUTHOR}\"}}"
      ;;
    *)
      RESPONSE="{}"
      ;;
  esac

  if [[ -n "${JQ_EXPR}" ]]; then
    echo "${RESPONSE}" | jq -r "${JQ_EXPR}"
  else
    echo "${RESPONSE}"
  fi
  exit 0
elif [[ "$1" == "issue" && "$2" == "comment" ]]; then
  cat > /dev/null
  exit 0
fi
MOCKEOF

  # Patch placeholders with actual paths.
  local escaped_log="${gh_log//\//\\/}"
  local escaped_dir="${TMPDIR//\//\\/}"
  perl -pi -e "s/LOGFILE_PLACEHOLDER/${escaped_log}/g" "${mock_bin}/gh"
  perl -pi -e "s/DATADIR_PLACEHOLDER/${escaped_dir}/g" "${mock_bin}/gh"

  chmod +x "${mock_bin}/gh"
  echo "${mock_bin}"
}

# --- Test helpers ---

run_test_stdout() {
  local test_name="$1"
  local pr_state="$2"
  local pr_author="$3"
  local expected_stdout="$4"
  local expect_exit="$5"
  local extra_env="${6:-}"

  local mock_bin
  mock_bin="$(build_mock "${pr_state}" "${pr_author}")"

  local env_cmd=(
    env
    PATH="${mock_bin}:${PATH}"
    PR_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    PR_URL="https://github.com/test-org/test-repo/pull/42"
    FULLSEND_FORGE="github"
    REVIEW_TOKEN="fake-token"
    GH_TOKEN="fake-token"
  )

  # Add extra env vars if provided.
  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${SCRIPT_DIR}/pre-review.sh" \
    > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log" 2>/dev/null; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Check that gh calls contain a specific pattern.
run_test_gh_call() {
  local test_name="$1"
  local pr_state="$2"
  local pr_author="$3"
  local expected_pattern="$4"
  local expect_exit="$5"
  local extra_env="${6:-}"

  local mock_bin
  mock_bin="$(build_mock "${pr_state}" "${pr_author}")"
  local gh_log="${TMPDIR}/gh-calls.log"

  local env_cmd=(
    env
    PATH="${mock_bin}:${PATH}"
    PR_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    PR_URL="https://github.com/test-org/test-repo/pull/42"
    FULLSEND_FORGE="github"
    REVIEW_TOKEN="fake-token"
    GH_TOKEN="fake-token"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${SCRIPT_DIR}/pre-review.sh" \
    > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_pattern}" "${gh_log}" 2>/dev/null; then
    echo "FAIL: ${test_name} — expected gh call pattern '${expected_pattern}' not found"
    echo "Actual calls:"
    cat "${gh_log}" 2>/dev/null || echo "(no calls)"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# Check that gh calls do NOT contain a specific pattern.
run_test_no_gh_call() {
  local test_name="$1"
  local pr_state="$2"
  local pr_author="$3"
  local forbidden_pattern="$4"
  local expect_exit="$5"
  local extra_env="${6:-}"

  local mock_bin
  mock_bin="$(build_mock "${pr_state}" "${pr_author}")"
  local gh_log="${TMPDIR}/gh-calls.log"

  local env_cmd=(
    env
    PATH="${mock_bin}:${PATH}"
    PR_NUMBER="42"
    REPO_FULL_NAME="test-org/test-repo"
    PR_URL="https://github.com/test-org/test-repo/pull/42"
    FULLSEND_FORGE="github"
    REVIEW_TOKEN="fake-token"
    GH_TOKEN="fake-token"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${SCRIPT_DIR}/pre-review.sh" \
    > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if grep -qF "${forbidden_pattern}" "${gh_log}" 2>/dev/null; then
    echo "FAIL: ${test_name} — forbidden gh call pattern '${forbidden_pattern}' was found"
    echo "Actual calls:"
    cat "${gh_log}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Test cases ---

# 1. Author in skip list → exit 0, skip notice
run_test_stdout "skip-renovate-bot" \
  "OPEN" "app/renovate" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate,app/dependabot"

# 2. Different bot in skip list → exit 0, skip notice
run_test_stdout "skip-dependabot" \
  "OPEN" "app/dependabot" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate,app/dependabot"

# 3. Author NOT in skip list → review proceeds
run_test_stdout "no-skip-human-author" \
  "OPEN" "some-human" \
  "proceeding with review agent" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# 4. REVIEW_SKIP_AUTHORS unset → no skip, review proceeds for any author
run_test_stdout "unset-skip-authors-proceeds" \
  "OPEN" "app/renovate" \
  "proceeding with review agent" \
  0

# 5. REVIEW_SKIP_AUTHORS empty → no skip, review proceeds
run_test_stdout "empty-skip-authors-proceeds" \
  "OPEN" "app/renovate" \
  "proceeding with review agent" \
  0 \
  "REVIEW_SKIP_AUTHORS="

# 6. Custom bot name in skip list → exit 0
run_test_stdout "skip-custom-bot" \
  "OPEN" "custom-bot" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=custom-bot"

# 7. Whitespace around entries → still matches after trimming
run_test_stdout "skip-with-whitespace" \
  "OPEN" "app/renovate" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS= app/renovate , app/dependabot "

# 8. Skip posts a comment
run_test_gh_call "skip-posts-comment" \
  "OPEN" "app/renovate" \
  "gh issue comment 42 --repo test-org/test-repo --body-file -" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# 9. Non-matching author does not trigger author fetch for comment
run_test_stdout "no-skip-different-author" \
  "OPEN" "other-user" \
  "proceeding with review agent" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate,app/dependabot"

# 10. PR state check still works — merged PR skips before author check
run_test_stdout "merged-pr-skips-before-author-check" \
  "MERGED" "app/renovate" \
  "skipping review" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# 11. Single author in skip list works
run_test_stdout "single-author-skip-list" \
  "OPEN" "app/dependabot" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/dependabot"

# 12. Case-insensitive matching — GitHub usernames are case-insensitive
run_test_stdout "case-insensitive-skip" \
  "OPEN" "App/Renovate" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# ---------------------------------------------------------------------------
# GitLab forge pre-review tests
# ---------------------------------------------------------------------------

build_gitlab_mock() {
  local mr_state="$1"
  local mr_author="$2"
  local mock_bin="${TMPDIR}/bin-gitlab"
  local call_log="${TMPDIR}/curl-calls.log"

  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"
  : > "${call_log}"

  printf '%s' "${mr_state}" > "${TMPDIR}/mr-state.txt"
  printf '%s' "${mr_author}" > "${TMPDIR}/mr-author.txt"

  cat > "${mock_bin}/curl" <<MOCKEOF
#!/usr/bin/env bash
CALL_LOG="${call_log}"
echo "curl \$*" >> "\${CALL_LOG}"

URL=""
METHOD="GET"
PREV=""
for arg in "\$@"; do
  case "\${arg}" in
    https://*) URL="\${arg}" ;;
  esac
  if [[ "\${PREV}" == "--request" ]] || [[ "\${PREV}" == "-X" ]]; then
    METHOD="\${arg}"
  fi
  PREV="\${arg}"
done

# POST /notes → success (skip comment)
if [[ "\${METHOD}" == "POST" ]]; then
  echo '{"id":1}'
  exit 0
fi

# GET /merge_requests/:iid → MR metadata
if [[ "\${URL}" == *"/merge_requests/"* ]]; then
  MR_STATE=\$(cat "${TMPDIR}/mr-state.txt")
  MR_AUTHOR=\$(cat "${TMPDIR}/mr-author.txt")
  echo "{\"state\":\"\${MR_STATE}\",\"draft\":false,\"author\":{\"username\":\"\${MR_AUTHOR}\"},\"iid\":42}"
  exit 0
fi

exit 0
MOCKEOF

  chmod +x "${mock_bin}/curl"
  echo "${mock_bin}"
}

run_gitlab_test_stdout() {
  local test_name="$1"
  local mr_state="$2"
  local mr_author="$3"
  local expected_stdout="$4"
  local expect_exit="$5"
  local extra_env="${6:-}"

  local mock_bin
  mock_bin="$(build_gitlab_mock "${mr_state}" "${mr_author}")"

  local env_cmd=(
    env
    PATH="${mock_bin}:${PATH}"
    PR_NUMBER="42"
    REPO_FULL_NAME="test-group/test-project"
    PR_URL="https://gitlab.com/test-group/test-project/-/merge_requests/42"
    FULLSEND_FORGE="gitlab"
    REVIEW_TOKEN="fake-gitlab-token"
    CI_SERVER_HOST="gitlab.com"
  )

  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  local exit_code=0
  "${env_cmd[@]}" bash "${SCRIPT_DIR}/pre-review.sh" \
    > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log" 2>/dev/null; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    echo "Actual stdout:"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

# GitLab: open MR proceeds with review
run_gitlab_test_stdout "gitlab-open-mr-proceeds" \
  "opened" "some-user" \
  "proceeding with review agent" \
  0

# GitLab: merged MR skips review
run_gitlab_test_stdout "gitlab-merged-mr-skips" \
  "merged" "some-user" \
  "skipping review" \
  0

# GitLab: author in skip list → skip
run_gitlab_test_stdout "gitlab-skip-bot-author" \
  "opened" "app/renovate" \
  "skipping review (REVIEW_SKIP_AUTHORS)" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# GitLab: author NOT in skip list → proceed
run_gitlab_test_stdout "gitlab-no-skip-human" \
  "opened" "some-human" \
  "proceeding with review agent" \
  0 \
  "REVIEW_SKIP_AUTHORS=app/renovate"

# GitLab: invalid URL pattern rejected
run_gitlab_test_stdout "gitlab-invalid-url-rejected" \
  "opened" "some-user" \
  "ERROR: PR_URL does not match expected GitLab MR pattern" \
  1 \
  "PR_URL=https://gitlab.com/group/project/pull/42"

# GitLab: disallowed host rejected
run_gitlab_test_stdout "gitlab-disallowed-host-rejected" \
  "opened" "some-user" \
  "ERROR: GitLab host" \
  1 \
  "PR_URL=https://gitlab.evil.com/group/project/-/merge_requests/42"

# GitLab: no token → skip state check, proceed
run_gitlab_test_stdout "gitlab-no-token-proceeds" \
  "opened" "some-user" \
  "No token available" \
  0 \
  "REVIEW_TOKEN="

# --- Clone-deepening tests (risk assessment Tier 2) ---
#
# These build a real local repo pair (working clone + bare "remote") so the
# actual `git fetch --unshallow --filter=blob:none origin` in pre-review.sh
# runs offline. Stubbing git was rejected deliberately: what these tests need
# to assert is the state of the resulting clone (still shallow? blobless?
# rename detection off?), which a stub cannot produce.

# build_deepen_repo creates ${TMPDIR}/deepen/target-repo as a depth-1 clone of
# a local bare repo whose history contains a rename, and echoes its path.
build_deepen_repo() {
  local root="${TMPDIR}/deepen"
  rm -rf "${root}"
  mkdir -p "${root}"
  (
    set -e
    git init -q -b main "${root}/src"
    cd "${root}/src"
    git config user.email "test@example.com"
    git config user.name "Test User"
    local i
    for i in 1 2 3; do
      printf 'line%s\n%s\n' "${i}" "$(seq 1 40 | tr '\n' ' ')" > "file${i}.txt"
      git add -A
      git commit -qm "commit ${i}"
    done
    # A rename *plus* a content edit is what makes a blobless clone lazily
    # fetch blobs: exact renames are detected from the blob hash alone, so
    # only inexact (similarity) detection has to read content. Renaming
    # without editing would make this fixture pass no matter what.
    git mv file1.txt renamed1.txt
    printf 'CHANGED HEADER\n%s\nextra tail line\n' "$(seq 1 34 | tr '\n' ' ')" > renamed1.txt
    git add -A
    git commit -qm "rename and modify file1"
    cd "${root}"
    git clone -q --bare src bare.git
    # Partial clone is served only when the remote opts in.
    git -C bare.git config uploadpack.allowFilter true
    git clone -q --depth=1 "file://${root}/bare.git" target-repo
  ) >/dev/null 2>&1
  echo "${root}/target-repo"
}

# run_deepen_test runs pre-review.sh with REPO_DIR pointed at a fixture clone.
# Arguments:
#   $1 — test name
#   $2 — expected stdout substring
#   $3 — REPO_DIR value
#   $4+ — extra KEY=VALUE environment entries
run_deepen_test() {
  local test_name="$1"
  local expected_stdout="$2"
  local repo_dir="$3"
  shift 3

  local mock_bin
  mock_bin="$(build_mock "OPEN" "human-author")"

  local exit_code=0
  env \
    PATH="${mock_bin}:${PATH}" \
    PR_NUMBER="42" \
    REPO_FULL_NAME="test-org/test-repo" \
    PR_URL="https://github.com/test-org/test-repo/pull/42" \
    FULLSEND_FORGE="github" \
    REVIEW_TOKEN="fake..." \
    GH_TOKEN="fake..." \
    REPO_DIR="${repo_dir}" \
    REVIEW_RISK_ASSESSMENT_ENABLED="true" \
    "$@" \
    bash "${SCRIPT_DIR}/pre-review.sh" > "${TMPDIR}/stdout.log" 2>&1 || exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected exit 0, got ${exit_code}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log" 2>/dev/null; then
    echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  echo "PASS: ${test_name}"
  return 0
}

# check_repo_state asserts a git config/state value on the fixture clone.
check_repo_state() {
  local test_name="$1"
  local actual="$2"
  local expected="$3"

  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL: ${test_name} — expected '${expected}', got '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${test_name}"
}

# Happy path: shallow clone is deepened, blobless, with renames disabled.
DEEPEN_REPO="$(build_deepen_repo)"
if run_deepen_test "deepen-shallow-clone" \
  "Clone deepened successfully" \
  "${DEEPEN_REPO}"; then

  check_repo_state "deepen-clears-shallow" \
    "$(git -C "${DEEPEN_REPO}" rev-parse --is-shallow-repository)" "false"

  check_repo_state "deepen-full-history" \
    "$(git -C "${DEEPEN_REPO}" rev-list --count HEAD)" "4"

  check_repo_state "deepen-applies-blob-filter" \
    "$(git -C "${DEEPEN_REPO}" config --get remote.origin.partialclonefilter)" "blob:none"

  # The point of the whole exercise: Tier 2's change-coupling command must
  # run offline on a commit containing a rename. Break the promisor remote
  # first so any lazy blob fetch fails loudly instead of silently working.
  git -C "${DEEPEN_REPO}" remote set-url origin "file:///nonexistent/gone.git"

  check_repo_state "deepen-disables-rename-detection" \
    "$(git -C "${DEEPEN_REPO}" config --get diff.renames)" "false"

  RENAME_COMMIT="$(git -C "${DEEPEN_REPO}" log --format=%H -1)"

  # Negative control: with rename detection on, the same commit *does* need a
  # blob it cannot get. This is what the diff.renames=false line in
  # pre-review.sh prevents — if that line is dropped, the assertions below
  # stop being vacuous and start failing.
  RENAME_ERRS="$(git -C "${DEEPEN_REPO}" -c diff.renames=true show --name-only \
    --format= "${RENAME_COMMIT}" 2>&1 | grep -ciE 'fatal|could not' || true)"
  check_repo_state "deepen-rename-detection-would-need-network" \
    "$([[ "${RENAME_ERRS}" -gt 0 ]] && echo "needs-network" || echo "offline")" \
    "needs-network"

  COUPLING_OUT="$(git -C "${DEEPEN_REPO}" diff-tree -r --no-commit-id --name-only \
    --no-renames "${RENAME_COMMIT}" 2>&1)"
  check_repo_state "deepen-coupling-command-needs-no-blobs" \
    "$(printf '%s' "${COUPLING_OUT}" | grep -ciE 'fatal|could not fetch')" "0"
  check_repo_state "deepen-coupling-command-names-both-paths" \
    "$(printf '%s\n' "${COUPLING_OUT}" | sort | tr '\n' ' ')" "file1.txt renamed1.txt "
fi

# Explicit REVIEW_GIT_FETCH_DEPTH wins over the risk-assessment auto-default.
DEEPEN_REPO_2="$(build_deepen_repo)"
if run_deepen_test "no-deepen-when-depth-explicitly-set" \
  "proceeding with review agent" \
  "${DEEPEN_REPO_2}" \
  REVIEW_GIT_FETCH_DEPTH="1"; then

  check_repo_state "explicit-depth-leaves-clone-shallow" \
    "$(git -C "${DEEPEN_REPO_2}" rev-parse --is-shallow-repository)" "true"
fi

# Risk assessment disabled — no deepening, no warning.
DEEPEN_REPO_3="$(build_deepen_repo)"
if run_deepen_test "no-deepen-when-risk-assessment-disabled" \
  "proceeding with review agent" \
  "${DEEPEN_REPO_3}" \
  REVIEW_RISK_ASSESSMENT_ENABLED="false"; then

  check_repo_state "disabled-risk-leaves-clone-shallow" \
    "$(git -C "${DEEPEN_REPO_3}" rev-parse --is-shallow-repository)" "true"
fi

# Unreachable remote — the script warns and still exits 0, leaving the clone
# shallow so the Tier 2 sub-agent detects the degraded state itself.
DEEPEN_REPO_4="$(build_deepen_repo)"
git -C "${DEEPEN_REPO_4}" remote set-url origin "file:///nonexistent/gone.git"
if run_deepen_test "deepen-failure-warns-and-continues" \
  "::warning::Failed to deepen clone" \
  "${DEEPEN_REPO_4}"; then

  check_repo_state "failed-deepen-leaves-clone-shallow" \
    "$(git -C "${DEEPEN_REPO_4}" rev-parse --is-shallow-repository)" "true"
fi

# Missing target directory is reported, not silently skipped.
run_deepen_test "deepen-missing-target-dir-warns" \
  "::warning::Clone-deepening skipped" \
  "${TMPDIR}/deepen/does-not-exist"

# Non-GitHub forge does not attempt a gh-token fetch.
DEEPEN_REPO_5="$(build_deepen_repo)"
run_deepen_test "deepen-skipped-without-token" \
  "::warning::Cannot deepen clone" \
  "${DEEPEN_REPO_5}" \
  GH_TOKEN=""

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
