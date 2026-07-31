#!/usr/bin/env bash
# check-rollup-result.sh — Decide whether the functional-tests-complete
# roll-up job should pass or fail.
#
# Inputs (env vars):
#   EVENT_NAME    — github.event_name
#   EVENT_ACTION  — github.event.action  (only set for pull_request_target)
#   LABEL_NAME    — github.event.label.name (only set when action == labeled)
#   GATE_RESULT   — needs.gate.result
#   DETECT_RESULT — needs.detect.result
#   TESTS_RESULT  — needs.functional-tests.result
#
# Exit 0 = pass, exit 1 = fail.

set -euo pipefail

EVENT_NAME="${EVENT_NAME:-}"
EVENT_ACTION="${EVENT_ACTION:-}"
LABEL_NAME="${LABEL_NAME:-}"
GATE_RESULT="${GATE_RESULT:-}"
DETECT_RESULT="${DETECT_RESULT:-}"
TESTS_RESULT="${TESTS_RESULT:-}"

if [ "$EVENT_NAME" = "pull_request_target" ] && [ "$EVENT_ACTION" = "labeled" ] && [ "$LABEL_NAME" != "ok-to-test" ]; then
  echo "Labeled event (${LABEL_NAME}) is not ok-to-test — skipping is expected"
  exit 0
fi

if [ "$GATE_RESULT" = "failure" ] || [ "$GATE_RESULT" = "cancelled" ]; then
  echo "::error::Gate job ${GATE_RESULT}"
  exit 1
fi

if [ "$EVENT_NAME" = "pull_request_target" ] && [ "$DETECT_RESULT" = "skipped" ]; then
  echo "::error::Detect was ${DETECT_RESULT} on pull_request_target — tests were not authorized to run"
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
