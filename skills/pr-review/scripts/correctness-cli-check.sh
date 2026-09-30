#!/usr/bin/env bash
# correctness-cli-check.sh — Run a single, argv-constrained --help/--version
# probe against a CLI named in a PR diff, for the correctness sub-agent's
# "Scoped execution" invocation (skills/pr-review/sub-agents/correctness.md).
#
# Run by the correctness sub-agent inside the review sandbox:
#   bash "${CLAUDE_CONFIG_DIR}/skills/pr-review/scripts/correctness-cli-check.sh" <binary>
#
# The caller supplies only a bare binary name. This script — not the
# model — decides which flag to run and validates the binary before
# running anything:
#   - Rejects any name containing "/", "..", whitespace, or shell
#     metacharacters. This refuses repository-local paths such as
#     "./local-script" outright; only a plain PATH basename is accepted.
#   - Resolves the name via `command -v`, so it can only match a binary
#     already on PATH — never a relative path into the PR-head tree or
#     the checkout.
#   - Runs exactly one flag: `--help`, falling back to `--version` only
#     when `--help` fails or produces no output. No other flags, and no
#     test/build/run invocations, are ever executed.
#
# Output: KEY=VALUE lines, then a delimited OUTPUT block on success, or a
# single ENVIRONMENT_FAILURE line when the probe could not run. The
# sub-agent treats ENVIRONMENT_FAILURE as a skip, never as a finding.
# Exit code: always 0 — this script never fails the caller; check the
# output for ENVIRONMENT_FAILURE instead.
#
# This script is designed to be sourceable for testing. All logic lives
# in named functions; the main flow is guarded by a BASH_SOURCE check so
# `source correctness-cli-check.sh` only defines functions.

set -uo pipefail

TIMEOUT_SECS=30

is_safe_basename() {
  local name="$1"
  [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.+-]*$ ]]
}

resolve_on_path() {
  local name="$1"
  command -v -- "${name}" 2>/dev/null
}

run_probe() {
  local binary="${1:-}"

  if [ -z "${binary}" ]; then
    echo "ENVIRONMENT_FAILURE: no binary name supplied"
    return 0
  fi

  if ! is_safe_basename "${binary}"; then
    echo "ENVIRONMENT_FAILURE: '${binary}' is not a plain PATH basename (contains a path separator, whitespace, or other disallowed character)"
    return 0
  fi

  local resolved
  resolved="$(resolve_on_path "${binary}")"
  if [ -z "${resolved}" ]; then
    echo "ENVIRONMENT_FAILURE: '${binary}' is not on PATH"
    return 0
  fi

  echo "BINARY=${binary}"
  echo "RESOLVED=${resolved}"

  local output exit_code flag
  flag="--help"
  output="$(timeout "${TIMEOUT_SECS}" "${resolved}" --help 2>&1)"
  exit_code=$?

  if [ "${exit_code}" -ne 0 ] || [ -z "${output}" ]; then
    flag="--version"
    output="$(timeout "${TIMEOUT_SECS}" "${resolved}" --version 2>&1)"
    exit_code=$?
  fi

  if [ "${exit_code}" -ne 0 ] || [ -z "${output}" ]; then
    echo "ENVIRONMENT_FAILURE: '${binary}' exited non-zero or produced no output for both --help and --version"
    return 0
  fi

  echo "FLAG=${flag}"
  echo "EXIT_CODE=${exit_code}"
  echo "---OUTPUT---"
  echo "${output}"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_probe "${1:-}"
fi
