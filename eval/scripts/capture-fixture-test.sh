#!/usr/bin/env bash
# capture-fixture-test.sh — Tests for empty fixture responses and PR discovery.
# Required issue and PR views must return JSON before capture writes state.
# A failed or malformed `gh pr list` must be recorded as pull_requests_fetch_failed
# (PR existence unknown), never as a successful empty pull_requests=[].
# Also runs eval/code/eval.yaml's pr_created and expected_files judges
# against each captured state. Fully offline: `gh` is a stub on PATH.
#
# Run from the repo root:
#   bash eval/scripts/capture-fixture-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE="${SCRIPT_DIR}/capture-fixture.sh"
EVAL_YAML="${SCRIPT_DIR}/../code/eval.yaml"
FAILURES=0
TESTS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The judge assertions need yq (the script-test workflow installs it). Fail
# hard rather than skip, so a missing dependency can never yield a green run
# in which no judge was exercised.
if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required to extract judge blocks from ${EVAL_YAML}" >&2
  exit 1
fi
EXPECT_CALC='{"expected_files": ["calc.py"]}'
EXPECT_NONE='{}'

pass() { TESTS=$((TESTS + 1)); echo "PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL: $1"; }

# Stub gh: issue view and pr view succeed; pr list behaviour is selected by
# GH_STUB_PR_LIST (one|empty|blank|error|malformed|object).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue view")
    if [[ " $* " == *" comments"* ]]; then
      [[ "${GH_STUB_EMPTY_VIEW:-}" == "comments" ]] && exit 0
      echo '{"comments":[]}'
    else
      [[ "${GH_STUB_EMPTY_VIEW:-}" == "issue" ]] && exit 0
      echo '{"state":"OPEN","labels":[],"assignees":[],"milestone":null,"title":"t"}'
    fi
    ;;
  "pr list")
    case "${GH_STUB_PR_LIST}" in
      one) echo '[{"number":7,"title":"fix","url":"https://github.com/o/r/pull/7","state":"OPEN","headRefName":"agent/1-x","baseRefName":"main"}]' ;;
      empty) echo '[]' ;;
      blank) ;;  # exits 0 with empty stdout
      error) echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2; exit 1 ;;
      malformed) echo 'not json' ;;
      object) echo '{"message":"unexpected"}' ;;
    esac
    ;;
  "pr view")
    [[ "${GH_STUB_EMPTY_VIEW:-}" == "pull_request" ]] && exit 0
    if [[ " $* " == *" --json files "* ]]; then
      echo '["calc.py"]'
    else
      echo '{"state":"OPEN","comments":[],"reviews":[],"files":[]}'
    fi
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# run_capture <mode> [fixture_type] — run the capture hook with stubbed gh.
run_capture() {
  local mode="$1" ws="$TMP/$1" fixture_type="${2:-issue}" url_path=issues
  if [[ "$fixture_type" == pull_request ]]; then
    url_path=pull
  fi
  mkdir -p "$ws"
  PATH="$TMP/bin:$PATH" GH_STUB_PR_LIST="$mode" GH_TOKEN="ghp_stubtokenvalue" \
    CASE_WORKSPACE="$ws" EPHEMERAL_REPO="o/r" FIXTURE_NUMBER=1 \
    FIXTURE_TYPE="$fixture_type" FIXTURE_URL="https://github.com/o/r/$url_path/1" \
    bash "$CAPTURE" >/dev/null 2>"$ws/stderr"
}

# expect_state <mode> <jq-filter> <description>
expect_state() {
  if jq -e "$2" "$TMP/$1/output/fixture-state.json" >/dev/null; then
    pass "$1: $3"
  else
    fail "$1: $3 (state: $(cat "$TMP/$1/output/fixture-state.json"))"
  fi
}

