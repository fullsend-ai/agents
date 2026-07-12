#!/usr/bin/env bash
# test-lib.sh — Shared helpers for agent script tests.
#
# Source from *-test.sh files that execute bundled or source agent scripts.

# shellcheck shell=bash

[[ -n "${AGENTS_TEST_LIB_SH_LOADED:-}" ]] && return 0
AGENTS_TEST_LIB_SH_LOADED=1

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
