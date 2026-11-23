#!/usr/bin/env bash
# pre-retro.sh — Validate inputs for the retro agent.
#
# Runs on the host via the harness pre_script mechanism. Validates the
# originating URL (PR or issue) and logs the trigger context.
#
# Required env vars:
#   ORIGINATING_URL — HTML URL of the PR or issue that triggered retro
#   FULLSEND_FORGE  — "github" or "gitlab"
#
# Optional env vars:
#   RETRO_COMMENT   — The /retro comment text (empty for automatic triggers)
#   FULLSEND_TRACKER — "jira", or the same value as FULLSEND_FORGE
#                      (defaults to FULLSEND_FORGE)
#   FULLSEND_DIR    — .fullsend directory (required when FULLSEND_TRACKER=jira)
#
# When FULLSEND_TRACKER=jira, scripts/lib/jira-retro-ops.lib.sh (sourced
# through retro-ops.lib.sh) also enforces JIRA_BASE_URL, RETRO_JIRA_PROJECT
# and a Jira credential, and reads tracker.jira from FULLSEND_DIR's config.
# RETRO_MODE=summary_only relaxes those requirements: no issue is filed.
# A Jira-originated run additionally requires RETRO_JIRA_CONTEXT_FILE: the
# path this script writes the issue context to is the host_files src the
# harness mounts into the sandbox.

set -euo pipefail

: "${ORIGINATING_URL:?ORIGINATING_URL is required}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retro-ops.lib.sh
source "${SCRIPT_DIR}/lib/retro-ops.lib.sh"

forge_validate_originating_url
forge_parse_originating_url
forge_mask_token

# A runner that reuses its host keeps RETRO_JIRA_CONTEXT_FILE between runs, and
# harness/retro.yaml uploads it on every retro run, so a stale file would put an
# earlier Jira issue's text into an unrelated run's sandbox. Drop it here, for
# forge-originated runs too; a Jira-originated run writes a fresh one below.
if [[ -n "${RETRO_JIRA_CONTEXT_FILE:-}" ]]; then
  rm -f "${RETRO_JIRA_CONTEXT_FILE}" || true
fi

if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
  if [[ "${RETRO_MODE:-all}" != "summary_only" || "${JIRA_ORIGINATING:-false}" == "true" ]]; then
    if [[ -z "${FULLSEND_DIR:-}" ]]; then
      echo "ERROR: FULLSEND_DIR must be set when FULLSEND_TRACKER=jira (the fullsend CLI reads tracker.jira from its config.yaml)" >&2
      exit 1
    fi
  fi
fi

echo "::notice::Retro target: $(_gha_sanitize "${ORIGINATING_URL}")"

# A Jira-originated run analyzes a work item the sandbox cannot reach: it has
# no Atlassian route and no Jira credential. Fetch the issue and its comments
# here, on the host, into the context file the harness mounts into the
# sandbox (harness/retro.yaml host_files, exposed as RETRO_JIRA_CONTEXT).
# Fail closed: a retrospective that cannot read its subject would file
# proposals it cannot substantiate.
if [[ "${JIRA_ORIGINATING:-false}" == "true" ]]; then
  # The harness declares this path as its host_files src, and fullsend expands
  # ${VAR} in that src from the runner environment, so an unset value would
  # mount nothing and the agent would run blind. Fail here instead.
  if [[ -z "${RETRO_JIRA_CONTEXT_FILE:-}" ]]; then
    echo "ERROR: RETRO_JIRA_CONTEXT_FILE must be set for a Jira-originated retro — harness/retro.yaml mounts that path into the sandbox as RETRO_JIRA_CONTEXT" >&2
    exit 1
  fi
  if [[ "${JIRA_AUTH_MODE:-none}" == "none" ]]; then
    echo "ERROR: a Jira-originated retro needs JIRA_TOKEN, or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET" >&2
    exit 1
  fi
  _retro_jira_xtrace_off
  _retro_jira_mint_rc=0
  jira_auth_mint || _retro_jira_mint_rc=$?
  _retro_jira_xtrace_restore
  if [[ "${_retro_jira_mint_rc}" -ne 0 ]]; then
    echo "ERROR: failed to obtain a Jira access token for the originating-issue fetch" >&2
    exit 1
  fi
  if ! JIRA_CONTEXT_PATH=$(_retro_jira_write_context "${ORIGINATING_NUMBER}"); then
    echo "ERROR: failed to fetch Jira issue ${ORIGINATING_NUMBER} for the retrospective" >&2
    exit 1
  fi
  echo "::notice::Jira issue context for ${ORIGINATING_NUMBER} written to ${JIRA_CONTEXT_PATH}"
fi

if [[ -n "${RETRO_COMMENT:-}" ]]; then
  echo "Retro triggered on-demand with comment."
else
  echo "Retro triggered automatically (PR close)."
fi

echo "Pre-retro validation complete."
