#!/usr/bin/env bash
# write-approval-gate.lib.sh — Merge gate for triage-role-triggered code/fix runs.
#
# Source from post-code.src.sh / post-fix.src.sh (after post-failure-report.lib.sh
# for gha_echo):
#   source "${SCRIPT_DIR}/lib/write-approval-gate.lib.sh"
#
# fullsend-ai/fullsend#5687: dispatch now accepts the GitHub `triage` role for
# /fs-code and /fs-fix. Triage-role users still get a bot-authored PR (the
# agent always held write-level credentials), but that PR must carry an
# explicit visible marker so reviewers and merge tooling know it needs a
# write+ collaborator's approval — the actual enforcement (requiring an
# approval from a currently write+ user, not just any reviewDecision) lives
# in skills/merge-queue/scripts/await-and-enqueue.sh, which checks this label.

# shellcheck shell=bash

[[ -n "${WRITE_APPROVAL_GATE_SH_LOADED:-}" ]] && return 0
WRITE_APPROVAL_GATE_SH_LOADED=1

# Emit a runner warning through gha_echo when available.
_write_approval_gate_warn() {
  if declare -F gha_echo >/dev/null 2>&1; then
    gha_echo warning "$*"
  else
    echo "warning: $*" >&2
  fi
}

# Normalize a TRIGGER_ROLE value: lowercase and trim surrounding whitespace.
_normalize_trigger_role() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | xargs
}

# Apply the needs-write-approval label to a PR when TRIGGER_ROLE is "triage"
# (case-insensitive, surrounding whitespace ignored). No-op (and no gh calls)
# when TRIGGER_ROLE is unset or "write" — unset means the trigger was resolved
# at write+ (or a path that predates TRIGGER_ROLE, e.g. bot-triggered
# review->fix), so no gate is needed. Any other non-empty value is treated
# the same as "write" (no gate) but logged, since it likely indicates a bug
# in the caller rather than a legitimate write+ trigger.
# Requires REPO_FULL_NAME. Best-effort: never fails the calling script.
# Note: parameter is target_pr (not pr_number) to avoid SC2153 against
# PR_NUMBER from post-failure-report.lib.sh once both libs are bundled into
# post-code.sh / post-fix.sh — same fix as maybe_assign_pr in pr-assignee.lib.sh.
apply_write_approval_gate_if_needed() {
  local target_pr="$1"
  local role
  role="$(_normalize_trigger_role "${TRIGGER_ROLE:-}")"

  if [[ -z "${role}" ]]; then
    return 0
  fi
  if [[ "${role}" != "triage" ]]; then
    if [[ "${role}" != "write" ]]; then
      _write_approval_gate_warn "Unrecognized TRIGGER_ROLE '${TRIGGER_ROLE}' — treating as write (no gate applied). Expected 'triage' or 'write'."
    fi
    return 0
  fi

  echo "Trigger role is 'triage' — applying needs-write-approval gate to PR #${target_pr}"
  gh label create "needs-write-approval" --repo "${REPO_FULL_NAME}" \
    --description "Triggered by a triage-role user; needs write+ approval before merge" \
    --color "B60205" 2>/dev/null || true
  gh pr edit "${target_pr}" --repo "${REPO_FULL_NAME}" \
    --add-label "needs-write-approval" 2>/dev/null || \
    _write_approval_gate_warn "Failed to apply needs-write-approval label to PR #${target_pr}"
}
