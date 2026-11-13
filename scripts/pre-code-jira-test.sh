#!/usr/bin/env bash
# pre-code-jira-test.sh — Test pre-code-jira.sh Jira-source pre-script.
#
# Validates URL parsing and error handling, and the existing human-PR,
# child-issue, and --force checks.  gh, curl, and fullsend are stubbed;
# the stubs read MOCK_* env vars and record their calls under TMPDIR.
# Run from the repo root: bash scripts/pre-code-jira-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"

PRE_SCRIPT="$(resolve_agent_script pre-code-jira "${SCRIPT_DIR}")"
FAILURES=0

# /proc exposes initial parent environments on Linux; macOS has no equivalent
# fixture here. Both platforms still check inherited child environments and
# restoration for trusted Jira calls below.
JIRA_EXPECTED_PROC_LEAK=no
if [[ "$(uname -s)" != Linux ]]; then
  JIRA_EXPECTED_PROC_LEAK=unavailable
  echo 'SKIP: Jira parent /proc environment inspection (non-Linux host)'
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

PRESCRIPT_OUT="${TMPDIR}/prescript.out"
FULLSEND_CALLS="${TMPDIR}/fullsend-calls.log"
PAYLOAD_DIR="${TMPDIR}/fullsend-dir/dispatch"

# --- Helpers ---

# build_mock creates mock binaries for gh, curl, fullsend, git, python3.
build_mock() {
  local mock_bin="${TMPDIR}/bin"

  rm -rf "${mock_bin}"
  mkdir -p "${mock_bin}"

  # Mock gh: `gh pr list` prints MOCK_GH_PRS (default: no PRs).
  cat > "${mock_bin}/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then
  [[ "${MOCK_GH_FAIL:-}" == "1" ]] && exit 1
  printf '%s\n' "${MOCK_GH_PRS:-[]}"
fi
exit 0
GHEOF
  chmod +x "${mock_bin}/gh"

  # Mock curl: Jira JQL search and GitLab MR listing.
  cat > "${mock_bin}/curl" <<'CURLEOF'
#!/usr/bin/env bash
data=""
prev=""
for arg in "$@"; do
  [[ "${prev}" == "--data" ]] && data="${arg}"
  prev="${arg}"
done
for arg in "$@"; do
  case "${arg}" in
    */rest/api/3/search/jql)
      [[ "${MOCK_JIRA_CHILD_FAIL:-}" == "1" ]] && exit 22
      # MOCK_JIRA_EXPECT_BEARER=1: fail unless service-account Bearer auth
      # was used.
      if [[ "${MOCK_JIRA_EXPECT_BEARER:-}" == "1" && " $* " != *" --oauth2-bearer "* ]]; then
        exit 22
      fi
      # MOCK_JIRA_SUBTASKS_ONLY=1: every child is a subtask, so a query
      # that excludes subtask types finds none, as Jira would.
      if [[ "${MOCK_JIRA_SUBTASKS_ONLY:-}" == "1" && "${data}" == *"issuetype not in subTaskIssueTypes()"* ]]; then
        printf '{"issues":[]}\n'
        exit 0
      fi
      printf '%s\n' "${MOCK_JIRA_CHILDREN:-{\"issues\":[]\}}"
      exit 0
      ;;
    */merge_requests*page=1)
      printf '%s\n' "${MOCK_GL_MRS:-[]}"
      exit 0
      ;;
    */merge_requests*)
      printf '[]\n'
      exit 0
      ;;
  esac
done
exit 7
CURLEOF
  chmod +x "${mock_bin}/curl"

  # Mock fullsend: records the post-comment call and its stdin.
  cat > "${mock_bin}/fullsend" <<'FSEOF'
#!/usr/bin/env bash
{
  echo "ARGS: $*"
  echo "AUTH: token=${FULLSEND_JIRA_TOKEN:-unset} email=${FULLSEND_JIRA_EMAIL-unset}"
  if [[ "$1 $2" == "issues post-comment" ]]; then
    echo "BODY:"
    cat
  fi
} >> "${FULLSEND_CALLS}"
if [[ "$1 $2" == "issues transition" && "${MOCK_FULLSEND_EXIT:-0}" != 0 ]]; then
  echo "API error ${FULLSEND_JIRA_TOKEN}" >&2
