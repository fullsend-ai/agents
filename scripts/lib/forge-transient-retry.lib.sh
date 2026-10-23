#!/usr/bin/env bash
# forge-transient-retry.lib.sh — Retry forge CLI/API calls on 5xx/timeouts.
#
# Usage:
#   forge_retry_transient cmd [args...]
#
# On success, prints the command's stdout. On failure, prints the command's
# combined output to stderr so callers (and workflow logs) can diagnose.
# Retries only when the output looks like a transient 5xx or timeout.
#
# Environment:
#   FORGE_TRANSIENT_RETRY_ATTEMPTS   — default 3
#   FORGE_TRANSIENT_RETRY_BASE_DELAY — default 2 (seconds; doubles each retry)

# shellcheck shell=bash

[[ -n "${FORGE_TRANSIENT_RETRY_SH_LOADED:-}" ]] && return 0
FORGE_TRANSIENT_RETRY_SH_LOADED=1

forge_is_transient_error() {
  local text="$1"
  local lower
  lower=$(printf '%s' "${text}" | tr '[:upper:]' '[:lower:]')

  if echo "${lower}" | grep -qE \
    'http[[:space:]]*5[0-9][0-9]|status([:]|[[:space:]]+code:?)[[:space:]]*5[0-9][0-9]|error:[[:space:]]*5[0-9][0-9]|\(http 5[0-9][0-9]\)'; then
    return 0
  fi
  if echo "${lower}" | grep -qE \
    'internal server error|service unavailable|bad gateway|gateway timeout'; then
    return 0
  fi
  if echo "${lower}" | grep -qE \
    'context deadline exceeded|connection reset|i/o timeout|operation timed out|timed out'; then
    return 0
  fi
  # Go net/http (gh) and curl timeout diagnostics that carry no other marker.
  # Specific phrases only: a bare "timeout" would match branch names such as
  # "agent/42-fix-webhook-timeout".
  if echo "${lower}" | grep -qE \
    'tls handshake timeout|ssl connection timeout|timeout awaiting response headers|connection timeout after|client\.timeout exceeded'; then
    return 0
  fi
  return 1
}

_forge_retry_notice() {
  local msg="$1"
  # Always stderr so success stdout (e.g. a PR URL) stays clean.
  if declare -F gha_echo >/dev/null 2>&1; then
    gha_echo warning "${msg}" >&2
  else
    echo "${msg}" >&2
  fi
}

# Sanitize captured command output before it reaches the runner log.
# Secret redaction (tokens/PEMs) comes from sanitize_failure_detail when
# post-failure-report.lib.sh is loaded. Whether or not it is, the same
# order-safe escaping runs as the final step on every path: the shared
# sanitizers delete "%0A"/"::" piecemeal, and a nested payload such as
# ":%0%0AA:error" can reassemble into a live "::error" command after one
# deletion pass. Escaping instead of deleting avoids that — "%" is escaped
# first and then "::", so no sequence of the escaped output can form "::",
# "%0A" or "%0D". ANSI escapes and other control characters are dropped
# (newline and tab kept).
_forge_retry_sanitize() {
  local text="$1"
  if declare -F sanitize_failure_detail >/dev/null 2>&1; then
    # max_lines=0 disables truncation — this is diagnostic log output, not a
    # length-limited PR comment.
    text="$(sanitize_failure_detail "${text}" 0)"
  fi
  text="$(printf '%s' "${text}" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
  text="${text//%/%25}"
  text="${text//::/%3A%3A}"
  printf '%s' "${text}"
}

# Run a command, retrying transient 5xx/timeout failures with exponential
# backoff (2s, 4s, 8s by default). Non-transient failures return immediately.
forge_retry_transient() {
  local max_attempts="${FORGE_TRANSIENT_RETRY_ATTEMPTS:-3}"
  local delay="${FORGE_TRANSIENT_RETRY_BASE_DELAY:-2}"
  local attempt=1
  local outfile errfile rc combined

  outfile=$(mktemp)
  errfile=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '${outfile}' '${errfile}'" RETURN

  while [ "${attempt}" -le "${max_attempts}" ]; do
    : >"${outfile}"
    : >"${errfile}"
    rc=0
    "$@" >"${outfile}" 2>"${errfile}" || rc=$?

    if [ "${rc}" -eq 0 ]; then
      cat "${outfile}"
      return 0
    fi

    combined=$(cat "${outfile}" "${errfile}")
    if [ "${attempt}" -lt "${max_attempts}" ] && forge_is_transient_error "${combined}"; then
      _forge_retry_notice \
        "Transient forge error (attempt ${attempt}/${max_attempts}); retrying in ${delay}s..."
      sleep "${delay}"
      delay=$((delay * 2))
      attempt=$((attempt + 1))
      continue
    fi

    local sanitized_combined
    sanitized_combined="$(_forge_retry_sanitize "${combined}")"
    printf '%s' "${sanitized_combined}" >&2
    if [ -n "${sanitized_combined}" ]; then
      printf '\n' >&2
    fi
    return "${rc}"
  done

  return 1
}
