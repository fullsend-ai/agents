#!/usr/bin/env bash
# Exercise the real post-code script and Gitleaks; only forge HTTP calls
# and remote URL rewriting are substituted. No scanner-policy mocks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"
POST_SCRIPT="$(resolve_agent_script post-code "${SCRIPT_DIR}")"
# shellcheck source=lib/gitleaks-install.lib.sh
source "${SCRIPT_DIR}/lib/gitleaks-install.lib.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT
REAL_GIT="$(command -v git)"
REAL_GITLEAKS="${GITLEAKS_TEST_BIN:-$(command -v gitleaks || true)}"
if [ -z "${REAL_GITLEAKS}" ]; then
  platform="$(resolve_platform)"
  curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${platform}.tar.gz" \
    -o "${TEST_DIR}/gitleaks.tar.gz"
  verify_checksum "${TEST_DIR}/gitleaks.tar.gz" "$(gitleaks_sha256 "${platform}")"
  tar xzf "${TEST_DIR}/gitleaks.tar.gz" -C "${TEST_DIR}" gitleaks
  REAL_GITLEAKS="${TEST_DIR}/gitleaks"
fi
[ "$("${REAL_GITLEAKS}" version)" = "${GITLEAKS_VERSION}" ] || {
  echo "FAIL: real scanner must be Gitleaks ${GITLEAKS_VERSION}" >&2
  exit 1
}
export REAL_GIT REAL_GITLEAKS
mkdir -p "${TEST_DIR}/bin"

cat > "${TEST_DIR}/bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "remote set-url" ]; then exit 0; fi
exec "${REAL_GIT}" "$@"
EOF
cat > "${TEST_DIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "issue comment") cat > "${PUBLIC_TEXT_CAPTURE}" ;;
  "pr create")
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--body" ]; then printf '%s' "$2" > "${PUBLIC_TEXT_CAPTURE}"; break; fi
      shift
    done
    echo "https://github.com/test-org/test-repo/pull/1" ;;
  "pr list") ;;
  "api repos/test-org/test-repo") echo main ;;
  "api "*) echo '[]' ;;
esac
EOF
cat > "${TEST_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET
body=""
url=""
status=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method="$2"; shift ;;
    --write-out) status=true; shift ;;
    --data-urlencode)
      case "$2" in body=*|description=*) body="${2#*=}" ;; esac
      shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
case "${method} ${url}" in
  "POST "*/issues/99/notes) printf '%s' "${body}" > "${PUBLIC_TEXT_CAPTURE}"; echo '{}' ;;
  "POST "*/merge_requests)
    printf '%s' "${body}" > "${PUBLIC_TEXT_CAPTURE}"
    echo '{"web_url":"https://gitlab.com/test-org/test-repo/-/merge_requests/1"}';;
  "GET "*/merge_requests*) echo '[]' ;;
  "GET "*/projects/test-org%2Ftest-repo) echo '{"id":1,"default_branch":"main"}' ;;
  *) echo '[]' ;;
esac
if "${status}"; then printf '\n201'; fi
EOF
cat > "${TEST_DIR}/bin/gitleaks" <<'EOF'
#!/usr/bin/env bash
ORIGINAL_ARGS=("$@")
source_path=""
public=false
for arg in "$@"; do
  if [ "${arg}" = "--no-git" ]; then public=true; fi
done
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--source" ]; then source_path="$2"; break; fi
  shift
done
if "${public}"; then
  case "${TEST_SCAN_MODE}" in
    error|unavailable)
      printf '%s\n' "${TEST_CREDENTIAL}" >&2
      printf '%s\n' "${TEST_CREDENTIAL}"
      if [ "${TEST_SCAN_MODE}" = unavailable ]; then exit 127; fi
      exit 2 ;;
    ignore)
      # Supply the exact temporary-file fingerprint, giving the hostile
      # repo ignore file its strongest possible chance to bypass detection.
      printf '%s:aws-access-token:1\n' "${source_path}" > "${TEST_REPO}/.gitleaksignore" ;;
  esac
fi
exec "${REAL_GITLEAKS}" "${ORIGINAL_ARGS[@]}"
EOF
chmod +x "${TEST_DIR}/bin/"*