fi
exit "${MOCK_FULLSEND_EXIT:-0}"
FSEOF
  chmod +x "${mock_bin}/fullsend"

  # Mock git (needed for pre-commit tool resolution)
  cat > "${mock_bin}/git" <<'GITEOF'
#!/usr/bin/env bash
exit 1
GITEOF
  chmod +x "${mock_bin}/git"

  # Mock python3 (needed for resolve-precommit-tools.py)
  cat > "${mock_bin}/python3" <<'PYEOF'
#!/usr/bin/env bash
if [[ "${MOCK_TOOL_SETUP:-}" == 1 ]]; then
  echo "resolver jira=${JIRA_TOKEN:-unset} fullsend=${FULLSEND_JIRA_TOKEN:-unset}" >> "${TOOL_CALLS}"
  echo '{"tools":[{"name":"fixture"}]}'
  exit 0
fi
exit 1
PYEOF
  chmod +x "${mock_bin}/python3"

  echo "${mock_bin}"
}

# Base env for all tests — Jira→GitHub composition.
base_env() {
  local mock_bin="$1"
  echo "PATH=${mock_bin}:${PATH}"
  echo "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-42"
  echo "JIRA_USER_EMAIL=bot@acme.com"
  echo "JIRA_TOKEN=fake-jira-token"
  echo "JIRA_BASE_URL=https://acme.atlassian.net"
  echo "REPO_FULL_NAME=test-org/test-repo"
  echo "FULLSEND_FORGE=github"
  echo "GH_TOKEN=fake-gh-token"
  echo "GITHUB_OUTPUT=/dev/null"
  echo "GITHUB_PATH=/dev/null"
  echo "GITHUB_WORKSPACE=${TMPDIR}/workspace"
  echo "FULLSEND_DIR=${TMPDIR}/fullsend-dir"
  echo "FULLSEND_PRESCRIPT_OUTPUT=${PRESCRIPT_OUT}"
  echo "FULLSEND_CALLS=${FULLSEND_CALLS}"
  echo "COMMENT_BODY="
  echo "CODE_FORCE="
  echo "CODE_JIRA_STARTED_TRANSITION=off"
  echo "CODE_JIRA_PR_READY_TRANSITION=off"
  echo "FULLSEND_TRACKER=jira"
  echo "FULLSEND_WORK_ITEM_SOURCE=jira"
  echo "FULLSEND_WORK_ITEM_KEY=PROJ-42"
  echo "FULLSEND_WORK_ITEM_URL=https://acme.atlassian.net/browse/PROJ-42"
  echo "FULLSEND_JIRA_TOKEN=inherited-jira-token"
  echo "FULLSEND_JIRA_EMAIL=inherited@example.com"
  echo "HOME=${TMPDIR}/test-home"
  echo "TOOL_CALLS=${TMPDIR}/tool-calls.log"
}

