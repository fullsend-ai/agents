#!/usr/bin/env bash
# jira-auth-test.sh — Tests for scripts/lib/jira-auth.lib.sh (agents#1926).
#
# Covers the four credential cases: token + email (Basic), token only
# (Bearer), OAuth 2.0 client credentials (minted Bearer token, fake curl and
# fake fullsend on PATH), and conflicting settings. In client-credentials
# mode, asserts the client secret is in no curl or fullsend argv and in no
# stdout or stderr.
#
# Run from the repo root:
#   bash scripts/jira-auth-test.sh

set -euo pipefail

if [[ "${SCRIPT_TEST_TARGET:-source}" == "bundled" ]]; then
  echo "SKIP: jira-auth-test (lib tests skipped in bundled mode)"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Tests set exactly the Jira credentials they need.
unset FULLSEND_JIRA_TOKEN FULLSEND_JIRA_EMAIL FULLSEND_JIRA_CLIENT_ID \
  FULLSEND_JIRA_CLIENT_SECRET JIRA_TOKEN JIRA_USER_EMAIL JIRA_API_URL
LIB="${SCRIPT_DIR}/lib/jira-auth.lib.sh"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT
MOCK_BIN="${TMPDIR_ROOT}/bin"
mkdir -p "${MOCK_BIN}"

# A secret with JSON metacharacters, to check the request body escaping.
SECRET='sec"ret\value-DO-NOT-LEAK'
CLIENT_ID="client-id-123"
API_URL="https://api.atlassian.com/ex/jira/cloud-1"

# Fake curl: logs its argv, logs stdin when the body is read from stdin,
# and answers the Atlassian token endpoint (body + "\n<status>", as
# --write-out produces). Other calls print a fixed body.
cat > "${MOCK_BIN}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LOG_DIR}/curl-argv.log"
url=""
stdin_body=0
for arg in "$@"; do
  case "${arg}" in
    https://*) url="${arg}" ;;
    @-) stdin_body=1 ;;
  esac
done
if [[ "${stdin_body}" -eq 1 ]]; then
  cat >> "${LOG_DIR}/curl-stdin.log"
  printf '\n' >> "${LOG_DIR}/curl-stdin.log"
fi
if [[ "${url}" == "https://auth.atlassian.com/oauth/token" ]]; then
  n=0
  [[ -f "${LOG_DIR}/mint-count" ]] && n="$(cat "${LOG_DIR}/mint-count")"
  n=$((n + 1))
  printf '%s' "${n}" > "${LOG_DIR}/mint-count"
  case "${FAKE_MINT:-ok}" in
    ok) printf '{"access_token":"minted-token-%s","expires_in":%s,"token_type":"Bearer"}\n200' "${n}" "${FAKE_EXPIRES_IN:-3600}" ;;
    deny) printf '{"error":"access_denied","error_description":"leaky-response-body"}\n401' ;;
  esac
  exit 0
fi
printf '{"ok":true}'
MOCKEOF
chmod +x "${MOCK_BIN}/curl"

# Fake fullsend: logs its argv and which Jira variables it got. The secret
# value is compared here rather than logged.
cat > "${MOCK_BIN}/fullsend" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LOG_DIR}/fullsend-argv.log"
secret_state="unset"
if [[ -n "${FULLSEND_JIRA_CLIENT_SECRET+x}" ]]; then
  secret_state="wrong"
  [[ "${FULLSEND_JIRA_CLIENT_SECRET}" == "${EXPECTED_SECRET:-}" ]] && secret_state="ok"
fi
printf 'token=%s email=%s id=%s secret=%s\n' "${FULLSEND_JIRA_TOKEN-unset}" \
  "${FULLSEND_JIRA_EMAIL-unset}" "${FULLSEND_JIRA_CLIENT_ID-unset}" "${secret_state}" \
  >> "${LOG_DIR}/fullsend-env.log"
MOCKEOF
chmod +x "${MOCK_BIN}/fullsend"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1 — $2"
  FAILURES=$((FAILURES + 1))
}

