#!/usr/bin/env bash
# Tests for setup-fixture.sh: the EVAL_REPO_VISIBILITY value is validated
# before anything is created; the developer's git hooks are bypassed on the
# snapshot commit and its push only for a private repo; a half-created repo
# found on retry is reused only with the visibility this run asked for; the
# snapshot push is retried (STUB_PUSH_FAILURES fails the first N pushes); and
# the repo name is recorded for teardown-fixture.sh as soon as it exists, so a
# later failure still leaves the record behind (#1736).
#
# gh, git, sleep and uuidgen are stubs that record their arguments; yq and jq
# are the real ones. The script needs bash 4 (mapfile), so it runs under the
# same bash as this test, except for one public-repo case that is also run
# under /bin/bash when that bash predates 4.4 (SF_BASH).
#
# Run from the repo root:
#   bash eval/scripts/setup-fixture-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/setup-fixture.sh"
FAILURES=0
TESTS=0

for tool in yq jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool is required to run these tests" >&2
    exit 1
  fi
done
REAL_YQ_DIR="$(dirname "$(command -v yq)")"
REAL_JQ_DIR="$(dirname "$(command -v jq)")"
BASH_DIR="$(dirname "$BASH")"

pass() { TESTS=$((TESTS + 1)); echo "PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL: $1"; }

setup_fixture() { # root
  local root="$1"
  mkdir -p "${root}/bin" "${root}/capture" "${root}/case" "${root}/ws"
  cat > "${root}/case/input.yaml" <<'YAML'
fixture:
  type: issue
  title: Test issue
  body: Test body
YAML

  cat > "${root}/bin/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Stub gh: records every call; STUB_CREATE_RC fails `repo create`, and
# STUB_EXISTING_VISIBILITY makes `repo view` find a repo with that visibility.
set -euo pipefail
echo "$*" >> "${CAPTURE_DIR}/gh-calls.log"
case "${1:-} ${2:-}" in
  "repo create") exit "${STUB_CREATE_RC:-0}" ;;
  "repo view")
    if [[ -n "${STUB_EXISTING_VISIBILITY:-}" ]]; then echo "$STUB_EXISTING_VISIBILITY"; exit 0; fi
    exit 1 ;;
  "issue create") echo "https://github.com/testorg/eval-case-deadbeef/issues/7" ;;
  "pr create") echo "https://github.com/testorg/eval-case-deadbeef/pull/8" ;;
  *) exit 0 ;;
esac
STUBEOF

  cat > "${root}/bin/git" <<'STUBEOF'
#!/usr/bin/env bash
# Stub git: records every call with its -C / -c options, fakes a clone and
# reports staged changes so the snapshot commit runs. STUB_PUSH_FAILURES makes
# the first N pushes fail.
set -euo pipefail
echo "$*" >> "${CAPTURE_DIR}/git-calls.log"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|-c) shift 2 ;;
    *) break ;;
  esac
