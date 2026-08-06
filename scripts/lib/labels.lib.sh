#!/usr/bin/env bash
# labels.lib.sh — Idempotent label creation for fullsend dispatch labels.
#
# Source from post-scripts:
#   source "${SCRIPT_DIR}/lib/labels.lib.sh"

# shellcheck shell=bash

[[ -n "${LABELS_LIB_SH_LOADED:-}" ]] && return 0
LABELS_LIB_SH_LOADED=1

# _label_defaults LABEL — print "description\tcolor" for known labels.
# Returns 1 for unknown labels (caller should handle).
_label_defaults() {
  case "$1" in
    ready-for-review)        printf '%s\t%s' 'Fullsend: triggers review agent dispatch' '0E8A16' ;;
    ready-to-code)           printf '%s\t%s' 'Fullsend: triggers code agent dispatch'   '0e8a16' ;;
    ready-for-triage)        printf '%s\t%s' 'Fullsend: awaiting triage agent'          'ededed' ;;
    ready-for-merge)         printf '%s\t%s' 'Fullsend: all reviewers approved'         '0E8A16' ;;
    requires-manual-review)  printf '%s\t%s' 'Fullsend: review requires human judgment' 'FBCA04' ;;
    rejected)                printf '%s\t%s' 'Fullsend: approach rejected by review'    'B60205' ;;
    needs-human)             printf '%s\t%s' 'Fullsend: agent loop needs human input'   'D93F0B' ;;
    pr-open)                 printf '%s\t%s' 'Fullsend: open PR addresses this issue'   'D4C5F9' ;;
    needs-info)              printf '%s\t%s' 'Fullsend: issue needs more information'   'd876e3' ;;
    blocked)                 printf '%s\t%s' 'Fullsend: issue blocked on prerequisites' 'e11d48' ;;
    duplicate)               printf '%s\t%s' 'Fullsend: duplicate issue'                'cfd3d7' ;;
    triaged)                 printf '%s\t%s' 'Fullsend: triaged, awaiting prioritization' 'c2e0c6' ;;
    question)                printf '%s\t%s' 'Fullsend: issue is a question'            'd876e3' ;;
    bug)                     printf '%s\t%s' 'Fullsend: bug report'                     'd73a4a' ;;
    documentation)           printf '%s\t%s' 'Fullsend: documentation improvement'      '0075ca' ;;
    feature)                 printf '%s\t%s' 'Fullsend: feature request'                'a2eeef' ;;
    not-planned)             printf '%s\t%s' 'Fullsend: will not be implemented'        'ffffff' ;;
    *) return 1 ;;
  esac
}

# ensure_label REPO LABEL — create a label if it does not already exist.
# Uses defaults from _label_defaults when available. No-op when the label
# already exists (gh label create returns non-zero for duplicates).
# Always returns 0 so callers don't need error handling.
ensure_label() {
  local repo="$1" label="$2"
  local defaults desc color
  local -a create_args=("$label" --repo "$repo")

  if defaults=$(_label_defaults "$label"); then
    desc="${defaults%%	*}"
    color="${defaults##*	}"
    create_args+=(--description "$desc" --color "$color")
  fi

  local err
  if ! err=$(gh label create "${create_args[@]}" 2>&1); then
    case "$err" in
      *already\ exists*) ;;
      *) echo "Warning: gh label create '${label}' failed: ${err}" >&2 ;;
    esac
  fi
  return 0
}
