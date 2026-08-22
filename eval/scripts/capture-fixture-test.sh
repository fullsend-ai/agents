#!/usr/bin/env bash
# capture-fixture-test.sh — Test capture-fixture.sh's PR-diff capture gate.
#
# The gate decides whether the extra `gh pr diff` call runs. Getting its
# fallback backwards is silent: cases that need output/pr-<num>.diff would fail
# their content judge for a missing artifact. Only the gate is exercised here —
# the rest of capture-fixture.sh needs live GitHub state.
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

if [[ $failures -gt 0 ]]; then
  echo "FAIL: ${failures} capture-fixture gate test(s) failed" >&2
  exit 1
fi
echo "All capture-fixture tests passed"