# run_case NAME BODY — run BODY (bash code) in a fresh bash with the library
# sourced and the fakes first on PATH. Its stdout is a pipe, as on a CI
# runner. Sets CASE_DIR, CASE_RC, CASE_OUT and
# CASE_ERR (paths to the captured stdout and stderr).
run_case() {
  local name="$1"
  local body="$2"
  CASE_DIR="${TMPDIR_ROOT}/${name}"
  mkdir -p "${CASE_DIR}"
  CASE_OUT="${CASE_DIR}/stdout"
  CASE_ERR="${CASE_DIR}/stderr"
  CASE_RC=0
  env -u FULLSEND_JIRA_TOKEN -u FULLSEND_JIRA_EMAIL -u FULLSEND_JIRA_CLIENT_ID \
    -u FULLSEND_JIRA_CLIENT_SECRET -u JIRA_TOKEN -u JIRA_USER_EMAIL -u JIRA_API_URL \
    PATH="${MOCK_BIN}:${PATH}" LOG_DIR="${CASE_DIR}" EXPECTED_SECRET="${SECRET}" \
    TEST_SECRET="${SECRET}" TEST_CLIENT_ID="${CLIENT_ID}" TEST_API_URL="${API_URL}" \
    FAKE_MINT="${FAKE_MINT:-ok}" FAKE_EXPIRES_IN="${FAKE_EXPIRES_IN:-3600}" \
    bash -c "set -euo pipefail; source '${LIB}'; ${body}" \
    2> "${CASE_ERR}" | cat > "${CASE_OUT}" || CASE_RC=$?
}

# Assert the secret is in no argv of any curl or fullsend call and in no
# stdout or stderr of the case.
assert_secret_hidden() {
  local name="$1"
  local f
  for f in "${CASE_DIR}/curl-argv.log" "${CASE_DIR}/fullsend-argv.log" "${CASE_OUT}" "${CASE_ERR}"; do
    [[ -f "${f}" ]] || continue
    if grep -qF -- "${SECRET}" "${f}"; then
      fail "${name}-secret-hidden" "client secret found in $(basename "${f}")"
      return
    fi
  done
  pass "${name}-secret-hidden"
}

# --- Case 1: token + email — Basic auth, unchanged ---
run_case token-email '
  jira_auth_select "tok-1" "" ""
  echo "mode=${JIRA_AUTH_MODE}"
  jira_auth_curl "tok-1" " bot@example.com " "https://site.atlassian.net/rest/api/3/myself" >/dev/null
  jira_auth_fullsend fullsend "tok-1" "bot@example.com" issues get
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "mode=token" "${CASE_OUT}" \
  && grep -qF -- "--user bot@example.com:tok-1 " "${CASE_DIR}/curl-argv.log" \
  && grep -qx "token=tok-1 email=bot@example.com id=unset secret=unset" "${CASE_DIR}/fullsend-env.log" \
  && [[ ! -f "${CASE_DIR}/mint-count" ]]; then
  pass "token-email-basic-auth"
else
  fail "token-email-basic-auth" "rc=${CASE_RC}; $(cat "${CASE_DIR}/curl-argv.log" "${CASE_DIR}/fullsend-env.log" "${CASE_ERR}" 2>/dev/null)"
fi

# Without jira_auth_select the helpers keep the token behaviour.
run_case token-no-select '
  jira_auth_curl "tok-1" "bot@example.com" "https://site.atlassian.net/x" >/dev/null
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qF -- "--user bot@example.com:tok-1 " "${CASE_DIR}/curl-argv.log"; then
  pass "token-without-select-unchanged"
else
  fail "token-without-select-unchanged" "rc=${CASE_RC}"
fi

# --- Case 2: token only — Bearer auth, unchanged ---
run_case token-only '
  export FULLSEND_JIRA_EMAIL=inherited@example.com
  jira_auth_select "tok-2" "" ""
  jira_auth_curl "tok-2" "  " "https://site.atlassian.net/rest/api/3/myself" >/dev/null
  jira_auth_fullsend fullsend "tok-2" "" issues get
'
if [[ "${CASE_RC}" -eq 0 ]] \
  && grep -qF -- "--oauth2-bearer tok-2 " "${CASE_DIR}/curl-argv.log" \
  && ! grep -qF -- "--user" "${CASE_DIR}/curl-argv.log" \
  && grep -qx "token=tok-2 email=unset id=unset secret=unset" "${CASE_DIR}/fullsend-env.log"; then
  pass "token-only-bearer-auth"
else
  fail "token-only-bearer-auth" "rc=${CASE_RC}; $(cat "${CASE_DIR}/curl-argv.log" "${CASE_DIR}/fullsend-env.log" "${CASE_ERR}" 2>/dev/null)"
fi

run_case token-empty '
  jira_auth_select "" "" ""
  echo "mode=${JIRA_AUTH_MODE}"
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "mode=none" "${CASE_OUT}"; then
  pass "nothing-set-selects-none"
else
  fail "nothing-set-selects-none" "rc=${CASE_RC}"