# expect_judge <mode> <judge> <True|False> <message-substring> <annotations-json>
# The judge's check block is extracted with yq (byte-identical to the YAML
# block scalar) and exec'd into a function, so the test runs the real judge.
expect_judge() {
  local mode="$1" judge="$2" want="$3" substr="$4" annotations="$5" got check_file
  check_file="$TMP/judge-${mode}-${judge}.py"
  yq -r ".judges[] | select(.name == \"${judge}\") | .check" "$EVAL_YAML" > "$check_file"
  if [[ ! -s "$check_file" ]]; then
    echo "ERROR: could not extract judge '${judge}' from ${EVAL_YAML}" >&2
    exit 1
  fi
  got=$(python3 - "$check_file" "$TMP/$mode/output/fixture-state.json" "$annotations" <<'PY'
import json, sys, textwrap
check_path, state_path, annotations = sys.argv[1:4]
ns = {}
exec("def check(outputs):\n" + textwrap.indent(open(check_path).read(), "    "), ns)
outputs = {"files": {"output/fixture-state.json": open(state_path).read()},
           "annotations": json.loads(annotations)}
ok, msg = ns["check"](outputs)
print(f"{ok}|{msg}")
PY
)
  if [[ "${got%%|*}" == "$want" && "${got#*|}" == *"$substr"* ]]; then
    pass "$mode: $judge returns $want"
  else
    fail "$mode: $judge expected $want containing '$substr', got '$got'"
  fi
}

# 1. Successful nonempty lookup.
run_capture one
expect_state one '.pull_requests_fetch_failed == false' "pull_requests_fetch_failed is false"
expect_state one '.pull_requests | length == 1 and .[0].files == ["calc.py"]' "PR recorded with files"
expect_judge one pr_created True "PR created" "$EXPECT_CALC"
expect_judge one expected_files True "All expected files present" "$EXPECT_CALC"

# 2. Successful empty lookup keeps the existing missing-PR behaviour.
run_capture empty
expect_state empty '.comments == []' "valid empty comments are captured"
expect_state empty '.pull_requests_fetch_failed == false' "pull_requests_fetch_failed is false"
expect_state empty '.pull_requests == []' "pull_requests is an empty list"
expect_judge empty pr_created False "No pull requests found" "$EXPECT_CALC"
expect_judge empty expected_files False "Expected files missing" "$EXPECT_CALC"

# 3. Exhausted retries, 4. malformed / non-array responses, and 5. exit 0
# with empty stdout (no JSON at all) must all be flagged as lookup failures.
for mode in error blank malformed object; do
  run_capture "$mode"
  expect_state "$mode" '.pull_requests_fetch_failed == true' "pull_requests_fetch_failed is true"
  expect_state "$mode" '.pull_requests == null' "pull_requests is null, not an empty success"
  if grep -q 'gh pr list' "$TMP/$mode/stderr" && grep -q 'o/r' "$TMP/$mode/stderr"; then
    pass "$mode: warning names the failed operation and repo"
  else
    fail "$mode: warning names the failed operation and repo (stderr: $(cat "$TMP/$mode/stderr"))"
  fi
  if grep -q 'ghp_stubtokenvalue' "$TMP/$mode/stderr"; then
    fail "$mode: diagnostics do not include the token"
  else
    pass "$mode: diagnostics do not include the token"
  fi
  expect_judge "$mode" pr_created False "PR existence unknown" "$EXPECT_CALC"
  expect_judge "$mode" expected_files False "Infrastructure failure" "$EXPECT_CALC"
  # A discovery failure must fail expected_files even when the case declares
  # no expected_files (the flag check precedes the no-expectations early return).
  expect_judge "$mode" expected_files False "Infrastructure failure" "$EXPECT_NONE"
done

# A successful gh call with no output must not publish an empty snapshot.
for view in issue comments pull_request; do
  fixture_type=issue
  if [[ "$view" == pull_request ]]; then
    fixture_type=pull_request
  fi
  if GH_STUB_EMPTY_VIEW="$view" run_capture "blank-$view" "$fixture_type"; then
    fail "empty $view response: capture unexpectedly succeeded"
  elif [[ -e "$TMP/blank-$view/output/fixture-state.json" ]]; then
    fail "empty $view response: failed capture left a snapshot"
  else
    pass "empty $view response: capture failed before publishing the snapshot"
  fi
done

run_capture valid-pr pull_request
expect_state valid-pr '.pr_fetch_failed == false and .comments == [] and .files == []' \
  "a PR with empty comments and files is captured"

state="$TMP/valid-pr/output/fixture-state.json"
cp "$state" "$TMP/previous-state.json"
if GH_STUB_EMPTY_VIEW=pull_request run_capture valid-pr pull_request; then
  fail "recapture with empty PR data unexpectedly succeeded"
elif cmp -s "$TMP/previous-state.json" "$state"; then
  pass "failed recapture preserves the previous snapshot"
else
  fail "failed recapture replaced the previous snapshot"
fi

echo ""
echo "=== $TESTS tests, $FAILURES failures ==="
[[ $FAILURES -eq 0 ]]