done
case "${1:-}" in
  clone) mkdir -p "${@: -1}" ;;
  diff) exit 1 ;;
  rev-parse) echo 0123456789abcdef0123456789abcdef01234567 ;;
  push)
    n=$(( $(cat "${CAPTURE_DIR}/push-calls" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "${CAPTURE_DIR}/push-calls"
    [[ $n -gt ${STUB_PUSH_FAILURES:-0} ]] || exit 1 ;;
  *) exit 0 ;;
esac
STUBEOF

  cat > "${root}/bin/sleep" <<'STUBEOF'
#!/usr/bin/env bash
echo "sleep $*" >> "${CAPTURE_DIR}/sleep-calls.log"
STUBEOF

  cat > "${root}/bin/uuidgen" <<'STUBEOF'
#!/usr/bin/env bash
echo DEADBEEF-0000-4000-8000-000000000000
STUBEOF

  chmod +x "${root}/bin/"*
}

run_sf() { # root [VAR=value ...]
  local root="$1"
  shift
  env -i \
    PATH="${root}/bin:${REAL_YQ_DIR}:${REAL_JQ_DIR}:${BASH_DIR}:/usr/bin:/bin" \
    HOME="$root" \
    GH_TOKEN="test-token" \
    CAPTURE_DIR="${root}/capture" \
    CASE_SOURCE_DIR="${root}/case" \
    CASE_WORKSPACE="${root}/ws" \
    EVAL_ORG="testorg" \
    "$@" \
    "${SF_BASH:-$BASH}" "$SCRIPT"
}

gh_calls() { cat "$1/capture/gh-calls.log" 2>/dev/null || true; }
hook_output() { yq -r "$2 // \"\"" "$1/ws/.hook-outputs.yaml" 2>/dev/null || true; }
git_calls() { cat "$1/capture/git-calls.log" 2>/dev/null || true; }
sleep_calls() { cat "$1/capture/sleep-calls.log" 2>/dev/null || true; }

# --- An unknown visibility value is refused before anything is created ---
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_sf "$ROOT" EVAL_REPO_VISIBILITY=privte 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "EVAL_REPO_VISIBILITY must be private or public, not 'privte'" \
  && ! gh_calls "$ROOT" | grep -q "repo create"; then
  pass "an unknown EVAL_REPO_VISIBILITY is refused before gh repo create"
else
  fail "an unknown EVAL_REPO_VISIBILITY is refused before gh repo create (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# --- The default is private, and the snapshot commit bypasses local hooks ---
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_sf "$ROOT" 2>&1) || RC=$?
if [[ $RC -eq 0 ]] \
  && gh_calls "$ROOT" | grep -q "^repo create testorg/eval-case-deadbeef --private " \
  && git_calls "$ROOT" | grep -q -- "-c core.hooksPath=/dev/null commit --no-verify -m eval: initial content" \
  && git_calls "$ROOT" | grep -q -- "-c core.hooksPath=/dev/null push origin HEAD" \
  && ! echo "$OUT" | grep -q "WARNING" \
  && [[ "$(hook_output "$ROOT" .env.EPHEMERAL_REPO)" == "testorg/eval-case-deadbeef" ]] \
  && [[ "$(hook_output "$ROOT" .data.ephemeral_repo)" == "testorg/eval-case-deadbeef" ]] \
  && [[ "$(hook_output "$ROOT" .env.FIXTURE_URL)" == "https://github.com/testorg/eval-case-deadbeef/issues/7" ]] \
  && [[ "$(hook_output "$ROOT" .env.FIXTURE_NUMBER)" == "7" ]] \
  && [[ "$(hook_output "$ROOT" .env.FIXTURE_TYPE)" == "issue" ]]; then
  pass "by default the repo is private, the commit and push bypass local git hooks, and the full hook outputs replace the early record"
else
  fail "by default the repo is private, the commit and push bypass local git hooks, and the full hook outputs replace the early record (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# --- public keeps the developer's hooks on the commit and the push, and warns ---
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_sf "$ROOT" EVAL_REPO_VISIBILITY=public 2>&1) || RC=$?
if [[ $RC -eq 0 ]] \
  && gh_calls "$ROOT" | grep -q "^repo create testorg/eval-case-deadbeef --public " \
  && git_calls "$ROOT" | grep -q -- " commit -m eval: initial content" \
  && git_calls "$ROOT" | grep -q -- " push origin HEAD" \
  && ! git_calls "$ROOT" | grep -qE "hooksPath|no-verify" \
  && echo "$OUT" | grep -q "WARNING: EVAL_REPO_VISIBILITY=public: the snapshot will be published under the eval account; local git hooks run on this commit and its push"; then
  pass "EVAL_REPO_VISIBILITY=public keeps local git hooks on the snapshot commit and push, and warns"
else
  fail "EVAL_REPO_VISIBILITY=public keeps local git hooks on the snapshot commit and push, and warns (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# --- internal is not an accepted value ---
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_sf "$ROOT" EVAL_REPO_VISIBILITY=internal 2>&1) || RC=$?
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "must be private or public, not 'internal'" && ! gh_calls "$ROOT" | grep -q "repo create"; then
  pass "EVAL_REPO_VISIBILITY=internal is refused before gh repo create"
else
  fail "EVAL_REPO_VISIBILITY=internal is refused before gh repo create (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# --- A half-created repo is reused when its visibility matches ---
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_sf "$ROOT" STUB_CREATE_RC=1 STUB_EXISTING_VISIBILITY=PRIVATE 2>&1) || RC=$?
if [[ $RC -eq 0 ]] \
  && [[ "$(gh_calls "$ROOT" | grep -c "^repo create ")" == "1" ]] \
  && git_calls "$ROOT" | grep -q "commit --no-verify -m eval: initial content" \
  && [[ -z "$(sleep_calls "$ROOT")" ]]; then
  pass "a failed create followed by an existing repo of the requested visibility continues without retrying"
else
  fail "a failed create followed by an existing repo of the requested visibility continues without retrying (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# --- A half-created repo of another visibility is refused ---
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_sf "$ROOT" STUB_CREATE_RC=1 STUB_EXISTING_VISIBILITY=PUBLIC 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "testorg/eval-case-deadbeef already exists with visibility public, not private; refusing to reuse it" \
  && ! git_calls "$ROOT" | grep -q "commit"; then
  pass "a failed create followed by an existing repo of another visibility is refused before any push"