# run_script EXTRA_ENV — run the pre-script; sets RUN_EXIT.
run_script() {
  local extra_env="${1:-}"

  local mock_bin
  mock_bin="$(build_mock)"
  rm -f "${PRESCRIPT_OUT}" "${FULLSEND_CALLS}" "${TMPDIR}/tool-calls.log"
  rm -rf "${TMPDIR}/workspace" "${TMPDIR}/test-home"
  if [[ "${TEST_TOOL_INSTALL:-}" == 1 ]]; then
    mkdir -p "${TMPDIR}/workspace/scripts" "${TMPDIR}/workspace/target-repo"
    printf 'repos: []\n' > "${TMPDIR}/workspace/target-repo/.pre-commit-config.yaml"
    touch "${TMPDIR}/workspace/scripts/resolve-precommit-tools.py"
    cat > "${TMPDIR}/workspace/scripts/install-precommit-tools.sh" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail
leak=unavailable
if [[ "$(uname -s)" == Linux ]]; then
  leak=no
  read -r _ _ _ gp _ < "/proc/${PPID}/stat"
  for pid in "${PPID}" "${gp}"; do
    if tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep -qE '^(JIRA_TOKEN|JIRA_USER_EMAIL|FULLSEND_JIRA_TOKEN|FULLSEND_JIRA_EMAIL)=.'; then
      leak=yes
    fi
  done
fi
echo "installer jira=${JIRA_TOKEN:-unset} email=${JIRA_USER_EMAIL:-unset} fullsend=${FULLSEND_JIRA_TOKEN:-unset} fullsend-email=${FULLSEND_JIRA_EMAIL:-unset} proc-leak=${leak}" >> "${TOOL_CALLS}"
mkdir -p "${HOME}/.local/bin"
printf '#!/usr/bin/env bash\necho SHADOW >> "${FULLSEND_CALLS}"\n' > "${HOME}/.local/bin/fullsend"
chmod +x "${HOME}/.local/bin/fullsend"
exit "${MOCK_INSTALL_EXIT:-0}"
INSTALL
  fi

  local env_cmd=(env)

  # Read base env
  while IFS= read -r kv; do
    [[ -n "${kv}" ]] && env_cmd+=("${kv}")
  done <<< "$(base_env "${mock_bin}")"

  # Add extra env vars
  if [[ -n "${extra_env}" ]]; then
    while IFS= read -r kv; do
      [[ -n "${kv}" ]] && env_cmd+=("${kv}")
    done <<< "${extra_env}"
  fi

  # A multi-line COMMENT_BODY cannot go through the line-based EXTRA_ENV.
  if [[ -n "${TEST_COMMENT_BODY:-}" ]]; then
    env_cmd+=("COMMENT_BODY=${TEST_COMMENT_BODY}")
  fi

  if [[ "${TEST_NO_CLI:-}" == 1 ]]; then
    rm -f "${mock_bin}/fullsend"
    # Restrict PATH to these known tools so a host-installed fullsend cannot
    # satisfy the missing-CLI fixture accidentally.
    local tool
    for tool in bash env mktemp rm dirname sed tr awk jq head cut; do
      ln -s "$(command -v "${tool}")" "${mock_bin}/${tool}"
    done
    env_cmd+=("PATH=${mock_bin}")
  fi

  RUN_EXIT=0
  "${env_cmd[@]}" bash "${PRE_SCRIPT}" > "${TMPDIR}/stdout.log" 2>&1 || RUN_EXIT=$?
}

run_test() {
  local test_name="$1"
  local expect_exit="$2"
  local expected_stdout="$3"
  local extra_env="${4:-}"

  run_script "${extra_env}"

  if [[ ${RUN_EXIT} -ne ${expect_exit} ]]; then
    echo "FAIL: ${test_name} — expected exit ${expect_exit}, got ${RUN_EXIT}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_stdout}" ]]; then
    if ! grep -qF "${expected_stdout}" "${TMPDIR}/stdout.log" 2>/dev/null; then
      echo "FAIL: ${test_name} — expected stdout '${expected_stdout}' not found"
      echo "Actual stdout:"
      cat "${TMPDIR}/stdout.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

# run_skip_test NAME EXPECT_SKIP EXPECTED_TEXT EXTRA_ENV — run the script,
# require exit 0, and check whether it wrote skipped=true. EXPECTED_TEXT
# (optional) must appear in the prescript output (skip) or stdout (no skip).
run_skip_test() {
  local test_name="$1"
  local expect_skip="$2"
  local expected_text="$3"
  local extra_env="${4:-}"

  run_script "${extra_env}"

  if [[ ${RUN_EXIT} -ne 0 ]]; then
    echo "FAIL: ${test_name} — expected exit 0, got ${RUN_EXIT}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local skipped=false
  if [[ -f "${PRESCRIPT_OUT}" ]] && grep -qx 'skipped=true' "${PRESCRIPT_OUT}"; then
    skipped=true
  fi
  if [[ "${skipped}" != "${expect_skip}" ]]; then
    echo "FAIL: ${test_name} — expected skipped=${expect_skip}, got ${skipped}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_text}" ]]; then
    local where="${TMPDIR}/stdout.log"
    [[ "${expect_skip}" == "true" ]] && where="${PRESCRIPT_OUT}"
    if ! grep -qF -- "${expected_text}" "${where}" 2>/dev/null; then
      echo "FAIL: ${test_name} — expected '${expected_text}' not found in $(basename "${where}")"
      cat "${where}" 2>/dev/null || true
      cat "${TMPDIR}/stdout.log"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

# write_payload JSON — write the dispatch event payload; clear_payload removes it.
write_payload() {
  mkdir -p "${PAYLOAD_DIR}"
  printf '%s' "$1" > "${PAYLOAD_DIR}/event-payload.json"
}
clear_payload() {
  rm -f "${PAYLOAD_DIR}/event-payload.json"
}

