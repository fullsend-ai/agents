#!/usr/bin/env bash
# relabel-retrigger.lib.sh — Force a fresh `labeled` webhook event by
# removing then re-adding a label on a pull request.
#
# Source from any agent post-script needing to re-trigger label-gated
# dispatch (currently post-fix.src.sh; e.g. after pushing a fix commit, to
# re-dispatch the review agent via the same authorization-free
# `ready-for-review`-labeled path used when the PR was first opened):
#   source "${SCRIPT_DIR}/lib/relabel-retrigger.lib.sh"
#
# GitHub does not fire a new `labeled` event when a label already present
# is simply re-added — only a genuine absent-to-present transition fires
# one. retrigger_via_label removes the label first to force that
# transition, then re-adds it.
#
# Verified live (not just inferred from docs): on a disposable PR in a
# personal fork, applying a label fired one `pull_request.labeled` run;
# removing then immediately re-applying the same label fired a second,
# genuinely distinct run (confirmed via `gh run list`/`gh api .../runs/<id>`
# timing and metadata) — a plain re-add of an already-present label does
# not redeliver the event, but remove-then-add does.
#
# The GitHub token is taken as an explicit argument and scoped to each `gh`
# invocation individually (GH_TOKEN="${token}" gh ...) rather than relying
# on the caller having already exported GH_TOKEN into the shell environment
# at the right point in script execution. The original version of this fix
# broke exactly that way: GH_TOKEN was exported two steps after these gh
# calls ran, so they silently authenticated with whatever token happened to
# be ambient. Taking the token as a parameter makes that class of ordering
# bug structurally impossible here.

# shellcheck shell=bash

[[ -n "${RELABEL_RETRIGGER_SH_LOADED:-}" ]] && return 0
RELABEL_RETRIGGER_SH_LOADED=1

# Remove then re-add `label` on `repo_full_name`'s pull request `target_pr`,
# to force a fresh `labeled` webhook event for label-gated dispatch to
# re-trigger on. Never fails the caller's script — a missed re-dispatch is
# not worth aborting an otherwise-successful run over.
# Note: parameter is target_pr (not pr_number) to avoid SC2153 against
# PR_NUMBER once this lib is bundled into post-fix.sh alongside it — same
# reasoning as maybe_assign_pr's target_pr in pr-assignee.lib.sh.
# Args: repo_full_name target_pr label token
retrigger_via_label() {
  local repo_full_name="$1" target_pr="$2" label="$3" token="$4"

  # Determine ground truth before attempting anything. --add-label is
  # idempotent: if --remove-label fails for a genuine reason (transient API
  # error, permission issue) while the label is actually still present, the
  # subsequent --add-label trivially "succeeds" as a no-op — no
  # absent-to-present transition happens, no fresh labeled event fires, and
  # the whole retrigger silently no-ops. Without knowing whether the label
  # was actually present beforehand, a --remove-label failure can't be told
  # apart from the benign "label wasn't there" case, so a genuine failure
  # here would otherwise only ever produce the same reassuring-sounding
  # notice as the harmless case.
  local labels_before
  labels_before="$(GH_TOKEN="${token}" gh pr view "${target_pr}" --repo "${repo_full_name}" \
       --json labels --jq '.labels[].name' 2>/dev/null)" || labels_before=""
  local label_was_present="false"
  if printf '%s\n' "${labels_before}" | grep -qxF "${label}"; then
    label_was_present="true"
  fi

  # Capture combined output via command substitution rather than mktemp, and
  # flatten via pure bash parameter expansion rather than a `tr | tr` pipe.
  # This function runs in the caller's shell (sourced, not a subshell) under
  # post-fix.src.sh's `set -euo pipefail` — an external mktemp failure, or a
  # pipefail-tripped pipe, would abort the whole post-fix script here despite
  # this function's contract to never fail the caller. Pure bash builtins
  # (command substitution, ${var//pat/repl}) can't trip errexit/pipefail the
  # same way external-process pipelines can.
  local remove_output
  if ! remove_output="$(GH_TOKEN="${token}" gh pr edit "${target_pr}" --repo "${repo_full_name}" \
       --remove-label "${label}" 2>&1)"; then
    # Flatten embedded newlines/CRs first — sanitize_gha_log_output strips
    # "::" and percent-encoded %0A/%0D but not literal line breaks, which
    # would otherwise split this across multiple raw output lines.
    local flattened_err="${remove_output//$'\r'/}"
    flattened_err="${flattened_err//$'\n'/ }"
    if [ "${label_was_present}" = "true" ]; then
      # The label WAS present and removal still failed — a genuine problem,
      # not the benign "wasn't there" case. The upcoming --add-label call
      # will silently no-op against this already-present label, so this is
      # the retrigger's last chance to surface that it's about to fail.
      _relabel_retrigger_warn "Failed to remove ${label} label from ${repo_full_name}#${target_pr} even though it was present — dispatch will likely not be re-triggered: ${flattened_err}"
    else
      # Expected when the label wasn't present (e.g. a human-authored PR
      # that never went through the code agent's PR-open labeling, or
      # labels_before itself couldn't be fetched) — genuinely benign.
      _relabel_retrigger_notice "Could not remove ${label} label from ${repo_full_name}#${target_pr} (was not present): ${flattened_err}"
    fi
  fi

  local add_output
  if ! add_output="$(GH_TOKEN="${token}" gh pr edit "${target_pr}" --repo "${repo_full_name}" \
       --add-label "${label}" 2>&1)"; then
    local flattened_add_err="${add_output//$'\r'/}"
    flattened_add_err="${flattened_add_err//$'\n'/ }"
    _relabel_retrigger_warn "Failed to re-apply ${label} label to ${repo_full_name}#${target_pr} — dispatch will not be re-triggered: ${flattened_add_err}"
  fi

  return 0
}

# Strip the same GHA workflow-command-injection vectors gha_echo's own
# sanitizer targets (:: and percent-encoded %0A/%0D), for the fallback path
# below. Currently unreachable from post-fix.src.sh (gha_echo is always
# available via post-failure-report.lib.sh there), but this library is
# meant to be sourced by other agent post-scripts too, and a future caller
# without that dependency shouldn't get unsanitized fallback output.
_relabel_retrigger_sanitize_fallback() {
  local value="$1"
  value="${value//::/}"
  value="${value//%0A/}"
  value="${value//%0a/}"
  value="${value//%0D/}"
  value="${value//%0d/}"
  printf '%s' "${value}"
}

# Emit via gha_echo when available (sanitizes :: / %0A / %0D), else a
# sanitized plain fallback — the gha_echo-when-available/plain-echo-otherwise
# structure follows pr-assignee.lib.sh's _pr_assignee_warn convention, but
# that function's own fallback path doesn't sanitize; this one does.
_relabel_retrigger_notice() {
  if declare -F gha_echo >/dev/null 2>&1; then
    gha_echo notice "$*"
  else
    echo "notice: $(_relabel_retrigger_sanitize_fallback "$*")"
  fi
}

_relabel_retrigger_warn() {
  if declare -F gha_echo >/dev/null 2>&1; then
    gha_echo warning "$*"
  else
    echo "warning: $(_relabel_retrigger_sanitize_fallback "$*")" >&2
  fi
}