else
  fail "a failed create followed by an existing repo of another visibility is refused before any push (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# --- Three failed creates with no repo give up ---
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_sf "$ROOT" STUB_CREATE_RC=1 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "could not create testorg/eval-case-deadbeef after 3 attempts" \
  && [[ "$(gh_calls "$ROOT" | grep -c "^repo create ")" == "3" ]] \
  && [[ "$(sleep_calls "$ROOT" | tr '\n' ' ')" == "sleep 5 sleep 10 " ]] \
  && [[ ! -f "${ROOT}/ws/.hook-outputs.yaml" ]]; then
  pass "three failed creates with no existing repo give up after two backoffs, with no sleep after the last, and record nothing for teardown"
else
  fail "three failed creates with no existing repo give up after two backoffs, with no sleep after the last, and record nothing for teardown (rc=$RC, output: $OUT, sleeps: $(sleep_calls "$ROOT" | tr '\n' ' '))"
fi
rm -rf "$ROOT"

# --- The snapshot push is retried, with the hook setting of the commit ---
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_sf "$ROOT" STUB_PUSH_FAILURES=2 2>&1) || RC=$?
if [[ $RC -eq 0 ]] \
  && [[ "$(git_calls "$ROOT" | grep -c -- "-c core.hooksPath=/dev/null push origin HEAD")" == "3" ]] \
  && [[ "$(sleep_calls "$ROOT" | tr '\n' ' ')" == "sleep 10 sleep 20 " ]] \
  && echo "$OUT" | grep -q "WARNING: push attempt 2 failed; retrying in 20s" \
  && gh_calls "$ROOT" | grep -q "^issue create "; then
  pass "a push that fails twice is retried with backoff and the run continues"
else
  fail "a push that fails twice is retried with backoff and the run continues (rc=$RC, output: $OUT, sleeps: $(sleep_calls "$ROOT" | tr '\n' ' '))"
fi
rm -rf "$ROOT"

# --- Three failed pushes give up; the early teardown record survives ---
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_sf "$ROOT" STUB_PUSH_FAILURES=3 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "could not push the snapshot to testorg/eval-case-deadbeef after 3 attempts" \
  && [[ "$(git_calls "$ROOT" | grep -c " push origin HEAD")" == "3" ]] \
  && [[ "$(sleep_calls "$ROOT" | tr '\n' ' ')" == "sleep 10 sleep 20 " ]] \
  && ! gh_calls "$ROOT" | grep -q "^issue create " \
  && [[ "$(hook_output "$ROOT" .env.EPHEMERAL_REPO)" == "testorg/eval-case-deadbeef" ]] \
  && [[ "$(hook_output "$ROOT" .data.ephemeral_repo)" == "testorg/eval-case-deadbeef" ]] \
  && [[ -z "$(hook_output "$ROOT" .env.FIXTURE_URL)" ]]; then
  pass "three failed pushes give up with no sleep after the last, nothing created afterwards, and the repo recorded for teardown"
else
  fail "three failed pushes give up with no sleep after the last, nothing created afterwards, and the repo recorded for teardown (rc=$RC, output: $OUT, sleeps: $(sleep_calls "$ROOT" | tr '\n' ' '))"
fi
rm -rf "$ROOT"

# --- The public path survives a bash whose set -u treats an empty array as
# unbound (before 4.4). Run it under the system bash when that is one; a PR
# fixture, since the issue path needs mapfile, which bash 3.2 lacks. ---
if [[ -x /bin/bash ]] && /bin/bash -c '(( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) ))'; then
  ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
  cat > "${ROOT}/case/input.yaml" <<'YAML'
fixture:
  type: pull_request
  title: Test PR
  body: Test body
  files:
    - path: a.txt
      content: hello
YAML
  RC=0
  OUT=$(SF_BASH=/bin/bash run_sf "$ROOT" EVAL_REPO_VISIBILITY=public 2>&1) || RC=$?
  if [[ $RC -eq 0 ]] \
    && git_calls "$ROOT" | grep -q -- " push origin HEAD" \
    && ! git_calls "$ROOT" | grep -qE "hooksPath|no-verify" \
    && ! echo "$OUT" | grep -q "unbound variable"; then
    pass "EVAL_REPO_VISIBILITY=public pushes under $(/bin/bash -c 'echo $BASH_VERSION') with the empty hook option list"
  else
    fail "EVAL_REPO_VISIBILITY=public pushes under $(/bin/bash -c 'echo $BASH_VERSION') with the empty hook option list (rc=$RC, output: $OUT)"
  fi
  rm -rf "$ROOT"
else
  echo "SKIP: /bin/bash is not older than 4.4; empty-array expansion case not run"
fi

echo
echo "=== ${TESTS} tests, ${FAILURES} failures ==="
[[ $FAILURES -eq 0 ]]