HUMAN_PR_URL_BODY='[{"number":7,"title":"Fix the thing","body":"Change details.\n\nRelated to https://acme.atlassian.net/browse/PROJ-42","url":"https://github.com/test-org/test-repo/pull/7","author":{"login":"alice","is_bot":false}}]'
HUMAN_PR_PREFIX_KEY='[{"number":8,"title":"PROJ-4: other work","body":"See PROJ-421","url":"https://github.com/test-org/test-repo/pull/8","author":{"login":"alice","is_bot":false}}]'
BOT_PR='[{"number":9,"title":"fix(PROJ-42): agent fix","body":"Related to https://acme.atlassian.net/browse/PROJ-42","url":"https://github.com/test-org/test-repo/pull/9","author":{"login":"app/fullsend-ai-coder","is_bot":true}}]'
HAS_CHILDREN='{"issues":[{"id":"10001","key":"PROJ-43"}]}'

# --- Test cases: URL and host validation ---

# Valid Jira→GitHub composition succeeds.
run_test "valid-jira-github-succeeds" \
  0 \
  "Jira source:"

# Valid Jira→GitLab composition also works.
run_test "valid-jira-gitlab-succeeds" \
  0 \
  "Jira source:" \
  "FULLSEND_FORGE=gitlab"

# Invalid Jira URL pattern is rejected.
run_test "invalid-jira-url-rejected" \
  1 \
  "does not match expected Jira pattern" \
  "ISSUE_URL=https://github.com/org/repo/issues/1"

# Non-atlassian.net host is rejected.
run_test "non-atlassian-host-rejected" \
  1 \
  "not in the allowed host list" \
  "ISSUE_URL=https://evil.example.com/browse/PROJ-42"

# JIRA_BASE_URL mismatch is rejected.
run_test "base-url-mismatch-rejected" \
  1 \
  "does not match ISSUE_URL host" \
  "JIRA_BASE_URL=https://other.atlassian.net"

# JIRA_BASE_URL with trailing slash normalizes and matches.
run_test "base-url-trailing-slash-normalizes" \
  0 \
  "Jira source:" \
  "JIRA_BASE_URL=https://acme.atlassian.net/"

# Script succeeds without JIRA_USER_EMAIL.
run_test "no-jira-email-still-succeeds" \
  0 \
  "Jira source:" \
  "JIRA_USER_EMAIL="

# Script succeeds without JIRA_TOKEN.
run_test "no-jira-token-still-succeeds" \
  0 \
  "Jira source:" \
  "JIRA_TOKEN="

# --- Test cases: existing human-PR check ---

run_skip_test "human-pr-with-jira-url-skips" \
  true \
  "reason=open PR #7 by @alice already addresses PROJ-42" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"

# The skip comment goes to the Jira issue with the fixed marker and PR URL.
if grep -qF -- "--marker <!-- fullsend:pre-code-jira-skip -->" "${FULLSEND_CALLS}" 2>/dev/null \
   && grep -qF -- "--number 42" "${FULLSEND_CALLS}" \
   && grep -qF "https://github.com/test-org/test-repo/pull/7" "${FULLSEND_CALLS}" \
   && grep -qF "/fs-code --force" "${FULLSEND_CALLS}"; then
  echo "PASS: human-pr-skip-posts-sticky-jira-comment"
else
  echo "FAIL: human-pr-skip-posts-sticky-jira-comment — expected sticky comment call"
  cat "${FULLSEND_CALLS}" 2>/dev/null || true
  FAILURES=$((FAILURES + 1))
fi

run_skip_test "human-pr-key-prefix-does-not-match" \
  false \
  "No existing human PRs found" \
  "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-42
MOCK_GH_PRS=${HUMAN_PR_PREFIX_KEY}"

run_skip_test "human-pr-key-letter-suffix-does-not-match" \
  false \
  "No existing human PRs found" \
  "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-42
