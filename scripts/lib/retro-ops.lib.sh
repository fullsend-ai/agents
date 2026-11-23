#!/usr/bin/env bash
# shellcheck shell=bash
# retro-ops.lib.sh — Forge-dispatch wrapper for retro operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${RETRO_OPS_SH_LOADED:-}" ]] && return 0
RETRO_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

_gha_mask() {
  local value="$1"
  value="${value//%/%25}"
  value="${value//$'\r'/%0D}"
  value="${value//$'\n'/%0A}"
  printf '::add-mask::%s\n' "${value}"
}

# RETRO_MODE is validated here, before the tracker library is sourced, because
# jira-retro-ops.lib.sh branches on it at source time: a typo such as
# `summary-only` would otherwise take the full path and fail later with a
# misleading missing-credential error, and pre-retro, which also sources this
# file, would never reject it at all.
RETRO_MODE="${RETRO_MODE:-all}"
case "${RETRO_MODE}" in
  all|summary_only|issues_only) ;;
  *)
    echo "ERROR: RETRO_MODE must be 'all', 'summary_only', or 'issues_only' (got: $(_gha_sanitize "${RETRO_MODE}"))" >&2
    exit 1
    ;;
esac

case "${FULLSEND_FORGE:-}" in
  github)
    source "${SCRIPT_DIR}/lib/github-retro-ops.lib.sh"
    ;;
  gitlab)
    source "${SCRIPT_DIR}/lib/gitlab-retro-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — set FULLSEND_FORGE to github or gitlab" >&2
    exit 1
    ;;
esac

FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE}}"

case "${FULLSEND_TRACKER}" in
  "${FULLSEND_FORGE}") ;;
  jira)
    source "${SCRIPT_DIR}/lib/jira-retro-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_TRACKER: '$(_gha_sanitize "${FULLSEND_TRACKER}")' — must be 'jira' or match FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
