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