fi

# --- Case 3: client credentials ---
run_case client '
  export JIRA_API_URL="${TEST_API_URL}"
  export FULLSEND_JIRA_TOKEN=inherited-token FULLSEND_JIRA_EMAIL=inherited@example.com
  jira_auth_select "" "${TEST_CLIENT_ID}" "${TEST_SECRET}"
  echo "mode=${JIRA_AUTH_MODE}"
  jira_auth_require_api_url
  jira_auth_mint
  # A call in a command substitution reuses the token minted above, and its
  # captured output is the curl output only.
  captured="$(jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself")"
  echo "captured=${captured}"
  jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/search/jql" >/dev/null
  printf "body" | jira_auth_fullsend fullsend "" "" issues post-comment --result -
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "mode=client" "${CASE_OUT}"; then
  pass "client-selects-client-mode"
else
  fail "client-selects-client-mode" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi
if grep -c "https://auth.atlassian.com/oauth/token" "${CASE_DIR}/curl-argv.log" | grep -qx 1 \
  && grep -F "https://auth.atlassian.com/oauth/token" "${CASE_DIR}/curl-argv.log" | grep -qF -- "--data @-"; then
  pass "client-mints-once-with-body-on-stdin"
else
  fail "client-mints-once-with-body-on-stdin" "$(cat "${CASE_DIR}/curl-argv.log")"
fi
if grep -F "https://auth.atlassian.com/oauth/token" "${CASE_DIR}/curl-argv.log" | grep -q -- "^-q --proto =https "; then
  pass "client-mint-ignores-curl-config-https-only"
else
  fail "client-mint-ignores-curl-config-https-only" "$(cat "${CASE_DIR}/curl-argv.log")"
fi
if jq -e --arg id "${CLIENT_ID}" --arg secret "${SECRET}" \
  '.grant_type == "client_credentials" and .client_id == $id and .client_secret == $secret' \
  "${CASE_DIR}/curl-stdin.log" >/dev/null 2>&1; then
  pass "client-token-request-body"
else
  fail "client-token-request-body" "token request body is not the expected JSON"
fi
# Line 1 is the case's own "mode=" line; the mask comes before any other.
if [[ "$(sed -n 2p "${CASE_OUT}")" == "::add-mask::minted-token-1" ]] \
  && [[ "$(grep -c "minted-token" "${CASE_OUT}")" -eq 1 ]]; then
  pass "client-minted-token-masked-first"
else
  fail "client-minted-token-masked-first" "$(cat "${CASE_OUT}")"
fi
if grep -qx 'captured={"ok":true}' "${CASE_OUT}"; then
  pass "client-mask-not-in-captured-output"
else
  fail "client-mask-not-in-captured-output" "$(cat "${CASE_OUT}")"
fi
if [[ "$(grep -c -- "--oauth2-bearer minted-token-1 ${API_URL}/rest/api/3/" "${CASE_DIR}/curl-argv.log")" -eq 2 ]] \
  && ! grep -qF -- "--user" "${CASE_DIR}/curl-argv.log" \
  && ! grep -qF -- "inherited-token" "${CASE_DIR}/curl-argv.log"; then
  pass "client-rest-calls-bearer-to-api-url"
else
  fail "client-rest-calls-bearer-to-api-url" "$(cat "${CASE_DIR}/curl-argv.log")"
fi
if grep -qx "token=unset email=unset id=${CLIENT_ID} secret=ok" "${CASE_DIR}/fullsend-env.log"; then
  pass "client-fullsend-gets-client-vars-only"
else
  fail "client-fullsend-gets-client-vars-only" "$(cat "${CASE_DIR}/fullsend-env.log")"
fi
assert_secret_hidden "client"

# xtrace on: the mint still prints no secret.
run_case client-xtrace '
  export JIRA_API_URL="${TEST_API_URL}"
  jira_auth_select "" "${TEST_CLIENT_ID}" "${TEST_SECRET}"
  set -x
  jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself" >/dev/null
  set +x
'
if [[ "${CASE_RC}" -eq 0 ]] && [[ -f "${CASE_DIR}/mint-count" ]]; then
  pass "client-xtrace-mints"
else
  fail "client-xtrace-mints" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi
assert_secret_hidden "client-xtrace"

