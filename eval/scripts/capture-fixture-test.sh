#!/usr/bin/env bash
# capture-fixture-test.sh — Tests for empty fixture responses and PR discovery.
# Required issue and PR views must return JSON before capture writes state.
# A failed or malformed `gh pr list` must be recorded as pull_requests_fetch_failed
# (PR existence unknown), never as a successful empty pull_requests=[].
# Also runs eval/code/eval.yaml's pr_created and expected_files judges
# against each captured state. Fully offline: `gh` is a stub on PATH.
#
# Second half: the PR-diff capture gate (case_wants_pr_diff) and the
# run_go_checks build/test half of the fixture_checks evidence. Getting the
# gate's fallback backwards is silent: cases that need output/pr-<num>.diff
# would fail their content judge for a missing artifact. Wrong exit-code
# plumbing in run_go_checks would let a non-compiling PR read as clean.
# run_pr_checks' clone half needs live GitHub state and is not exercised.
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

# 001-fix-add declares no removed_symbols, so capture skips the PR-diff
# fetch and the build/test clone (both need live GitHub state).
CASE_001="${SCRIPT_DIR}/../code/cases/001-fix-add"

# run_capture <mode> [fixture_type] — run the capture hook with stubbed gh.
run_capture() {
  local mode="$1" ws="$TMP/$1" fixture_type="${2:-issue}" url_path=issues
  if [[ "$fixture_type" == pull_request ]]; then
    url_path=pull
  fi
  mkdir -p "$ws"
  PATH="$TMP/bin:$PATH" GH_STUB_PR_LIST="$mode" GH_TOKEN="ghp_stubtokenvalue" \
    CASE_WORKSPACE="$ws" CASE_SOURCE_DIR="$CASE_001" EPHEMERAL_REPO="o/r" FIXTURE_NUMBER=1 \
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

# --- PR-diff capture gate ---

# Source just the gate: the script itself requires live fixture env and exits.
gate_src="$(sed -n '/^case_wants_pr_diff() {/,/^}/p' "$CAPTURE")"
if [[ -z "$gate_src" ]]; then
  echo "ERROR: case_wants_pr_diff not found in capture-fixture.sh" >&2
  exit 1
fi
eval "$gate_src"

checks_src="$(sed -n '/^run_go_checks() {/,/^}/p' "$CAPTURE")"
if [[ -z "$checks_src" ]]; then
  echo "ERROR: run_go_checks not found in capture-fixture.sh" >&2
  exit 1
fi
eval "$checks_src"

# assert_gate <expect: capture|skip> <description>  (CASE_SOURCE_DIR preset)
assert_gate() {
  local expect="$1" desc="$2" actual="capture"
  case_wants_pr_diff || actual="skip"
  if [[ "$actual" == "$expect" ]]; then
    pass "${desc} → ${actual}"
  else
    fail "${desc} — expected ${expect}, got ${actual}"
  fi
}

# Unknown case dir must capture: never withhold an artifact a judge may need.
CASE_SOURCE_DIR="" assert_gate capture "CASE_SOURCE_DIR unset"
CASE_SOURCE_DIR="${TMP}/missing" assert_gate capture "CASE_SOURCE_DIR points nowhere"

no_symbols="${TMP}/no-symbols"
mkdir -p "$no_symbols"
printf 'state: open\nexpected_files:\n  - calc.py\n' > "${no_symbols}/annotations.yaml"
CASE_SOURCE_DIR="$no_symbols" assert_gate skip "case declares no removed_symbols"

with_symbols="${TMP}/with-symbols"
mkdir -p "$with_symbols"
printf 'state: open\nremoved_symbols:\n  VerboseLogging:\n    config/config.go: 2\n' \
  > "${with_symbols}/annotations.yaml"
CASE_SOURCE_DIR="$with_symbols" assert_gate capture "case declares removed_symbols"

commented="${TMP}/commented"
mkdir -p "$commented"
printf 'state: open\n# removed_symbols: not declared, just discussed\n' \
  > "${commented}/annotations.yaml"
CASE_SOURCE_DIR="$commented" assert_gate skip "removed_symbols only mentioned in a comment"

# --- run_go_checks ----------------------------------------------------------

# assert_checks <expect-json> <dir> <description>
assert_checks() {
  local expect="$1" dir="$2" desc="$3" actual
  actual="$(run_go_checks "$dir")"
  if [[ "$actual" == "$expect" ]]; then
    pass "${desc} → ${actual}"
  else
    fail "${desc} — expected ${expect}, got ${actual}"
  fi
}

no_gomod="${TMP}/no-gomod"
mkdir -p "$no_gomod"
assert_checks '{"skipped":"no go.mod"}' "$no_gomod" "checkout without go.mod is a recorded skip"

if command -v go >/dev/null 2>&1; then
  clean="${TMP}/clean"
  mkdir -p "$clean"
  printf 'module clean\n\ngo 1.21\n' > "${clean}/go.mod"
  printf 'package clean\n\nfunc Two() int { return 2 }\n' > "${clean}/clean.go"
  printf 'package clean\n\nimport "testing"\n\nfunc TestTwo(t *testing.T) {\n\tif Two() != 2 {\n\t\tt.Fatal("nope")\n\t}\n}\n' \
    > "${clean}/clean_test.go"
  assert_checks '{"build_exit":0,"test_exit":0}' "$clean" "compiling module with passing tests"

  # The commented-out-site shape fixture_checks exists for: does not compile.
  # Assert build_exit != 0 specifically (not just "not all-zero"), so a
  # test-only failure could not masquerade as the broken-build case.
  broken="${TMP}/broken"
  mkdir -p "$broken"
  printf 'module broken\n\ngo 1.21\n' > "${broken}/go.mod"
  printf 'package broken\n\nfunc Two() int { return undefinedSymbol }\n' > "${broken}/broken.go"
  build_json="$(run_go_checks "$broken")"
  if [[ "$(jq -r '.build_exit' <<<"$build_json")" != 0 ]]; then
    pass "non-compiling module reports nonzero build_exit → ${build_json}"
  else
    fail "non-compiling module reported build_exit 0: ${build_json}"
  fi

  # A failing test must be build_exit 0 AND test_exit != 0 — not merely
  # "not the all-zero literal", which a build error would also satisfy.
  failing="${TMP}/failing"
  mkdir -p "$failing"
  printf 'module failing\n\ngo 1.21\n' > "${failing}/go.mod"
  printf 'package failing\n\nfunc Two() int { return 3 }\n' > "${failing}/failing.go"
  printf 'package failing\n\nimport "testing"\n\nfunc TestTwo(t *testing.T) {\n\tif Two() != 2 {\n\t\tt.Fatal("nope")\n\t}\n}\n' \
    > "${failing}/failing_test.go"
  test_json="$(run_go_checks "$failing")"
  if [[ "$(jq -r '.build_exit' <<<"$test_json")" == 0 && "$(jq -r '.test_exit' <<<"$test_json")" != 0 ]]; then
    pass "failing tests report build_exit 0, nonzero test_exit → ${test_json}"
  else
    fail "failing tests not reported as build 0 / test nonzero: ${test_json}"
  fi

  # Containment: the env -i scrub must strip runner credentials so agent-
  # authored `go test` cannot read them. This is the property the commit
  # message claims and the accepted mitigation for running that code on the
  # privileged runner — prove it. A test that t.Fatals when any credential
  # var is visible must still pass (test_exit 0) even with all of them
  # exported into the parent shell here.
  scrub_mod="${TMP}/scrub"
  mkdir -p "$scrub_mod"
  printf 'module scrub\n\ngo 1.21\n' > "${scrub_mod}/go.mod"
  printf 'package scrub\n' > "${scrub_mod}/scrub.go"
  cat > "${scrub_mod}/scrub_test.go" <<'GO'
package scrub

import (
	"os"
	"testing"
)

func TestNoRunnerSecrets(t *testing.T) {
	for _, k := range []string{
		"EVAL_GH_TOKEN", "GH_TOKEN", "GOOGLE_APPLICATION_CREDENTIALS",
		"ACTIONS_ID_TOKEN_REQUEST_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_URL",
	} {
		if os.Getenv(k) != "" {
			t.Fatalf("runner secret %s leaked into the go test env", k)
		}
	}
}
GO
  scrub_json="$(EVAL_GH_TOKEN=x GH_TOKEN=x GOOGLE_APPLICATION_CREDENTIALS=/x \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=x ACTIONS_ID_TOKEN_REQUEST_URL=https://x \
    run_go_checks "$scrub_mod")"
  if [[ "$scrub_json" == '{"build_exit":0,"test_exit":0}' ]]; then
    pass "env -i scrub hides all five runner secrets from go test → ${scrub_json}"
  else
    fail "credential vars survived the scrub into go test: ${scrub_json}"
  fi

  # Containment: GOPROXY=off + -mod=readonly must stop a module fetch, so a
  # test needing a network dependency cannot build (let alone reach out).
  net_mod="${TMP}/net"
  mkdir -p "$net_mod"
  printf 'module net\n\ngo 1.21\n\nrequire rsc.io/quote v1.5.2\n' > "${net_mod}/go.mod"
  printf 'package net\n\nimport _ "rsc.io/quote"\n' > "${net_mod}/net.go"
  net_json="$(run_go_checks "$net_mod")"
  if [[ "$(jq -r '.build_exit' <<<"$net_json")" != 0 ]]; then
    pass "module needing a network fetch cannot build under the scrub → ${net_json}"
  else
    fail "network-dependent module built despite GOPROXY=off: ${net_json}"
  fi
else
  pass "go toolchain not installed here; skipping build/test-path cases (gate + no-go.mod still covered)"
fi

echo ""
echo "=== $TESTS tests, $FAILURES failures ==="
[[ $FAILURES -eq 0 ]]
