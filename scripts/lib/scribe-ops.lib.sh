#!/usr/bin/env bash
# shellcheck shell=bash
# scribe-ops.lib.sh — Forge-dispatch wrapper for scribe operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE. When
# FULLSEND_TRACKER=jira, additionally sources the Jira tracker ops, which
# redefine the backlog and issue-creation functions so they target Jira
# while repo context (closed issues, PRs, docs) stays on the forge.
# FULLSEND_TRACKER defaults to FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
SCRIBE_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

case "${FULLSEND_FORGE:-}" in
  github)
    source "${SCRIPT_DIR}/lib/github-scribe-ops.lib.sh"
    ;;
  gitlab)
    source "${SCRIPT_DIR}/lib/gitlab-scribe-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '$(_gha_sanitize "${FULLSEND_FORGE:-}")' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac

FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE}}"

case "${FULLSEND_TRACKER}" in
  "${FULLSEND_FORGE}") ;;
  jira)
    source "${SCRIPT_DIR}/lib/jira-scribe-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_TRACKER: '$(_gha_sanitize "${FULLSEND_TRACKER}")' — must be 'jira' or match FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
