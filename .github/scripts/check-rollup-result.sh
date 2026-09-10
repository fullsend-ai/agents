#!/usr/bin/env bash
# check-rollup-result.sh — Decide whether the functional-tests-complete
# roll-up job should pass or fail.
#
# Inputs (env vars):
#   EVENT_NAME    — github.event_name
#   GATE_RESULT   — needs.gate.result
#   DETECT_RESULT — needs.detect.result
#   TESTS_RESULT  — needs.functional-tests.result
#   CROSS_REPO    — 'true' when invoked from a different repository
#   EVENT_ACTION  — github.event.action (for pull_request_target)
#   LABEL_NAME    — github.event.label.name (empty unless action is 'labeled')
#   HEAD_SHA      — github.event.pull_request.head.sha
#   GITHUB_RUN_ID — this workflow run, so its own check run is excluded
#
# Exit 0 = pass, exit 1 = fail.

set -euo pipefail

EVENT_NAME="${EVENT_NAME:-}"
GATE_RESULT="${GATE_RESULT:-}"
DETECT_RESULT="${DETECT_RESULT:-}"
TESTS_RESULT="${TESTS_RESULT:-}"
CROSS_REPO="${CROSS_REPO:-}"
EVENT_ACTION="${EVENT_ACTION:-}"
LABEL_NAME="${LABEL_NAME:-}"
HEAD_SHA="${HEAD_SHA:-}"
ROLLUP_CHECK_NAME="${ROLLUP_CHECK_NAME:-functional-tests-complete}"

# A pull_request_target `labeled` event for any label other than ok-to-test
# starts this workflow but is never meant to run tests: the gate job's own
# `if:` skips, and detect skips with it. Such a run carries no verdict about
# the code, so it must not assert one — but it cannot stay silent either,
# because GitHub supersedes the previous check run of the same name with
# whatever this one reports.
#
# Neither constant answer is safe. Exiting 0 would launder a genuinely
# failing run green the moment anyone labels the PR; skipping the job would
# do the same, because a `skipped` conclusion also supersedes and is treated
# as satisfying a required check. So mirror the verdict the previous run
# reached on this same commit, and fail closed when there is no previous
# verdict to mirror.
if [ "$EVENT_NAME" = "pull_request_target" ] && [ "$EVENT_ACTION" = "labeled" ] \
   && [ "$LABEL_NAME" != "ok-to-test" ] && [ "$GATE_RESULT" = "skipped" ]; then
  if [ -z "$HEAD_SHA" ]; then
    echo "::error::Label event carries no verdict and HEAD_SHA is unset — cannot mirror the previous result"
    exit 1
  fi
  # check_name filters server-side, so the roll-up's own history is the only
  # thing paged over — a commit can easily exceed 100 check runs in total,
  # but not 100 runs of this one name.
  prior="$(gh api \
    "repos/${GITHUB_REPOSITORY}/commits/${HEAD_SHA}/check-runs?check_name=${ROLLUP_CHECK_NAME}&per_page=100" \
    --jq "[.check_runs[]
           | select((.details_url // \"\") | contains(\"/runs/${GITHUB_RUN_ID}/\") | not)
           | select(.status == \"completed\")]
          | sort_by(.completed_at) | last | .conclusion // empty" 2>/dev/null || true)"

  # LABEL_NAME comes from github.event.label.name and is settable by anyone
  # with triage access, so neutralise it before it reaches a
  # ::notice::/::error:: line. Stripping literal newlines is not sufficient:
  # the workflow-command parser also decodes %0A/%0D as line breaks, and %25
  # can re-introduce a % to build them, so every percent sign goes too.
  # ESC is dropped as well so a label cannot smuggle ANSI into the log.
  safe_label="$(printf '%s' "${LABEL_NAME}" | tr -d '\n\r\033' | sed 's/::/__/g; s/%/_/g')"

  if [ "$prior" = "success" ]; then
    echo "::notice::Label '${safe_label}' does not run tests; mirroring the previous ${ROLLUP_CHECK_NAME} result on ${HEAD_SHA} (success)"
    exit 0
  fi
  echo "::error::Label '${safe_label}' does not run tests, and the previous ${ROLLUP_CHECK_NAME} result on ${HEAD_SHA} was '${prior:-none}' — failing closed"
  exit 1
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

if [ "$CROSS_REPO" = "true" ] && [ "$TESTS_RESULT" = "skipped" ]; then
  echo "::error::Cross-repo call completed with zero functional tests — agents list was empty or detect was skipped"
  exit 1
fi
