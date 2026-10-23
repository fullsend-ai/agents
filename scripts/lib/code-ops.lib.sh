#!/usr/bin/env bash
# shellcheck shell=bash
# code-ops.lib.sh — Forge-dispatch wrapper for code agent operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${CODE_OPS_SH_LOADED:-}" ]] && return 0
CODE_OPS_SH_LOADED=1

# Load the transient-retry helper unconditionally, before forge dispatch, so
# forge_retry_transient is defined for every forge (including callers in the
# pre-code scripts that wrap commands outside the forge-specific libs).
# shellcheck source=forge-transient-retry.lib.sh
source "${SCRIPT_DIR}/lib/forge-transient-retry.lib.sh"

case "${FULLSEND_FORGE:-}" in
  github)
    source "${SCRIPT_DIR}/lib/github-code-ops.lib.sh"
    ;;
  gitlab)
    source "${SCRIPT_DIR}/lib/gitlab-code-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '${FULLSEND_FORGE:-}' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
