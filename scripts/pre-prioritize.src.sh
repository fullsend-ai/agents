#!/usr/bin/env bash
# pre-prioritize.sh — Validate the issue URL before the agent runs.
#
# Runs on the host via the harness pre_script mechanism.
#
# Required env vars:
#   ISSUE_URL      — HTML URL of the issue to score
#   FULLSEND_FORGE — "github" or "gitlab"

set -euo pipefail

: "${ISSUE_URL:?ISSUE_URL must be set}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prioritize-ops.lib.sh
source "${SCRIPT_DIR}/lib/prioritize-ops.lib.sh"

forge_validate_issue_url
echo "::notice::🔗 Prioritize target: $(_gha_sanitize "${ISSUE_URL}")"

echo "Issue URL validated."
