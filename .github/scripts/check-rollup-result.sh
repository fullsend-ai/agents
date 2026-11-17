#!/usr/bin/env bash
# check-rollup-result.sh — Decide whether the functional-tests-complete
# roll-up job should pass or fail.
#
# Inputs (env vars):
#   EVENT_NAME    — github.event_name (issue_comment when called from the
#                   /ok-to-test workflow through workflow_call)
#   GATE_RESULT   — needs.gate.result
#   DETECT_RESULT — needs.detect.result
#   TESTS_RESULT  — needs.functional-tests.result
#   CROSS_REPO    — 'true' when invoked from a different repository
#   HEAD_SHA      — PR head sha (github.event.pull_request.head.sha, or the
#                   sha an /ok-to-test comment authorized)
#
# Exit 0 = pass, exit 1 = fail.

set -euo pipefail

EVENT_NAME="${EVENT_NAME:-}"
GATE_RESULT="${GATE_RESULT:-}"
DETECT_RESULT="${DETECT_RESULT:-}"
TESTS_RESULT="${TESTS_RESULT:-}"
CROSS_REPO="${CROSS_REPO:-}"
HEAD_SHA="${HEAD_SHA:-}"

if [ "$GATE_RESULT" = "failure" ] || [ "$GATE_RESULT" = "cancelled" ]; then
  echo "::error::Gate job ${GATE_RESULT}"
  exit 1
fi

# On a PR event a skipped detect means the tests were not authorized: a fork
# PR (the gate is skipped, fork runs get no secrets) or an author without
# write access. Only a writer's /ok-to-test comment naming the head runs them.
if { [ "$EVENT_NAME" = "pull_request" ] || [ "$EVENT_NAME" = "issue_comment" ]; } \
   && [ "$DETECT_RESULT" = "skipped" ]; then
  # Only a 40-character hex sha reaches the ::error:: line.
  sha="<full sha of the latest push>"
  if printf '%s' "$HEAD_SHA" | grep -Eqx '[0-9a-f]{40}'; then
    sha="$HEAD_SHA"
  fi
  echo "::error::Functional tests were not authorized to run on ${EVENT_NAME}. Someone with write access must review the latest push and comment '/ok-to-test ${sha}' on the PR; a later push needs a new comment."
  exit 1
fi

if [ "$DETECT_RESULT" = "failure" ] || [ "$DETECT_RESULT" = "cancelled" ]; then
  echo "::error::Detect job ${DETECT_RESULT}"
  exit 1
fi

if [ "$TESTS_RESULT" = "failure" ] || [ "$TESTS_RESULT" = "cancelled" ]; then
  echo "::error::One or more functional tests ${TESTS_RESULT}"
  exit 1
fi

if [ "$CROSS_REPO" = "true" ] && [ "$TESTS_RESULT" = "skipped" ]; then
  echo "::error::Cross-repo call completed with zero functional tests — agents list was empty or detect was skipped"
  exit 1
fi