FAILURES=0
# Synthetic credential assembled at runtime so the test source is not a leak.
TEST_CREDENTIAL="AKIA""QWERTYUIOPASDFGH"
export TEST_CREDENTIAL
run_case() {
  local forge="$1" path="$2" mode="$3" expected="$4"
  local name="${forge}-${path}-${mode}" run_dir rc=0 text
  run_dir="${TEST_DIR}/${name}"
  mkdir -p "${run_dir}/output"
  "${REAL_GIT}" init -q --bare -b main "${run_dir}/remote.git"
  "${REAL_GIT}" clone -q "${run_dir}/remote.git" "${run_dir}/repo" 2>/dev/null
  "${REAL_GIT}" -C "${run_dir}/repo" config user.email test@example.com
  "${REAL_GIT}" -C "${run_dir}/repo" config user.name Test
  printf 'init\n' > "${run_dir}/repo/README.md"
  "${REAL_GIT}" -C "${run_dir}/repo" add README.md
  "${REAL_GIT}" -C "${run_dir}/repo" commit -q -m init
  "${REAL_GIT}" -C "${run_dir}/repo" push -q origin main
  if [ "${path}" = pr ]; then
    "${REAL_GIT}" -C "${run_dir}/repo" checkout -q -b agent/99-fix
    printf 'fixed\n' > "${run_dir}/repo/README.md"
    "${REAL_GIT}" -C "${run_dir}/repo" commit -qam 'fix: test' -m 'Trusted commit explanation'
  fi
  text="aws_access_key_id = \"${TEST_CREDENTIAL}\""
  case "${mode}" in
    safe) text='Safe upstream explanation' ;;
    empty) text='' ;;
    allow) text="${text} # gitleaks:allow" ;;
  esac
  jq -n --arg text "${text}" '{target_branch:"main",pr_body:$text}' \
    > "${run_dir}/output/agent-result.json"
  # Runtime fixtures are untracked artifacts, like hostile files in the
  # extracted tree. The production no-op guard intentionally permits them.
  mkdir -p "${run_dir}/repo/.agentready"
  printf '%s\n' 'title = "hostile"' '[extend]' 'useDefault = true' \
    '[allowlist]' 'regexes = [".*"]' > "${run_dir}/repo/.agentready/allow.toml"
  cp "${run_dir}/repo/.agentready/allow.toml" "${run_dir}/repo/.gitleaks.toml"
  printf '/.gitleaks.toml\n/.gitleaksignore\n' >> "${run_dir}/repo/.git/info/exclude"
  # shellcheck disable=SC2030,SC2031
  (
    cd "${run_dir}"
    export PATH="${TEST_DIR}/bin:${PATH}"
    export PUBLIC_TEXT_CAPTURE="${run_dir}/published.txt" TEST_REPO="${run_dir}/repo"
    export TEST_SCAN_MODE="${mode}" PUSH_TOKEN=fake-token
    export REPO_FULL_NAME=test-org/test-repo ISSUE_NUMBER=99 REPO_DIR=repo
    export FULLSEND_FORGE="${forge}" FULLSEND_VALIDATED_ITERATION_DIR="${run_dir}/output"
    export CODE_AUTO_MERGE=false
    unset FULLSEND_TRACKER GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
    if [ "${forge}" = gitlab ]; then
      export ISSUE_URL=https://gitlab.com/test-org/test-repo/-/issues/99 GITLAB_TOKEN=fake-token
      export CI_SERVER_HOST=gitlab.com
      unset GITLAB_HOST
    fi
    case "${mode}" in
      config) export GITLEAKS_CONFIG="${run_dir}/repo/.agentready/allow.toml" ;;
      config-toml)
        GITLEAKS_CONFIG_TOML="$(< "${run_dir}/repo/.agentready/allow.toml")"
        export GITLEAKS_CONFIG_TOML ;;
      jira) export FULLSEND_TRACKER=jira FULLSEND_WORK_ITEM_URL=https://jira.example.com/browse/TEST-99 ;;
    esac
    bash "${POST_SCRIPT}"
  ) > "${run_dir}/log" 2>&1 || rc=$?
  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: ${name} — post-script exit ${rc}"
    cat "${run_dir}/log"
    FAILURES=$((FAILURES + 1))
  elif [ "${expected}" = jira ]; then
    if [ -e "${run_dir}/published.txt" ] || ! grep -q 'No PR created for TEST-99' "${run_dir}/log"; then
      echo "FAIL: ${name} — changed Jira no-op behavior"; FAILURES=$((FAILURES + 1))
    else echo "PASS: ${name}"; fi
  elif [ ! -s "${run_dir}/published.txt" ]; then
    echo "FAIL: ${name} — publication path was not exercised"
    cat "${run_dir}/log"
    FAILURES=$((FAILURES + 1))
  elif grep -qF "${TEST_CREDENTIAL}" "${run_dir}/published.txt" \
    || grep -qF "${TEST_CREDENTIAL}" "${run_dir}/log"; then
    echo "FAIL: ${name} — credential reached public output"; FAILURES=$((FAILURES + 1))
  elif [ "${expected}" = safe ] && ! grep -qF 'Safe upstream explanation' "${run_dir}/published.txt"; then
    echo "FAIL: ${name} — safe text was discarded"; FAILURES=$((FAILURES + 1))
  elif [ "${path}" = pr ] && [ "${expected}" = blocked ] \
    && ! grep -qF 'Trusted commit explanation' "${run_dir}/published.txt"; then
    echo "FAIL: ${name} — commit-body fallback missing"; FAILURES=$((FAILURES + 1))
  elif [ "${path}" = noop ] && [ "${expected}" = blocked ] \
    && grep -qF '**Agent context:**' "${run_dir}/published.txt"; then
    echo "FAIL: ${name} — unscanned context block retained"; FAILURES=$((FAILURES + 1))
  elif [ "${path}" = pr ] && [[ "${mode}" = error || "${mode}" = unavailable ]] \
    && ! grep -qF 'PR body secret scan: error' "${run_dir}/published.txt"; then
    echo "FAIL: ${name} — scanner failure status missing"; FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${name}"
  fi
}

for forge in github gitlab; do
  for path in noop pr; do
    run_case "${forge}" "${path}" safe safe
    run_case "${forge}" "${path}" empty blocked
    for mode in secret allow config config-toml ignore error unavailable; do
      run_case "${forge}" "${path}" "${mode}" blocked
    done
  done
  run_case "${forge}" noop jira jira
done
[ "${FAILURES}" -eq 0 ] || { echo "${FAILURES} public-text tests failed"; exit 1; }
echo 'All public-text tests passed'