MOCK_GH_PRS=[{\"number\":5,\"title\":\"PROJ-42abc work\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/5\",\"author\":{\"login\":\"alice\"}}]"

run_skip_test "human-pr-key-underscore-suffix-does-not-match" \
  false \
  "No existing human PRs found" \
  "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-42
MOCK_GH_PRS=[{\"number\":5,\"title\":\"PROJ-42_work\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/5\",\"author\":{\"login\":\"alice\"}}]"

run_skip_test "human-pr-key-leading-underscore-does-not-match" \
  false \
  "No existing human PRs found" \
  "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-42
MOCK_GH_PRS=[{\"number\":5,\"title\":\"prefix_PROJ-42 work\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/5\",\"author\":{\"login\":\"alice\"}}]"

run_skip_test "human-pr-shorter-key-not-matching-longer-issue-key" \
  false \
  "No existing human PRs found" \
  "ISSUE_URL=https://acme.atlassian.net/browse/PROJ-123
MOCK_GH_PRS=[{\"number\":5,\"title\":\"PROJ-12 work\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/5\",\"author\":{\"login\":\"alice\"}}]"

run_skip_test "bot-pr-only-does-not-skip" \
  false \
  "No existing human PRs found" \
  "MOCK_GH_PRS=${BOT_PR}"

run_skip_test "custom-app-set-bot-pr-does-not-skip" \
  false \
  "No existing human PRs found" \
  "FULLSEND_APP_SET=custom-app
MOCK_GH_PRS=[{\"number\":9,\"title\":\"PROJ-42\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/9\",\"author\":{\"login\":\"app/custom-app\"}}]"

run_skip_test "third-party-bot-pr-does-not-skip" \
  false \
  "No existing human PRs found" \
  "MOCK_GH_PRS=[{\"number\":11,\"title\":\"chore: bump deps for PROJ-42\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/11\",\"author\":{\"login\":\"app/dependabot\",\"is_bot\":true}}]"

run_skip_test "human-pr-lowercase-key-skips" \
  true \
  "reason=open PR #12 by @alice" \
  "MOCK_GH_PRS=[{\"number\":12,\"title\":\"fix/proj-42-retry\",\"body\":\"\",\"url\":\"https://github.com/test-org/test-repo/pull/12\",\"author\":{\"login\":\"alice\",\"is_bot\":false}}]"

run_skip_test "human-pr-force-on-line-1-does-not-skip" \
  false \
  "Force override" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}
COMMENT_BODY=/fs-code --force"

TEST_COMMENT_BODY=$'/fs-code\n--force'
run_skip_test "human-pr-force-on-line-2-skips" \
  true \
  "open PR #7" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"
TEST_COMMENT_BODY=""

run_skip_test "human-pr-code-force-does-not-skip" \
  false \
  "Force override" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}
CODE_FORCE=true"

write_payload '{"comment":{"body":"/fs-code --force\r\nplease"},"_normalized_event":{"transition":{"comment":{"command":"/fs-code","instruction":"--force"}}}}'
run_skip_test "human-pr-payload-comment-force-does-not-skip" \
  false \
  "Force override" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"
clear_payload

write_payload '{"comment":{"body":"/fs-code\n--force"}}'
run_skip_test "human-pr-payload-force-on-line-2-skips" \
  true \
  "open PR #7" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"
clear_payload

write_payload '{"_normalized_event":{"transition":{"comment":{"command":"/fs-code","instruction":"--force"}}}}'
run_skip_test "human-pr-payload-instruction-force-does-not-skip" \
  false \
  "Force override" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"
clear_payload

write_payload '{"_normalized_event":{"transition":{"kind":"label_changed","label":{"name":"ready-to-code","action":"added"}}}}'
run_skip_test "human-pr-label-trigger-skips" \
  true \
  "open PR #7" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"
clear_payload

run_skip_test "human-pr-jira-comment-failure-still-skips" \
  true \
  "open PR #7" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}
MOCK_FULLSEND_EXIT=1"

run_skip_test "human-pr-no-jira-token-still-skips" \
  true \
  "open PR #7" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}
JIRA_TOKEN="

run_skip_test "pr-list-failure-fails-open" \
  false \
  "failing open" \
  "MOCK_GH_FAIL=1"

run_skip_test "no-gh-token-skips-pr-check" \
  false \
  "No github token set — skipping existing-PR check" \
  "MOCK_GH_PRS=${HUMAN_PR_URL_BODY}
GH_TOKEN="

run_skip_test "gitlab-human-mr-skips" \
  true \
  "open PR !3 by @bob already addresses PROJ-42" \
  "FULLSEND_FORGE=gitlab
GITLAB_TOKEN=fake-gl-token
CI_SERVER_HOST=gitlab.example.com
MOCK_GL_MRS=[{\"iid\":3,\"title\":\"PROJ-42 fix\",\"description\":\"\",\"web_url\":\"https://gitlab.example.com/g/p/-/merge_requests/3\",\"author\":{\"username\":\"bob\"}}]"

# --- Test cases: child-issue check ---

run_skip_test "issue-with-children-skips" \
  true \
  "reason=PROJ-42 has child issue(s)" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}"

run_skip_test "issue-with-only-subtasks-does-not-skip" \
  false \
  "No child issues found" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}
MOCK_JIRA_SUBTASKS_ONLY=1"

run_skip_test "issue-with-children-force-does-not-skip" \
  false \
  "Force override" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}
COMMENT_BODY=/fs-code --force"

run_skip_test "child-query-failure-does-not-skip" \
  false \
  "::warning::Could not read child issues of PROJ-42" \
  "MOCK_JIRA_CHILD_FAIL=1"

run_skip_test "service-account-token-only-runs-child-check" \
  true \
  "reason=PROJ-42 has child issue(s)" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}
MOCK_JIRA_EXPECT_BEARER=1
JIRA_USER_EMAIL="

run_skip_test "no-jira-token-skips-child-check" \
  false \
  "No Jira credentials set — skipping child-issue check" \
  "MOCK_JIRA_CHILDREN=${HAS_CHILDREN}
JIRA_TOKEN="

run_skip_test "no-children-does-not-skip" \
  false \
  "No child issues found"

# --- Optional started transition ---
run_started_test() {
  local name="$1" expected_exit="$2" expected_calls="$3" extra="$4" message="${5:-}"
  run_script "${extra}"
  local calls
  calls="$(grep -c '^ARGS: issues transition ' "${FULLSEND_CALLS}" 2>/dev/null || true)"
  if [[ "${RUN_EXIT}" -ne "${expected_exit}" || "${calls:-0}" -ne "${expected_calls}" ]] \
    || { [[ -n "${message}" ]] && ! grep -qF "${message}" "${TMPDIR}/stdout.log"; }; then
    echo "FAIL: ${name} — exit=${RUN_EXIT}, transitions=${calls:-0}"
    cat "${TMPDIR}/stdout.log"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${name}"
  fi
}

for _started_forge in github gitlab; do
  run_started_test "started-${_started_forge}" 0 1 "CODE_JIRA_STARTED_TRANSITION=Start Progress
FULLSEND_FORGE=${_started_forge}
GITLAB_TOKEN=fake-gitlab-token
CI_SERVER_HOST=gitlab.example.com"
  if ! grep -qF -- '--tracker jira --fullsend-dir' "${FULLSEND_CALLS}" \
     || ! grep -qF -- '--project PROJ --number 42 --transition Start Progress' "${FULLSEND_CALLS}" \
     || ! grep -qF 'AUTH: token=fake-jira-token email=bot@acme.com' "${FULLSEND_CALLS}"; then
    echo "FAIL: started-${_started_forge}-identity-and-auth"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: started-${_started_forge}-identity-and-auth"
  fi
done

run_started_test started-default 0 0 ''
run_started_test started-off 0 0 'CODE_JIRA_STARTED_TRANSITION=off'
run_started_test started-empty 0 0 'CODE_JIRA_STARTED_TRANSITION='
run_started_test started-independent-of-ready 0 0 'CODE_JIRA_PR_READY_TRANSITION=Review'
run_started_test started-human-pr-skip 0 0 "CODE_JIRA_STARTED_TRANSITION=Start
MOCK_GH_PRS=${HUMAN_PR_URL_BODY}"
run_started_test started-child-skip 0 0 "CODE_JIRA_STARTED_TRANSITION=Start
MOCK_JIRA_CHILDREN=${HAS_CHILDREN}"
run_started_test started-force-bypasses-skips 0 1 "CODE_JIRA_STARTED_TRANSITION=Start
CODE_FORCE=true
MOCK_GH_PRS=${HUMAN_PR_URL_BODY}
MOCK_JIRA_CHILDREN=${HAS_CHILDREN}"
run_started_test started-invalid-url 1 0 'CODE_JIRA_STARTED_TRANSITION=Start
ISSUE_URL=https://github.com/org/repo/issues/42'
run_started_test started-host-mismatch 1 0 'CODE_JIRA_STARTED_TRANSITION=Start
JIRA_BASE_URL=https://other.atlassian.net'
run_started_test started-invalid-forge 1 0 'CODE_JIRA_STARTED_TRANSITION=Start
FULLSEND_FORGE=invalid'
for _started_identity in \
  'FULLSEND_WORK_ITEM_KEY=PROJ-7' \
  'FULLSEND_WORK_ITEM_URL=https://other.atlassian.net/browse/PROJ-42' \
  'FULLSEND_WORK_ITEM_SOURCE=github' \
  'FULLSEND_TRACKER=gitlab'; do
  run_started_test "started-identity-${_started_identity%%=*}" 0 0 "CODE_JIRA_STARTED_TRANSITION=Start
${_started_identity}" 'Jira source identity does not match'
done
for _started_missing in JIRA_TOKEN FULLSEND_DIR; do
  run_started_test "started-missing-${_started_missing}" 0 0 "CODE_JIRA_STARTED_TRANSITION=Start
${_started_missing}=" 'requires JIRA_TOKEN, FULLSEND_DIR and the fullsend CLI'
done
TEST_NO_CLI=1 run_started_test started-missing-cli 0 0 'CODE_JIRA_STARTED_TRANSITION=Start' \
  'requires JIRA_TOKEN, FULLSEND_DIR and the fullsend CLI'
run_started_test started-service-account 0 1 'CODE_JIRA_STARTED_TRANSITION=Start
JIRA_USER_EMAIL='
if ! grep -qF 'AUTH: token=fake-jira-token email=unset' "${FULLSEND_CALLS}"; then
  echo 'FAIL: started-service-account-auth'
  FAILURES=$((FAILURES + 1))
else
  echo 'PASS: started-service-account-auth'
fi
run_started_test started-write-failure-warns-no-retry 0 1 'CODE_JIRA_STARTED_TRANSITION=Start
MOCK_FULLSEND_EXIT=1' 'Optional Jira started transition failed'
if grep -qF 'fake-jira-token' "${TMPDIR}/stdout.log"; then
  echo 'FAIL: started-write-failure-token-disclosure'
  FAILURES=$((FAILURES + 1))
else
  echo 'PASS: started-write-failure-token-redacted'
fi

TEST_TOOL_INSTALL=1 run_started_test started-after-tool-install 0 1 'CODE_JIRA_STARTED_TRANSITION=Start
MOCK_TOOL_SETUP=1'
if ! grep -qF 'resolver jira=unset fullsend=unset' "${TMPDIR}/tool-calls.log" \
   || ! grep -qF "installer jira=unset email=unset fullsend=unset fullsend-email=unset proc-leak=${JIRA_EXPECTED_PROC_LEAK}" "${TMPDIR}/tool-calls.log" \
   || grep -q 'SHADOW' "${FULLSEND_CALLS}"; then
  echo 'FAIL: started-tools-cannot-read-token-or-shadow-cli'
  FAILURES=$((FAILURES + 1))
else
  echo 'PASS: started-tools-cannot-read-token-or-shadow-cli'
fi
TEST_TOOL_INSTALL=1 run_started_test started-tool-install-failure 1 0 'CODE_JIRA_STARTED_TRANSITION=Start
MOCK_TOOL_SETUP=1
MOCK_INSTALL_EXIT=1'
TEST_TOOL_INSTALL=1 run_started_test started-force-still-requires-setup 1 0 'CODE_JIRA_STARTED_TRANSITION=Start
CODE_FORCE=true
MOCK_TOOL_SETUP=1
MOCK_INSTALL_EXIT=1'

if [[ "$(yq -r '.env.runner.CODE_JIRA_STARTED_TRANSITION' "${SCRIPT_DIR}/../harness/code.yaml")" == off ]] \
  && [[ "$(yq -r '.env.sandbox.CODE_JIRA_STARTED_TRANSITION' "${SCRIPT_DIR}/../harness/code.yaml")" == null ]]; then
  echo 'PASS: started-harness-runner-only-disabled'
else
  echo 'FAIL: started-harness-runner-only-disabled'
  FAILURES=$((FAILURES + 1))
fi

# --- Summary ---

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
