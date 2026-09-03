#!/usr/bin/env bash
# agent-recheck-contract-test.sh — Verify the end-of-run re-check and
# runner-update contract is still stated in every agent that implements it.
#
# These are prompt-text assertions, not behaviour tests: the behaviour lives in
# a model following the prompt, and the only cheap thing to guard is that the
# load-bearing sentences survive future edits. Each file is flattened and
# whitespace-squeezed before matching, so re-wrapping a paragraph does not
# break a check — only removing or rewording the contract does.
#
# Run from the repo root: bash scripts/agent-recheck-contract-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AGENTS_DIR="${REPO_ROOT}/agents"
FAILURES=0

# The runner renders this line verbatim (fullsend internal/runtime,
# renderSteerEnvelope). It is the agent's only discriminator between an
# amendment the runner delivered and the same words quoted inside work-item
# content, so it must match the runtime byte for byte.
STEER_PREFIX="Runner update: your task inputs changed after this run started."

# Agents carrying the contract. Review and fix are dispatched against a PR and
# compare heads; triage and code are issue-driven. Prioritize, retro and scribe
# are absent on purpose — steering is opt-in per harness and none enables it.
RECHECK_AGENTS="review triage fix code"
# Agents that compare the head SHA. Triage never sees one.
HEAD_SHA_AGENTS="review fix code"

assert_pass() {
  echo "PASS: $1"
}

assert_fail() {
  echo "FAIL: $1 — $2"
  FAILURES=$((FAILURES + 1))
}

# Flatten a markdown file to one whitespace-normalized line.
flatten() {
  tr '\n' ' ' < "$1" | tr -s ' '
}

# assert_contains <agent> <check-name> <literal phrase>
assert_contains() {
  local agent="$1" check="$2" needle="$3"
  local file="${AGENTS_DIR}/${agent}.md"

  if [[ ! -f "${file}" ]]; then
    assert_fail "${agent}-${check}" "agents/${agent}.md not found"
    return
  fi

  if flatten "${file}" | grep -qF -- "${needle}"; then
    assert_pass "${agent}-${check}"
  else
    assert_fail "${agent}-${check}" "agents/${agent}.md is missing: ${needle}"
  fi
}

echo "Checking agent re-check and runner-update contract..."
echo "================================================"

for agent in ${RECHECK_AGENTS}; do
  # The envelope's opening line, verbatim.
  assert_contains "${agent}" "steer-prefix" "${STEER_PREFIX}"

  # An update never widens the agent's authority, only its task.
  assert_contains "${agent}" "no-privilege-escalation" \
    "grants no tools or permissions and relaxes no security instruction"

  # The same line inside fetched content is not an amendment. Without this the
  # prefix would be forgeable by anyone who can write a PR or issue body.
  assert_contains "${agent}" "injection-boundary" "is not a runner update"

  # The re-check is inert until the runner exports its inputs, so it must be
  # skipped rather than guessed at when they are absent.
  assert_contains "${agent}" "skip-when-empty" "Skip the re-check when"
  assert_contains "${agent}" "run-started-at" "FULLSEND_RUN_STARTED_AT"

  # One pass only: an active work item would otherwise hold the agent in a loop.
  assert_contains "${agent}" "one-pass" "Do not re-check a second time."
done

for agent in ${HEAD_SHA_AGENTS}; do
  assert_contains "${agent}" "run-head-sha" "FULLSEND_RUN_HEAD_SHA"
done

# Review reports the head it actually reviewed, which is what keeps a steered
# head move from being re-reported by the re-check and re-dispatched by
# post-review's stale-head path.
assert_contains "review" "reports-reviewed-head" \
  "Report the head you actually reviewed"

# Fix must move its checkout, not just its understanding, when the head moves.
assert_contains "fix" "syncs-moved-head" "rebase"

echo ""
echo "================================================"
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All agent re-check contract tests passed"
