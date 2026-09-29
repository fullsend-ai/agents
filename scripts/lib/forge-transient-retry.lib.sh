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
    'http[[:space:]]*5[0-9][0-9]|status([:]|[[:space:]]+code)[[:space:]]*5[0-9][0-9]|error:[[:space:]]*5[0-9][0-9]|\(http 5[0-9][0-9]\)'; then
    return 0
  fi
  if echo "${lower}" | grep -qE \
    'internal server error|service unavailable|bad gateway|gateway timeout'; then
    return 0
  fi
  if echo "${lower}" | grep -qE \
    'context deadline exceeded|connection reset|i/o timeout|operation timed out|timed out|timeout'; then
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

# Sanitize captured command output before it reaches the runner log. Compose
# both shared sanitizers from post-failure-report.lib.sh when available:
# sanitize_failure_detail first (redacts tokens/PEMs; only strips a narrow,
# line-start "::word::" form intended for comment bodies), then
# sanitize_gha_log_output (strips any "::"/"%0A"/"%0D" sequence regardless of
# position or parameters — the blanket sanitizer this codebase uses for log
# destinations). Relying on sanitize_failure_detail alone would leave
# parameterized commands (e.g. "::error file=x::") and mid-string commands
# like "::stop-commands::"/"::add-mask::" intact. Falls back to a minimal
# inline strip of "::"/"%0A"/"%0D" when neither sanitizer is loaded, so
# callers never get a raw, unsanitized dump of forge output (which may embed
# issue/agent-influenced text or truncated API response bodies).
_forge_retry_sanitize() {
  local text="$1"
  if declare -F sanitize_failure_detail >/dev/null 2>&1; then
    # max_lines=0 disables truncation — this is diagnostic log output, not a
    # length-limited PR comment.
    text="$(sanitize_failure_detail "${text}" 0)"
  fi
  if declare -F sanitize_gha_log_output >/dev/null 2>&1; then
    sanitize_gha_log_output "${text}"
    return 0
  fi
  local fallback="${text}"
  fallback="${fallback//::/}"
  fallback="${fallback//%0A/}"
  fallback="${fallback//%0a/}"
  fallback="${fallback//%0D/}"
  fallback="${fallback//%0d/}"
  printf '%s' "${fallback}"
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
