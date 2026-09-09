#!/usr/bin/env bash
# shellcheck shell=bash
# review-labels.lib.sh — recognize pipeline-managed "control" labels.
#
# Control labels are set by the review pipeline (or a maintainer, for the
# fix-budget knob), not by the review agent. post-review refuses to add or
# remove them via agent-recommended label_actions. Kept in a sourceable lib so
# the same definition is exercised by both production and the unit test — a
# duplicated copy in the test would pass even if the production branch drifted.
#
# Bundled into post-review.sh via bundle-sh.sh.

[[ -n "${REVIEW_LABELS_SH_LOADED:-}" ]] && return 0
REVIEW_LABELS_SH_LOADED=1

REVIEW_CONTROL_LABELS=(
  "ready-for-merge" "requires-manual-review" "rejected"
  "ready-for-review" "fullsend-no-fix" "fullsend-fix"
)

# is_control_label LABEL — return 0 if LABEL is pipeline-managed, 1 otherwise.
is_control_label() {
  local label="$1"
  local cl
  for cl in "${REVIEW_CONTROL_LABELS[@]}"; do
    if [[ "${cl}" == "${label}" ]]; then
      return 0
    fi
  done
  # Pipeline-managed label prefixes.
  if [[ "${label}" == risk/* ]]; then
    return 0
  fi
  # Maintainer-set fix-loop budget (fullsend-fix-budget/N); pipeline-managed so
  # the review agent preserves it rather than treating it as a contextual label.
  if [[ "${label}" == fullsend-fix-budget/* ]]; then
    return 0
  fi
  return 1
}
