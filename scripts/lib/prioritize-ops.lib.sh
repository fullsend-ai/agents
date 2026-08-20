#!/usr/bin/env bash
# shellcheck shell=bash
# prioritize-ops.lib.sh — Forge-dispatch wrapper for prioritize operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${PRIORITIZE_OPS_SH_LOADED:-}" ]] && return 0
PRIORITIZE_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

case "${FULLSEND_FORGE:-}" in
  github)
    source "${SCRIPT_DIR}/lib/github-prioritize-ops.lib.sh"
    ;;
  gitlab)
    source "${SCRIPT_DIR}/lib/gitlab-prioritize-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
