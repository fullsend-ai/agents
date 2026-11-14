#!/usr/bin/env bash
# test-lib.sh — Shared helpers for agent script tests.
#
# Source from *-test.sh files that execute bundled or source agent scripts.

# shellcheck shell=bash

[[ -n "${AGENTS_TEST_LIB_SH_LOADED:-}" ]] && return 0
AGENTS_TEST_LIB_SH_LOADED=1

# Jira credentials from the developer's environment would change which
# credential mode the scripts select; tests set exactly what they need.
unset FULLSEND_JIRA_TOKEN FULLSEND_JIRA_EMAIL FULLSEND_JIRA_CLIENT_ID \
  FULLSEND_JIRA_CLIENT_SECRET JIRA_TOKEN JIRA_USER_EMAIL JIRA_API_URL

# SCRIPT_TEST_TARGET=source|bundled (default: source)
resolve_agent_script() {
  local base="$1"
  local dir="${2:-$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"

  if [[ "${SCRIPT_TEST_TARGET:-source}" == "bundled" ]]; then
    echo "${dir}/${base}.sh"
  else
    echo "${dir}/${base}.src.sh"
  fi
}

parse_script_test_args() {
  for arg in "$@"; do
    case "${arg}" in
      --bundled)
        export SCRIPT_TEST_TARGET=bundled
        ;;
    esac
  done
}