# xtrace on through select, mint and the fullsend call: no trace line
# carries the secret. The call line of jira_auth_select is traced by the
# caller before the function runs, so it is left out of the check.
run_case client-xtrace-all '
  export JIRA_API_URL="${TEST_API_URL}"
  set -x
  jira_auth_select "" "${TEST_CLIENT_ID}" "${TEST_SECRET}"
  jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself" >/dev/null
  printf "body" | jira_auth_fullsend fullsend "" "" issues post-comment --result -
  set +x
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -q "secret=ok" "${CASE_DIR}/fullsend-env.log" \
  && ! grep -v "^+* jira_auth_select " "${CASE_ERR}" | grep -qF -- "${SECRET}" \
  && grep -q "^+* jira_auth_curl " "${CASE_ERR}"; then
  pass "client-xtrace-select-and-fullsend-hide-secret"
else
  fail "client-xtrace-select-and-fullsend-hide-secret" "rc=${CASE_RC}"
fi

# A first mint inside a command substitution keeps the mask line out of
# the captured value.
run_case client-mint-in-substitution '
  export JIRA_API_URL="${TEST_API_URL}"
  jira_auth_select "" "${TEST_CLIENT_ID}" "${TEST_SECRET}"
  captured="$(jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself")"
  printf "%s" "${captured}" > "${LOG_DIR}/captured"
'
# With /proc (Linux), the mask reaches the main shell's stdout pipe;
# without it, stderr.
MASK_FILE="${CASE_ERR}"
[[ -e /proc/self/fd/1 ]] && MASK_FILE="${CASE_OUT}"
if [[ "${CASE_RC}" -eq 0 ]] && [[ "$(cat "${CASE_DIR}/captured")" == '{"ok":true}' ]] \
  && grep -qx "::add-mask::minted-token-1" "${MASK_FILE}"; then
  pass "client-subshell-mint-mask-not-captured"
else
  fail "client-subshell-mint-mask-not-captured" "rc=${CASE_RC}; $(cat "${CASE_DIR}/captured" 2>/dev/null)"
fi

# A caller that redirects stdout to a file around a subshell mint gets no
# token in that file; the mask goes to stderr instead.
run_case client-mint-redirected '
  export JIRA_API_URL="${TEST_API_URL}"
  jira_auth_select "" "${TEST_CLIENT_ID}" "${TEST_SECRET}"
  g() { r="$(jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself")"; echo "r=${r}"; }
  g > "${LOG_DIR}/redirected"
  g > /dev/null
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx 'r={"ok":true}' "${CASE_DIR}/redirected" \
  && ! grep -qF "minted-token" "${CASE_DIR}/redirected" \
  && [[ "$(grep -c "^::add-mask::minted-token-" "${CASE_ERR}")" -eq 2 ]]; then
  pass "client-subshell-mint-redirected-stdout-gets-no-token"
else
  fail "client-subshell-mint-redirected-stdout-gets-no-token" "rc=${CASE_RC}"
fi

# Loading the library leaves no extra file descriptor open for child
# processes to inherit.
CASE_RC=0
fd_out="$(env -u FULLSEND_JIRA_TOKEN -u FULLSEND_JIRA_CLIENT_ID -u FULLSEND_JIRA_CLIENT_SECRET -u JIRA_TOKEN \
  bash -c "before=\"\$(cd /dev/fd && echo *)\"; source '${LIB}'; after=\"\$(cd /dev/fd && echo *)\"; echo \"before=\${before} after=\${after}\"" \
  2>&1)" || CASE_RC=$?
