#!/usr/bin/env bash
# github-host-test.sh — Test that the GitHub ops libraries validate, parse
# and build URLs against the host in GITHUB_SERVER_URL (default github.com)
# instead of a hard-coded github.com.
#
# Run from the repo root:
#   bash scripts/github-host-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

GH="https://github.com"
GHE="https://ghe.example.com"

# check NAME EXPECTED LIB SNIPPET
# Sources scripts/lib/LIB in a fresh shell (with the current
# GITHUB_SERVER_URL), runs SNIPPET and compares "<stdout>|rc=<rc>".
check() {
  local name="$1" expected="$2" lib="$3" snippet="$4" actual
  actual=$(bash -c '
    _gha_sanitize() { printf "%s" "$1"; }
    SCRIPT_DIR="$1"
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/lib/$2"
    rc=0
    out=$(eval "$3" 2>/dev/null) || rc=$?
    printf "%s|rc=%s" "${out}" "${rc}"
  ' _ "${SCRIPT_DIR}" "${lib}" "${snippet}")
  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL: ${name} — expected '${expected}', got '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "PASS: ${name}"
}

# validate_cases LABEL LIB FN VAR GOOD_PATH
# FN is the validation function; it reads the URL from VAR.
validate_cases() {
  local label="$1" lib="$2" fn="$3" var="$4" path="$5"

  unset GITHUB_SERVER_URL
  check "${label}/default-accepts-github.com" "|rc=0" "${lib}" \
    "${var}='${GH}/${path}' ${fn}"
  check "${label}/default-rejects-other-host" "|rc=1" "${lib}" \
    "${var}='${GHE}/${path}' ${fn}"
  check "${label}/default-dot-is-literal" "|rc=1" "${lib}" \
    "${var}='https://githubxcom/${path}' ${fn}"

  export GITHUB_SERVER_URL="${GHE}"
  check "${label}/server-url-accepts-own-host" "|rc=0" "${lib}" \
    "${var}='${GHE}/${path}' ${fn}"
  check "${label}/server-url-rejects-github.com" "|rc=1" "${lib}" \
    "${var}='${GH}/${path}' ${fn}"

  export GITHUB_SERVER_URL="${GHE}/"
  check "${label}/server-url-trailing-slash" "|rc=0" "${lib}" \
    "${var}='${GHE}/${path}' ${fn}"

  export GITHUB_SERVER_URL="${GHE}:8443"
  check "${label}/server-url-with-port" "|rc=0" "${lib}" \
    "${var}='${GHE}:8443/${path}' ${fn}"
  check "${label}/server-url-port-mismatch" "|rc=1" "${lib}" \
    "${var}='${GHE}/${path}' ${fn}"

  export GITHUB_SERVER_URL="http://ghe.example.com"
  check "${label}/server-url-not-https-rejected" "|rc=1" "${lib}" \
    "${var}='http://ghe.example.com/${path}' ${fn}"

  unset GITHUB_SERVER_URL
}

# --- Validation ---

validate_cases review github-review-ops.lib.sh forge_validate_pr_url \
  PR_URL "acme/widgets/pull/107"
validate_cases code github-code-ops.lib.sh forge_validate_issue_url \
  ISSUE_URL "acme/widgets/issues/107"
validate_cases fix github-fix-ops.lib.sh forge_validate_pr_url \
  PR_URL "acme/widgets/pull/107"
validate_cases prioritize github-prioritize-ops.lib.sh forge_validate_issue_url \
  ISSUE_URL "acme/widgets/issues/107"
validate_cases retro-issue github-retro-ops.lib.sh forge_validate_originating_url \
  ORIGINATING_URL "acme/widgets/issues/107"
validate_cases retro-pull github-retro-ops.lib.sh forge_validate_originating_url \
  ORIGINATING_URL "acme/widgets/pull/107"

# --- Parsing ---

for server in "" "${GHE}"; do
  label="${server:+server-url}"
  label="${label:-default}"
  base="${server:-${GH}}"
  if [[ -n "${server}" ]]; then
    export GITHUB_SERVER_URL="${server}"
  else
    unset GITHUB_SERVER_URL
  fi

  check "review/${label}/parse" "acme/widgets 107|rc=0" github-review-ops.lib.sh \
    "PR_URL='${base}/acme/widgets/pull/107' forge_parse_pr_url; echo \"\${REPO} \${PR_NUMBER}\""
  check "code/${label}/parse" "acme/widgets 107|rc=0" github-code-ops.lib.sh \
    "forge_parse_issue_url '${base}/acme/widgets/issues/107'; echo \"\${REPO_FULL_NAME} \${ISSUE_NUMBER}\""
  check "code/${label}/extract-repo" "acme/widgets|rc=0" github-code-ops.lib.sh \
    "forge_extract_repo_from_url '${base}/acme/widgets/issues/107'"
  check "fix/${label}/parse" "acme/widgets 107|rc=0" github-fix-ops.lib.sh \
    "forge_parse_pr_url '${base}/acme/widgets/pull/107'; echo \"\${REPO_FULL_NAME} \${PR_NUMBER}\""
  check "prioritize/${label}/parse" "acme/widgets 107|rc=0" github-prioritize-ops.lib.sh \
    "ISSUE_URL='${base}/acme/widgets/issues/107' forge_parse_issue_url; echo \"\${REPO} \${ISSUE_NUMBER}\""
  check "retro/${label}/parse" "acme/widgets 107|rc=0" github-retro-ops.lib.sh \
    "ORIGINATING_URL='${base}/acme/widgets/pull/107' forge_parse_originating_url; echo \"\${ORIGINATING_REPO} \${ORIGINATING_NUMBER}\""

  # --- Links ---

  check "scribe/${label}/issue-url-base" "${base}/acme/widgets/issues|rc=0" \
    github-scribe-ops.lib.sh "forge_issue_url_base acme/widgets"

  # --- Push remote ---

  host="${base#https://}"
  for lib in github-code-ops.lib.sh github-fix-ops.lib.sh; do
    repo_dir="${TEST_TMPDIR}/repo-${label}-${lib}"
    git init -q "${repo_dir}"
    git -C "${repo_dir}" remote add origin "${base}/acme/widgets.git"
    check "${lib%%-ops.lib.sh}/${label}/push-remote" \
      "https://x-access-token:tok@${host}/acme/widgets.git|rc=0" "${lib}" \
      "cd '${repo_dir}' && REPO_FULL_NAME=acme/widgets forge_set_push_remote tok && git remote get-url origin"
  done
done
unset GITHUB_SERVER_URL

# A non-HTTPS GITHUB_SERVER_URL fails closed for links and the push remote.
export GITHUB_SERVER_URL="http://ghe.example.com"
check "scribe/server-url-not-https-rejected" "|rc=1" github-scribe-ops.lib.sh \
  "forge_issue_url_base acme/widgets"
check "code/push-remote-server-url-not-https-rejected" "|rc=1" github-code-ops.lib.sh \
  "REPO_FULL_NAME=acme/widgets forge_set_push_remote tok"
unset GITHUB_SERVER_URL

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
