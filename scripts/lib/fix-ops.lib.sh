#!/usr/bin/env bash
# shellcheck shell=bash
# fix-ops.lib.sh — Forge-dispatch wrapper for fix agent operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${FIX_OPS_SH_LOADED:-}" ]] && return 0
FIX_OPS_SH_LOADED=1

case "${FULLSEND_FORGE:-}" in
  github)
    source "${SCRIPT_DIR}/lib/github-fix-ops.lib.sh"
    ;;
  gitlab)
    source "${SCRIPT_DIR}/lib/gitlab-fix-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac

is_bot_user() {
  if [ "${FULLSEND_FORGE:-}" = "gitlab" ]; then
    [[ "${1:-}" =~ _bot$ ]]
  else
    [[ "${1:-}" =~ \[bot\]$ ]]
  fi
}
