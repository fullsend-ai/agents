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
#   FULLSEND_TRACKER — "github", "gitlab", or "jira" (defaults to FULLSEND_FORGE)
#   FULLSEND_DIR    — .fullsend directory (required when FULLSEND_TRACKER=jira)

set -euo pipefail

: "${ORIGINATING_URL:?ORIGINATING_URL is required}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retro-ops.lib.sh
source "${SCRIPT_DIR}/lib/retro-ops.lib.sh"

if [[ "${FULLSEND_TRACKER}" == "jira" && -z "${FULLSEND_DIR:-}" ]]; then
  echo "ERROR: FULLSEND_DIR must be set when FULLSEND_TRACKER=jira (the fullsend CLI reads tracker.jira from its config.yaml)" >&2
  exit 1
fi

if [[ -n "${JIRA_TOKEN:-}" ]]; then
  printf '::add-mask::%s\n' "$(printf '%s' "${JIRA_TOKEN}" | tr -d '\n\r')"
fi

forge_validate_originating_url

echo "::notice::Retro target: $(_gha_sanitize "${ORIGINATING_URL}")"

if [[ -n "${RETRO_COMMENT:-}" ]]; then
  echo "Retro triggered on-demand with comment."
else
  echo "Retro triggered automatically (PR close)."
fi

echo "Pre-retro validation complete."
