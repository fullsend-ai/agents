#!/usr/bin/env bash
# gha-log-sanitize.lib.sh — Sanitize untrusted values before they reach
# GitHub Actions' workflow-command log parser.
#
# GHA treats any line starting with "::cmd::" in step output as a workflow
# command. Interpolating untrusted input (issue/PR bodies, dispatch inputs)
# into echoed diagnostics without stripping "::" lets that input inject its
# own workflow commands. This library holds only the sanitizing helpers —
# no `gh` calls or comment-posting logic — so it can be sourced from
# trust-sensitive pre-scripts without pulling in unrelated capabilities.
#
# Source from a .src.sh script:
#   source "${SCRIPT_DIR}/lib/gha-log-sanitize.lib.sh"

# shellcheck shell=bash

[[ -n "${GHA_LOG_SANITIZE_SH_LOADED:-}" ]] && return 0
GHA_LOG_SANITIZE_SH_LOADED=1

_sanitize_workflow_value() {
  local value="$1"
  value="${value//::/}"
  value="${value//%0A/}"
  value="${value//%0a/}"
  value="${value//%0D/}"
  value="${value//%0d/}"
  printf '%s' "${value}"
}

# Neutralize line-start GHA workflow commands in comment bodies without
# stripping mid-string :: (e.g. std::string in compiler output).
sanitize_comment_workflow_commands() {
  local value="$1"
  value="$(printf '%s\n' "${value}" | sed -E \
    -e 's/^::(warning|error|notice|debug|group|endgroup):://')"
  value="${value//%0A/}"
  value="${value//%0a/}"
  value="${value//%0D/}"
  value="${value//%0d/}"
  # printf '%s' drops trailing newline added by the pipeline above.
  printf '%s' "${value}"
}

# Strip GitHub Actions workflow-command sequences from runner log output.
sanitize_gha_log_output() {
  _sanitize_workflow_value "$1"
}

# Print sanitized command output to stdout or stderr without SC2005 echo-$(cmd) noise.
print_sanitized_gha_log() {
  local sanitized
  sanitized="$(sanitize_gha_log_output "$1")"
  if [ "${2:-}" = "stderr" ]; then
    printf '%s\n' "${sanitized}" >&2
  else
    printf '%s\n' "${sanitized}"
  fi
}

# Emit a GitHub Actions workflow command with a sanitised message body.
# Defence-in-depth: sanitize the level parameter too, even though current
# call sites only pass hardcoded string literals.
gha_echo() {
  local level="$1"
  shift
  level="${level//::/}"
  printf '::%s::%s\n' "${level}" "$(sanitize_gha_log_output "$*")"
}
