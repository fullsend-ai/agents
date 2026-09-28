#!/usr/bin/env bash
# harness-steer-optout-test.sh — Verify every harness with a pre-script
# declares steering explicitly.
#
# The fullsend runner steers every harness by default: a follow-up event on the
# same work item is delivered into the run already in flight, and the delivery
# is receipted so the queued run skips. An agent that does not act on the
# update loses it. These agents opt out with `steer: {enabled: false}`, and
# this test fails if a later edit drops that. The agents taught the envelope
# opt in with `steer: {enabled: true}`. An absorbed update skips the
# pre-script, so fullsend's lint warns when a harness with a pre_script leaves
# steer.enabled unset. This test fails on any such harness.
#
# Run from the repo root: bash scripts/harness-steer-optout-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0

# prioritize and retro are one-shot analyses; scribe is scheduled and has no
# work item.
OPTOUT_AGENTS="prioritize retro scribe"

for agent in ${OPTOUT_AGENTS}; do
  file="${REPO_ROOT}/harness/${agent}.yaml"
  if [[ ! -f "${file}" ]]; then
    echo "FAIL: ${agent} — harness/${agent}.yaml not found"
    FAILURES=$((FAILURES + 1))
    continue
  fi
  # Exactly the boolean false: a missing key, null, or the string "false" would
  # leave steering on.
  got="$(yq '.steer.enabled | (tag + ":" + tostring)' "${file}")"
  if [[ "${got}" == "!!bool:false" ]]; then
    echo "PASS: ${agent} — steer.enabled is false"
  else
    echo "FAIL: ${agent} — harness/${agent}.yaml must set steer.enabled: false (got ${got})"
    FAILURES=$((FAILURES + 1))
  fi
done

# code, fix, review and triage are taught the runner-update envelope.
STEERED_AGENTS="code fix review triage"

for agent in ${STEERED_AGENTS}; do
  file="${REPO_ROOT}/harness/${agent}.yaml"
  if [[ ! -f "${file}" ]]; then
    echo "FAIL: ${agent} — harness/${agent}.yaml not found"
    FAILURES=$((FAILURES + 1))
    continue
  fi
  got="$(yq '.steer.enabled | (tag + ":" + tostring)' "${file}")"
  if [[ "${got}" == "!!bool:true" ]]; then
    echo "PASS: ${agent} — steer.enabled is true"
  else
    echo "FAIL: ${agent} — harness/${agent}.yaml must set steer.enabled: true (got ${got})"
    FAILURES=$((FAILURES + 1))
  fi
done

# Every harness with a pre_script declares steer.enabled as a boolean.
for file in "${REPO_ROOT}"/harness/*.yaml; do
  name="$(basename "${file}" .yaml)"
  if [[ "$(yq '.pre_script // ""' "${file}")" == "" ]]; then
    continue
  fi
  got="$(yq '.steer.enabled | tag' "${file}")"
  if [[ "${got}" == "!!bool" ]]; then
    echo "PASS: ${name} — has a pre_script and declares steer.enabled"
  else
    echo "FAIL: ${name} — has a pre_script but leaves steer.enabled unset (got ${got})"
    FAILURES=$((FAILURES + 1))
  fi
done

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All harness steer tests passed"
