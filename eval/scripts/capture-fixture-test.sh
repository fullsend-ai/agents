#!/usr/bin/env bash
# capture-fixture-test.sh — Test capture-fixture.sh's PR-diff capture gate
# and the run_go_checks build/test half of the fixture_checks evidence.
#
# The gate decides whether the extra `gh pr diff` call runs. Getting its
# fallback backwards is silent: cases that need output/pr-<num>.diff would fail
# their content judge for a missing artifact. run_go_checks turns a checkout
# into the {build_exit, test_exit} / {skipped} JSON the fixture_checks judge
# grades — wrong exit-code plumbing would let a non-compiling PR read as
# clean. Only these two are exercised here (run_pr_checks' clone half needs
# live GitHub state).
#
# Usage:
#   bash eval/scripts/capture-fixture-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE_SCRIPT="${SCRIPT_DIR}/capture-fixture.sh"

if [[ ! -f "$CAPTURE_SCRIPT" ]]; then
  echo "FAIL: capture-fixture.sh not found at ${CAPTURE_SCRIPT}" >&2
  exit 1
fi

# Source just the gate: the script itself requires live fixture env and exits.
gate_src="$(sed -n '/^case_wants_pr_diff() {/,/^}/p' "$CAPTURE_SCRIPT")"
if [[ -z "$gate_src" ]]; then
  echo "FAIL: case_wants_pr_diff not found in capture-fixture.sh" >&2
  exit 1
fi
eval "$gate_src"

checks_src="$(sed -n '/^run_go_checks() {/,/^}/p' "$CAPTURE_SCRIPT")"
if [[ -z "$checks_src" ]]; then
  echo "FAIL: run_go_checks not found in capture-fixture.sh" >&2
  exit 1
fi
eval "$checks_src"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
failures=0

# assert_gate <expect: capture|skip> <description>  (CASE_SOURCE_DIR preset)
assert_gate() {
  local expect="$1" desc="$2" actual="capture"
  case_wants_pr_diff || actual="skip"
  if [[ "$actual" == "$expect" ]]; then
    echo "ok: ${desc} → ${actual}"
  else
    echo "FAIL: ${desc} — expected ${expect}, got ${actual}" >&2
    failures=$((failures + 1))
  fi
}

# Unknown case dir must capture: never withhold an artifact a judge may need.
CASE_SOURCE_DIR="" assert_gate capture "CASE_SOURCE_DIR unset"
CASE_SOURCE_DIR="${TMP_ROOT}/missing" assert_gate capture "CASE_SOURCE_DIR points nowhere"

no_symbols="${TMP_ROOT}/no-symbols"
mkdir -p "$no_symbols"
printf 'state: open\nexpected_files:\n  - calc.py\n' > "${no_symbols}/annotations.yaml"
CASE_SOURCE_DIR="$no_symbols" assert_gate skip "case declares no removed_symbols"

with_symbols="${TMP_ROOT}/with-symbols"
mkdir -p "$with_symbols"
printf 'state: open\nremoved_symbols:\n  VerboseLogging:\n    config/config.go: 2\n' \
  > "${with_symbols}/annotations.yaml"
CASE_SOURCE_DIR="$with_symbols" assert_gate capture "case declares removed_symbols"

commented="${TMP_ROOT}/commented"
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
    echo "ok: ${desc} → ${actual}"
  else
    echo "FAIL: ${desc} — expected ${expect}, got ${actual}" >&2
    failures=$((failures + 1))
  fi
}

no_gomod="${TMP_ROOT}/no-gomod"
mkdir -p "$no_gomod"
assert_checks '{"skipped":"no go.mod"}' "$no_gomod" "checkout without go.mod is a recorded skip"

if command -v go >/dev/null 2>&1; then
  clean="${TMP_ROOT}/clean"
  mkdir -p "$clean"
  printf 'module clean\n\ngo 1.21\n' > "${clean}/go.mod"
  printf 'package clean\n\nfunc Two() int { return 2 }\n' > "${clean}/clean.go"
  printf 'package clean\n\nimport "testing"\n\nfunc TestTwo(t *testing.T) {\n\tif Two() != 2 {\n\t\tt.Fatal("nope")\n\t}\n}\n' \
    > "${clean}/clean_test.go"
  assert_checks '{"build_exit":0,"test_exit":0}' "$clean" "compiling module with passing tests"

  # The commented-out-site shape fixture_checks exists for: does not compile.
  broken="${TMP_ROOT}/broken"
  mkdir -p "$broken"
  printf 'module broken\n\ngo 1.21\n' > "${broken}/go.mod"
  printf 'package broken\n\nfunc Two() int { return undefinedSymbol }\n' > "${broken}/broken.go"
  build_json="$(run_go_checks "$broken")"
  if [[ "$build_json" == '{"build_exit":0'* ]]; then
    echo "FAIL: non-compiling module reported build_exit 0: ${build_json}" >&2
    failures=$((failures + 1))
  else
    echo "ok: non-compiling module reports nonzero build_exit → ${build_json}"
  fi

  failing="${TMP_ROOT}/failing"
  mkdir -p "$failing"
  printf 'module failing\n\ngo 1.21\n' > "${failing}/go.mod"
  printf 'package failing\n\nfunc Two() int { return 3 }\n' > "${failing}/failing.go"
  printf 'package failing\n\nimport "testing"\n\nfunc TestTwo(t *testing.T) {\n\tif Two() != 2 {\n\t\tt.Fatal("nope")\n\t}\n}\n' \
    > "${failing}/failing_test.go"
  test_json="$(run_go_checks "$failing")"
  if [[ "$test_json" == '{"build_exit":0,"test_exit":0}' ]]; then
    echo "FAIL: failing tests reported test_exit 0: ${test_json}" >&2
    failures=$((failures + 1))
  else
    echo "ok: failing tests report nonzero test_exit → ${test_json}"
  fi
else
  echo "ok: go toolchain not installed here; skipping build/test-path cases (gate + no-go.mod still covered)"
fi

if [[ $failures -gt 0 ]]; then
  echo "FAIL: ${failures} capture-fixture test(s) failed" >&2
  exit 1
fi
echo "All capture-fixture tests passed"
