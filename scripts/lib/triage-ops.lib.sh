#!/usr/bin/env bash
# shellcheck shell=bash
# triage-ops.lib.sh — Tracker-dispatch wrapper for triage operations.
#
# Sources the correct tracker-specific ops based on FULLSEND_TRACKER
# (falling back to FULLSEND_FORGE if FULLSEND_TRACKER is unset).
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${TRIAGE_OPS_SH_LOADED:-}" ]] && return 0
TRIAGE_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE:-}}"

case "${FULLSEND_TRACKER:-}" in
  github)
    source "${SCRIPT_DIR}/lib/github-triage-ops.lib.sh"
    ;;
  gitlab)
    source "${SCRIPT_DIR}/lib/gitlab-triage-ops.lib.sh"
    ;;
  jira)
    source "${SCRIPT_DIR}/lib/jira-triage-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_TRACKER: '${FULLSEND_TRACKER:-}' — pass --tracker <github|gitlab|jira> or set FULLSEND_TRACKER" >&2
    exit 1
    ;;
esac

# triage_find_skip_label — print the first skip label on the issue (#2076).
# A skip label keeps an issue with a planning process: the built-in
# skip-triage, plus each label in the comma-separated TRIAGE_SKIP_LABELS.
# Returns 0 when the issue carries one, 1 when it carries none, and 2 when
# its labels cannot be read. Call after tracker_parse_issue_url.
triage_find_skip_label() {
  local issue_labels
  issue_labels=$(tracker_list_issue_labels) || return 2

  local skip_labels=("skip-triage") extra_labels label
  IFS=',' read -ra extra_labels <<< "${TRIAGE_SKIP_LABELS:-}"
  for label in "${extra_labels[@]}"; do
    label="${label#"${label%%[![:space:]]*}"}"
    label="${label%"${label##*[![:space:]]}"}"
    [[ -n "${label}" ]] && skip_labels+=("${label}")
  done

  local current
  while IFS= read -r current; do
    for label in "${skip_labels[@]}"; do
      if [[ -n "${current}" && "${current}" == "${label}" ]]; then
        printf '%s\n' "${current}"
        return 0
      fi
    done
  done <<< "${issue_labels}"
  return 1
}
