#!/usr/bin/env bash
# Tests for setup-fixture.sh: the EVAL_REPO_VISIBILITY value is validated
# before anything is created, the developer's git hooks are bypassed on the
# snapshot commit only for a private repo, and a half-created repo found on
# retry is reused only with the visibility this run asked for.
#
# gh, git, sleep and uuidgen are stubs that record their arguments; yq and jq
# are the real ones. The script needs bash 4 (mapfile), so it runs under the
# same bash as this test.
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
# reports staged changes so the snapshot commit runs.
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
    "$BASH" "$SCRIPT"
}

gh_calls() { cat "$1/capture/gh-calls.log" 2>/dev/null || true; }
git_calls() { cat "$1/capture/git-calls.log" 2>/dev/null || true; }
sleep_calls() { cat "$1/capture/sleep-calls.log" 2>/dev/null || true; }

# --- An unknown visibility value is refused before anything is created ---
ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
RC=0
OUT=$(run_sf "$ROOT" EVAL_REPO_VISIBILITY=privte 2>&1) || RC=$?
if [[ $RC -eq 1 ]] \
  && echo "$OUT" | grep -q "EVAL_REPO_VISIBILITY must be private, public or internal, not 'privte'" \
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
  && ! echo "$OUT" | grep -q "WARNING" \
  && grep -q 'FIXTURE_NUMBER: "7"' "${ROOT}/ws/.hook-outputs.yaml"; then
  pass "by default the repo is private and the snapshot commit bypasses local git hooks"
else
  fail "by default the repo is private and the snapshot commit bypasses local git hooks (rc=$RC, output: $OUT)"
fi
rm -rf "$ROOT"

# --- public and internal keep the developer's hooks and warn ---
for vis in public internal; do
  ROOT="$(mktemp -d)"; setup_fixture "$ROOT"
  RC=0
  OUT=$(run_sf "$ROOT" EVAL_REPO_VISIBILITY="$vis" 2>&1) || RC=$?
  if [[ $RC -eq 0 ]] \
    && gh_calls "$ROOT" | grep -q "^repo create testorg/eval-case-deadbeef --${vis} " \
    && git_calls "$ROOT" | grep -q -- " commit -m eval: initial content" \
    && ! git_calls "$ROOT" | grep -qE "hooksPath|no-verify" \
    && echo "$OUT" | grep -q "WARNING: EVAL_REPO_VISIBILITY=${vis}: the snapshot will be visible beyond the eval account; local git hooks run on this commit"; then
    pass "EVAL_REPO_VISIBILITY=${vis} keeps local git hooks on the snapshot commit and warns"
  else
    fail "EVAL_REPO_VISIBILITY=${vis} keeps local git hooks on the snapshot commit and warns (rc=$RC, output: $OUT)"
  fi
  rm -rf "$ROOT"
done

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
  && [[ "$(sleep_calls "$ROOT" | tr '\n' ' ')" == "sleep 5 sleep 10 sleep 15 " ]]; then
  pass "three failed creates with no existing repo give up after the documented backoff"
else
  fail "three failed creates with no existing repo give up after the documented backoff (rc=$RC, output: $OUT, sleeps: $(sleep_calls "$ROOT" | tr '\n' ' '))"
fi
rm -rf "$ROOT"

echo
echo "=== ${TESTS} tests, ${FAILURES} failures ==="
[[ $FAILURES -eq 0 ]]
