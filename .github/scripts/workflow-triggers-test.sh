#!/usr/bin/env bash
# workflow-triggers-test.sh — Guard: no workflow declares pull_request_target.
#
# GitHub blocks pull_request_target by default on public repositories from
# 2026-12-02; a blocked run ends in startup_failure and cannot be re-run
# (#1975). PR workflows use pull_request plus /ok-to-test (ok-to-test.yml) or
# a schedule (vouch-check.yml) instead.
#
# Fails when any file in .github/workflows/ declares pull_request_target under
# `on:` in map, list or string form. Only the trigger key counts: comparing
# github.event_name with the string 'pull_request_target' is fine.
#
# Requires mikefarah yq v4 (installed by script-test.yml).
#
# Run from the repo root: bash .github/scripts/workflow-triggers-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="${SCRIPT_DIR}/../workflows"
FAILURES=0

# Workflows allowed to keep pull_request_target, one file name per line.
# fullsend.yaml: the fullsend consumer shim, synced from fullsend's scaffold.
# It moves off pull_request_target with fullsend-ai/fullsend#9230 (ADR 0164)
# and this repo's next sync; remove the entry then.
ALLOWLIST="fullsend.yaml"

if ! command -v yq >/dev/null 2>&1; then
  echo "FAIL: workflow-triggers-test needs yq (mikefarah yq v4)" >&2
  exit 1
fi

# Prints the event names a workflow declares under `on:`, one per line.
workflow_events() {
  # The parentheses matter: yq binds `,` tighter than `|`.
  yq -r '
    .on
    | ((select(tag == "!!map") | keys | .[]),
       (select(tag == "!!seq") | .[]),
       select(tag == "!!str"))
  ' "$1"
}

declares_prt() {
  local events
  events="$(workflow_events "$1")" || return 2
  grep -qx 'pull_request_target' <<<"${events}"
}

is_allowlisted() {
  grep -qxF -- "$1" <<<"${ALLOWLIST}"
}

# check_dir DIR — prints offending files; returns 1 if any.
check_dir() {
  local dir="$1" f name rc=0 status
  for f in "${dir}"/*.yml "${dir}"/*.yaml; do
    test -f "${f}" || continue
    name="$(basename "${f}")"
    status=0
    declares_prt "${f}" || status=$?
    if test "${status}" -eq 2; then
      echo "${name}: could not parse"
      rc=1
    elif test "${status}" -eq 0 && ! is_allowlisted "${name}"; then
      echo "${name}"
      rc=1
    fi
  done
  return "${rc}"
}

pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES + 1))
}

# --- Self-tests on temp files ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# expect_prt NAME EXPECTED(yes|no) CONTENT
expect_prt() {
  local name="$1" expected="$2" file="${TMPDIR}/case.yml" got=no
  printf '%s\n' "$3" >"${file}"
  if declares_prt "${file}"; then
    got=yes
  fi
  if test "${got}" = "${expected}"; then
    pass "self-test: ${name}"
  else
    fail "self-test: ${name} (expected ${expected}, got ${got})"
  fi
}

expect_prt "map form is detected" yes 'on:
  pull_request_target:
    types: [opened]
jobs: {}'

expect_prt "map form with a null value is detected" yes 'on:
  push:
  pull_request_target:
jobs: {}'

expect_prt "list form is detected" yes 'on: [push, pull_request_target]
jobs: {}'

expect_prt "block list form is detected" yes 'on:
  - push
  - pull_request_target
jobs: {}'

expect_prt "string form is detected" yes 'on: pull_request_target
jobs: {}'

expect_prt "quoted on key is detected" yes '"on":
  pull_request_target: {}
jobs: {}'

expect_prt "pull_request is not pull_request_target" no 'on:
  pull_request:
    types: [opened, synchronize, reopened]
jobs: {}'

expect_prt "event_name string comparisons only" no "on:
  pull_request:
  issue_comment:
    types: [created]
jobs:
  test:
    if: github.event_name != 'pull_request_target'
    runs-on: ubuntu-24.04
    env:
      IS_PRT: \${{ github.event_name == 'pull_request_target' }}
    steps:
      - run: echo pull_request_target"

expect_prt "pull_request_target outside on: is ignored" no 'on: push
env:
  pull_request_target: "1"
jobs: {}'

# check_dir: an allowlisted file passes, any other file fails.
mkdir -p "${TMPDIR}/wf"
printf 'on:\n  pull_request_target:\njobs: {}\n' >"${TMPDIR}/wf/fullsend.yaml"
printf 'on: [pull_request]\njobs: {}\n' >"${TMPDIR}/wf/ok.yml"
if out="$(check_dir "${TMPDIR}/wf")"; then
  pass "self-test: allowlisted file passes"
else
  fail "self-test: allowlisted file passes (got: ${out})"
fi
printf 'on:\n  pull_request_target:\njobs: {}\n' >"${TMPDIR}/wf/bad.yml"
if out="$(check_dir "${TMPDIR}/wf")"; then
  fail "self-test: non-allowlisted file fails"
elif test "${out}" = "bad.yml"; then
  pass "self-test: non-allowlisted file fails"
else
  fail "self-test: non-allowlisted file fails (unexpected output: ${out})"
fi
printf 'on:\n  pull_request_target:\njobs: {}\n' >"${TMPDIR}/wf/bad.yml"
mv "${TMPDIR}/wf/bad.yml" "${TMPDIR}/wf/bad.yaml"
if check_dir "${TMPDIR}/wf" >/dev/null; then
  fail "self-test: .yaml extension is checked too"
else
  pass "self-test: .yaml extension is checked too"
fi

# --- The allowlist entry must still exist ---
# A stale entry would let a re-added file of that name through unnoticed.
while IFS= read -r entry; do
  test -n "${entry}" || continue
  if test -f "${WORKFLOWS_DIR}/${entry}"; then
    pass "allowlisted workflow ${entry} exists"
  else
    fail "allowlisted workflow ${entry} does not exist — remove it from ALLOWLIST"
  fi
done <<<"${ALLOWLIST}"

# --- Repository workflows ---
if out="$(check_dir "${WORKFLOWS_DIR}")"; then
  pass "no workflow outside the allowlist declares pull_request_target"
else
  fail "workflows declare pull_request_target (use pull_request + /ok-to-test, see #1975):"
  sed 's/^/  /' <<<"${out}"
fi

echo ""
if test "${FAILURES}" -gt 0; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All workflow-triggers tests passed."
