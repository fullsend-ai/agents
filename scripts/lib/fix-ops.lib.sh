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

# is_human_rebase_request INSTRUCTION — true if a harness-captured human
# /fs-fix instruction asked for a rebase or merge-conflict resolution (see
# agents/fix.md's "Rebase onto the target branch" and docs/fix.md's
# "Rebasing a stale PR"). The instruction text is HUMAN_INSTRUCTION, which
# the triggering workflow sets from the literal PR/MR comment before the
# sandbox is created — the fix agent cannot alter it during its own run,
# unlike agent-result.json (PR #1296 auth-bypass finding: a non-bot
# TRIGGER_SOURCE alone does not prove the run's instruction was a rebase
# request, so callers must check this in addition to TRIGGER_SOURCE).
is_human_rebase_request() {
  local instruction
  instruction="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "${instruction}" == *"rebase"* || "${instruction}" == *"merge conflict"* ]]
}
