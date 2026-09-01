#!/usr/bin/env bash
# labels.lib.sh — Mandatory label management for fullsend agent scripts.
#
# Provides forge_ensure_label() which creates mandatory dispatch labels
# without --force, preserving admin customizations. Non-mandatory labels
# are silently skipped (no-op).

# shellcheck shell=bash

[[ -n "${LABELS_SH_LOADED:-}" ]] && return 0
LABELS_SH_LOADED=1

MANDATORY_LABELS=("ready-for-review" "ready-to-code" "ready-for-triage")

_labels_mandatory_defaults() {
  printf '%s\t%s\t%s\n' \
    "ready-for-review" "Triggers review agent dispatch" "0E8A16" \
    "ready-to-code" "Triggers code agent dispatch" "0E8A16" \
    "ready-for-triage" "Triggers triage agent dispatch" "0E8A16"
}

forge_ensure_label() {
  local name="$1"
  local description="${2:-}"
  local color="${3:-}"

  local is_mandatory=false
  local m
  for m in "${MANDATORY_LABELS[@]}"; do
    [[ "${m}" == "${name}" ]] && is_mandatory=true && break
  done
  if [[ "${is_mandatory}" != "true" ]]; then
    return 0
  fi

  if [[ -z "${description}" || -z "${color}" ]]; then
    local line
    line=$(_labels_mandatory_defaults | grep "^${name}	" || true)
    if [[ -n "${line}" ]]; then
      [[ -z "${description}" ]] && description=$(printf '%s' "${line}" | cut -f2)
      [[ -z "${color}" ]] && color=$(printf '%s' "${line}" | cut -f3)
    fi
  fi

  forge_create_label "${name}" "${description}" "${color}"
}