if [[ "${CASE_RC}" -eq 0 && "${fd_out}" =~ ^before=(.*)\ after=(.*)$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
  pass "library-load-opens-no-fd"
else
  fail "library-load-opens-no-fd" "${fd_out}"
fi

# Surrounding whitespace in the client ID and secret is trimmed, as fullsend
# does; a tab inside the secret is kept and JSON-escaped.
SAVED_SECRET="${SECRET}"
SECRET=$'sec\tret-inner-DO-NOT-LEAK'
run_case client-whitespace '
  export JIRA_API_URL="${TEST_API_URL}"
  jira_auth_select "" "  ${TEST_CLIENT_ID} " $'"'"'\t '"'"'"${TEST_SECRET}"$'"'"' \t'"'"'
  jira_auth_mint
  printf "body" | jira_auth_fullsend fullsend "" "" issues get
'
if [[ "${CASE_RC}" -eq 0 ]] && jq -e --arg id "${CLIENT_ID}" --arg secret "${SECRET}" \
  '.client_id == $id and .client_secret == $secret' "${CASE_DIR}/curl-stdin.log" >/dev/null 2>&1 \
  && grep -qx "token=unset email=unset id=${CLIENT_ID} secret=ok" "${CASE_DIR}/fullsend-env.log"; then
  pass "client-credentials-trimmed"
else
  fail "client-credentials-trimmed" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi
assert_secret_hidden "client-whitespace"
SECRET="${SAVED_SECRET}"

# A token that is only whitespace counts as unset.
run_case token-whitespace '
  jira_auth_select " 	 " "" ""
  echo "mode=${JIRA_AUTH_MODE}"
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "mode=none" "${CASE_OUT}"; then
  pass "whitespace-token-selects-none"
else
  fail "whitespace-token-selects-none" "rc=${CASE_RC}"
fi

# A token within 5 minutes of expiry is minted again.
FAKE_EXPIRES_IN=200 run_case client-expiring '
  export JIRA_API_URL="${TEST_API_URL}"
  jira_auth_select "" "${TEST_CLIENT_ID}" "${TEST_SECRET}"
  jira_auth_curl "" "" "${JIRA_API_URL}/a" >/dev/null
  jira_auth_curl "" "" "${JIRA_API_URL}/b" >/dev/null
'
if [[ "${CASE_RC}" -eq 0 ]] && [[ "$(cat "${CASE_DIR}/mint-count")" == "2" ]] \
  && grep -qF -- "--oauth2-bearer minted-token-2 ${API_URL}/b" "${CASE_DIR}/curl-argv.log"; then
  pass "client-remints-near-expiry"
else
  fail "client-remints-near-expiry" "rc=${CASE_RC}; $(cat "${CASE_DIR}/curl-argv.log")"
fi

# A refused token request reports the HTTP status, never the body, and no
# REST call is made.
FAKE_MINT=deny run_case client-denied '
  export JIRA_API_URL="${TEST_API_URL}"
  jira_auth_select "" "${TEST_CLIENT_ID}" "${TEST_SECRET}"
  jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself"
'
if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "HTTP 401" "${CASE_ERR}" \
  && ! grep -qF "leaky-response-body" "${CASE_OUT}" "${CASE_ERR}" \
  && ! grep -qF "/rest/api/3/myself" "${CASE_DIR}/curl-argv.log"; then
  pass "client-mint-failure-status-only"
else
  fail "client-mint-failure-status-only" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi
assert_secret_hidden "client-denied"

# Client credentials need JIRA_API_URL; there is no JIRA_BASE_URL fallback.
run_case client-no-api-url '
  jira_auth_select "" "${TEST_CLIENT_ID}" "${TEST_SECRET}"
  jira_auth_require_api_url
'
if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "JIRA_API_URL" "${CASE_ERR}"; then
  pass "client-requires-api-url"
else
  fail "client-requires-api-url" "rc=${CASE_RC}"
fi
run_case token-no-api-url '
  jira_auth_select "tok" "" ""
  jira_auth_require_api_url
'
if [[ "${CASE_RC}" -eq 0 ]]; then
  pass "token-does-not-require-api-url"
else
  fail "token-does-not-require-api-url" "rc=${CASE_RC}"
fi

# --- Case 4: conflicting settings fail, naming variables, not values ---
for conflict in "both|tok-4|${CLIENT_ID}|${SECRET}" "token-and-id|tok-4|${CLIENT_ID}|" \
  "id-only||${CLIENT_ID}|" "secret-only|||${SECRET}"; do
  IFS='|' read -r cname ctoken cid csecret <<< "${conflict}"
  CASE_DIR="${TMPDIR_ROOT}/conflict-${cname}"
  mkdir -p "${CASE_DIR}"
  CASE_OUT="${CASE_DIR}/stdout"
  CASE_ERR="${CASE_DIR}/stderr"
  CASE_RC=0
  # The secret goes through the environment, not the bash -c body.
  env PATH="${MOCK_BIN}:${PATH}" LOG_DIR="${CASE_DIR}" TEST_SECRET_ARG="${csecret}" \
    bash -c "source '${LIB}'; jira_auth_select '${ctoken}' '${cid}' \"\${TEST_SECRET_ARG}\"" \
    > "${CASE_OUT}" 2> "${CASE_ERR}" || CASE_RC=$?
  if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "FULLSEND_JIRA_CLIENT_" "${CASE_ERR}" \
    && ! grep -qF "tok-4" "${CASE_ERR}" && ! grep -qF "${CLIENT_ID}" "${CASE_ERR}"; then
    pass "conflict-${cname}-fails"
  else
    fail "conflict-${cname}-fails" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
  fi
  assert_secret_hidden "conflict-${cname}"
done

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
