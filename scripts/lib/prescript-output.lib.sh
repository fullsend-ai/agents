#!/usr/bin/env bash
# prescript-output.lib.sh — Write pre-script output protocol lines.
#
# The pre-script output protocol (fullsend docs/normative/prescript-output/v1,
# fullsend-ai/fullsend#4718) is the contract between `fullsend run` and a
# harness pre-script: the CLI exports FULLSEND_PRESCRIPT_OUTPUT naming a
# file, and the script appends key=value lines to it — `skipped=true` (plus
# an optional `reason`) stops the run before sandbox creation. Under a CLI
# that predates the protocol the variable is unset and writes are skipped,
# so the run proceeds — the protocol's version-skew contract.
#
# Source from a pre-script .src.sh:
#   source "${SCRIPT_DIR}/lib/prescript-output.lib.sh"

# shellcheck shell=bash

[[ -n "${PRESCRIPT_OUTPUT_SH_LOADED:-}" ]] && return 0
PRESCRIPT_OUTPUT_SH_LOADED=1

# prescript_output KEY VALUE — append a protocol line, if the CLI
# supports the protocol. Values must be single-line (protocol grammar).
prescript_output() {
  if [[ -n "${FULLSEND_PRESCRIPT_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "${FULLSEND_PRESCRIPT_OUTPUT}"
  fi
}
