#!/usr/bin/env bash
# harness-steer-optout-test.sh — Verify the agents that must not be steered
# opt out of steering in their harness.
#
# The fullsend runner steers every harness by default: a follow-up event on the
# same work item is delivered into the run already in flight, and the delivery
# is receipted so the queued run skips. An agent that does not act on the
# update loses it. These agents opt out with `steer: {enabled: false}`, and
# this test fails if a later edit drops that.
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

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All harness steer opt-out tests passed"
